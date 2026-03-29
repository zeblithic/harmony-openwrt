include $(TOPDIR)/rules.mk

PKG_NAME:=harmony-node
PKG_VERSION:=0.1.0
PKG_RELEASE:=10

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/zeblithic/harmony.git
PKG_SOURCE_VERSION:=73f526a7134979892001c9e29af1a4920a6aa95f
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE:=$(PKG_SOURCE_SUBDIR).tar.gz
# Git-sourced packages generate the tarball locally from the cloned repo,
# so the hash varies by git/tar version. Set to the SHA-256 of the
# generated tarball after a first build:
#   sha256sum $(DL_DIR)/harmony-node-0.1.0.tar.gz
PKG_MIRROR_HASH:=skip

PKG_BUILD_DEPENDS:=rust/host

# Map OpenWRT arch to Rust target triple and BLAKE3 feature flags.
# aarch64: --features no-neon disables NEON assembly (avoids cc crate for NEON intrinsics)
# x86_64: no feature flag — SSE2/AVX2 assembly compiles fine with $(TARGET_CC) from SDK
ifeq ($(ARCH),aarch64)
  RUST_TARGET:=aarch64-unknown-linux-musl
  RUST_FEATURES:=--features no-neon
else ifeq ($(ARCH),x86_64)
  RUST_TARGET:=x86_64-unknown-linux-musl
  RUST_FEATURES:=
else
  # Sentinel — Build/Compile will error if this package is actually selected.
  RUST_TARGET:=unsupported-$(ARCH)
  RUST_FEATURES:=
endif

# Cargo linker env var: CARGO_TARGET_<UPPER_TRIPLE>_LINKER (uppercase)
RUST_TARGET_UPPER:=$(shell echo '$(RUST_TARGET)' | tr 'a-z-' 'A-Z_')
# cc-crate compiler env var: CC_<lower_triple> (lowercase with underscores)
RUST_TARGET_LOWER_US:=$(subst -,_,$(RUST_TARGET))

include $(INCLUDE_DIR)/package.mk

define Package/harmony-node
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Harmony decentralized mesh node
  URL:=https://github.com/zeblithic/harmony
  DEPENDS:=@(aarch64||x86_64) +block-mount
endef

define Package/harmony-node/description
  A decentralized mesh networking node for the Harmony protocol.
  Statically linked binary — no runtime dependencies.
  For WiFi mesh: install wpad-mesh-wolfssl. Setup guide: https://github.com/zeblithic/harmony-openwrt/blob/main/docs/mesh-wifi-setup.md
endef

define Package/harmony-node/conffiles
/etc/config/harmony-node
/etc/harmony-node.firewall
endef

# Fetch Cargo dependencies while network is available (Build/Prepare
# runs before the offline Build/Compile phase in OpenWRT's buildroot).
# CARGO_HOME is isolated inside PKG_BUILD_DIR to avoid cache pollution
# from parallel builds or stale crates in ~/.cargo.
define Build/Prepare
	$(if $(findstring unsupported,$(RUST_TARGET)),$(error Unsupported architecture: $(ARCH). Supported: aarch64, x86_64))
	$(call Build/Prepare/Default)
	cd $(PKG_BUILD_DIR) && \
	CARGO_HOME=$(PKG_BUILD_DIR)/.cargo \
	cargo fetch --locked --target $(RUST_TARGET)
endef

define Build/Compile
	cd $(PKG_BUILD_DIR) && \
	CARGO_HOME=$(PKG_BUILD_DIR)/.cargo \
	CARGO_TARGET_$(RUST_TARGET_UPPER)_LINKER="$(TARGET_CC)" \
	CC_$(RUST_TARGET_LOWER_US)="$(TARGET_CC)" \
	cargo build -p harmony-node \
		$(RUST_FEATURES) \
		--target $(RUST_TARGET) \
		--profile release-cross \
		--offline \
		--locked
endef

define Package/harmony-node/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release-cross/harmony \
		$(1)/usr/bin/harmony

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/harmony-node.init $(1)/etc/init.d/harmony-node

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/harmony-node.conf $(1)/etc/config/harmony-node

	install -d -m 0750 $(1)/etc/harmony
	chown 473:473 $(1)/etc/harmony 2>/dev/null || true

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/harmony-node.keep $(1)/lib/upgrade/keep.d/harmony-node

	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_BIN) ./files/harmony-node.firewall $(1)/etc/harmony-node.firewall

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/harmony-node.uci-defaults $(1)/etc/uci-defaults/99-harmony-node-setup
endef

