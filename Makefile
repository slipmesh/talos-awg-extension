# Builds the AmneziaWG Talos system extension with podman - no Docker, no bldr.
#
# The siderolabs Pkgfile build system is a custom BuildKit frontend (the `# syntax =`
# line in their Pkgfiles), and podman/buildah cannot execute custom frontends - their
# Pkgfiles aren't even Dockerfiles, they're YAML. So instead of driving that machinery,
# this assembles the same environment (their `tools` + `llvm` images, see
# Dockerfile.builder) and runs the kernel/module steps in it directly. Everything here
# is plain podman.
#
# build/ is disposable: `make distclean && make all` reproduces it from versions.env,
# scripts/ and the two Dockerfiles alone.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

BUILD_DIR := build
PKGS_DIR  := $(BUILD_DIR)/pkgs
KERNEL_DIR := $(BUILD_DIR)/kernel-$(TARGET_ARCH)
AWG_DIR   := $(BUILD_DIR)/awg
OUT_DIR   := $(BUILD_DIR)/out-$(TARGET_ARCH)
CACHE_DIR := $(BUILD_DIR)/cache

# The kernel's own ARCH= spelling vs the suffix upstream uses on its config files.
KERNEL_ARCH := $(if $(filter arm64,$(TARGET_ARCH)),arm64,x86)
CONFIG_ARCH := $(TARGET_ARCH)

AWG_SHORT := $(shell printf '%.7s' '$(AWG_REF)')
EXT_IMAGE := localhost/amneziawg:$(AWG_SHORT)-$(TALOS_VERSION)
BUILDER   := localhost/awg-builder:$(TARGET_ARCH)

# The per-arch tag is what `installer`/`push` build and publish - each is a genuine
# single-platform image, kept separate so building both archs doesn't have one overwrite
# the other. MANIFEST_IMAGE is the tag nodes actually pull: a manifest list combining
# both, assembled by `push-manifest` from whichever per-arch tags are already in the
# registry (build+push each arch first). Same tag as before the arch suffix existed, so
# the upgrade command in the README needed no change - that was the point of doing this.
INSTALLER_IMAGE := $(IMAGE):installer-$(TALOS_VERSION)-awg-$(TARGET_ARCH)
MANIFEST_IMAGE  := $(IMAGE):installer-$(TALOS_VERSION)-awg
ARCHS           := amd64 arm64

# imager's --system-extension-image CLI flag only ever produces an imageRef, which means
# a registry pull - confirmed separately that it is also broken in v1.13.7 regardless.
# But the *profile* format (which `bake` feeds on stdin either way) accepts an extension
# as `ociPath: <dir>` instead of `imageRef` - a plain local OCI-layout directory, read
# straight off disk (pkg/imager/profile/input.go: ContainerAsset.pullFromOCI ->
# layout.FromPath, no network at all). So there is no registry, throwaway or otherwise:
# `podman push --format oci` writes the layout next to the other build output, and that
# directory is what gets referenced. One quirk: podman's oci: transport does not stamp a
# `platform` on the index descriptor, which imager requires to pick the arch - patched in
# with jq right after the push.
EXT_OCI_DIR := $(OUT_DIR)/ext-oci
IMAGER      := ghcr.io/siderolabs/imager:$(TALOS_VERSION)

# Read straight out of the pinned checkout rather than duplicated here - these are
# upstream's values and must move with UPSTREAM_PKGS_REF.
PKGFILE := $(PKGS_DIR)/Pkgfile
kernel_version = $(shell grep -oP '^\s*linux_version:\s*\K\S+' $(PKGFILE))
kernel_sha256  = $(shell grep -oP '^\s*linux_sha256:\s*\K\S+' $(PKGFILE))
tools_rev      = $(shell grep -oP '^\s*TOOLS_REV:\s*\K\S+' $(PKGFILE))

