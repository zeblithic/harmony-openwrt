# OpenWRT Package Feed — Design

**Date:** 2026-03-19
**Status:** Proposed
**Bead:** harmony-os-ted

## Problem

Harmony nodes should run on commodity WiFi 7 routers (GL.iNet Filogic 880 and similar aarch64 OpenWRT devices). There is no packaging infrastructure to build, distribute, or manage harmony-node on OpenWRT.

## Solution

A standalone OpenWRT package feed repo (`zeblithic/harmony-openwrt`) containing a package Makefile, procd init script, and UCI configuration for harmony-node. The package cross-compiles a static musl binary using Rust's bundled linker (no OpenWRT SDK dependency), installs it as a procd-supervised service, and is disabled by default until the event loop is wired.

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

### Metadata

| Field | Value |
|-------|-------|
| `PKG_NAME` | `harmony-node` |
| `PKG_VERSION` | `0.1.0` (tracks harmony core workspace version) |
| `PKG_RELEASE` | `1` |
| `PKG_SOURCE_PROTO` | `git` |
| `PKG_SOURCE_URL` | `https://github.com/zeblithic/harmony.git` |
| `PKG_SOURCE_VERSION` | pinned commit hash |
| `SECTION` | `net` |
| `CATEGORY` | `Network` |
| `DEPENDS` | none (static binary) |
| `PKGARCH` | `aarch64_cortex-a53` |

### Build

The `Build/Compile` target invokes Cargo directly:

```makefile
define Build/Compile
	cd $(PKG_BUILD_DIR) && \
	CARGO_FEATURE_NO_NEON=1 \
	cargo build -p harmony-node \
		--target aarch64-unknown-linux-musl \
		--profile release-cross
endef
```

This uses the `.cargo/config.toml` from harmony core (merged in PR #73) which configures `rust-lld` as the linker with self-contained linking. No OpenWRT SDK C cross-compiler required.

**BLAKE3 NEON tradeoff:** NEON assembly is disabled (`CARGO_FEATURE_NO_NEON=1`) because the `cc` crate requires a C cross-compiler for NEON intrinsics. Pure Rust BLAKE3 is ~3x slower but negligible for mesh node workloads (small-message hashing). If the OpenWRT SDK toolchain is available, `CARGO_FEATURE_NO_NEON` can be omitted and `CC_aarch64_unknown_linux_musl=$(TARGET_CC)` set instead — this is documented as an upgrade path.

### Install

```makefile
define Package/harmony-node/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/aarch64-unknown-linux-musl/release-cross/harmony \
		$(1)/usr/bin/harmony

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/harmony-node.init $(1)/etc/init.d/harmony-node

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/harmony-node.conf $(1)/etc/config/harmony-node
endef
```

Installed files:

| Path | Purpose |
|------|---------|
| `/usr/bin/harmony` | Static aarch64 binary (~3 MB) |
| `/etc/init.d/harmony-node` | procd init script |
| `/etc/config/harmony-node` | UCI defaults |

## procd Init Script

Uses OpenWRT's procd init system for automatic restart on crash.

```sh
#!/bin/sh /etc/rc.common

START=95
USE_PROCD=1

start_service() {
    local enabled cache_capacity compute_budget
    local filter_broadcast_ticks filter_mutation_threshold

    config_load harmony-node
    config_get_bool enabled main enabled 0
    [ "$enabled" -eq 1 ] || return 0

    config_get cache_capacity main cache_capacity 256
    config_get compute_budget main compute_budget 100000
    config_get filter_broadcast_ticks main filter_broadcast_ticks 30
    config_get filter_mutation_threshold main filter_mutation_threshold 100

    procd_open_instance
    procd_set_param command /usr/bin/harmony run \
        --cache-capacity "$cache_capacity" \
        --compute-budget "$compute_budget" \
        --filter-broadcast-ticks "$filter_broadcast_ticks" \
        --filter-mutation-threshold "$filter_mutation_threshold"
    procd_set_param respawn
    procd_set_param stderr 1
    procd_close_instance
}
```

- `START=95` — late boot, after networking
- `enabled` defaults to `0` — service does not start until explicitly enabled
- `procd_set_param respawn` — automatic restart on crash with default backoff
- `procd_set_param stderr 1` — capture stderr to logd/syslog

## UCI Configuration

```
config harmony-node 'main'
    option enabled '0'
    option cache_capacity '256'
    option compute_budget '100000'
    option filter_broadcast_ticks '30'
    option filter_mutation_threshold '100'
```

- `enabled '0'` — disabled by default (event loop not yet wired)
- `cache_capacity '256'` — lower than desktop default (1024) for router RAM constraints
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

## Future Extensions

| Extension | Notes |
|-----------|-------|
| MIPS support | Add `mipsel-unknown-linux-musl` target triple, test on MIPS routers |
| `apk` packages | Newer OpenWRT snapshots use Alpine's apk — same Makefile, different output |
| OpenWRT SDK CI | GitHub Actions with OpenWRT SDK Docker image for automated ipk builds |
| `harmony-relay` package | Lightweight relay-only node (no compute, no content storage) |
| USB persistent storage | Mount detection, filesystem setup, key hierarchy persistence (harmony-os-qyp) |
| LuCI integration | Web UI page for harmony-node configuration |

## What Does NOT Change

- harmony core codebase — no modifications needed (cross-compile config already merged)
- harmony-os — unaffected, separate deployment model
- `harmony-node` CLI interface — init script wraps existing flags
