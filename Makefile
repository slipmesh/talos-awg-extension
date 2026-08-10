# Builds the AmneziaWG Talos system extension the way siderolabs builds their own
# out-of-tree kernel modules (zfs, gasket-driver): the module is compiled *inside* the
# same buildkit session as the kernel itself (siderolabs/pkgs' `kernel-build` stage), so
# both get signed by the one signing key that build generates - no persistent PKI of our
# own, no MOK, no `sig_enforce=0` workaround. See docs/kernel-signing.md for the full
# mechanism and why a lighter "just swap the kernel" approach doesn't work.
#
# This needs Docker + `docker buildx` (siderolabs' real `bldr` toolchain, a custom
# BuildKit frontend podman/buildah can't run - the whole reason this repo used to be
# podman-only was to dodge exactly this, at the cost of hand-rolling kernel prep instead
# of using siderolabs' own build). No more hand-rolling: three upstream repos
# (siderolabs/pkgs, siderolabs/extensions, siderolabs/talos) get checked out under
# build/, patched with a thin overlay (patches/), and built with their own Makefiles.
#
# build/ is disposable: `make distclean && make all` reproduces it from versions.env and
# patches/ alone.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# No silent single-arch default: nodes are amd64 and arm64 both, so a bare `make all`
# picking one quietly is how you forget to build the other. Pass TARGET_ARCH explicitly,
# or use `make release` (or any target below marked arch-independent), which builds both.
# `kernel`/`checkout-*` are arch-independent themselves - the kernel+module build produces
# one multi-platform image covering both arches in a single buildx invocation.
_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(TARGET_ARCH),)
  ifneq ($(filter-out release push-manifest distclean help hashes check-pins kernel checkout-pkgs checkout-extensions checkout-talos,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64, or run `make release` to build both)
  endif
endif

BUILD_DIR      := build
PKGS_DIR       := $(BUILD_DIR)/pkgs
EXTENSIONS_DIR := $(BUILD_DIR)/extensions
TALOS_DIR      := $(BUILD_DIR)/talos
OUT_DIR        := $(BUILD_DIR)/out-$(TARGET_ARCH)

# The `awg` Talos extension-service daemon (mesh + roadwarriors interface config) lives in a
# sibling repo, not here - this repo only cross-compiles it and hands the binary to the
# siderolabs/extensions checkout for packaging. See that repo's README/AGENTS.md for what it does.
AGENTS_DIR              := ../talos-extensions
AGENT_RUST_TARGET_amd64 := x86_64-unknown-linux-musl
AGENT_RUST_TARGET_arm64 := aarch64-unknown-linux-musl
AGENT_RUST_TARGET       := $(AGENT_RUST_TARGET_$(TARGET_ARCH))
AGENTS_SHA              := $(shell git -C $(AGENTS_DIR) rev-parse --short HEAD 2>/dev/null || echo unknown)

AWG_SHORT := $(shell printf '%.7s' '$(AWG_REF)')

# Shared registry namespace for the intermediate artifacts this pipeline produces on the
# way to the final installer - one repo per artifact (kernel, amneziawg-pkg), matching
# upstream's own convention (ghcr.io/siderolabs/kernel, ghcr.io/siderolabs/zfs-pkg, ...)
# rather than this repo's older single-repo-many-tags scheme, because siderolabs/extensions'
# pkg.yaml templates expect exactly that shape ({{ .BUILD_ARG_PKGS_PREFIX }}/<name>:{{ .BUILD_ARG_PKGS }}).
DOCKER_NS         := docker.io/ffaxl
PKGS_TAG          := $(TALOS_VERSION)-awg-$(AWG_SHORT)
KERNEL_IMAGE      := $(DOCKER_NS)/kernel:$(PKGS_TAG)
AMNEZIAWG_PKG_IMAGE := $(DOCKER_NS)/amneziawg-pkg:$(PKGS_TAG)

# The extension image keeps living under $(IMAGE) (versions.env), same namespace as
# before - just built by `docker buildx` via siderolabs/extensions now instead of a local
# Dockerfile.extension. Tag includes AGENTS_SHA (../talos-extensions' own commit) so a
# rebuild after fixing something there always gets a genuinely new tag - re-pushing under
# an unchanged tag has previously failed to actually propagate to a node on `talosctl
# upgrade` (observed directly: same digest hash across two different builds under one
# tag), and AWG_REF/TALOS_VERSION alone don't change on an ext-awg-only fix.
EXT_IMAGE := $(IMAGE):extension-$(TALOS_VERSION)-awg-$(AGENTS_SHA)-$(TARGET_ARCH)

# INSTALLER_IMAGE is the per-arch tag `installer`/`push` build and publish. MANIFEST_IMAGE
# (no arch suffix) is what nodes actually pull - only `push-manifest` produces it, by
# combining whichever per-arch tags are already in the registry.
#
# Includes AGENTS_SHA for the same reason as EXT_IMAGE: re-pushing genuinely new content
# under a tag that's already been pushed before does NOT reliably reach a node on
# `talosctl upgrade` - confirmed directly on a real node (node-a) across repeated
# installer rebuilds under one unchanging tag: the brand-new-tag deploy picked up the
# fresh kernel cmdline/extension version immediately, the reused-tag deploy silently kept
# serving old content (same symptom previously seen and worked around at the extension
# level, now confirmed at the installer level too - digest/cache staleness somewhere
# between registry, node-side image pull, and/or the install step, not narrowed down
# further since a unique tag sidesteps it entirely).
INSTALLER_IMAGE := $(IMAGE):installer-$(TALOS_VERSION)-awg-$(AGENTS_SHA)-$(TARGET_ARCH)
MANIFEST_IMAGE  := $(IMAGE):installer-$(TALOS_VERSION)-awg-$(AGENTS_SHA)
ARCHS           := amd64 arm64

# The imager *tool* stays the stock siderolabs one - unmodified, never rebuilt. Getting our
# own coherently-signed kernel+initramfs into its output is a bind-mount at run time (see
# `bake`), not a rebuild of the tool itself. See docs/kernel-signing.md, "Why not build a
# custom imager image" for why that's both simpler and safer than the alternative.
IMAGER               := ghcr.io/siderolabs/imager:$(TALOS_VERSION)
BASE_OCI_DIR         := $(OUT_DIR)/base-oci
CUSTOM_KERNEL_DIR    := $(OUT_DIR)/custom-kernel

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: | checkout-pkgs ## Show the resolved pins, arch and image names.
	@echo "talos          : $(TALOS_VERSION)"
	@echo "pkgs ref       : $(UPSTREAM_PKGS_REF)"
	@echo "extensions ref : $(UPSTREAM_EXTENSIONS_REF)"
	@echo "awg ref        : $(AWG_REF) ($(AWG_SHORT))"
	@echo "host arch      : $$(uname -m)"
	@echo "target arch    : $(TARGET_ARCH)"
	@echo "kernel image   : $(KERNEL_IMAGE)"
	@echo "amneziawg pkg  : $(AMNEZIAWG_PKG_IMAGE)"
	@echo "extension image: $(EXT_IMAGE)"
	@echo "installer image: $(INSTALLER_IMAGE)"
	@echo "manifest image  : $(MANIFEST_IMAGE)"

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
	for t in docker git curl jq; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (permission denied or not running)"; fail=1; }; \
	command -v cargo >/dev/null || { echo "MISSING: cargo"; fail=1; }; \
	command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild (cargo install cargo-zigbuild --locked)"; fail=1; }; \
	[ -d $(AGENTS_DIR) ] || { echo "MISSING: sibling checkout $(AGENTS_DIR)"; fail=1; }; \
	free=$$(df -BG --output=avail $(PWD) | tail -1 | tr -dc 0-9); \
	if [ "$$free" -lt 40 ]; then echo "LOW DISK: $${free}G here, want >=40G for a kernel build"; fail=1; fi; \
	echo "host $$(uname -m), $$(nproc) cores"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build

