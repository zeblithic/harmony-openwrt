include $(TOPDIR)/rules.mk

PKG_NAME:=harmony-node
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/zeblithic/harmony.git
PKG_SOURCE_VERSION:=6f6121870a7e237bc5fdd05a78d8ddd4f4df3888
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
endef

$(eval $(call BuildPackage,harmony-node))
