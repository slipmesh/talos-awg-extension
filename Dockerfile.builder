# Build environment: siderolabs' `tools` image (full rootfs) with their `llvm` image
# (clang/lld) overlaid on top - the same combination bldr assembles for kernel builds,
# but as an ordinary Dockerfile podman can build natively.
ARG TOOLS_REV
FROM ghcr.io/siderolabs/llvm:${TOOLS_REV} AS llvm
FROM ghcr.io/siderolabs/tools:${TOOLS_REV}
COPY --from=llvm / /
