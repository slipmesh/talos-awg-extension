# talos-awg-extension

Builds the **AmneziaWG** Talos system extension — the DPI-obfuscated WireGuard fork's
kernel module, packaged so Talos can load it, plus `ext-awg`, the extension service that
actually configures AmneziaWG interfaces (mesh links and/or road-warrior peers) on the
node from a static config — see `docs/extension-services.md`.

Builds with **podman**, on any machine, for any target architecture.

## How it works

A Talos system extension is just a container image holding a `manifest.yaml` and a
`rootfs/`. The only hard part is the module inside it, which must be compiled against
exactly the kernel the nodes boot — same version, same config, same patches.

siderolabs build that kernel with `bldr`, a custom BuildKit frontend that podman/buildah
cannot run (their `Pkgfile`s aren't even Dockerfiles). Instead, this project assembles
the same environment they use — their `tools` image with their `llvm` image overlaid,
see `Dockerfile.builder` — and runs the kernel and module steps in it directly with
plain podman.

```
versions.env          every pin: Talos version, pkgs commit, AWG ref, target arch, image
Dockerfile.builder    siderolabs tools + llvm, merged into a build environment
Dockerfile.extension  FROM scratch + manifest + rootfs
scripts/
  prepare-kernel.sh   patch/configure the kernel tree so modules can build against it
  build-module.sh     compile amneziawg.ko, strip it, assert it is real
manifest.yaml.in      extension manifest, @VERSION@ substituted at build time
docs/
  extension-services.md  ext-awg: config schema, machine config example, verification
build/                (gitignored) pkgs checkout, kernel tree, downloads, output
```

Only `pkgs` is cloned, purely as the source of the kernel config, signing certs, patch
set and the pinned kernel version. `build/` is disposable: `make distclean && make all
TARGET_ARCH=<arch>` reproduces it.

`ext-awg` itself — a Rust binary, no relation to the kernel-build toolchain above — lives in
the sibling repo `../talos-extensions` and is cross-compiled + staged into `build/out-<arch>/
rootfs/` by `make agents` (part of `make all`/`make extension`, see "Usage" below). See that
repo's README for what it does; see `docs/extension-services.md` here for how it's configured
and packaged into this extension.

## Cross-architecture

`TARGET_ARCH` (amd64 or arm64) is the *nodes'* architecture, not necessarily the build
machine's — clang cross-compiles natively, so building amd64 on an aarch64 workstation is
a normal native-speed build, not the QEMU emulation the bldr path would need for a
foreign target. There's no default; every target needs it explicitly, or use
`make release` to build both:

```sh
make all TARGET_ARCH=amd64
make all TARGET_ARCH=arm64
```

The resulting image is tagged with the target arch (`podman build --arch`), so an amd64
module never ends up in an image advertising arm64.

## Pinning

A module built against the wrong kernel carries the wrong `vermagic` and will not load.
Talos declares which pkgs it was built from, so the pkgs pin is derivable:

```sh
curl https://raw.githubusercontent.com/siderolabs/talos/$TALOS_VERSION/pkg/machinery/gendata/data/pkgs
```

For `v1.13.8` that is `v1.13.0-55-gf677246` — commit `f677246`, whose Pkgfile pins
`linux_version: 6.18.42`. `make check-pins` asserts this and runs as part of `make all`.

## Kernel prep

`prepare-kernel.sh` builds `vmlinux` from Talos' config unmodified — including
`CONFIG_DEBUG_INFO_BTF_MODULES`, which is not optional: it changes the size of
`struct module` itself. Turn it off and the module's `struct module` no longer matches
the real (BTF-enabled) running kernel's, and the module fails to load with `.gnu.linkonce.
this_module section size must match the kernel's built struct module size at run time` /
`exec format error` — confirmed on a real node. An earlier revision disabled BTF to work
around a `pahole` crash on `vmlinux.unstripped`; that crash no longer reproduces with the
current toolchain pin, so there's nothing left to work around.

One thing that still produces a 0-byte-module extension that installs happily if gotten
wrong:

- **No `Module.symvers`** — `modules_prepare` doesn't produce one, and a full
  `make modules` would double the build for something never shipped. Without it modpost
  turns every imported kernel symbol into a hard `undefined!`, so `build-module.sh` sets
  `KBUILD_MODPOST_WARN=1`. The kernel tolerates the resulting module having no
  `__versions` section, at the cost of symbol-CRC checking — `check-pins` covers that gap
  instead. To get CRC checking back, add `make -j $(nproc) modules` to `prepare-kernel.sh`.

## Module signing

The module isn't signed by the key the stock Talos kernel trusts (that key is a
build-time throwaway the kernel generates fresh on every build and never exports — not
reproducible by us, and not fixable by switching build tooling), so any image baking it
in needs to turn off `sig_enforce`. It must be baked into the image, not set via machine
config: it's a kernel argument, and `extraKernelArgs` only takes effect after the install
that already needs it.

