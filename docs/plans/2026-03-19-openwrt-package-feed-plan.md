# OpenWRT Package Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an OpenWRT package feed that builds and packages harmony-node for aarch64 routers.

**Architecture:** A standalone feed repo with one package (`harmony-node`). The Makefile fetches harmony core via git, cross-compiles with Cargo, and installs a static binary + procd init script + UCI config. No OpenWRT SDK required — uses rust-lld for linking.

**Tech Stack:** OpenWRT build system (Makefile), procd (init), UCI (config), shell (init script)

**Spec:** `docs/plans/2026-03-19-openwrt-package-feed-design.md`

**Repo:** `zeblithic/harmony-openwrt` at `/Users/zeblith/work/zeblithic/harmony-openwrt`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `harmony-node/Makefile` | OpenWRT package definition: metadata, source fetch, build, install |
| `harmony-node/files/harmony-node.init` | procd init script: reads UCI config, launches harmony with correct flags |
| `harmony-node/files/harmony-node.conf` | UCI defaults: disabled service, router-tuned parameters |
| `README.md` | Feed setup, prerequisites, build instructions, configuration guide |

---

### Task 1: UCI Configuration Defaults

**Files:**
- Create: `harmony-node/files/harmony-node.conf`

- [ ] **Step 1: Create the UCI config file**

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

