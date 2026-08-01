# talos-awg-extension

Builds the **AmneziaWG** Talos system extension — the DPI-obfuscated WireGuard fork's
kernel module, packaged so Talos can load it. The `mesh` and `roadwarriors` operators
(see `../operators`) talk to that module over the `amneziawg` genl family; without this
extension they have nothing to talk to.

Builds with **podman**, on any machine, for any target architecture.

## How it works

A Talos system extension is just a container image holding a `manifest.yaml` and a
`rootfs/`. The only hard part is the module inside it, which must be compiled against
exactly the kernel the nodes boot — same version, same config, same patches.

siderolabs build that kernel with `bldr`, a custom BuildKit frontend. That is a dead end
here: their `Pkgfile`s are YAML, not Dockerfiles, and podman/buildah cannot execute
custom frontends at all (`podman build` on one fails with `stage 1 requires a FROM
instruction`). Rather than drag in Docker for it, this project assembles the *same
environment* they use — their `tools` image (a full rootfs) with their `llvm` image
overlaid, see `Dockerfile.builder` — and runs the kernel and module steps in it
directly. Everything here is plain podman.

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
set and the pinned kernel version — everything else is ours. `build/` is disposable:
`make distclean && make all` reproduces it.

## Cross-architecture

`TARGET_ARCH` (amd64 or arm64) is the architecture of the *nodes*, and need not match
the machine you build on. clang is a cross-compiler by nature, so building amd64 on an
aarch64 workstation is a normal native-speed cross build:

```sh
make all                      # amd64, the default, for this cluster
make all TARGET_ARCH=arm64
```

This is strictly better than the bldr path, where the architecture comes from the
*build platform* and a foreign target means running the entire kernel build under QEMU.
The resulting image is tagged with the target arch (`podman build --arch`), so an amd64
module never ends up in an image advertising arm64.

## Pinning

The pins are not free choices — a module built against the wrong kernel carries the
wrong `vermagic` and will not load. Talos declares which pkgs it was built from, so the
pkgs pin is derivable rather than guessed:

```sh
curl https://raw.githubusercontent.com/siderolabs/talos/$TALOS_VERSION/pkg/machinery/gendata/data/pkgs
```

For `v1.13.7` that is `v1.13.0-49-g91fe0a0` — commit `91fe0a0`, whose Pkgfile pins
`linux_version: 6.18.39`, which is what the cluster runs. `make check-pins` asserts it
and runs as part of `make all`.

This is not hypothetical: an earlier revision inherited pins from the pre-split
experimental tree that build kernel **6.18.40**, one patch ahead of the nodes. The build
would have succeeded and the module would have silently refused to load.

## Two things the kernel prep has to get right

Both were found by watching this fail, and both are why the naive approach produces a
0-byte extension that installs perfectly happily:

- **BTF off entirely**, not just `CONFIG_DEBUG_INFO_BTF_MODULES`. Otherwise
  `make vmlinux` runs pahole over `vmlinux.unstripped` and dies with
  `FAILED: load BTF from vmlinux.unstripped: Invalid argument`.
- **No `Module.symvers`.** `modules_prepare` doesn't produce one — only a full
  `make modules` does, which would rebuild every in-tree module and roughly double the
  build for something we never ship. Without it modpost turns every imported kernel
  symbol into a hard `undefined!`, so `build-module.sh` sets `KBUILD_MODPOST_WARN=1`.
  The module then has no `__versions` section, which the kernel explicitly tolerates
  (`check_version()` returns OK when there is no version info at all). The module that
  has been running on the cluster was built the same way.

  What this gives up is symbol-CRC checking — the thing that would catch an ABI drift
  between the kernel built against and the one booted. `check-pins` replaces that
  guarantee. To get it back, add `make -j $(nproc) modules` to `prepare-kernel.sh`.

## Module signing

The module is not signed by the key the stock Talos kernel trusts — that key is
generated inside siderolabs' own kernel build. So any image baking this extension in
needs `--extra-kernel-arg module.sig_enforce=0`; without it the running kernel silently
refuses to load the module and the extension is inert.

It must be baked into the image, not set in machine config: it is a kernel argument, and
`extraKernelArgs` only takes effect after the install that already needs it. The running
cluster matches — `/proc/cmdline` has `module.sig_enforce=0` while its machine config
does not mention it.

## Usage

```sh
make print-config   # resolved pins, arch, image names
make preflight      # podman/git/curl present, >=40G free
make all            # toolchain -> kernel -> module -> extension image
make installer      # bake the extension into an installer image
make push           # publish the installer - the only thing that gets published
make shell          # interactive shell in the build environment, for debugging
```

