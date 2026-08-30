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
grep -q '^PKG_VERSION:=0.3.3$' routepolicy/Makefile || fail '核心包版本未升级到 0.3.3 修复版本'
grep -q '^PKG_VERSION:=0.3.3$' luci-app-routepolicy/Makefile || fail 'LuCI 包版本未同步到 0.3.3 修复版本'
grep -q '^PKG_RELEASE:=1$' luci-app-routepolicy/Makefile || fail '新的 0.3.3 LuCI 包发布序号必须从 1 开始'
grep -q "^config main 'main'$" routepolicy/files/etc/config/routepolicy || fail '缺少 main 配置段'
grep -q "^[[:space:]]*option enabled '0'$" routepolicy/files/etc/config/routepolicy || fail '安装默认必须禁用'
rpcd_plugin=luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy
[ -f "$rpcd_plugin" ] || fail 'rpcd ucode 插件未安装到正式扫描目录'
[ ! -e luci-app-routepolicy/root/usr/libexec/rpcd/routepolicy ] || fail '包中仍保留错误的 exec 插件路径'
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
grep -Fq 'smartdns-control' routepolicy/Makefile || fail '核心包未安装 SmartDNS 深模块'
grep -Fq 'files/usr/libexec/routepolicy/observe' routepolicy/Makefile || fail '核心包未安装 observation 深模块'
grep -Fq '/etc/routepolicy/user.d/local-hosts.list' routepolicy/Makefile || fail '本地主机文件未声明为 conffile'
grep -Fq '91-routepolicy-smartdns-extra.conf' routepolicy/Makefile || fail '卸载脚本未清理 91 片段登记'
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

printf '%s\n' '软件包安全契约测试通过。'