Note: UCI config files use **tabs** for indentation, not spaces. All options match `harmony run` CLI defaults except `cache_capacity` (256 vs CLI's 1024 — intentionally lower for router RAM constraints) and `enabled` (0 — service disabled until event loop is wired).

- [ ] **Step 2: Verify file uses tabs**

Run: `cat -A harmony-node/files/harmony-node.conf | head -3`
Expected: Lines starting with `^I` (tab), NOT spaces.

- [ ] **Step 3: Commit**

```bash
git add harmony-node/files/harmony-node.conf
git commit -m "feat: add UCI configuration defaults for harmony-node"
```

---

### Task 2: procd Init Script

**Files:**
- Create: `harmony-node/files/harmony-node.init`

- [ ] **Step 1: Create the init script**

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

Note: This file must use **tabs** for indentation and have the executable bit set. The shebang `#!/bin/sh /etc/rc.common` is OpenWRT-specific — it sources the rc.common library which provides `config_load`, `config_get`, `procd_*` functions.

- [ ] **Step 2: Make executable**

Run: `chmod +x harmony-node/files/harmony-node.init`

- [ ] **Step 3: Verify shellcheck passes**

Run: `shellcheck -s sh harmony-node/files/harmony-node.init || echo "shellcheck not available — skip"`

Note: shellcheck may warn about OpenWRT-specific functions (`config_load`, `procd_*`) being undefined — these are sourced at runtime by `/etc/rc.common`. Warnings about undefined functions are expected and acceptable.

- [ ] **Step 4: Commit**

```bash
git add harmony-node/files/harmony-node.init
git commit -m "feat: add procd init script for harmony-node"
```

---

### Task 3: OpenWRT Package Makefile

**Files:**
- Create: `harmony-node/Makefile`

- [ ] **Step 1: Create the Makefile**

```makefile
include $(TOPDIR)/rules.mk

PKG_NAME:=harmony-node
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/zeblithic/harmony.git
PKG_SOURCE_VERSION:=d2bdde6
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

Note: OpenWRT Makefiles use **tabs** for recipe lines (the indented lines inside `define` blocks). The `PKG_SOURCE_VERSION` is pinned to `d2bdde6` (harmony core main with cross-compile config from PR #73). Update this hash when upgrading to newer harmony releases.

- [ ] **Step 2: Verify Makefile uses tabs for indentation**

Run: `cat -A harmony-node/Makefile | grep '^\^I'`
Expected: Recipe lines start with `^I` (tab character).

- [ ] **Step 3: Commit**

```bash
git add harmony-node/Makefile
git commit -m "feat: add OpenWRT package Makefile for harmony-node"
```

---

### Task 4: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create the README**

```markdown
# harmony-openwrt

OpenWRT package feed for [Harmony](https://github.com/zeblithic/harmony) mesh networking.

## Packages

| Package | Description |
|---------|-------------|
| `harmony-node` | Harmony decentralized mesh node (~3 MB static binary) |

## Prerequisites

- Rust toolchain with the `aarch64-unknown-linux-musl` target:
  ```bash
  rustup target add aarch64-unknown-linux-musl
  ```
- OpenWRT buildroot (or SDK) for your target device

## Feed Setup

Add this feed to your OpenWRT buildroot:

```bash
echo "src-git harmony https://github.com/zeblithic/harmony-openwrt.git" >> feeds.conf
./scripts/feeds update harmony
./scripts/feeds install harmony-node
```

Then select the package in menuconfig:

```bash
make menuconfig
# Navigate: Network → harmony-node → <*> (built-in) or <M> (module)
```

Build:

```bash
make package/harmony-node/compile
```

The output `.ipk` is in `bin/packages/<arch>/harmony/`.

## Standalone Build (without OpenWRT buildroot)

To cross-compile harmony-node directly:

```bash
git clone https://github.com/zeblithic/harmony.git
cd harmony
CARGO_FEATURE_NO_NEON=1 cargo build -p harmony-node \
    --target aarch64-unknown-linux-musl \
    --profile release-cross
```

The binary is at `target/aarch64-unknown-linux-musl/release-cross/harmony`.
Copy it to `/usr/bin/harmony` on your router via scp.

## Configuration

The service is managed via UCI and procd.

### Enable the service

```bash
uci set harmony-node.main.enabled=1
uci commit harmony-node
/etc/init.d/harmony-node enable
/etc/init.d/harmony-node start
```

### Configuration options

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | `0` | Enable/disable the service |
| `cache_capacity` | `256` | W-TinyLFU cache items (CLI default: 1024) |
| `compute_budget` | `100000` | WASM compute fuel per tick |
| `filter_broadcast_ticks` | `30` | Bloom filter broadcast interval |
| `filter_mutation_threshold` | `100` | Bloom filter mutation threshold |
| `encrypted_durable_persist` | `0` | Accept encrypted durable content |
| `encrypted_durable_announce` | `0` | Announce encrypted durable content |
| `no_public_ephemeral_announce` | `0` | Disable public ephemeral announcements |

Edit with `uci`:

```bash
uci set harmony-node.main.cache_capacity=512
uci commit harmony-node
# Service restarts automatically via procd trigger
```

Or edit `/etc/config/harmony-node` directly and restart:

```bash
/etc/init.d/harmony-node restart
```

## BLAKE3 NEON Performance

By default, the build disables BLAKE3 NEON assembly (`CARGO_FEATURE_NO_NEON=1`)
because cross-compilation requires a C cross-compiler for NEON intrinsics. This
uses a pure Rust fallback (~3x slower hashing, negligible for mesh workloads).

To enable NEON (requires OpenWRT SDK or a musl cross-compiler):

```bash
# In the OpenWRT buildroot, the SDK provides TARGET_CC:
CC_aarch64_unknown_linux_musl=$(TARGET_CC) cargo build -p harmony-node \
    --target aarch64-unknown-linux-musl \
    --profile release-cross
```

## License

Apache-2.0 OR MIT — same as [harmony core](https://github.com/zeblithic/harmony).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with feed setup, build, and configuration guide"
```

---

### Task 5: Final Validation and Push

- [ ] **Step 1: Verify repo structure**

Run: `find . -not -path './.git/*' -not -path './.git' -type f | sort`

Expected:
```
./LICENSE
./README.md
./docs/plans/2026-03-19-openwrt-package-feed-design.md
./docs/plans/2026-03-19-openwrt-package-feed-plan.md
./harmony-node/Makefile
./harmony-node/files/harmony-node.conf
./harmony-node/files/harmony-node.init
```

- [ ] **Step 2: Verify all files use correct indentation**

Run: `file harmony-node/files/harmony-node.init` → should show "POSIX shell script"
Run: `head -1 harmony-node/files/harmony-node.init` → should show `#!/bin/sh /etc/rc.common`
Run: `head -1 harmony-node/Makefile` → should show `include $(TOPDIR)/rules.mk`

- [ ] **Step 3: Push**

```bash
git push
```

- [ ] **Step 4: Verify on GitHub**

Run: `gh repo view zeblithic/harmony-openwrt --web` or check the repo on GitHub.

- [ ] **Step 5: Close bead**

Run from harmony-os repo:
```bash
cd /Users/zeblith/work/zeblithic/harmony-os
bd close harmony-os-ted --reason "OpenWRT package feed created: Makefile + procd init + UCI config in zeblithic/harmony-openwrt. Targets aarch64 GL.iNet Filogic 880."
```
