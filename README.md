# talos-awg-extension

Builds the **AmneziaWG** Talos system extension — the DPI-obfuscated WireGuard fork's
kernel module, packaged so Talos can load it.

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
build/                (gitignored) pkgs checkout, kernel tree, downloads, output
```

Only `pkgs` is cloned, purely as the source of the kernel config, signing certs, patch
set and the pinned kernel version. `build/` is disposable: `make distclean && make all
TARGET_ARCH=<arch>` reproduces it.

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

For `v1.13.7` that is `v1.13.0-49-g91fe0a0` — commit `91fe0a0`, whose Pkgfile pins
`linux_version: 6.18.39`. `make check-pins` asserts this and runs as part of `make all`.

## Kernel prep

Both of these produce a 0-byte-module extension that installs happily if gotten wrong:

- **BTF off entirely**, not just `CONFIG_DEBUG_INFO_BTF_MODULES` — otherwise
  `make vmlinux` dies running pahole over `vmlinux.unstripped`.
- **No `Module.symvers`** — `modules_prepare` doesn't produce one, and a full
  `make modules` would double the build for something never shipped. Without it modpost
  turns every imported kernel symbol into a hard `undefined!`, so `build-module.sh` sets
  `KBUILD_MODPOST_WARN=1`. The kernel tolerates the resulting module having no
  `__versions` section, at the cost of symbol-CRC checking — `check-pins` covers that gap
  instead. To get CRC checking back, add `make -j $(nproc) modules` to `prepare-kernel.sh`.

## Module signing

The module isn't signed by the key the stock Talos kernel trusts, so any image baking it
in needs `--extra-kernel-arg module.sig_enforce=0` — without it the kernel silently
refuses to load the module. It must be baked into the image, not set via machine config:
it's a kernel argument, and `extraKernelArgs` only takes effect after the install that
already needs it.

## Usage

Every target below needs `TARGET_ARCH=amd64` or `TARGET_ARCH=arm64` (no default — see
"Cross-architecture"); `export TARGET_ARCH=amd64` once, or pass it per invocation.

```sh
make print-config   # resolved pins, arch, image names
make preflight      # podman/git/curl present, >=40G free
make all            # toolchain -> kernel -> module -> extension image
make installer      # bake the extension into an installer image (this arch only)
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

## Why the extension is never published

Image Factory only assembles extensions from its own catalog by name — there's no way to
feed it an arbitrary image. So the extension is baked into the installer locally, by
`make installer`, via `imager`'s stdin profile format rather than its
`--system-extension-image` flag (broken in v1.13.7 — always ends up with an empty image
reference).

That profile accepts extensions and the base installer as `ociPath: <dir>`, a plain local
OCI layout read straight off disk — no registry involved. `make installer` exports both
images to such directories with `podman push --format oci` (patching a `platform` onto
the index with `jq`, since podman's `oci:` transport doesn't stamp one, and imager needs
it to pick the arch). This is also why the extension itself is never published: nothing
ever needs to pull it over a registry, so it stays `localhost/amneziawg:...`.

One more quirk: `baseInstaller` also has an `imageRef`, used only to *name* the image
inside the output tarball, not to fetch it. Pointing that at our own `INSTALLER_IMAGE`
(instead of the real `ghcr.io/siderolabs/installer:<ver>`) means `podman load` writes our
tag directly, and the real upstream tag is never touched.

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