.DEFAULT_GOAL := help

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: checkout ## Show the resolved pins, arch and image names.
	@echo "talos          : $(TALOS_VERSION)"
	@echo "pkgs ref       : $(UPSTREAM_PKGS_REF)"
	@echo "kernel         : $(call kernel_version)"
	@echo "toolchain      : ghcr.io/siderolabs/{tools,llvm}:$(call tools_rev)"
	@echo "awg ref        : $(AWG_REF) ($(AWG_SHORT))"
	@echo "host arch      : $$(uname -m)"
	@echo "target arch    : $(TARGET_ARCH) (kernel ARCH=$(KERNEL_ARCH))"
	@echo "extension image: $(EXT_IMAGE)"

.PHONY: check-pins
check-pins: ## Assert UPSTREAM_PKGS_REF is the pkgs Talos $(TALOS_VERSION) was built from.
	@want=$$(curl -sS --fail "https://raw.githubusercontent.com/siderolabs/talos/$(TALOS_VERSION)/pkg/machinery/gendata/data/pkgs"); \
	echo "talos $(TALOS_VERSION) declares pkgs: $$want"; \
	short=$${want##*-g}; \
	case "$(UPSTREAM_PKGS_REF)" in \
	  $$short*) echo "UPSTREAM_PKGS_REF matches ($$short)";; \
	  *) echo "MISMATCH: $(UPSTREAM_PKGS_REF) does not start with $$short"; \
	     echo "the module would be built for the wrong kernel and silently fail to load"; \
	     exit 1;; \
	esac

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in podman git curl jq; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	free=$$(df -BG --output=avail $(PWD) | tail -1 | tr -dc 0-9); \
	if [ "$$free" -lt 40 ]; then echo "LOW DISK: $${free}G here, want >=40G for a kernel tree"; fail=1; fi; \
	echo "host $$(uname -m), $$(nproc) cores -> building for $(TARGET_ARCH)"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build