$(BUILD_DIR):
	@mkdir -p $@

.PHONY: checkout-pkgs
checkout-pkgs: | $(BUILD_DIR) ## Fetch siderolabs/pkgs at the pinned commit, overlay patches/pkgs/.
	@if [ ! -d "$(PKGS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/pkgs"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/pkgs.git $(PKGS_DIR); \
	fi
	@git -C $(PKGS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_PKGS_REF) 2>/dev/null || git -C $(PKGS_DIR) fetch --quiet origin
	@git -C $(PKGS_DIR) checkout --quiet --force --detach $(UPSTREAM_PKGS_REF)
	@rm -rf $(PKGS_DIR)/amneziawg-pkg
	@cp -r patches/pkgs/amneziawg-pkg $(PKGS_DIR)/amneziawg-pkg

.PHONY: checkout-extensions
checkout-extensions: | $(BUILD_DIR) ## Fetch siderolabs/extensions at the pinned commit, overlay patches/extensions/.
	@if [ ! -d "$(EXTENSIONS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/extensions"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/extensions.git $(EXTENSIONS_DIR); \
	fi
	@git -C $(EXTENSIONS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_EXTENSIONS_REF) 2>/dev/null || git -C $(EXTENSIONS_DIR) fetch --quiet origin
	@git -C $(EXTENSIONS_DIR) checkout --quiet --force --detach $(UPSTREAM_EXTENSIONS_REF)
	@rm -rf $(EXTENSIONS_DIR)/amneziawg
	@cp -r patches/extensions/amneziawg $(EXTENSIONS_DIR)/amneziawg

.PHONY: checkout-talos
checkout-talos: | $(BUILD_DIR) ## Fetch siderolabs/talos at $(TALOS_VERSION) - used only to extract a kernel+initramfs pair built against our own kernel package.
	@if [ ! -d "$(TALOS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/talos"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/talos.git $(TALOS_DIR); \
	fi
	@git -C $(TALOS_DIR) fetch --quiet --filter=blob:none origin $(TALOS_VERSION) 2>/dev/null || git -C $(TALOS_DIR) fetch --quiet origin
	@git -C $(TALOS_DIR) checkout --quiet --force --detach $(TALOS_VERSION)

# kernel+amneziawg-pkg MUST be built back to back against the same warm buildx cache -
# that's the entire mechanism that gives them the same signing key (kbuild auto-generates
# certs/signing_key.pem into the kernel-build stage's output the first time `make` runs
# against it; amneziawg-pkg's `dependencies: [stage: kernel-build]` only sees the *same*
# key if BuildKit serves that stage from cache rather than re-running it, which produces a
# fresh random key). Don't insert a `docker builder prune`/`--no-cache` between these two,
# don't switch buildx builders between them, and don't run them from a script that might
# retry only one half. See docs/kernel-signing.md for the full explanation, verified
# against siderolabs/pkgs' own zfs/gasket-driver packages and bldr's source.
# bldr loads and validates every pkg.yaml in the checkout up front, regardless of which
# --target= is actually being built (confirmed the hard way: `docker-kernel` alone fails
# amneziawg-pkg's own sha256/sha512 length validation if those build-args are absent, even
# though the kernel target never references that package) - so both invocations get the
# same full AWG_ARGS, not just the one that actually consumes them.
AWG_ARGS := --build-arg=AWG_REF=$(AWG_REF) --build-arg=AWG_SHA256=$(AWG_SHA256) --build-arg=AWG_SHA512=$(AWG_SHA512)

.PHONY: kernel
kernel: checkout-pkgs ## Build the kernel + amneziawg module together (shared signing key), push both. Arch-independent (multi-platform).
	@echo "==> building $(KERNEL_IMAGE) (linux/amd64,linux/arm64)"
	@$(MAKE) -C $(PKGS_DIR) docker-kernel PLATFORM=linux/amd64,linux/arm64 \
	  TARGET_ARGS="--tag=$(KERNEL_IMAGE) --push=true $(AWG_ARGS)"
	@echo "==> building $(AMNEZIAWG_PKG_IMAGE) (linux/amd64,linux/arm64)"
	@$(MAKE) -C $(PKGS_DIR) docker-amneziawg-pkg PLATFORM=linux/amd64,linux/arm64 \
	  TARGET_ARGS="--tag=$(AMNEZIAWG_PKG_IMAGE) --push=true $(AWG_ARGS)"

.PHONY: agents
agents: ## Cross-compile the ext-awg extension-service daemon (../talos-extensions).
	@test -d $(AGENTS_DIR) || { echo "sibling checkout not found: $(AGENTS_DIR)"; exit 1; }
	@command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild"; exit 1; }
	@rustup target add $(AGENT_RUST_TARGET) >/dev/null 2>&1 || true
	@echo "==> cross-compiling awg for $(TARGET_ARCH) ($(AGENT_RUST_TARGET))"
	@(cd $(AGENTS_DIR) && cargo zigbuild --release --target $(AGENT_RUST_TARGET) -p awg)

# AWG_REF/TALOS_VERSION alone are not enough to make this version string unique - ext-awg's
# own behavior changes on ../talos-extensions commits that don't touch either pin (its
# git SHA is included specifically so a rebuild after fixing something in that repo is
# never mistaken for a repeat of an earlier build under some cache, anywhere in the
# pipeline, keyed on this string).
EXT_VERSION := $(AWG_SHORT)-$(TALOS_VERSION)-$(AGENTS_SHA)

.PHONY: extension
extension: kernel agents checkout-extensions ## Package the module + ext-awg into a Talos system extension image (bldr).
	@cp $(AGENTS_DIR)/target/$(AGENT_RUST_TARGET)/release/awg $(EXTENSIONS_DIR)/amneziawg/awg-bin
	@cp $(AGENTS_DIR)/extension-services/awg.yaml $(EXTENSIONS_DIR)/amneziawg/awg-service.yaml
	@echo "==> building $(EXT_IMAGE) ($(TARGET_ARCH))"
	@$(MAKE) -C $(EXTENSIONS_DIR) docker-amneziawg PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(EXT_IMAGE) --push=true \
	    --build-arg=PKGS_PREFIX=$(DOCKER_NS) --build-arg=PKGS=$(PKGS_TAG) --build-arg=VERSION=$(EXT_VERSION)"

.PHONY: all
all: preflight check-pins extension ## Everything: kernel+module -> agents -> extension image.
	@echo
	@echo "next: make installer && make push"


##@ Talos images

# extraKernelArgs no longer needs -module.sig_enforce - the module is signed by the same
# key the running kernel trusts (see docs/kernel-signing.md), so sig_enforce stays on.
#
# baseInstaller.ociPath is what's actually read for everything EXCEPT kernel/initramfs
# (rootfs, sd-boot/sd-stub, etc) - those still come from the stock siderolabs installer,
# unchanged. imageRef only names the image inside the output tarball: setting it to our
# own $(INSTALLER_IMAGE) means `docker load` writes our tag directly, the real upstream tag
# is never touched. input.kernel/input.initramfs are plain paths read from *the imager
# tool's own container filesystem*, independent of baseInstaller - `bake` below overrides
# them via bind mount at `docker run` time rather than pointing this profile at a
# different path, since the paths themselves (/usr/install/$(TARGET_ARCH)/{vmlinuz,
# initramfs.xz}) are a fixed convention baked into every siderolabs imager build.
define imager_profile
arch: $(TARGET_ARCH)
platform: metal
secureboot: false
version: $(TALOS_VERSION)
input:
  kernel:
    path: /usr/install/$(TARGET_ARCH)/vmlinuz
  initramfs:
    path: /usr/install/$(TARGET_ARCH)/initramfs.xz
  baseInstaller:
    imageRef: $(INSTALLER_IMAGE)
    ociPath: /out/base-oci
  systemExtensions:
    - imageRef: $(EXT_IMAGE)
output:
  kind: installer
  outFormat: raw
endef

# Exports a registry image to a plain OCI-layout directory and stamps a platform onto its
# index - via `docker buildx build --output=type=oci`, the one docker-native way to get a
# real OCI layout (index.json + blobs/) onto disk; docker itself has no `oci:`-transport
# push the way podman did. $(1) = source image, $(2) = destination dir under $(OUT_DIR).
define export-to-oci
	rm -rf $(2); mkdir -p $(2); \
	printf 'FROM %s\n' $(1) | docker buildx build --platform=linux/$(TARGET_ARCH) \
	  --output=type=oci,dest=$(2)/image.tar -; \
	tar -xf $(2)/image.tar -C $(2); rm -f $(2)/image.tar; \
	tmp=$$(mktemp); \
	jq '.manifests[0].platform = {architecture:"$(TARGET_ARCH)", os:"linux"}' \
	  $(2)/index.json >"$$tmp" && mv "$$tmp" $(2)/index.json
endef

# Refreshes the base installer and exports it to a local OCI layout, extracts a
# kernel+initramfs pair coherently built against our own kernel package (extension was
# already pushed by the `extension` target itself - imager only takes systemExtensions by
# registry reference), and runs the *stock* imager against $(OUT_DIR)/profile.yaml with
# those two files bind-mounted over the ones it ships with by default.
#
# local-kernel/local-initramfs (not the bare kernel/initramfs shortcuts, which don't
# forward TARGET_ARGS) with --network=host: siderolabs/talos's own Dockerfile RUN steps
# for TARGET_ARCH != host arch (go mod download, in particular) hang indefinitely under
# plain docker-bridge networking when run through QEMU emulation - confirmed directly
# (docker run --platform=linux/amd64 ... curl -4 to any address times out under the
# default bridge network on this host, works instantly under --network=host). Not
# something wrong with the module fetch itself; --network=host sidesteps whatever's
# broken in the emulated-container-to-bridge-NAT path entirely.
define bake
	docker pull -q --platform linux/$(TARGET_ARCH) ghcr.io/siderolabs/installer:$(TALOS_VERSION) >/dev/null; \
	$(call export-to-oci,ghcr.io/siderolabs/installer:$(TALOS_VERSION),$(BASE_OCI_DIR)); \
	mkdir -p $(CUSTOM_KERNEL_DIR); \
	$(MAKE) -C $(TALOS_DIR) local-kernel local-initramfs \
	  PKG_KERNEL=$(KERNEL_IMAGE) PLATFORM=linux/$(TARGET_ARCH) DEST=$(PWD)/$(CUSTOM_KERNEL_DIR) \
	  TARGET_ARGS="--network=host"; \
	docker run --rm -i --privileged --network host \
	  -v $(PWD)/$(OUT_DIR):/out:z \
	  -v $(PWD)/$(CUSTOM_KERNEL_DIR)/vmlinuz-$(TARGET_ARCH):/usr/install/$(TARGET_ARCH)/vmlinuz:ro \
	  -v $(PWD)/$(CUSTOM_KERNEL_DIR)/initramfs-$(TARGET_ARCH).xz:/usr/install/$(TARGET_ARCH)/initramfs.xz:ro \
	  -v /dev:/dev $(IMAGER) - --insecure \
	  < $(OUT_DIR)/profile.yaml
endef

$(OUT_DIR):
	@mkdir -p $@

# $(file ...) writes are expanded when make builds this recipe's command text, which
# happens before ANY of the recipe's own lines actually run - a bare `@mkdir -p
# $(OUT_DIR)` line earlier in the same recipe does NOT run in time to satisfy it (verified
# directly: GNU Make prints/executes recipe lines one at a time, but expands $(file ...)
# eagerly regardless). $(OUT_DIR) has to exist before this rule's recipe is expanded at
# all, hence the order-only prerequisite below, not an in-recipe mkdir.
.PHONY: installer
installer: extension checkout-talos | $(OUT_DIR) ## Bake an installer image (what `talosctl upgrade` pulls).
	$(file >$(OUT_DIR)/profile.yaml,$(imager_profile))
	@echo "==> baking installer for $(TALOS_VERSION)/$(TARGET_ARCH)"
	@$(bake)
	@docker load -q -i $(OUT_DIR)/installer-$(TARGET_ARCH).tar >/dev/null
	@docker image inspect $(INSTALLER_IMAGE) --format 'built $(INSTALLER_IMAGE) arch={{.Architecture}} size={{.Size}}'

.PHONY: push
push: ## Push this arch's installer (intermediate - see push-manifest for what nodes pull).
	@docker push $(INSTALLER_IMAGE)
	@echo "pushed $(INSTALLER_IMAGE) - run push-manifest once every arch you need is pushed"

.PHONY: push-manifest
push-manifest: ## Combine the per-arch installers already in the registry into one multi-arch tag.
	@for a in $(ARCHS); do \
	  img="$(IMAGE):installer-$(TALOS_VERSION)-awg-$$a"; \
	  docker image inspect "$$img" >/dev/null 2>&1 || { echo "missing $$img locally - run: make installer push TARGET_ARCH=$$a"; exit 1; }; \
	done
	@docker manifest rm $(MANIFEST_IMAGE) >/dev/null 2>&1 || true
	@docker manifest create $(MANIFEST_IMAGE) \
	  $(foreach a,$(ARCHS),$(IMAGE):installer-$(TALOS_VERSION)-awg-$(a)) >/dev/null
	@docker manifest push $(MANIFEST_IMAGE)
	@echo
	@echo "pushed multi-arch $(MANIFEST_IMAGE) ($(ARCHS))"
	@echo "upgrade a node with:"
	@echo "  talosctl -n <node> upgrade --image $(MANIFEST_IMAGE)"

.PHONY: release
release: ## Build+push every arch and publish the multi-arch tag - the one command for a release.
	@for a in $(ARCHS); do \
	  echo "==> $$a"; \
	  $(MAKE) --no-print-directory installer push TARGET_ARCH=$$a; \
	done
	@$(MAKE) --no-print-directory push-manifest

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute AWG_SHA256/AWG_SHA512 for the current AWG_REF.
	@tmp=$$(mktemp); \
	curl -sSL --fail "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/$(AWG_REF).tar.gz" -o "$$tmp"; \
	echo "AWG_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	echo "AWG_SHA512=$$(sha512sum "$$tmp" | cut -d' ' -f1)"; \
	rm -f "$$tmp"

.PHONY: clean
clean: ## Drop build outputs, keep the pinned checkouts.
	@rm -rf $(OUT_DIR)

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkouts.
	@rm -rf $(BUILD_DIR)
