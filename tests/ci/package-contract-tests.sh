#!/bin/sh
# 不依赖 SDK 的快速契约测试，守住包的安装安全边界。
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

fail() {
    printf '契约测试失败：%s\n' "$1" >&2
    exit 1
}

[ -f routepolicy/Makefile ] || fail '缺少 routepolicy Makefile'
[ -f luci-app-routepolicy/Makefile ] || fail '缺少 luci-app-routepolicy Makefile'
[ -f routepolicy/files/etc/config/routepolicy ] || fail '缺少默认 UCI 配置'
[ -f routepolicy/files/usr/libexec/routepolicy/observe ] || fail '缺少 observation 深模块'

grep -q '^PKG_NAME:=routepolicy$' routepolicy/Makefile || fail '核心包名不正确'
grep -q '^PKG_NAME:=luci-app-routepolicy$' luci-app-routepolicy/Makefile || fail 'LuCI 包名不正确'
core_version=$(sed -n 's/^PKG_VERSION:=//p' routepolicy/Makefile)
luci_version=$(sed -n 's/^PKG_VERSION:=//p' luci-app-routepolicy/Makefile)
printf '%s\n' "$core_version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || fail '核心包版本必须为 X.Y.Z'
[ "$core_version" = "$luci_version" ] || fail '两包版本必须一致'
core_release=$(sed -n 's/^PKG_RELEASE:=//p' routepolicy/Makefile)
luci_release=$(sed -n 's/^PKG_RELEASE:=//p' luci-app-routepolicy/Makefile)
printf '%s\n' "$core_release" | grep -Eq '^[1-9][0-9]*$' || fail '包发布序号必须为正整数'
[ "$core_release" = "$luci_release" ] || fail '两包发布序号必须一致'
grep -q "^config main 'main'$" routepolicy/files/etc/config/routepolicy || fail '缺少 main 配置段'
grep -q "^[[:space:]]*option enabled '0'$" routepolicy/files/etc/config/routepolicy || fail '安装默认必须禁用'
rpcd_plugin=luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy
[ -f "$rpcd_plugin" ] || fail 'rpcd ucode 插件未安装到正式扫描目录'
[ ! -e luci-app-routepolicy/root/usr/libexec/rpcd/routepolicy ] || fail '包中仍保留错误的 exec 插件路径'
grep -Fq '+kmod-nft-nat' routepolicy/Makefile || fail '核心包缺少 DNS redirect 内核依赖'
grep -Fq '+rpcd-mod-ucode' luci-app-routepolicy/Makefile || fail 'LuCI 包缺少 rpcd ucode loader 依赖'
grep -Fq 'define Package/$(PKG_NAME)/postinst' luci-app-routepolicy/Makefile || fail 'LuCI 包缺少显式安装生命周期'
grep -Fq 'if ! /etc/init.d/rpcd restart; then' luci-app-routepolicy/Makefile || fail 'rpcd 重启失败必须立即终止安装脚本'
grep -Fq 'ubus -t 10 wait_for routepolicy' luci-app-routepolicy/Makefile || fail '安装升级必须等待 routepolicy 对象注册'
grep -Fq 'rm -f /tmp/luci-indexcache.*' luci-app-routepolicy/Makefile || fail '安装升级必须清理 LuCI 索引缓存'
grep -Fq 'rm -rf /tmp/luci-modulecache/' luci-app-routepolicy/Makefile || fail '安装升级必须清理 LuCI 模块缓存'
settings_view=luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/settings-v2.js
[ -f "$settings_view" ] || fail '基础设置缺少新的静态资源 generation'
[ ! -e luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/settings.js ] || fail '仍保留可命中旧浏览器缓存的基础设置路径'
grep -Fq '"path": "routepolicy/settings-v2"' luci-app-routepolicy/root/usr/share/luci/menu.d/luci-app-routepolicy.json || fail '菜单未切换到新的基础设置资源 generation'
grep -Fq 'luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy' .github/workflows/build.yml || fail '构建工作流未编译正式 rpcd ucode 路径'
grep -Fq 'luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy' .github/workflows/release.yml || fail '发布工作流未编译正式 rpcd ucode 路径'
[ -f tests/luci/ucode-popen-contract.uc ] || fail '缺少 OpenWrt 25.12 ucode popen 运行时合同'
[ -f tests/core/nft-syntax-test.sh ] || fail '缺少真实 nft 语法门禁'
grep -Fq 'tests/luci/ucode-popen-contract.uc' .github/workflows/build.yml || fail '构建工作流未执行目标 ucode popen 运行时合同'
grep -Fq 'tests/luci/ucode-popen-contract.uc' .github/workflows/release.yml || fail '发布工作流未执行目标 ucode popen 运行时合同'
grep -Fq 'nft-syntax-test.sh' tests/core/run.sh || fail 'core 测试未执行真实 nft 语法门禁'
grep -Fq 'nftables shellcheck' .github/workflows/build.yml || fail '构建工作流未安装 nft 语法检查器'
grep -Fq 'nftables shellcheck' .github/workflows/release.yml || fail '发布工作流未安装 nft 语法检查器'
if grep -R -Fq 'luci-app-routepolicy/root/usr/libexec/rpcd/routepolicy' .github tests/luci/README.md; then fail 'CI 或测试说明仍引用错误的 rpcd exec 路径'; fi
grep -Fq '+bind-dig' routepolicy/Makefile || fail '双协议 DNS 查询验证缺少 bind-dig 依赖'
grep -Fq 'files/usr/libexec/routepolicy/init-dns' routepolicy/Makefile || fail '核心包未安装初始化 DNS 协调模块'
grep -Fq '$(INSTALL_DATA) ./files/lib/upgrade/routepolicy.sh $(1)/lib/upgrade/routepolicy.sh' routepolicy/Makefile || fail '核心包未安装官方备份 hook'
grep -Fq '$(INSTALL_BIN) ./files/usr/libexec/routepolicy/firmware-backup $(1)/usr/libexec/routepolicy/firmware-backup' routepolicy/Makefile || fail '核心包未安装固件备份依赖盘点器'
grep -Fq 'smartdns-control' routepolicy/Makefile || fail '核心包未安装 SmartDNS 深模块'
grep -Fq 'files/usr/libexec/routepolicy/observe' routepolicy/Makefile || fail '核心包未安装 observation 深模块'
grep -Fq '/etc/routepolicy/user.d/local-hosts.list' routepolicy/Makefile || fail '本地主机文件未声明为 conffile'
postrm=$(sed -n '/^define Package\/routepolicy\/postrm$/,/^endef$/p' routepolicy/Makefile)
if printf '%s\n' "$postrm" | grep -Eq 'uci |reload|restart|rm -f'; then fail '代码删除后 postrm 仍修改或重载 DNS'; fi
grep -Fq 'routepolicy-*.apk' scripts/ci/prepare-release.sh || fail 'Release 收集必须使用 OpenWrt APK 连字符命名'
if grep -Fq 'routepolicy_*.apk' scripts/ci/prepare-release.sh; then fail 'Release 收集仍使用旧 IPK 风格下划线命名'; fi
grep -Fq -- "-name 'packages.adb'" scripts/ci/prepare-release.sh || fail 'OpenWrt 25.12 Release 必须收集 apk packages.adb 索引'
if grep -Fq -- "-name 'Packages'" scripts/ci/prepare-release.sh; then fail 'Release 收集仍使用旧 opkg Packages 索引名'; fi
grep -Fq "ubus list | grep -qx routepolicy" scripts/ci/prepare-release.sh || fail 'Release 安装说明缺少 rpcd 对象 smoke'
grep -Fq "ubus call routepolicy status '{}'" scripts/ci/prepare-release.sh || fail 'Release 安装说明缺少 RPC 执行 smoke'
grep -Fq "ubus call routepolicy status '{}'" README.md || fail 'README 升级流程缺少 RPC 执行 smoke'
grep -Fq '路由器本机 IPv4 分流' README.md || fail 'README 缺少本机 IPv4 分流开关说明'
grep -Fq '按源 IP 统计' README.md || fail 'README 缺少有界源 IP 统计说明'
grep -Fq 'active catalog' SECURITY.md || fail '安全文档缺少 active catalog 生效态边界'

