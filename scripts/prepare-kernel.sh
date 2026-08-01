#!/bin/bash
# Runs INSIDE the builder container. Turns an extracted kernel source tree into one
# that out-of-tree modules can be built against, using Talos' own config and patches.
#
# This is a direct port of what a `kernel-modprep` bldr stage would do, with two
# deliberate differences from upstream's kernel-build, both found by watching this fail:
#
#   - BTF is disabled entirely, not just for modules. Otherwise `make vmlinux` runs
#     pahole over vmlinux.unstripped and dies with "FAILED: load BTF from
#     vmlinux.unstripped: Invalid argument". Out-of-tree module builds need none of it.
#   - Only `vmlinux` + `modules_prepare` are built, not the full in-tree module set.
#     That is what makes this ~40 minutes instead of ~90, at the cost of no
#     Module.symvers - see build-module.sh for what that implies.
set -euo pipefail

: "${KERNEL_ARCH:?}"   # kernel's own ARCH= value: x86 or arm64
: "${CONFIG_ARCH:?}"   # suffix of upstream's config-* file: amd64 or arm64
: "${SRC:=/kernel}"    # extracted kernel tree, bind-mounted from the host
: "${ASSETS:=/assets}" # upstream's kernel/build dir: config-*, certs/, patches/

cd "$SRC"

if [ -f .awg-prepared ]; then
    echo "==> kernel tree already prepared, skipping (rm $SRC/.awg-prepared to redo)"
    exit 0
fi

echo "==> applying Talos kernel patches"
for patch in $(find "$ASSETS/patches" -type f -name '*.patch' | sort); do
    patch -p1 <"$patch" || {
        echo "failed to apply $patch" >&2
        exit 1
    }
    echo "    applied $(basename "$patch")"
done

echo "==> installing Talos kernel config (${CONFIG_ARCH}) and signing certs"
cp -v "$ASSETS/config-${CONFIG_ARCH}" .config
mkdir -p certs && cp -v "$ASSETS"/certs/* certs/

export ARCH="$KERNEL_ARCH" LLVM=1

echo "==> configuring"
./scripts/config --disable CONFIG_DEBUG_INFO_BTF --disable CONFIG_DEBUG_INFO_BTF_MODULES
make olddefconfig

echo "==> building vmlinux + modules_prepare (this is the slow part)"
make -j "$(nproc)" vmlinux
make -j "$(nproc)" modules_prepare

touch .awg-prepared
echo "==> kernel tree ready: $(cat include/config/kernel.release)"
