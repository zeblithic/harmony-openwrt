# OpenWRT Package Feed — Design

**Date:** 2026-03-19
**Status:** Proposed
**Bead:** harmony-os-ted

## Problem

Harmony nodes should run on commodity WiFi 7 routers (GL.iNet Filogic 880 and similar aarch64 OpenWRT devices). There is no packaging infrastructure to build, distribute, or manage harmony-node on OpenWRT.

## Solution

A standalone OpenWRT package feed repo (`zeblithic/harmony-openwrt`) containing a package Makefile, procd init script, and UCI configuration for harmony-node. The package cross-compiles a static musl binary using Rust's bundled linker (no OpenWRT SDK dependency), installs it as a procd-supervised service, and is disabled by default until the event loop is wired.

## Prerequisites

- **Rust toolchain** with `aarch64-unknown-linux-musl` target installed
- **harmony core PR #73** merged — provides `.cargo/config.toml` (rust-lld linker config) and `[profile.release-cross]` (strip + thin LTO)

## Target Hardware

- **GL.iNet devices with MediaTek Filogic 880** (aarch64, Cortex-A53, 1-2 GB RAM)
- USB 3.0 ports available for persistent storage (future bead)
- OpenWRT with `opkg` package manager (newer snapshots may use `apk`)
- Only `aarch64` for v1 — MIPS support is a future extension

## Repository Structure

```
harmony-openwrt/
├── harmony-node/
│   ├── Makefile              # OpenWRT package Makefile
│   └── files/
│       ├── harmony-node.init  # procd init script (disabled by default)
│       └── harmony-node.conf  # UCI defaults
├── docs/
│   └── plans/
│       └── 2026-03-19-openwrt-package-feed-design.md
├── README.md                  # Feed setup + build instructions
└── LICENSE                    # Apache-2.0 OR MIT
```

The `harmony-node/` subdirectory follows OpenWRT feed conventions — each package gets its own directory. Future packages (e.g., `harmony-relay/` for lightweight relay-only nodes) can be added without restructuring.

## Feed Installation

Users add the feed to their OpenWRT build:

```bash
echo "src-git harmony https://github.com/zeblithic/harmony-openwrt.git" >> feeds.conf
./scripts/feeds update harmony
./scripts/feeds install harmony-node
make menuconfig  # select Network → harmony-node
make package/harmony-node/compile
```

## Package Makefile

### Complete Skeleton

```makefile
include $(TOPDIR)/rules.mk

PKG_NAME:=harmony-node
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/zeblithic/harmony.git
PKG_SOURCE_VERSION:=<pinned-commit-hash>
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE:=$(PKG_SOURCE_SUBDIR).tar.gz
PKG_MIRROR_HASH:=skip

PKG_BUILD_DEPENDS:=rust/host

include $(INCLUDE_DIR)/package.mk

define Package/harmony-node
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Harmony decentralized mesh node
  URL:=https://github.com/zeblithic/harmony
  DEPENDS:=@(aarch64)
endef

define Package/harmony-node/description
  A decentralized mesh networking node for the Harmony protocol.
  Statically linked binary — no runtime dependencies.
endef

define Package/harmony-node/conffiles
/etc/config/harmony-node
endef

define Build/Compile
	cd $(PKG_BUILD_DIR) && \
	CARGO_FEATURE_NO_NEON=1 \
	cargo build -p harmony-node \
		--target aarch64-unknown-linux-musl \
		--profile release-cross
endef

define Package/harmony-node/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/aarch64-unknown-linux-musl/release-cross/harmony \
		$(1)/usr/bin/harmony

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/harmony-node.init $(1)/etc/init.d/harmony-node

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/harmony-node.conf $(1)/etc/config/harmony-node
endef

$(eval $(call BuildPackage,harmony-node))
```

### Key Design Decisions

**`DEPENDS:=@(aarch64)`** — Constrains package visibility to aarch64 targets only. No sub-architecture pinning — the static binary runs on any aarch64 OpenWRT device, not just Cortex-A53.

**`conffiles`** — Declares `/etc/config/harmony-node` so `opkg upgrade` preserves user-modified configuration.

**No stripping step** — The `release-cross` profile in harmony core sets `strip = true`, so Cargo handles stripping natively. The output binary is already ~3 MB stripped.

**BLAKE3 NEON tradeoff:** NEON assembly is disabled (`CARGO_FEATURE_NO_NEON=1`) because the `cc` crate requires a C cross-compiler for NEON intrinsics. This is an env var read by blake3's `build.rs` to skip the NEON C/asm compilation. Pure Rust BLAKE3 is ~3x slower but negligible for mesh node workloads (small-message hashing).

**Upgrade path:** If the OpenWRT SDK toolchain is available, omit `CARGO_FEATURE_NO_NEON` and set `CC_aarch64_unknown_linux_musl=$(TARGET_CC)` instead. This re-enables NEON for full BLAKE3 throughput. A future improvement is adding a `no-neon` passthrough feature to `harmony-crypto`'s Cargo.toml for a cleaner mechanism.

