# talos-awg-extension

Builds the **AmneziaWG** Talos system extension — the DPI-obfuscated WireGuard fork's
kernel module, packaged so Talos can load it, plus `ext-awg`, the extension service that
actually configures AmneziaWG interfaces (mesh links and/or road-warrior peers) on the
node from a static config — see `docs/extension-services.md`.

Builds with **Docker** (`docker buildx`), on any machine, for any target architecture.
The module is signed by the same key the kernel it ships with trusts, so Talos's own
module signature enforcement (`sig_enforce`) stays on — no workaround, no key of our own
to manage. See `docs/kernel-signing.md` for the full mechanism and why it needs Docker.

## How it works

A Talos system extension is just a container image holding a `manifest.yaml` and a
`rootfs/`. The hard part is the module inside it: it must be compiled against exactly the
kernel the nodes boot (same version, same config, same patches) *and* signed by a key
that kernel's own module-signature verification trusts.

siderolabs already has a sanctioned way to do both at once — the same one their own ZFS
and Gasket-driver extensions use: compile the out-of-tree module *inside* the same
`bldr`/BuildKit session that builds the kernel package itself
(`siderolabs/pkgs`'s `kernel-build` stage), so both come out signed by the one throwaway
key that build generates. This repo now follows that path directly instead of
hand-rolling kernel prep with a bare kernel tree and a disabled signature check — no more
podman workaround, no more `-module.sig_enforce`.

```
versions.env            every pin: Talos version, pkgs/extensions commits, AWG ref, image
patches/
  pkgs/amneziawg-pkg/    overlaid onto a siderolabs/pkgs checkout - builds the module
                         alongside the kernel, shares its signing key
  extensions/awg/        overlaid onto a siderolabs/extensions checkout - packages the
                         signed module + ext-awg into an actual Talos system extension
docs/
  kernel-signing.md      the full mechanism: why this works, why lighter alternatives don't
  extension-services.md  ext-awg: config schema, machine config example, verification
build/                  (gitignored) the three checkouts above, plus imager output
```

`build/` is disposable: `make distclean && make all TARGET_ARCH=<arch>` reproduces it
from `versions.env` and `patches/` alone.

`ext-awg` itself — a Rust binary, unrelated to any of the above — lives in the sibling
repo `../talos-extensions` and is cross-compiled by `make agents`, then handed to the
`siderolabs/extensions` checkout for packaging alongside the module (part of
`make extension`, see "Usage" below). See that repo's README for what it does; see
`docs/extension-services.md` here for how it's configured and packaged into this
extension.

## Cross-architecture

`TARGET_ARCH` (amd64 or arm64) is the *nodes'* architecture, not necessarily the build
machine's. The kernel+module build (`make kernel`) is arch-independent — it's a single
multi-platform `docker buildx` invocation covering both `linux/amd64` and `linux/arm64`
at once, same as upstream's own release process. Everything downstream of that
(`extension`, `installer`) is per-arch, same as before:

```sh
make all TARGET_ARCH=amd64
make all TARGET_ARCH=arm64
```

Building for a foreign target arch runs under QEMU emulation (`docker buildx` registers
this automatically) rather than natively — slower than the old clang-cross-compiles-
natively approach, but this is what siderolabs' own pipeline does too; there's no way to
avoid it while sharing their actual kernel-build signing mechanism.

## Pinning

A module built against the wrong kernel carries the wrong `vermagic` and will not load.
Talos declares which pkgs it was built from, so the pkgs pin is derivable:

```sh
curl https://raw.githubusercontent.com/siderolabs/talos/$TALOS_VERSION/pkg/machinery/gendata/data/pkgs
```

For `v1.13.8` that is `v1.13.0-55-gf677246` — commit `f677246`, whose Pkgfile pins
`linux_version: 6.18.42`. `make check-pins` asserts this and runs as part of `make all`.

`UPSTREAM_EXTENSIONS_REF` (which commit of `siderolabs/extensions` packages the module
into an actual system extension) isn't coupled to the Talos version the same way — it
only consumes an OCI image reference, not source-level kernel state — so it can be bumped
independently, whenever.

## Module signing

See `docs/kernel-signing.md` for the full story. Short version: the module is compiled
inside the same BuildKit session as the kernel package (`make kernel`, below), so it gets
signed by the same per-build key the running kernel's `CONFIG_SYSTEM_TRUSTED_KEYRING`
trusts — no `sig_enforce=0`, no MOK enrollment, no persistent PKI of our own to manage.

## Usage

Every target below except `kernel`/`checkout-*`/`release`/`push-manifest`/`distclean`/
`help`/`hashes`/`check-pins` needs `TARGET_ARCH=amd64` or `TARGET_ARCH=arm64` (no default
— `export TARGET_ARCH=amd64` once, or pass it per invocation):

```sh
make print-config   # resolved pins, arch, image names
make preflight       # docker/buildx/git/curl/jq/cargo/cargo-zigbuild present, >=40G free
make kernel           # build the kernel + amneziawg module together, push both (arch-independent)
make agents            # cross-compile ext-awg from ../talos-extensions
make extension           # package module + ext-awg into a Talos system extension (this arch)
make all                  # preflight -> check-pins -> extension, the full local build
make installer              # bake an installer image (this arch) - what `talosctl upgrade` pulls
make push                     # publish this arch's installer tag
make shell                     # n/a - see docs/kernel-signing.md for interactive debugging
```

`installer`/`push` work on one `TARGET_ARCH` at a time and tag/publish
`installer-<talos>-awg-<agents-sha>-<arch>` (`<agents-sha>` is `../talos-extensions`'
own commit - included so a rebuild after fixing something there always gets a genuinely
new tag; re-pushing under a tag that's already been pushed before has been observed to
*not* reliably reach a node on `talosctl upgrade`, confirmed directly - see AGENTS.md).
The tag nodes actually pull is the arch-less `installer-<talos>-awg-<agents-sha>`, a
multi-arch manifest combining whichever of those are in the registry:

```sh
make release   # builds+pushes every ARCHS entry, then publishes the multi-arch tag
```

Then, per node (check `make print-config` for the exact current tag):

```sh
talosctl -n <node> upgrade --image docker.io/ffaxl/talos:installer-<talos>-awg-<agents-sha>
```

Bare-metal `dd` installs are assembled elsewhere, from this published installer tag —
out of scope here.

## Publishing the extension

Image Factory only assembles extensions from its own catalog by name — there's no way to
feed it an arbitrary image. So the extension is baked into the installer locally, by
`make installer`, via `imager`'s stdin profile format rather than its
`--system-extension-image` flag.

That profile's `systemExtensions` only takes a registry reference, not a local path —
`make extension` already pushes the just-built extension straight to
`docker.io/ffaxl/talos` (via `docker buildx build --push`), so it's already there by the
time `make installer` invokes imager. Nodes never pull this tag themselves: they get
everything already baked into the installer's initramfs.

`baseInstaller` is different: it carries both an `ociPath` (what's actually read for
everything except kernel/initramfs — rootfs, sd-boot/sd-stub etc — a local OCI layout
`make installer` exports via `docker buildx build --output=type=oci`, patching a
`platform` onto the index with `jq` since that exporter doesn't stamp one and imager
needs it to pick the arch) and an `imageRef`, used only to *name* the image inside the
output tarball. Pointing that at our own `INSTALLER_IMAGE` (instead of the real
`ghcr.io/siderolabs/installer:<ver>`) means `docker load` writes our tag directly, and the
real upstream tag is never touched.

Kernel and initramfs are handled separately from `baseInstaller` entirely — see
`docs/kernel-signing.md`, "Getting the signed kernel into the final installer" for why
and how.

Requires Docker (with `buildx`), git, curl, jq, ~40 GB free and a couple of hours of CPU
for `make kernel` (the slow step, shared once across both arches); everything after it is
fast.

Loading the module also needs the machine config to ask for it:

```yaml
machine:
  kernel:
    modules:
      - name: amneziawg
```

## Verifying a build

An extension with no module in it installs happily and only shows up later as "the
module never loaded" — check the artifact, not just the exit code. The
`amneziawg-pkg`/`awg` `pkg.yaml` packages both assert this themselves at build time
(`grep -FL '~Module signature appended~'` over every `.ko`, the same check siderolabs'
own zfs/gasket-driver packages run) — a build that completes has already proven its
module is signed. On top of that:

```sh
docker buildx imagetools inspect <image>                            # arch, manifest
talosctl -n <node> get extensions                                   # amneziawg <ver>
talosctl -n <node> read /proc/modules | grep amneziawg
talosctl -n <node> dmesg | grep -i "amneziawg\|sig"                 # no "unsigned module" anywhere
```

## Bumping

**Talos:** set `TALOS_VERSION`, update `UPSTREAM_PKGS_REF` to whatever the command under
"Pinning" returns, `make check-pins`, then `make distclean && make all TARGET_ARCH=<arch>`.

**AmneziaWG:** set `AWG_REF`, run `make hashes`, paste both values back, `make kernel`
(rebuilds kernel+module together — required, not optional, since a lone `amneziawg-pkg`
rebuild against a stale cached `kernel-build` stage would still work correctly, but
there's no way to rebuild *only* the module and skip the kernel half of the shared build).

**siderolabs/extensions:** bump `UPSTREAM_EXTENSIONS_REF` freely; it only needs to
resolve, no coupling to the Talos version.
