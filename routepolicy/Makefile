include $(TOPDIR)/rules.mk

PKG_NAME:=routepolicy
PKG_VERSION:=0.2.7
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=RoutePolicy contributors

include $(INCLUDE_DIR)/package.mk

define Package/routepolicy
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Policy routing with nftables and SmartDNS
  URL:=https://github.com/FelixJI/openwrt-routepolicy
  DEPENDS:=+nftables +ip-full +curl +ca-bundle +jsonfilter +ubus +uci +smartdns
endef

define Package/routepolicy/description
 RoutePolicy maintains an isolated nftables table, masked connection marks,
 a fail-closed policy routing table, and validated SmartDNS list integration.
endef

define Package/routepolicy/conffiles
/etc/config/routepolicy
/etc/routepolicy/user.d/domain-policy.list
/etc/routepolicy/user.d/domain-default.list
/etc/routepolicy/user.d/ipv4-policy.list
/etc/routepolicy/user.d/ipv4-default.list
/etc/routepolicy/user.d/local-hosts.list
endef

define Build/Compile
endef

define Package/routepolicy/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/etc/routepolicy/user.d $(1)/etc/routepolicy/managed.d/current
	$(INSTALL_DIR) $(1)/etc/routepolicy/managed.d/previous $(1)/etc/routepolicy/state
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/usr/libexec/routepolicy/converters
	$(INSTALL_CONF) ./files/etc/config/routepolicy $(1)/etc/config/routepolicy
	$(INSTALL_BIN) ./files/etc/init.d/routepolicy $(1)/etc/init.d/routepolicy
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/95-routepolicy $(1)/etc/hotplug.d/iface/95-routepolicy
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/routepolicy $(1)/lib/upgrade/keep.d/routepolicy
	$(INSTALL_BIN) ./files/usr/sbin/routepolicyctl $(1)/usr/sbin/routepolicyctl
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/apply $(1)/usr/libexec/routepolicy/apply
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/common $(1)/usr/libexec/routepolicy/common
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/converter-lib $(1)/usr/libexec/routepolicy/converter-lib
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/diagnose $(1)/usr/libexec/routepolicy/diagnose
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/import-legacy $(1)/usr/libexec/routepolicy/import-legacy
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/render $(1)/usr/libexec/routepolicy/render
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/rollback $(1)/usr/libexec/routepolicy/rollback
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/scheduler $(1)/usr/libexec/routepolicy/scheduler
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/smartdns-control $(1)/usr/libexec/routepolicy/smartdns-control
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/status $(1)/usr/libexec/routepolicy/status
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/update $(1)/usr/libexec/routepolicy/update
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/user-list $(1)/usr/libexec/routepolicy/user-list
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/validate $(1)/usr/libexec/routepolicy/validate
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/warm-state $(1)/usr/libexec/routepolicy/warm-state
	$(INSTALL_BIN) ./files/usr/libexec/routepolicy/watch $(1)/usr/libexec/routepolicy/watch
	$(CP) ./files/usr/libexec/routepolicy/converters/* $(1)/usr/libexec/routepolicy/converters/
	$(INSTALL_DATA) ./files/etc/routepolicy/user.d/* $(1)/etc/routepolicy/user.d/
endef

define Package/routepolicy/postrm
#!/bin/sh
[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0
for section in $$(uci -q show smartdns 2>/dev/null | sed -n 's/^smartdns\.\([A-Za-z0-9_][A-Za-z0-9_]*\)=smartdns$$/\1/p'); do
	uci -q del_list "smartdns.$$section.conf_files=/etc/smartdns/conf.d/90-routepolicy.conf" >/dev/null 2>&1 || true
	uci -q del_list "smartdns.$$section.conf_files=/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf" >/dev/null 2>&1 || true
done
uci commit smartdns >/dev/null 2>&1 || true
rm -f /etc/smartdns/conf.d/90-routepolicy.conf /etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf
[ ! -x /etc/init.d/smartdns ] || /etc/init.d/smartdns reload >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,routepolicy))
