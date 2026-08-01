# The kernel build environment, assembled the same way bldr assembles it for
# siderolabs' own kernel packages: the `tools` image is a full rootfs (bash, make,
# bison, flex, bc, perl...), and the `llvm` image is a bare file set carrying clang/lld
# that gets overlaid on top. Merging them here is the whole reason this project no
# longer needs bldr - and therefore no longer needs Docker, since this is an ordinary
# Dockerfile that podman builds natively.
ARG TOOLS_REV
FROM ghcr.io/siderolabs/llvm:${TOOLS_REV} AS llvm
FROM ghcr.io/siderolabs/tools:${TOOLS_REV}
COPY --from=llvm / /
