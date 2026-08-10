# Kernel module signing (consumer side)

This repo doesn't build or sign `amneziawg.ko` - that's `../talos-kernel`, see its own
`docs/kernel-signing.md` for the full mechanism (why `sig_enforce` can stay on, why a
lighter "just swap the kernel" approach doesn't work, how the signing key ends up shared
between the kernel and the module). This doc covers only what's specific to *this* repo:
turning an already-signed module into an actual Talos system extension.

## Packaging: `siderolabs/extensions`, not a local Dockerfile

The module coming out of `../talos-kernel`'s `amneziawg-pkg` is already signed correctly
- turning it into an actual Talos system extension is a separate, unrelated concern
(manifest metadata, the `ext-awg` binary, the container spec), and siderolabs has a
sanctioned way to do that too: `siderolabs/extensions`, the same repo `zfs`'s own
userspace-facing half lives in. Its `storage/zfs/pkg.yaml` pulls in `zfs-pkg` (the
module, from `pkgs`) as a plain OCI-image dependency and copies the already-signed `.ko`
files across - no recompilation, so the signature travels untouched:

```yaml
dependencies:
  - stage: base
  - image: "{{ .BUILD_ARG_PKGS_PREFIX }}/zfs-pkg:{{ .BUILD_ARG_PKGS }}"
steps:
  - install:
      - cp -R /usr/lib/modules/* /rootfs/usr/lib/modules/
```

`patches/extensions/amneziawg/pkg.yaml` mirrors this exactly for `amneziawg-pkg` (built in
`../talos-kernel`), plus staging in the `ext-awg` binary (cross-compiled by `make agents`,
copied in by `make extension` as a local file the package directory's own `install:` step
reads from `/pkg/awg-bin` - the same mechanism `zfs`'s own `install:` step uses to read
its `/pkg/zfs-service.yaml`: any file placed next to a package's `pkg.yaml` is available
under `/pkg/` inside that package's build). `manifest.yaml.tmpl` + `vars.yaml` render the
extension's metadata the same way `zfs`'s own do.

`PKGS_PREFIX`/`PKGS` build-args (see the `extension` target in the `Makefile`) point at
`../talos-kernel`'s published `amneziawg-pkg` image - reconstructed from this repo's own
`TALOS_VERSION`/`AWG_REF` pins, which must match that repo's `versions.env` exactly (see
README, "This is one of five repos"). If they don't match, `docker-amneziawg` fails to
resolve the dependency image outright - a fast, loud failure, not a silent wrong-kernel
mismatch.

## Verifying it worked

`patches/extensions/amneziawg/pkg.yaml`'s own `test:` step asserts
`~Module signature appended~` is present in the `.ko` it packages, *and* runs siderolabs'
own `extensions-validator` against the assembled manifest/rootfs - a build that completes
has already proven both the module is signed and the extension is structurally valid, not
just that it compiled. On a real node, after `talos-installer` bundles this extension
into an installer and `talosctl upgrade` applies it:

```sh
talosctl -n <node> dmesg | grep -i "amneziawg\|sig"
talosctl -n <node> get extensions
```

should show the module loading cleanly, with no "unsigned module" or "module
verification failed" anywhere in the log, and `amneziawg` listed with the version this
repo just published.