The base installer already carries `module.sig_enforce=1`, and `sig_enforce` is a
`bool_enable_only` module param — once on, a later `module.sig_enforce=0` on the same
cmdline is silently ignored (confirmed on a real node: both were in `/proc/cmdline`, but
`/sys/module/module/parameters/sig_enforce` stayed `Y`). The fix is `-module.sig_enforce`
(the `-` prefix), which removes the base arg instead of losing an override race against it.

## Usage

Every target below needs `TARGET_ARCH=amd64` or `TARGET_ARCH=arm64` (no default — see
"Cross-architecture"); `export TARGET_ARCH=amd64` once, or pass it per invocation.

```sh
make print-config   # resolved pins, arch, image names
make preflight      # podman/git/curl/cargo/cargo-zigbuild present, >=40G free
make agents         # cross-compile ext-awg from ../talos-extensions, stage into the rootfs
make all            # toolchain -> kernel -> module -> agents -> extension image
make installer      # publish the extension, then bake it into an installer (this arch)
make push           # publish this arch's installer tag
make shell          # interactive shell in the build environment, for debugging
```

`installer`/`push` work on one `TARGET_ARCH` at a time and tag/publish
`installer-<talos>-awg-<arch>`. The tag nodes actually pull is the arch-less
`installer-<talos>-awg`, a multi-arch manifest combining whichever of those are in the
registry:

```sh
make release   # builds+pushes every ARCHS entry, then publishes the multi-arch tag
```

Then, per node:

```sh
talosctl -n <node> upgrade --image docker.io/ffaxl/talos:installer-<talos>-awg
```

Bare-metal `dd` installs are assembled elsewhere, from this published installer tag —
out of scope here.

## Publishing the extension

Image Factory only assembles extensions from its own catalog by name — there's no way to
feed it an arbitrary image. So the extension is baked into the installer locally, by
`make installer`, via `imager`'s stdin profile format rather than its
`--system-extension-image` flag (broken in v1.13.7 — always ends up with an empty image
reference).

That profile's `systemExtensions` only takes a registry reference, not a local path — so
`bake` tags the just-built extension as `extension-<talos>-awg-<arch>` and pushes it to
`docker.io/ffaxl/talos` before every `make installer` invokes imager. Nodes never pull
this tag themselves: they get everything already baked into the installer's initramfs.

`baseInstaller` is different: it carries both an `ociPath` (what's actually read — a
local OCI layout `make installer` exports with `podman push --format oci`, patching a
`platform` onto the index with `jq` since podman's `oci:` transport doesn't stamp one and
imager needs it to pick the arch) and an `imageRef`, used only to *name* the image inside
the output tarball. Pointing that at our own `INSTALLER_IMAGE` (instead of the real
`ghcr.io/siderolabs/installer:<ver>`) means `podman load` writes our tag directly, and
the real upstream tag is never touched.

Requires podman, git, curl, jq, ~40 GB free and a couple of hours of CPU (the kernel is
the slow part; the module itself takes seconds). The prepared kernel tree is kept in
`build/kernel-$TARGET_ARCH` and reused — `make module` after a code change is fast.
`make clean` keeps it; `make distclean` doesn't.

Loading the module also needs the machine config to ask for it:

```yaml
machine:
  kernel:
    modules:
      - name: amneziawg
```

The installer is ~192 MB (~103 MB UKI + ~43 MB installer binary); the module itself adds
~240 KB — comparing sizes with/without the extension is a quick sanity check that it went
in.

## Verifying a build

An extension with no module in it installs happily and only shows up later as "the
module never loaded" — check the artifact, not just the exit code:

```sh
file build/out-amd64/rootfs/usr/lib/modules/*/extras/amneziawg.ko   # ELF ... x86-64
modinfo <the .ko> | grep vermagic                                   # must match the nodes
podman image inspect <image> --format '{{.Architecture}}'
talosctl -n <node> get extensions                                   # amneziawg <ver>
talosctl -n <node> read /proc/modules | grep amneziawg
```

## Bumping

**Talos:** set `TALOS_VERSION`, update `UPSTREAM_PKGS_REF` to whatever the command under
"Pinning" returns, `make check-pins`, then `make distclean && make all TARGET_ARCH=<arch>`
(the kernel tree must be rebuilt).

**AmneziaWG:** set `AWG_REF`, run `make hashes`, paste the value back,
`make module TARGET_ARCH=<arch>`.
