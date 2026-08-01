#!/bin/bash
# Runs INSIDE the builder container. Compiles the AmneziaWG module against the tree
# prepare-kernel.sh produced, and drops it where a Talos system extension expects it.
set -euo pipefail

: "${KERNEL_ARCH:?}"    # x86 or arm64
: "${SRC:=/kernel}"     # prepared kernel tree
: "${AWG:=/awg}"        # extracted amneziawg source
: "${OUT:=/out}"        # rootfs/ is assembled here

export ARCH="$KERNEL_ARCH" LLVM=1

# modules_prepare doesn't produce Module.symvers, so modpost would hard-fail on every
# imported kernel symbol; downgrade that to a warning. The resulting module has no
# __versions section, which the kernel tolerates - see README, "Kernel prep", for what
# this gives up and why `check-pins` covers it.
export KBUILD_MODPOST_WARN=1

echo "==> building amneziawg.ko against $(cat "$SRC/include/config/kernel.release")"
cd "$AWG/src"
make -C "$SRC" M="$(pwd)" modules

KREL=$(cat "$SRC/include/config/kernel.release")
DEST="$OUT/rootfs/usr/lib/modules/${KREL}/extras"
mkdir -p "$DEST"
cp amneziawg.ko "$DEST/"

# Debug info is most of the file (7.5MB -> ~330kB) and is useless on a node. Upstream
# gets this via modules_install's INSTALL_MOD_STRIP=1, which we don't go through.
llvm-strip --strip-debug "$DEST/amneziawg.ko"

echo "==> built $(du -h "$DEST/amneziawg.ko" | cut -f1) module:"
modinfo "$DEST/amneziawg.ko" | grep -E '^(name|version|vermagic|srcversion):'

# A 0-byte module installs happily and only shows up as a runtime failure later - assert
# the artifact, not just the exit code.
test -s "$DEST/amneziawg.ko"
modinfo "$DEST/amneziawg.ko" | grep -q "^vermagic:.*${KREL}"
