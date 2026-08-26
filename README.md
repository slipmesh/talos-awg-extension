# talos-awg-extension

Packages the **AmneziaWG** Talos system extension — the DPI-obfuscated WireGuard fork's
kernel module (built and signed in `talos-kernel`), plus `ext-awg`, the extension
service that actually configures AmneziaWG interfaces (mesh links and/or road-warrior
peers) on the node from a static config — see `docs/extension-services.md`.

Builds with **Docker** (`docker buildx`), on any machine, for any target architecture.
The module is signed by the same key the kernel it ships with trusts, so Talos's own
module signature enforcement (`sig_enforce`) stays on — no workaround, no key of our own
to manage. See `docs/kernel-signing.md` for how this repo consumes that (built in
`talos-kernel`, not here).

## This is one of five repos

- [talos-kernel](https://github.com/slipmesh/talos-kernel) —
  signed kernel + `amneziawg-pkg`
- [talos-awg-extension](https://github.com/slipmesh/talos-awg-extension) —
  amneziawg system extension (pulls `amneziawg-pkg`) — **this repo**
- [talos-router-extension](https://github.com/slipmesh/talos-router-extension) —
  router system extension (no kernel dependency)
- [talos-nftables-extension](https://github.com/slipmesh/talos-nftables-extension) —
  nftables system extension (no kernel dependency)
- [talos-installer](https://github.com/slipmesh/talos-installer) —
  assembles a kernel + N extensions into an installer

Each repo builds and publishes independently — none check out or depend on each other's
source, only on each other's published OCI tags. This repo needs `talos-kernel`'s
`amneziawg-pkg` image to already be published (`make kernel` there) before `make
extension` here can resolve it — `preflight` checks for it. Its `versions.env`'s
`TALOS_VERSION`/`AWG_REF` must match `talos-kernel`'s exactly, or the dependency image
reference won't resolve at all (a fast, loud failure, not a silent wrong-kernel mismatch).

### One checkout it does need

`make agents` cross-compiles the daemon out of
[talos-extensions](https://github.com/slipmesh/talos-extensions), so that repository has to exist
on disk - it's the one thing here that isn't consumed as a published image. The default is a
sibling checkout, `AGENTS_DIR := ../talos-extensions`; clone the two side by side, or point it
anywhere:

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=... AGENTS_DIR=/path/to/talos-extensions
```

`preflight` fails loudly if the directory isn't there.

## How it works

A Talos system extension is just a container image holding a `manifest.yaml` and a
`rootfs/`. siderolabs has a sanctioned way to package an already-signed out-of-tree
module into one — the same one their own ZFS extension uses:
`siderolabs/extensions`' own `pkg.yaml`/`bldr` pipeline, pulling the module in as a plain
OCI-image dependency (no recompilation, so the signature travels untouched).

```text
versions.env             every pin: Talos version, extensions commit, AWG ref, image
patches/
  extensions/amneziawg/  overlaid onto a siderolabs/extensions checkout - packages the
                          signed module (from ../talos-kernel) + ext-awg into an extension
docs/
  kernel-signing.md       the consumer-side half: packaging an already-signed module
  extension-services.md   ext-awg: config schema, machine config example, verification
build/                   (gitignored) the extensions checkout
```

`build/` is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces
it from `versions.env` and `patches/` alone.

`ext-awg` itself — a Rust binary, unrelated to any of the above — lives in the sibling
repo `talos-extensions` and is cross-compiled by `make agents`, then handed to the
`siderolabs/extensions` checkout for packaging alongside the module (part of
`make extension`, see "Usage" below). See that repo's README for what it does; see
`docs/extension-services.md` here for how it's configured and packaged into this
extension.

## Cross-architecture

`TARGET_ARCH` (amd64 or arm64) is the *nodes'* architecture, not necessarily the build
machine's:

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=v0.1.2+talos1.13.9
make extension TARGET_ARCH=arm64 RELEASE_TAG=v0.1.2+talos1.13.9
```

Building for a foreign target arch locally runs under QEMU emulation (`docker buildx`
registers this automatically). CI never does: each arch builds on a runner of its own
architecture.

## Pinning

`TALOS_VERSION`/`AWG_REF` should match `talos-kernel`'s `versions.env` - purely an
informational cross-check now (still folded into `EXT_VERSION`), not used to build
anything here. `KERNEL_RELEASE` is what actually names the `amneziawg-pkg` image this
build consumes - it's `talos-kernel`'s own release tag (see that repo's Makefile),
bumped by hand after a new talos-kernel release.

`UPSTREAM_EXTENSIONS_REF` (which commit of `siderolabs/extensions` packages the module
into an actual system extension) isn't coupled to the Talos version — it only consumes an
OCI image reference, not source-level kernel state — so it can be bumped independently,
whenever; `make checkout-extensions` just needs it to resolve.

## Usage

Every target below except `distclean`/`help`/`hashes`/`checkout-extensions` needs
`TARGET_ARCH=amd64` or `TARGET_ARCH=arm64` and `RELEASE_TAG=<the git tag being released>`
(no defaults — `export TARGET_ARCH=amd64` once, or pass either per invocation). Like
`bird`, `RELEASE_TAG` *is* the published image tag (`+` swapped for `-`, since OCI tags
can't contain `+`) - see `cliff.toml`'s `tag_pattern` for the exact shape
(`vX.Y.Z[+talosA.B.C]`).

```sh
make print-config   # resolved pins, arch, image names
make preflight       # docker/buildx/git/curl/cargo/cargo-zigbuild present, amneziawg-pkg exists
make agents            # cross-compile ext-awg from ../talos-extensions
make extension           # package module + ext-awg into a Talos system extension (this arch)
make all                   # preflight -> extension, the full local build
```

`make extension` pushes straight to `ghcr.io/slipmesh/talos-awg-extension` and prints the
tag — `talos-installer` needs that ref to bundle it into an installer. Build both
arches you need before handing off to `talos-installer`.

## Verifying a build

An extension with no module in it installs happily and only shows up later as "the
module never loaded" — check the artifact, not just the exit code. The
`amneziawg`/`pkg.yaml` package asserts this itself at build time
(`grep -FL '~Module signature appended~'` over the `.ko`, the same check siderolabs' own
zfs package runs) plus siderolabs' own `extensions-validator` against the assembled
manifest/rootfs — a build that completes has already proven both. On top of that:

```sh
docker buildx imagetools inspect <image>   # arch, manifest
```

Full node-level verification (module loaded, `sig_enforce` on, `ext-awg` running) happens
after `talos-installer` bundles this extension and a node runs `talosctl upgrade` — see
that repo's README.

## Bumping

**Talos/AmneziaWG:** bump `talos-kernel` first (its own README, "Bumping") and cut a
release there, then set `KERNEL_RELEASE` here to that release's tag (and copy
`TALOS_VERSION`/`AWG_REF` too, for the cross-check), then `make extension
TARGET_ARCH=<arch> RELEASE_TAG=<this repo's own new release tag>`.

**siderolabs/extensions:** bump `UPSTREAM_EXTENSIONS_REF` freely; it only needs to
resolve, no coupling to the Talos version.

**ext-awg:** any commit in `talos-extensions` — `make extension` always picks up
whatever's currently checked out there (see `AGENTS_SHA` in the `Makefile`, still folded
into `EXT_VERSION`); cut a new release (`RELEASE_TAG`) to publish under a fresh tag.