# 发布树不得捆绑或引用仅供现场迁移后使用的本地清理脚本。
if grep -R -n -E 'cleanup-legacy-splitroute-after-package-install\.sh' \
    routepolicy luci-app-routepolicy .github README.md CONTRIBUTING.md SECURITY.md 2>/dev/null; then
    fail '公开发布树引用了本地清理脚本'
fi

# 离线安装介质单入口契约
[ -f scripts/install.sh ] || fail '缺少离线介质单入口 scripts/install.sh'
case "$(sed -n '1p' scripts/install.sh)" in '#!'*sh*) ;; *) fail 'install.sh 缺少 POSIX shell shebang' ;; esac
grep -Fq -- '--allow-local-unsigned' scripts/install.sh || fail '安装入口必须要求显式的本地未签名确认参数'
grep -Fq 'sha256sum -c SHA256SUMS' scripts/install.sh || fail '安装入口必须先完整消费 SHA256SUMS 清单'
grep -Fq 'apk adbdump' scripts/install.sh || fail '安装入口必须用 apk adbdump 解析本地 APK 元数据'
if grep -Fq 'tar -x' scripts/install.sh; then fail '安装入口不得假定 APK 是 tar 归档'; fi
grep -Fq -- '--network=no' scripts/install.sh || fail '未签名豁免必须限定在无网络阶段'
grep -Fq -- '--repositories-file /dev/null' scripts/install.sh || fail '未签名豁免阶段必须切断软件源'
grep -Fq -- '--simulate' scripts/install.sh || fail '离线安装前必须 simulate 预检'
grep -Fq 'apk add --allow-untrusted' scripts/install.sh || fail '离线阶段必须以 apk add 安装两个本地 APK'
if grep -Eq 'apk[[:space:]]+upgrade' scripts/install.sh; then fail '安装入口不得批量升级系统包'; fi
grep -Fq 'DISTRIB_RELEASE' scripts/install.sh || fail '安装入口必须校验 OpenWrt 版本'
grep -Fq -- '--print-arch' scripts/install.sh || fail '安装入口必须校验设备架构'
grep -Fq 'routepolicy.main.enabled=1' scripts/install.sh || fail '升级已启用实例时不得宣称默认禁用或未接管'
grep -Fq '"$OUT_DIR/install.sh"' scripts/ci/prepare-release.sh || fail 'Release 介质必须包含离线安装入口 install.sh'
grep -Fq '+uhttpd +uhttpd-mod-ubus' luci-app-routepolicy/Makefile || fail 'LuCI 包必须显式依赖 uhttpd 与 uhttpd-mod-ubus'
grep -Fq '+ucode' routepolicy/Makefile || fail '核心包必须显式依赖 ucode（rpcd ucode 插件运行时）'
[ -f tests/ci/install-media-fixtures/core-adbdump.txt ] || fail '缺少真实 ADB 元数据测试夹具'
grep -Fq 'arch: noarch' tests/ci/install-media-fixtures/luci-adbdump.txt || fail 'LuCI 夹具必须反映真实 noarch 架构'
grep -Fq 'sh install.sh --allow-local-unsigned' README.md || fail 'README 安装流程必须使用介质单入口'
grep -Fq 'sha256sum -c SHA256SUMS' luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/status-v2.js || fail '升级命令必须先校验介质'
grep -Fq 'APK_CONFIG=/dev/null' scripts/install.sh || fail 'apk 调用必须命令级隔离 APK_CONFIG'
grep -Fq 'distfeeds.list' scripts/install.sh || fail '阶段一官方源必须取自实际 distfeeds 文件'
grep -Fq 'list --manifest --installed' scripts/install.sh || fail 'world 比较必须使用原生 manifest 精确 name/version'
grep -Fq 'downloads.openwrt.org/releases' scripts/install.sh || fail '阶段一必须限定当前官方 distfeeds'
grep -Fq 'routepolicyctl diagnose' luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/status-v2.js && fail '升级命令不得保留重复的 diagnose 行'
sh tests/ci/install-media-tests.sh || fail '离线安装介质功能契约测试失败'


[ -f luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/status-v2.js ] || fail '缺少新状态页资源'
grep -Fq '"path": "routepolicy/status-v2"' luci-app-routepolicy/root/usr/share/luci/menu.d/luci-app-routepolicy.json || fail '菜单未使用新状态页'
grep -Fq 'nft list chain inet routepolicy dns_prerouting' routepolicy/files/usr/libexec/routepolicy/diagnose || fail '诊断必须检查 DNS NAT 链'

printf '%s\n' '软件包安全契约测试通过。'
