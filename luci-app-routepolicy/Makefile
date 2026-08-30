include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-routepolicy
PKG_VERSION:=0.3.3
PKG_RELEASE:=1
PKG_LICENSE:=MIT

LUCI_TITLE:=LuCI support for RoutePolicy
LUCI_DESCRIPTION:=Safe operational interface for RoutePolicy policy routing
LUCI_DEPENDS:=+routepolicy +luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
if ! /etc/init.d/rpcd restart; then
	exit 1
fi
ubus -t 10 wait_for routepolicy
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
