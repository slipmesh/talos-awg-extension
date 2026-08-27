# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

## [0.1.5+talos1.13.9] - 2026-08-27

### Added ✨

- Package an ext-awg that serves per-peer metrics

### Documentation 📚

- Document the ext-awg metrics endpoint
- Verify road-warrior connectivity from the metrics endpoint
- Fix the grammar of the metrics sentence

## [0.1.4+talos1.13.9] - 2026-08-27

### Added ✨

- Track AmneziaWG 3.1 in the cross-check pin

### Miscellaneous 🧹

- Move markdownlint config to the cli2 file
- Pin the extensions checkout by release tag, not by commit
- Derive the extensions ref from the Talos version
- Package the kernel release that carries AmneziaWG 3.1

## [0.1.3+talos1.13.9] - 2026-08-26

### Documentation 📚

- Address the reader who cloned one repository, not five
- State the facts, drop how they were found
- State the facts, drop how they were found
- Scope the QEMU note to local builds

### Miscellaneous 🧹

- Add the standard markdownlint config, fix what it found

## [0.1.2+talos1.13.9] - 2026-08-19

### CI/CD ⚙️

- Pin amd64 matrix runner to ubuntu-24.04, not the floating ubuntu-latest alias

### Fixed 🐛

- Bump to Talos 1.13.9, pull AWG use-after-free fix

## [0.1.1+talos1.13.8] - 2026-08-18

### Added ✨

- Add installer/metal baking, stop publishing the extension
- Bundle ext-awg extension service, bump Talos/AmneziaWG pins
- Point at the full AmneziaWG 3.0 obfuscation field list
- Sign the AmneziaWG module for real: pkgs+extensions via Docker/bldr, drop sig_enforce=0

### CI/CD ⚙️

- Migrate to ghcr.io/slipmesh, add license files and release CI
- Tag releases like the bird repo: git release tag = published image tag
- Retag: awg-extension's release suffix is +talosX.Y.Z, not an awg ref
- Build arm64 on a native runner instead of QEMU-emulated amd64

### Changed 🔧

- Drop the throwaway registry - imager reads local OCI layouts directly
- Require explicit TARGET_ARCH, drop make metal, trim docs to essentials
- Split kernel build out into talos-kernel

### Documentation 📚

- Document net.ipv6.conf.default.keep_addr_on_down via machine.sysctls
- Document why EXT_VERSION's field order matters (extensions-validator regex)
- Document the fifth repo (talos-nftables-extension) in the split pipeline

### Fixed 🐛

- Publish a real multi-arch installer tag, fix a redundant kernel re-download
- Stop the build from overwriting the vanilla base installer tag; add `make release`
- Republish the extension, fix module signing and BTF ABI mismatch
