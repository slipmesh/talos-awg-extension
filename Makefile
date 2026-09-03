# Packages amneziawg.ko (built + signed in ../talos-kernel) and ext-awg (the extension
# service daemon, ../talos-extensions) into a Talos system extension image, via
# siderolabs/extensions' own pkg.yaml/bldr pipeline - the same mechanism their own zfs
# extension uses. See docs/kernel-signing.md for why this repo doesn't build or sign
# anything itself; it only packages an already-signed module.
#
# One of five repos in a split pipeline - see README, "This is one of five repos".
#
# Needs Docker + `docker buildx` (siderolabs' real `bldr` toolchain, a custom BuildKit
# frontend podman/buildah can't run).
#
# build/ is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces
# it from versions.env and patches/ alone.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# No silent single-arch default: nodes are amd64 and arm64 both, so a bare `make all`
# picking one quietly is how you forget to build the other. Pass TARGET_ARCH explicitly.
_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(TARGET_ARCH),)
  ifneq ($(filter-out distclean help hashes checkout-extensions check-agents,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64)
  endif
endif
ifeq ($(RELEASE_TAG),)
  ifneq ($(filter-out distclean help hashes checkout-extensions check-agents,$(_GOALS)),)
    $(error RELEASE_TAG not set - pass RELEASE_TAG=v0.1.0+talos1.13.8, the git tag this build is released under)
  endif
endif

BUILD_DIR      := build
EXTENSIONS_DIR := $(BUILD_DIR)/extensions

# The `awg` Talos extension-service daemon (mesh + roadwarriors interface config) lives in a
# sibling repo, not here - this repo only cross-compiles it and hands the binary to the
# siderolabs/extensions checkout for packaging. See that repo's README for what it does.
AGENTS_DIR              := ../talos-extensions
AGENT_RUST_TARGET_amd64 := x86_64-unknown-linux-musl
AGENT_RUST_TARGET_arm64 := aarch64-unknown-linux-musl
AGENT_RUST_TARGET       := $(AGENT_RUST_TARGET_$(TARGET_ARCH))
AGENTS_SHA              := $(shell git -C $(AGENTS_DIR) rev-parse --short HEAD 2>/dev/null || echo unknown)

AWG_SHORT := $(shell printf '%.7s' '$(AWG_REF)')

# ../talos-kernel now tags its published images by its own release tag (see that repo's
# Makefile/RELEASE_TAG_SAFE, mirroring ../bird) rather than a TALOS_VERSION+AWG_REF
# reconstruction - so versions.env's KERNEL_RELEASE pin names the exact talos-kernel
# release this build consumes, the same discipline BIRD_VERSION/AWG_REF already use for
# their own upstreams. Bump it by hand whenever you want to pick up a new talos-kernel
# release; TALOS_VERSION/AWG_REF stay as informational cross-checks (still folded into
# EXT_VERSION below) that the two repos' pins haven't silently drifted apart.
PKGS_NS  := ghcr.io/slipmesh
PKGS_TAG := $(subst +,-,$(KERNEL_RELEASE))

# Registry tag follows ../bird's own convention: the git release tag *is* the image tag
# (`+` swapped for `-`, since OCI tags can't contain `+`) - RELEASE_TAG is required, not
# derived from AGENTS_SHA, so a rebuild against unchanged pins still needs an explicit new
# release to publish under (the old AGENTS_SHA-keyed scheme's staleness fix - re-pushing
# under an unchanged tag has been observed to not reliably reach a node on `talosctl
# upgrade`, same digest hash across two different builds under one tag - is now just "cut
# a new release").
RELEASE_TAG_SAFE := $(subst +,-,$(RELEASE_TAG))
EXT_IMAGE := $(IMAGE):$(RELEASE_TAG_SAFE)-$(TARGET_ARCH)

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Show the resolved pins, arch and image names.
	@echo "talos            : $(TALOS_VERSION)"
	@echo "extensions ref   : $(UPSTREAM_EXTENSIONS_REF)"
	@echo "awg ref          : $(AWG_REF) ($(AWG_SHORT))"
	@echo "agents ref       : $(AGENTS_REF) (sibling at $(AGENTS_SHA))"
	@echo "kernel release   : $(KERNEL_RELEASE)"
	@echo "host arch        : $$(uname -m)"
	@echo "target arch      : $(TARGET_ARCH)"
	@echo "release tag      : $(RELEASE_TAG)"
	@echo "amneziawg pkg    : $(PKGS_NS)/amneziawg-pkg:$(PKGS_TAG)  (must exist - built by ../talos-kernel)"
	@echo "extension image  : $(EXT_IMAGE)"

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in docker git curl; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (permission denied or not running)"; fail=1; }; \
	command -v cargo >/dev/null || { echo "MISSING: cargo"; fail=1; }; \
	command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild (cargo install cargo-zigbuild --locked)"; fail=1; }; \
	[ -d $(AGENTS_DIR) ] || { echo "MISSING: sibling checkout $(AGENTS_DIR)"; fail=1; }; \
	docker buildx imagetools inspect $(PKGS_NS)/amneziawg-pkg:$(PKGS_TAG) >/dev/null 2>&1 || \
	  { echo "MISSING: $(PKGS_NS)/amneziawg-pkg:$(PKGS_TAG) - run 'make kernel' in ../talos-kernel first"; fail=1; }; \
	echo "host $$(uname -m)"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build

