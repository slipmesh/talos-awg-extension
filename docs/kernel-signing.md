# Kernel module signing

How `amneziawg.ko` ends up signed by a key the running kernel actually trusts, so
`sig_enforce` can stay on — no workaround, no key management of our own.

## The problem

Talos's kernel has `CONFIG_MODULE_SIG=y` / `CONFIG_MODULE_SIG_ALL=y`, and
`CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"` — a file that doesn't exist in
`siderolabs/pkgs`' checked-in source (only a template, `kernel/build/certs/x509.genkey`,
does: `CN = Build time throw-away kernel key`). The first time `make` runs against a
prepared kernel tree, standard kbuild machinery notices the referenced key file is
missing and generates a fresh RSA keypair from that template on the spot, then signs
every module built in that same tree with it. The public half becomes the sole entry in
that kernel's `CONFIG_SYSTEM_TRUSTED_KEYRING`.

That key is never exported anywhere, is different on every siderolabs build, and — this
part matters — **isn't reachable by MOK/Secure Boot enrollment either**:
`CONFIG_SECONDARY_TRUSTED_KEYRING` (the setting that makes module-signature verification
consult the MOK/platform keyring at all) is unset in Talos's kernel config. Confirmed
directly against the checked-out config, not assumed. So building a module and getting it
trusted isn't a question of *where* to enroll a cert — there's nowhere in this kernel's
verification path that would ever look at one.

## What doesn't work: swapping only the kernel

The tempting shortcut is: build our own `vmlinuz` with our own persistent signing key
baked in as the sole trusted entry, keep Talos's stock `initramfs.xz` otherwise
untouched, boot that. It doesn't work, and not for a subtle reason:

Talos's kernel config has `CONFIG_VIRTIO_PCI=m` — a *loadable* module, not built in. On
virtio-based hosts (which includes every QEMU/KVM node — most of what this cluster runs
on), that module is what makes the disk and NIC visible at all. It isn't part of vmlinuz;
it's packaged inside `initramfs.xz`'s own squashfs content (see
`siderolabs/talos`'s `Dockerfile`, the `initramfs-archive-*` stages — the squashfs
rootfs `/init` loads is built into the initramfs itself, from the same `pkg-kernel` stage
as everything else). If our kernel's trusted keyring contains only our own cert, while
`initramfs.xz` still ships modules signed by *siderolabs'* build-time key, `virtio_pci.ko`
fails signature verification under `sig_enforce`, and the node can't see its own disk —
a boot failure, not just "the mesh doesn't come up." `sig_enforce` is one systemwide
policy; a single out-of-place artifact breaks everything sharing that policy, not just
the thing you meant to change.

## What works: build the module *with* the kernel

`siderolabs/pkgs` already has a sanctioned pattern for exactly this, used by two real
out-of-tree modules they ship today — `zfs` and `gasket-driver`. Both compile inside the
*same* BuildKit session as the kernel package itself:

```yaml
# (abbreviated, see zfs/pkg.yaml or gasket-driver/pkg.yaml in siderolabs/pkgs)
dependencies:
  - stage: base
  - stage: kernel-build      # pulls in /src - the kernel's own build tree, certs and all
steps:
  - install:
      - |
        make -C /src M=$(pwd)/src modules_install DESTDIR=/rootfs \
          INSTALL_MOD_PATH=/rootfs/usr INSTALL_MOD_DIR=extras INSTALL_MOD_STRIP=1 \
          CONFIG_MODULE_SIG_ALL=y
  test:
    - find /rootfs/usr/lib/modules -name '*.ko' -exec grep -FL '~Module signature appended~' {} \+
```

`dependencies: [stage: kernel-build]` doesn't rebuild the kernel — it depends on that
BuildKit stage's *output*, which BuildKit serves from its ordinary layer cache once
that stage has run once. The `certs/signing_key.pem` that kbuild auto-generated the first
time `make` touched that tree is part of that cached output. So as long as the cache
between "build the kernel" and "build the module" stays warm (same builder, no
`--no-cache`, no prune in between), both artifacts come from the identical key — not
because of any special coordination, but because BuildKit never re-ran the step that
would have generated a *different* random key.

