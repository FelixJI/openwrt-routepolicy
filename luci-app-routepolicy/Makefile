include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-routepolicy
PKG_VERSION:=0.3.3
PKG_RELEASE:=2
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

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
if ! /etc/init.d/rpcd restart; then
	exit 1
fi
if ! ubus -t 10 wait_for rc; then
	echo 'luci-app-routepolicy: rpcd did not return to ubus after removal' >&2
	exit 1
fi
objects="$$(ubus list)" || {
	echo 'luci-app-routepolicy: ubus is unavailable; routepolicy object removal cannot be proven' >&2
	exit 1
}
if printf '%s\n' "$$objects" | grep -qx routepolicy; then
	echo 'luci-app-routepolicy: the routepolicy ubus object survived package removal' >&2
	exit 1
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