## procd Init Script

Uses OpenWRT's procd init system for automatic restart on crash.

```sh
#!/bin/sh /etc/rc.common

START=95
USE_PROCD=1

start_service() {
    local enabled cache_capacity compute_budget
    local filter_broadcast_ticks filter_mutation_threshold
    local encrypted_durable_persist encrypted_durable_announce
    local no_public_ephemeral_announce

    config_load harmony-node
    config_get_bool enabled main enabled 0
    [ "$enabled" -eq 1 ] || return 0

    config_get cache_capacity main cache_capacity 256
    config_get compute_budget main compute_budget 100000
    config_get filter_broadcast_ticks main filter_broadcast_ticks 30
    config_get filter_mutation_threshold main filter_mutation_threshold 100
    config_get_bool encrypted_durable_persist main encrypted_durable_persist 0
    config_get_bool encrypted_durable_announce main encrypted_durable_announce 0
    config_get_bool no_public_ephemeral_announce main no_public_ephemeral_announce 0

    procd_open_instance
    procd_set_param command /usr/bin/harmony run \
        --cache-capacity "$cache_capacity" \
        --compute-budget "$compute_budget" \
        --filter-broadcast-ticks "$filter_broadcast_ticks" \
        --filter-mutation-threshold "$filter_mutation_threshold"

    [ "$encrypted_durable_persist" -eq 1 ] && \
        procd_append_param command --encrypted-durable-persist
    [ "$encrypted_durable_announce" -eq 1 ] && \
        procd_append_param command --encrypted-durable-announce
    [ "$no_public_ephemeral_announce" -eq 1 ] && \
        procd_append_param command --no-public-ephemeral-announce

    procd_set_param respawn
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "harmony-node"
}
```

- `START=95` — late boot, after networking
- `enabled` defaults to `0` — service does not start until explicitly enabled
- `procd_set_param respawn` — automatic restart on crash with default backoff
- `procd_set_param stderr 1` — capture stderr to logd/syslog
- `service_triggers()` — `uci commit harmony-node` automatically restarts the service

## UCI Configuration

```
config harmony-node 'main'
    option enabled '0'
    option cache_capacity '256'
    option compute_budget '100000'
    option filter_broadcast_ticks '30'
    option filter_mutation_threshold '100'
    option encrypted_durable_persist '0'
    option encrypted_durable_announce '0'
    option no_public_ephemeral_announce '0'
```

- `enabled '0'` — disabled by default (event loop not yet wired)
- `cache_capacity '256'` — intentionally lower than CLI default (1024) for router RAM constraints. Running `harmony run` directly on the router uses 1024; the service uses 256. This asymmetry is deliberate — the service default is tuned for constrained devices.
- Content policy flags default to `0` (off), matching CLI defaults
- Other values match `harmony run` CLI defaults

## README

Documents:
1. What this feed provides
2. Prerequisites (Rust toolchain with `aarch64-unknown-linux-musl` target)
3. Feed installation steps
4. Manual build instructions (outside OpenWRT buildroot)
5. Configuration via UCI (`uci set harmony-node.main.enabled=1`)
6. Upgrade path: using OpenWRT SDK toolchain for NEON-enabled blake3

## Testing

### Structural (automated)
- Makefile variable validation (correct `PKG_*` fields, valid paths)
- Init script shellcheck
- UCI config syntax

### End-to-end (manual, documented in README)
- `make package/harmony-node/compile` in OpenWRT buildroot
- `opkg install harmony-node_*.ipk` on target device
- `/etc/init.d/harmony-node enable && /etc/init.d/harmony-node start`
- Verify process runs under procd: `ps | grep harmony`
- Verify restart on kill: `kill $(pidof harmony)`, confirm procd restarts it
- Verify config reload: `uci set harmony-node.main.cache_capacity=512 && uci commit harmony-node`, confirm service restarts

## Future Extensions

| Extension | Notes |
|-----------|-------|
| MIPS support | Add `mipsel-unknown-linux-musl` target triple, test on MIPS routers |
| `apk` packages | Newer OpenWRT snapshots use Alpine's apk — same Makefile, different output |
| OpenWRT SDK CI | GitHub Actions with OpenWRT SDK Docker image for automated ipk builds |
| `harmony-relay` package | Lightweight relay-only node (no compute, no content storage) |
| USB persistent storage | Mount detection, filesystem setup, key hierarchy persistence (harmony-os-qyp) |
| LuCI integration | Web UI page for harmony-node configuration |
| `no-neon` feature passthrough | Add Cargo feature to harmony-crypto for cleaner NEON disable mechanism |

## What Does NOT Change

- harmony core codebase — no modifications needed (cross-compile config already merged in PR #73)
- harmony-os — unaffected, separate deployment model
- `harmony-node` CLI interface — init script wraps existing flags