`patches/pkgs/amneziawg-pkg/pkg.yaml` in this repo does the same thing for `amneziawg`,
built from the pinned `AWG_REF`/`AWG_SHA256`/`AWG_SHA512` in `versions.env` (passed as
`--build-arg`s, since those pins are ours, not upstream pkgs' own `Pkgfile` vars).
`make kernel` builds both together, back to back, against the same warm cache — see the
comment on that target in the `Makefile` for the exact ordering constraint.

No `.kres.yaml` registration is needed for this to work: `bldr` (the tool behind
`docker buildx build --file=Pkgfile`) discovers `pkg.yaml` files by walking the checkout
tree at build time (confirmed against `bldr`'s own source,
`internal/pkg/solver/filesystem_loader.go`) — `.kres.yaml`'s `spec.targets` list only
controls which convenience `make <name>` shortcuts a generated Makefile exposes. The
generic `docker-%`/`target-%`/`local-%` pattern rules every kres-generated Makefile
already carries work for *any* package name, registered or not — `make docker-amneziawg-pkg`
just works once the `pkg.yaml` is on disk.

## Packaging: `siderolabs/extensions`, not a local Dockerfile

The module coming out of `amneziawg-pkg` is already signed correctly — turning it into an
actual Talos system extension is a separate, unrelated concern (manifest metadata, the
`ext-awg` binary, the container spec), and siderolabs has a sanctioned way to do that too:
`siderolabs/extensions`, the same repo `zfs`'s own userspace-facing half lives in. Its
`storage/zfs/pkg.yaml` pulls in `zfs-pkg` (the module, from `pkgs`) as a plain OCI-image
dependency and copies the already-signed `.ko` files across — no recompilation, so the
signature travels untouched:

```yaml
dependencies:
  - stage: base
  - image: "{{ .BUILD_ARG_PKGS_PREFIX }}/zfs-pkg:{{ .BUILD_ARG_PKGS }}"
steps:
  - install:
      - cp -R /usr/lib/modules/* /rootfs/usr/lib/modules/
```

`patches/extensions/awg/pkg.yaml` mirrors this exactly for `amneziawg-pkg`, plus staging
in the `ext-awg` binary (cross-compiled by `make agents`, copied in by `make extension`
as a local file the package directory's own `install:` step reads from `/pkg/awg-bin` —
the same mechanism `zfs`'s own `install:` step uses to read its
`/pkg/zfs-service.yaml`: any file placed next to a package's `pkg.yaml` is available
under `/pkg/` inside that package's build). `manifest.yaml.tmpl` + `vars.yaml` render the
extension's metadata the same way `zfs`'s own do.

## Getting the signed kernel into the final installer

The last step doesn't need a custom-built `imager` tool at all, even though the official
docs' example (`make kernel initramfs imager PKG_KERNEL=...`, run from a
`siderolabs/talos` checkout) reads that way. Two things make a lighter approach both
correct and preferable:

1. `siderolabs/talos`'s own `imager` container has `/usr/install/<arch>/{vmlinuz,
   initramfs.xz}` baked directly into its filesystem at build time (`Dockerfile`, the
   `installer-build`/`imager` stages: `COPY --from=pkg-kernel-amd64 /boot/vmlinuz
   /usr/install/amd64/vmlinuz`, and similarly for the initramfs). `imager`'s own profile
   format reads `input.kernel.path`/`input.initramfs.path` as plain paths *on its own
   container filesystem* (`pkg/imager/profile/input.go`'s `FileAsset{Path string}` —
   nothing baseInstaller-relative about it), independent of whatever `baseInstaller`
   image it's asked to otherwise mutate.
2. Docker lets us override files inside a container at `docker run` time with a bind
   mount — no rebuild required.

So: `make kernel initramfs PKG_KERNEL=<our-kernel-image> DEST=...` in a
`siderolabs/talos` checkout (a *local* output, `local-kernel`/`local-initramfs` — no
`imager` container gets built at all) produces `vmlinuz-<arch>` and
`initramfs-<arch>.xz`, both built against our own kernel package — meaning
`initramfs.xz`'s own squashfs content (including anything like `virtio_pci.ko`) comes
from the *same* coordinated, coherently-signed build as `amneziawg.ko`, not a mismatched
stock one. `make installer`'s `bake` macro then runs the **stock**
`ghcr.io/siderolabs/imager:$(TALOS_VERSION)` — completely unmodified — bind-mounting
those two extracted files over their conventional paths:

```sh
docker run --rm -i --privileged --network host \
  -v $(OUT_DIR):/out:z \
  -v $(CUSTOM_KERNEL_DIR)/vmlinuz-$(TARGET_ARCH):/usr/install/$(TARGET_ARCH)/vmlinuz:ro \
  -v $(CUSTOM_KERNEL_DIR)/initramfs-$(TARGET_ARCH).xz:/usr/install/$(TARGET_ARCH)/initramfs.xz:ro \
  -v /dev:/dev $(IMAGER) - --insecure < profile.yaml
```

Everything else about the installer — rootfs, sd-boot/sd-stub, our system extension via
`systemExtensions` — is untouched, exactly as before. Only the two files a mismatched
signing key could ever actually affect are swapped in.

This also means no separate `imager` image gets built, tagged, or published — one fewer
artifact to track, and the existing `installer`/`push`/`push-manifest`/`release`
targets needed no restructuring beyond the podman→docker verb swap.

## Verifying it worked

Every relevant `pkg.yaml` (`amneziawg-pkg`, `awg`) asserts `~Module signature appended~`
is present in every `.ko` it produces as part of its own `test:` step — a build that
completes has already proven the module is signed, not just that it compiled. On a real
node, after `talosctl upgrade` to an image built this way:

```sh
talosctl -n <node> dmesg | grep -i "amneziawg\|sig"
```

should show the module loading cleanly, with no "unsigned module" or "module
verification failed" anywhere in the log — and critically, no such message for *any*
other module either (the direct check that the virtio_pci-style mismatch risk above
really is closed: everything in this kernel's module set, ours and siderolabs', came from
one coherently-signed build).