Then, per node:

```sh
talosctl -n <node> upgrade --image docker.io/ffaxl/talos:installer-<talos>-awg
```

`make metal` builds a raw disk image instead, for installing from scratch with `dd`.

## Why the extension is not published

The extension image never leaves the build machine, and there is no target to push it -
it is named `localhost/amneziawg:...` so that publishing it is not even expressible.

The nodes never pull it. They pull the *installer*, which already has the module baked
into its initramfs; the extension is an intermediate artifact, closer to an object file
than to a distributable. Publishing it would mean maintaining a second versioned tag
that nothing consumes.

The `--system-extension-image` *CLI flag* only ever produces a registry reference (and is
broken outright in v1.13.7, see below), which is what made it look like a registry was
unavoidable. It isn't: the *profile* format `imager` reads from stdin accepts an
extension as `ociPath: <dir>` instead - a plain local OCI-layout directory, read straight
off disk (`pkg/imager/profile/input.go`, `ContainerAsset.pullFromOCI` -> `layout.FromPath`,
no network call in that path at all). `make installer` exports the extension it just
built to such a directory with `podman push --format oci` and points the profile at it.
Confirmed byte-for-byte identical output to a registry-mediated build. One quirk: podman's
`oci:` transport doesn't stamp a `platform` onto the index descriptor, which imager needs
to pick the arch - `make installer` patches it in with `jq` right after the push.

Requires podman, git, curl, jq, ~40 GB free and a couple of hours of CPU (the kernel is the
slow part; the module itself takes seconds). The prepared kernel tree is kept in
`build/kernel-$TARGET_ARCH` and reused — `make module` after a code change is fast.
`make clean` keeps it; `make distclean` doesn't.

## Verifying a build

An extension with no module in it installs perfectly happily and only shows up later as
"the operators can't reach the kernel", so check the artifact rather than the exit code.
`build-module.sh` asserts the basics itself; beyond that:

```sh
file build/out-amd64/rootfs/usr/lib/modules/*/extras/amneziawg.ko   # ELF ... x86-64
modinfo <the .ko> | grep vermagic                                   # must match the nodes
podman image inspect <image> --format '{{.Architecture}}'
talosctl -n <node> get extensions                                   # amneziawg <ver>
talosctl -n <node> read /proc/modules | grep amneziawg
```

`modinfo`'s `srcversion` is a hash of the module source. This build reports
`C078F40128FCA251A513EC9`, identical to the hand-built module currently running on the
cluster, with the same `version` and `vermagic`.

## Getting it onto the nodes

Image Factory cannot help: it only assembles extensions from **its own catalog**, keyed
by name, and has no field for an arbitrary image reference. Asking it for one produces a
misleading error - `official extension "ffaxl/talos:extension-awg" is not available for
Talos version v1.13.7` - which reads like a version problem but is not: the same error
comes back for every Talos version, because the name is not in the catalog at all (83
entries for v1.13.7, all `siderolabs/*`). A schematic containing it will even be
*created* successfully; it only fails when an image is requested. For the record, the
schematic this cluster was installed from is vanilla - `customization: {}`.

So the extension is baked in locally by `make installer`. Two things that cost time to
discover, both handled there:

- imager's `--system-extension-image` **flag is broken** in v1.13.7 - it ends up with an
  empty image reference (`error pulling image : parsing reference ""`) no matter what
  else you pass. Feeding an equivalent profile on stdin works.
- imager names its output tarball's image after the *base* installer, so loading it
  collides with the official `ghcr.io/siderolabs/installer:<ver>` tag locally. The
  Makefile retags by image ID; do not `podman untag` the collided name, which drops the
  image entirely.

The installer is ~192 MB, of which ~103 MB is the UKI (kernel + initramfs) and ~43 MB the
installer binary. Our module accounts for 240 KB of it - the same image built without the
extension is 240 KB smaller, which is a convenient way to confirm the module really went
in.

Loading the module also needs the machine config to ask for it, which belongs with the
rest of the Talos config, not here:

```yaml
machine:
  kernel:
    modules:
      - name: amneziawg
```

## Bumping

**Talos:** set `TALOS_VERSION`, update `UPSTREAM_PKGS_REF` to whatever the command under
"Pinning" returns, `make check-pins`, then `make distclean && make all` (the kernel tree
must be rebuilt).

**AmneziaWG:** set `AWG_REF`, run `make hashes`, paste the value back, `make module`.
