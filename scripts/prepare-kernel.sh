#!/bin/bash
# Runs inside the builder container. Turns an extracted kernel source tree into one
# out-of-tree modules can build against, using Talos' own config and patches unmodified
# (BTF stays on - CONFIG_DEBUG_INFO_BTF_MODULES changes struct module's layout, so
# disabling it makes the module ABI-incompatible with the real, BTF-enabled running
# kernel: "must match the kernel's built struct module size at run time"). Builds only
# vmlinux + modules_prepare, not the full module set - see README, "Kernel prep".
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
make olddefconfig

echo "==> building vmlinux + modules_prepare (this is the slow part)"
make -j "$(nproc)" vmlinux
make -j "$(nproc)" modules_prepare

touch .awg-prepared
echo "==> kernel tree ready: $(cat include/config/kernel.release)"
