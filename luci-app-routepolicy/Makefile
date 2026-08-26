include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-routepolicy
PKG_VERSION:=0.2.7
PKG_RELEASE:=1
PKG_LICENSE:=MIT

LUCI_TITLE:=LuCI support for RoutePolicy
LUCI_DESCRIPTION:=Safe operational interface for RoutePolicy policy routing
LUCI_DEPENDS:=+routepolicy +luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
