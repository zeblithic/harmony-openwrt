# x86_64 Target Support

**Date:** 2026-03-24
**Status:** Draft
**Scope:** `harmony-node/Makefile`, `README.md`
**Bead:** harmony-openwrt-bte

## Problem

The Makefile hardcodes `aarch64-unknown-linux-musl` in 5 places and
`DEPENDS:=@(aarch64)` restricts the package to aarch64 only. Many
OpenWRT devices and VMs run x86_64.

## Solution

Derive the Rust target triple from OpenWRT's `$(ARCH)` variable using
a Makefile conditional. Use `$(RUST_TARGET)` everywhere the triple
appears. Expand `DEPENDS` to allow both architectures.

## Makefile Architecture Mapping

```makefile
ifeq ($(ARCH),aarch64)
  RUST_TARGET:=aarch64-unknown-linux-musl
else ifeq ($(ARCH),x86_64)
  RUST_TARGET:=x86_64-unknown-linux-musl
else
  $(error Unsupported architecture: $(ARCH))
endif
```

The `CARGO_TARGET_*_LINKER` env var embeds the triple in uppercase
with hyphens → underscores. Computed via `$(shell ...)` or Make's
`subst` function.

## Changes

All 5 hardcoded references become `$(RUST_TARGET)`:

1. `DEPENDS:=@(aarch64||x86_64)` — allow both in menuconfig
2. `cargo fetch --target $(RUST_TARGET)` — fetch deps for target
3. `CARGO_TARGET_<UPPER>_LINKER=$(TARGET_CC)` — dynamic env var name
4. `cargo build --target $(RUST_TARGET)` — cross-compile
5. `$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release-cross/harmony` — binary path

Both architectures use `--features no-neon` (pure Rust BLAKE3).
The `no-neon` feature disables all BLAKE3 assembly, not just NEON.

## File Changes

| File | Change |
|------|--------|
| `harmony-node/Makefile` | Dynamic RUST_TARGET, DEPENDS for both arches, PKG_RELEASE bump |
| `README.md` | Add x86_64 target references |

## Not in Scope

- Other architectures (mips, arm32) — same pattern, add when needed
- NEON/SSE optimization — both use pure Rust BLAKE3

## Testing

- Build with `ARCH=aarch64`: verify cargo targets aarch64-unknown-linux-musl
- Build with `ARCH=x86_64`: verify cargo targets x86_64-unknown-linux-musl
- Build with unsupported arch: verify `$(error ...)` fires
- `make menuconfig`: verify package visible for both aarch64 and x86_64