$(BUILD_DIR):
	@mkdir -p $@

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

.PHONY: check-agents
check-agents: ## Assert ../talos-extensions is checked out at AGENTS_REF.
	@test -d $(AGENTS_DIR) || { echo "sibling checkout not found: $(AGENTS_DIR)"; exit 1; }
	@have=$$(git -C $(AGENTS_DIR) describe --tags --exact-match HEAD 2>/dev/null || echo "<untagged>"); \
	if [ "$$have" = "$(AGENTS_REF)" ]; then \
	  echo "talos-extensions at $(AGENTS_REF)"; \
	else \
	  echo "MISMATCH: ../talos-extensions is at $$have, AGENTS_REF is $(AGENTS_REF)"; \
	  echo "the daemon baked into the extension would not be the one this release names"; \
	  exit 1; \
	fi

.PHONY: agents
agents: check-agents ## Cross-compile the ext-awg extension-service daemon (../talos-extensions).
	@command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild"; exit 1; }
	@rustup target add $(AGENT_RUST_TARGET) >/dev/null 2>&1 || true
	@echo "==> cross-compiling awg for $(TARGET_ARCH) ($(AGENT_RUST_TARGET))"
	@(cd $(AGENTS_DIR) && cargo zigbuild --release --target $(AGENT_RUST_TARGET) -p awg)

# AWG_REF/TALOS_VERSION alone are not enough to make this version string unique - ext-awg's
# own behavior changes on ../talos-extensions commits that don't touch either pin (its
# git SHA is included specifically so a rebuild after fixing something in that repo is
# never mistaken for a repeat of an earlier build under some cache, anywhere in the
# pipeline, keyed on this string).
#
# Field order matters, not just for readability: siderolabs' own extensions-validator
# only accepts a handful of exact version regexes, and this hash-first-then-"v"+semver
# shape happens to satisfy `commitBuildArgRegex` in its cmd/validate.go. The same value in
# a version-first field order is rejected outright - see talos-router-extension's Makefile
# for the exact regex.
EXT_VERSION := $(AWG_SHORT)-$(TALOS_VERSION)-$(AGENTS_SHA)

.PHONY: extension
extension: agents checkout-extensions ## Package the module + ext-awg into a Talos system extension image (bldr).
	@cp $(AGENTS_DIR)/target/$(AGENT_RUST_TARGET)/release/awg $(EXTENSIONS_DIR)/amneziawg/awg-bin
	@cp $(AGENTS_DIR)/extension-services/awg.yaml $(EXTENSIONS_DIR)/amneziawg/awg-service.yaml
	@echo "==> building $(EXT_IMAGE) ($(TARGET_ARCH))"
	@$(MAKE) -C $(EXTENSIONS_DIR) docker-amneziawg PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(EXT_IMAGE) --push=true \
	    --build-arg=PKGS_PREFIX=$(PKGS_NS) --build-arg=PKGS=$(PKGS_TAG) --build-arg=VERSION=$(EXT_VERSION)"
	@echo
	@echo "published: $(EXT_IMAGE)"
	@echo "talos-installer needs this ref to bundle it into an installer"

.PHONY: all
all: preflight extension ## Everything: agents -> extension image.

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute AWG_SHA256/AWG_SHA512 for the current AWG_REF (informational - this repo doesn't consume them, see ../talos-kernel).
	@tmp=$$(mktemp); \
	curl -sSL --fail "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/$(AWG_REF).tar.gz" -o "$$tmp"; \
	echo "AWG_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	echo "AWG_SHA512=$$(sha512sum "$$tmp" | cut -d' ' -f1)"; \
	rm -f "$$tmp"

.PHONY: clean
clean: ## No separate build output to drop - kept for symmetry with the other repos.
	@true

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkout.
	@rm -rf $(BUILD_DIR)
