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

snap_files=/var/run/rpcd/snapshot-files
snap_delta=/var/run/rpcd/snapshot-delta
if [ -e "$$snap_files" ] || [ -L "$$snap_files" ] || [ -e "$$snap_delta" ] || [ -L "$$snap_delta" ]; then
	echo "luci-app-routepolicy: 检测到 rpcd 快照（$$snap_files 或 $$snap_delta；可能是待确认/回滚的原生 uci apply，或中断遗留）。为保留未提交配置与回滚数据，本钩子不执行 rpcd reload，也不清理快照或暂存。包文件可能已随 APK 删除，但 LuCI/rpcd 接口刷新未完成；请先完成原操作（确认或回滚），再手动 reload rpcd 并核实 routepolicy 对象已消失。" >&2
	exit 1
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/

rc_object_id() {
	rpcd_listing="$$(ubus -t 2 -v list rc 2>/dev/null)" || return 1
	set -f
	# Split the native ubus header with globbing disabled.
	# shellcheck disable=SC2086
	set -- $$rpcd_listing
	set +f
	[ "$$1" = "'rc'" ] || return 1
	case "$$2" in
		@) return 1 ;;
		@*) rpcd_hex_id=$${2#?} ;;
		*) return 1 ;;
	esac
	case "$$rpcd_hex_id" in
		''|*[!0-9a-fA-F]*) return 1 ;;
	esac
	printf '%s\n' "$$rpcd_hex_id"
}
if ! rpcd_object_id=$$(rc_object_id); then
	echo 'luci-app-routepolicy: 无法读取 rpcd rc 对象标识；接口刷新未完成' >&2
	exit 1
fi
if ! /etc/init.d/rpcd reload; then
	echo 'luci-app-routepolicy: rpcd reload 失败；驻留 routepolicy 对象未注销' >&2
	exit 1
fi
reloaded=0
attempts=0
while [ "$$attempts" -lt 10 ]; do
	if rpcd_listing=$$(rc_object_id); then
		if [ "$$rpcd_listing" != "$$rpcd_object_id" ]; then
			reloaded=1
			break
		fi
	fi
	attempts=$$((attempts + 1))
	sleep 1
done
if [ "$$reloaded" != 1 ]; then
	echo 'luci-app-routepolicy: rpcd reload 后 rc 对象未以新标识重新注册；接口刷新未完成' >&2
	exit 1
fi
if ! ubus -t 10 call uci configs >/dev/null 2>&1; then
	echo 'luci-app-routepolicy: rpcd 健康检查（uci configs）失败；接口刷新未完成' >&2
	exit 1
fi
objects="$$(ubus -t 2 list 2>/dev/null)" || {
	echo 'luci-app-routepolicy: ubus 对象列表读取失败；接口刷新未完成' >&2
	exit 1
}
printf '%s\n' "$$objects" | grep -qx rc
grep_status=$$?
if [ "$$grep_status" -ne 0 ]; then
	echo 'luci-app-routepolicy: rpcd rc 对象缺失；接口刷新未完成' >&2
	exit 1
fi
printf '%s\n' "$$objects" | grep -qx uci
grep_status=$$?
if [ "$$grep_status" -ne 0 ]; then
	echo 'luci-app-routepolicy: rpcd uci 对象缺失；接口刷新未完成' >&2
	exit 1
fi
printf '%s\n' "$$objects" | grep -qx routepolicy
grep_status=$$?
if [ "$$grep_status" -eq 0 ]; then
	echo 'luci-app-routepolicy: routepolicy 对象在卸载后仍驻留；接口刷新未完成' >&2
	exit 1
fi
if [ "$$grep_status" -ne 1 ]; then
	echo 'luci-app-routepolicy: 对象匹配检查出错；接口刷新未完成' >&2
	exit 1
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
