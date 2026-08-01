#!/bin/bash
# Runs INSIDE the builder container. Compiles the AmneziaWG module against the tree
# prepare-kernel.sh produced, and drops it where a Talos system extension expects it.
set -euo pipefail

: "${KERNEL_ARCH:?}"    # x86 or arm64
: "${SRC:=/kernel}"     # prepared kernel tree
: "${AWG:=/awg}"        # extracted amneziawg source
: "${OUT:=/out}"        # rootfs/ is assembled here

export ARCH="$KERNEL_ARCH" LLVM=1

# `make modules_prepare` does not produce Module.symvers - only a full `make modules`
# does, which would mean rebuilding every in-tree module and roughly doubling the build
# for something we never ship. Without it modpost turns every kernel symbol the module
# imports into a hard "undefined!", so downgrade that to a warning.
#
# The module then carries no __versions section, which the kernel explicitly tolerates:
# check_version() returns OK when there is no version info at all ("No versions at all?
# modprobe --force-vermagic!"), even on this CONFIG_MODVERSIONS kernel. The module that
# has been running on the cluster was built exactly this way.
#
# What this gives up is symbol-CRC checking - the thing that would catch an ABI drift
# between the kernel we built against and the one actually booted. `make check-pins`
# replaces that guarantee by deriving the kernel from the Talos version.
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

# The failure this project exists to prevent is shipping an extension with no module in
# it - which installs perfectly happily and only shows up as "the operators can't talk
# to the kernel". Assert the artifact, not the exit code.
test -s "$DEST/amneziawg.ko"
modinfo "$DEST/amneziawg.ko" | grep -q "^vermagic:.*${KREL}"
