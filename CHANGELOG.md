# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

## [0.1.0+talos1.13.8] - 2026-08-18

### Added ✨

- Add installer/metal baking, stop publishing the extension
- Bundle ext-awg extension service, bump Talos/AmneziaWG pins
- Point at the full AmneziaWG 3.0 obfuscation field list
- Sign the AmneziaWG module for real: pkgs+extensions via Docker/bldr, drop sig_enforce=0

### CI/CD ⚙️

- Migrate to ghcr.io/slipmesh, add license files and release CI
- Tag releases like ../bird: git release tag = published image tag
- Retag: awg-extension's release suffix is +talosX.Y.Z, not +awg<ref>
- Build arm64 on a native runner instead of QEMU-emulated amd64

### Changed 🔧

- Drop the throwaway registry - imager reads local OCI layouts directly
- Require explicit TARGET_ARCH, drop make metal, trim docs to essentials
- Split kernel build out into ../talos-kernel

### Documentation 📚

- Document net.ipv6.conf.default.keep_addr_on_down via machine.sysctls
- Document why EXT_VERSION's field order matters (extensions-validator regex)
- Document the fifth repo (talos-nftables-extension) in the split pipeline

### Fixed 🐛

- Publish a real multi-arch installer tag, fix a redundant kernel re-download
- Stop the build from overwriting the vanilla base installer tag; add `make release`
- Republish the extension, fix module signing and BTF ABI mismatch