define Package/harmony-node/postinst
#!/bin/sh
# Create harmony system user/group (UID/GID 473, no login shell).
# Runs in BOTH ImageBuilder and live-install contexts — writes to
# $$IPKG_INSTROOT prefix (empty for live, set for ImageBuilder).
# Idempotent: skips if user name or UID 473 already exists.
_PASSWD="$${IPKG_INSTROOT}/etc/passwd"
_GROUP="$${IPKG_INSTROOT}/etc/group"
if ! grep -q '^harmony:' "$$_PASSWD" 2>/dev/null && \
   ! grep -q ':473:' "$$_PASSWD" 2>/dev/null; then
  echo 'harmony:x:473:473:harmony:/var/lib/harmony:/bin/false' >> "$$_PASSWD"
fi
if ! grep -q '^harmony:' "$$_GROUP" 2>/dev/null && \
   ! grep -q ':473:' "$$_GROUP" 2>/dev/null; then
  echo 'harmony:x:473:' >> "$$_GROUP"
fi

# Own the identity key directory so the unprivileged process can read it.
# ImageBuilder: use numeric UID 473 (username resolves against build host, not target).
# If a 'harmony' user already exists with a different UID in the base image,
# this chown will be incorrect — an extremely unlikely edge case.
chown -R 473:473 "$${IPKG_INSTROOT}/etc/harmony" 2>/dev/null || true

# Skip remaining steps during ImageBuilder — UCI writes would target
# the build host, not the device.
[ -n "$$IPKG_INSTROOT" ] && exit 0

# Live install: fix /etc/harmony ownership by name (resolves correctly
# on the running system, unlike the numeric ImageBuilder path above).
chown -R harmony:harmony /etc/harmony

# Create and own volatile data directory (lost on reboot if /var → tmpfs).
# Also recreated in start_service() for reboot resilience.
mkdir -p /var/lib/harmony
chown harmony:harmony /var/lib/harmony
chmod 750 /var/lib/harmony

# Run the uci-defaults script directly for live installs.
# It is fully idempotent (skips firewall/mesh setup if already configured)
# and handles both firewall include registration and HARMONY-MESH VIF creation.
if [ -x /etc/uci-defaults/99-harmony-node-setup ]; then
  /etc/uci-defaults/99-harmony-node-setup || \
    logger -t "harmony-node" "WARNING: setup failed (uci commit error?); will retry on next boot"
fi
# Ensure firewall rules are active (idempotent — harmless if uci-defaults
# already reloaded the firewall during setup).
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload
exit 0
endef

define Package/harmony-node/prerm
#!/bin/sh
# On upgrade, only stop the service; preserve the boot-enable symlinks.
# On full removal, disable first so the service doesn't try to start
# after the binary is gone.
case "$$1" in
  upgrade) ;;
  *) [ -f /etc/init.d/harmony-node ] && /etc/init.d/harmony-node disable ;;
esac
[ -f /etc/init.d/harmony-node ] && /etc/init.d/harmony-node stop
exit 0
endef

define Package/harmony-node/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
# Only clean up on full removal, not on upgrade.
case "$$1" in
  upgrade) exit 0 ;;
esac
rm -rf /etc/harmony /var/lib/harmony
# Remove harmony system user/group (best-effort).
sed -i '/^harmony:/d' /etc/passwd 2>/dev/null
sed -i '/^harmony:/d' /etc/group 2>/dev/null
# Remove all harmony UCI configuration.
# Order: wireless first (disconnect mesh peers before changing firewall),
# then firewall (zone + rules + include), then network/DHCP.
# 1. Wireless — disconnect peers before any rule changes
if [ -n "$$(uci -q get wireless.harmony_mesh)" ]; then
  uci delete wireless.harmony_mesh
  if uci commit wireless; then
    [ -x /sbin/wifi ] && wifi reload
  else
    logger -t "harmony-node" "WARNING: uci commit wireless failed during removal — harmony_mesh may persist"
  fi
fi
# 2. Firewall: include + zone + all port rules
uci -q delete firewall.harmony_node
uci -q delete firewall.harmony_reticulum
uci -q delete firewall.harmony_zenoh
uci -q delete firewall.harmony_iroh
uci -q delete firewall.harmony_dns
uci -q delete firewall.harmony_dhcp
uci -q delete firewall.harmony_zone
if uci commit firewall; then
  [ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload
else
  logger -t "harmony-node" "WARNING: uci commit firewall failed during removal — harmony firewall rules may persist"
fi
# 3. DHCP
uci -q delete dhcp.harmony
if uci commit dhcp; then
  [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq reload
else
  logger -t "harmony-node" "WARNING: uci commit dhcp failed during removal — harmony DHCP config may persist"
fi
# 4. Network
uci -q delete network.harmony
uci -q delete network.br_harmony
if uci commit network; then
  [ -x /etc/init.d/network ] && /etc/init.d/network reload
else
  logger -t "harmony-node" "WARNING: uci commit network failed during removal — harmony network config may persist"
fi
exit 0
endef

$(eval $(call BuildPackage,harmony-node))
