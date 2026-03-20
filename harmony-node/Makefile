include $(TOPDIR)/rules.mk

PKG_NAME:=harmony-node
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/zeblithic/harmony.git
PKG_SOURCE_VERSION:=2fc9f06fc1af424b1271e505677055016c18359c
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE:=$(PKG_SOURCE_SUBDIR).tar.gz
# Git-sourced packages generate the tarball locally from the cloned repo,
# so the hash varies by git/tar version. Set to the SHA-256 of the
# generated tarball after a first build:
#   sha256sum $(DL_DIR)/harmony-node-0.1.0.tar.gz
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

# Fetch Cargo dependencies while network is available (Build/Prepare
# runs before the offline Build/Compile phase in OpenWRT's buildroot).
# CARGO_HOME is isolated inside PKG_BUILD_DIR to avoid cache pollution
# from parallel builds or stale crates in ~/.cargo.
define Build/Prepare
	$(call Build/Prepare/Default)
	cd $(PKG_BUILD_DIR) && \
	CARGO_HOME=$(PKG_BUILD_DIR)/.cargo \
	cargo fetch --locked --target aarch64-unknown-linux-musl
endef

define Build/Compile
	cd $(PKG_BUILD_DIR) && \
	CARGO_HOME=$(PKG_BUILD_DIR)/.cargo \
	CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$(TARGET_CC)" \
	cargo build -p harmony-node \
		--features no-neon \
		--target aarch64-unknown-linux-musl \
		--profile release-cross \
		--offline \
		--locked
endef

define Package/harmony-node/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/aarch64-unknown-linux-musl/release-cross/harmony \
		$(1)/usr/bin/harmony

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/harmony-node.init $(1)/etc/init.d/harmony-node

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/harmony-node.conf $(1)/etc/config/harmony-node

	install -d -m 0700 $(1)/etc/harmony
endef

define Package/harmony-node/postrm
#!/bin/sh
# Only delete the identity key on full removal, not on upgrade.
# opkg passes "upgrade" as $$1 during upgrade cycles.
case "$$1" in
  upgrade) exit 0 ;;
esac
rm -rf /etc/harmony
exit 0
endef

$(eval $(call BuildPackage,harmony-node))