.PHONY: checkout
checkout: | $(BUILD_DIR) ## Fetch upstream pkgs at the pinned commit (config/patches/certs).
	@if [ ! -d "$(PKGS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/pkgs"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/pkgs.git $(PKGS_DIR); \
	fi
	@git -C $(PKGS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_PKGS_REF) 2>/dev/null || git -C $(PKGS_DIR) fetch --quiet origin
	@git -C $(PKGS_DIR) checkout --quiet --force --detach $(UPSTREAM_PKGS_REF)

.PHONY: builder
builder: checkout ## Build the toolchain image (siderolabs tools + llvm merged).
	@echo "==> building $(BUILDER) from toolchain rev $(call tools_rev)"
	@podman build -q --build-arg TOOLS_REV=$(call tools_rev) -t $(BUILDER) -f Dockerfile.builder . >/dev/null
	@podman run --rm $(BUILDER) clang --version | head -1

$(BUILD_DIR) $(CACHE_DIR):
	@mkdir -p $@

# Kernel source straight from kernel.org at upstream's pinned version+hash.
$(CACHE_DIR)/linux.tar.xz: | checkout $(CACHE_DIR)
	@v=$(call kernel_version); \
	echo "==> fetching linux-$$v"; \
	curl -sSL --fail -o $@.tmp "https://cdn.kernel.org/pub/linux/kernel/v$${v%%.*}.x/linux-$$v.tar.xz"
	@echo "$(call kernel_sha256)  $@.tmp" | sha256sum -c - >/dev/null
	@mv $@.tmp $@

.PHONY: kernel
kernel: builder $(CACHE_DIR)/linux.tar.xz ## Prepare a kernel tree modules can be built against.
	@if [ ! -f $(KERNEL_DIR)/.awg-prepared ]; then \
	  echo "==> extracting kernel"; \
	  rm -rf $(KERNEL_DIR); mkdir -p $(KERNEL_DIR); \
	  tar -xJf $(CACHE_DIR)/linux.tar.xz --strip-components=1 -C $(KERNEL_DIR); \
	fi
	@podman run --rm \
	  -v $(PWD)/$(KERNEL_DIR):/kernel:z \
	  -v $(PWD)/$(PKGS_DIR)/kernel/build:/assets:ro,z \
	  -v $(PWD)/scripts:/scripts:ro,z \
	  -e KERNEL_ARCH=$(KERNEL_ARCH) -e CONFIG_ARCH=$(CONFIG_ARCH) \
	  $(BUILDER) /bin/bash /scripts/prepare-kernel.sh

$(CACHE_DIR)/awg.tar.gz: | $(CACHE_DIR)
	@echo "==> fetching amneziawg $(AWG_SHORT)"
	@curl -sSL --fail -o $@.tmp "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/$(AWG_REF).tar.gz"
	@echo "$(AWG_SHA256)  $@.tmp" | sha256sum -c - >/dev/null
	@mv $@.tmp $@

.PHONY: module
module: kernel $(CACHE_DIR)/awg.tar.gz ## Compile amneziawg.ko against the prepared tree.
	@rm -rf $(AWG_DIR) $(OUT_DIR); mkdir -p $(AWG_DIR) $(OUT_DIR)
	@tar -xzf $(CACHE_DIR)/awg.tar.gz --strip-components=1 -C $(AWG_DIR)
	@podman run --rm \
	  -v $(PWD)/$(KERNEL_DIR):/kernel:z \
	  -v $(PWD)/$(AWG_DIR):/awg:z \
	  -v $(PWD)/$(OUT_DIR):/out:z \
	  -v $(PWD)/scripts:/scripts:ro,z \
	  -e KERNEL_ARCH=$(KERNEL_ARCH) \
	  $(BUILDER) /bin/bash /scripts/build-module.sh

.PHONY: extension
extension: module ## Package the module as a Talos system extension image.
	@sed -e 's|@VERSION@|$(AWG_SHORT)-$(TALOS_VERSION)|' manifest.yaml.in > $(OUT_DIR)/manifest.yaml
	@echo "==> building $(EXT_IMAGE) ($(TARGET_ARCH))"
	@podman build -q --arch $(TARGET_ARCH) -t $(EXT_IMAGE) -f Dockerfile.extension $(OUT_DIR) >/dev/null
	@echo "built $(EXT_IMAGE):"
	@podman run --rm --arch $(TARGET_ARCH) --entrypoint="" $(EXT_IMAGE) true 2>/dev/null || true
	@podman image inspect $(EXT_IMAGE) --format '  arch={{.Architecture}}  size={{.Size}}'

.PHONY: all
all: preflight check-pins extension ## Everything: toolchain -> kernel -> module -> image.
	@echo
	@echo "next: make installer && make push"


##@ Talos images

# imager's --system-extension-image CLI flag is broken in v1.13.7: it ends up with an
# empty image reference ("error pulling image : parsing reference") regardless of
# --base-installer-image, target architecture, or emulation. An equivalent profile fed
# on stdin works, so that is what this generates.
define imager_profile
arch: $(TARGET_ARCH)
platform: metal
secureboot: false
version: $(TALOS_VERSION)
customization:
  extraKernelArgs:
    - module.sig_enforce=0
input:
  kernel:
    path: /usr/install/$(TARGET_ARCH)/vmlinuz
  initramfs:
    path: /usr/install/$(TARGET_ARCH)/initramfs.xz
  baseInstaller:
    imageRef: ghcr.io/siderolabs/installer:$(TALOS_VERSION)
  systemExtensions:
    - ociPath: /out/ext-oci
output:
  kind: $(1)
  outFormat: $(2)
endef

# Exports the just-built extension image to a local OCI layout (no registry involved),
# stamps the arch platform onto it (see EXT_OCI_DIR comment above), and runs imager
# against $(OUT_DIR)/profile.yaml. /out is the same bind mount imager always gets, so the
# ociPath in the profile and EXT_OCI_DIR agree by construction.
define bake
	rm -rf $(EXT_OCI_DIR); \
	podman push -q --format oci $(EXT_IMAGE) oci:$(EXT_OCI_DIR):bake; \
	tmp=$$(mktemp); \
	jq '.manifests[0].platform = {architecture:"$(TARGET_ARCH)", os:"linux"}' \
	  $(EXT_OCI_DIR)/index.json >"$$tmp" && mv "$$tmp" $(EXT_OCI_DIR)/index.json; \
	podman run --rm -i --privileged --network host \
	  -v $(PWD)/$(OUT_DIR):/out:z -v /dev:/dev $(IMAGER) - --insecure \
	  < $(OUT_DIR)/profile.yaml
endef

.PHONY: installer
installer: extension ## Bake an installer image (what `talosctl upgrade` pulls).
	@mkdir -p $(OUT_DIR)
	$(file >$(OUT_DIR)/profile.yaml,$(call imager_profile,installer,raw))
	@echo "==> baking installer for $(TALOS_VERSION)/$(TARGET_ARCH)"
	@$(bake)
	@# imager names the tarball's image after the base installer, colliding with the
	@# official tag locally. Retag by image ID; never `podman untag` the collided name,
	@# which drops the image outright.
	@podman load -q -i $(OUT_DIR)/installer-$(TARGET_ARCH).tar >/dev/null
	@id=$$(podman image inspect ghcr.io/siderolabs/installer:$(TALOS_VERSION) --format '{{.Id}}'); \
	  podman tag "$$id" $(INSTALLER_IMAGE)
	@podman image inspect $(INSTALLER_IMAGE) --format 'built $(INSTALLER_IMAGE) arch={{.Architecture}} size={{.Size}}'

.PHONY: push
push: ## Push this arch's installer (intermediate - see push-manifest for what nodes pull).
	@podman push $(INSTALLER_IMAGE)
	@echo "pushed $(INSTALLER_IMAGE) - run push-manifest once every arch you need is pushed"

.PHONY: push-manifest
push-manifest: ## Combine the per-arch installers already in the registry into one multi-arch tag.
	@for a in $(ARCHS); do \
	  img="$(IMAGE):installer-$(TALOS_VERSION)-awg-$$a"; \
	  podman image exists "$$img" || { echo "missing $$img locally - run: make installer push TARGET_ARCH=$$a"; exit 1; }; \
	done
	@podman manifest rm $(MANIFEST_IMAGE) >/dev/null 2>&1 || true
	@podman rmi $(MANIFEST_IMAGE) >/dev/null 2>&1 || true
	@podman manifest create $(MANIFEST_IMAGE) >/dev/null
	@for a in $(ARCHS); do \
	  podman manifest add $(MANIFEST_IMAGE) "$(IMAGE):installer-$(TALOS_VERSION)-awg-$$a" >/dev/null; \
	done
	@podman manifest push --all $(MANIFEST_IMAGE) docker://$(MANIFEST_IMAGE)
	@echo
	@echo "pushed multi-arch $(MANIFEST_IMAGE) ($(ARCHS))"
	@echo "upgrade a node with:"
	@echo "  talosctl -n <node> upgrade --image $(MANIFEST_IMAGE)"

.PHONY: metal
metal: extension ## Bake a raw disk image for a from-scratch install (dd).
	@mkdir -p $(OUT_DIR)
	$(file >$(OUT_DIR)/profile.yaml,$(call imager_profile,image,.zst))
	@echo "==> baking metal image for $(TALOS_VERSION)/$(TARGET_ARCH)"
	@$(bake)
	@ls -lh $(OUT_DIR)/metal-$(TARGET_ARCH).raw.zst

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute AWG_SHA256 for the current AWG_REF.
	@tmp=$$(mktemp); \
	curl -sSL --fail "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/$(AWG_REF).tar.gz" -o "$$tmp"; \
	echo "AWG_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	rm -f "$$tmp"

.PHONY: shell
shell: builder ## Interactive shell in the build environment (debugging).
	@podman run --rm -it \
	  -v $(PWD)/$(KERNEL_DIR):/kernel:z -v $(PWD)/$(AWG_DIR):/awg:z \
	  -e KERNEL_ARCH=$(KERNEL_ARCH) $(BUILDER) /bin/bash

.PHONY: clean
clean: ## Drop build outputs, keep the kernel tree and downloads.
	@rm -rf $(OUT_DIR) $(AWG_DIR)

.PHONY: distclean
distclean: ## Drop everything, including the prepared kernel tree.
	@rm -rf $(BUILD_DIR)
