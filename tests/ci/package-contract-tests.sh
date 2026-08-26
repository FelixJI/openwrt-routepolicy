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

grep -q '^PKG_NAME:=routepolicy$' routepolicy/Makefile || fail '核心包名不正确'
grep -q '^PKG_NAME:=luci-app-routepolicy$' luci-app-routepolicy/Makefile || fail 'LuCI 包名不正确'
grep -q '^PKG_VERSION:=0.2.4$' routepolicy/Makefile || fail '核心包版本未升级到 0.2.4 热修复'
grep -q '^PKG_VERSION:=0.2.4$' luci-app-routepolicy/Makefile || fail 'LuCI 包版本未同步到 0.2.4 热修复'
grep -q "^config main 'main'$" routepolicy/files/etc/config/routepolicy || fail '缺少 main 配置段'
grep -q "^[[:space:]]*option enabled '0'$" routepolicy/files/etc/config/routepolicy || fail '安装默认必须禁用'
rpcd_plugin=luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy
[ -f "$rpcd_plugin" ] || fail 'rpcd ucode 插件未安装到正式扫描目录'
[ ! -e luci-app-routepolicy/root/usr/libexec/rpcd/routepolicy ] || fail '包中仍保留错误的 exec 插件路径'
grep -Fq '+rpcd-mod-ucode' luci-app-routepolicy/Makefile || fail 'LuCI 包缺少 rpcd ucode loader 依赖'
grep -Fq 'luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy' .github/workflows/build.yml || fail '构建工作流未编译正式 rpcd ucode 路径'
grep -Fq 'luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy' .github/workflows/release.yml || fail '发布工作流未编译正式 rpcd ucode 路径'
[ -f tests/luci/ucode-popen-contract.uc ] || fail '缺少 OpenWrt 25.12 ucode popen 运行时合同'
grep -Fq 'tests/luci/ucode-popen-contract.uc' .github/workflows/build.yml || fail '构建工作流未执行目标 ucode popen 运行时合同'
grep -Fq 'tests/luci/ucode-popen-contract.uc' .github/workflows/release.yml || fail '发布工作流未执行目标 ucode popen 运行时合同'
if grep -R -Fq 'luci-app-routepolicy/root/usr/libexec/rpcd/routepolicy' .github tests/luci/README.md; then fail 'CI 或测试说明仍引用错误的 rpcd exec 路径'; fi
grep -Fq 'smartdns-control' routepolicy/Makefile || fail '核心包未安装 SmartDNS 深模块'
grep -Fq '/etc/routepolicy/user.d/local-hosts.list' routepolicy/Makefile || fail '本地主机文件未声明为 conffile'
grep -Fq '91-routepolicy-smartdns-extra.conf' routepolicy/Makefile || fail '卸载脚本未清理 91 片段登记'
grep -Fq 'routepolicy-*.apk' scripts/ci/prepare-release.sh || fail 'Release 收集必须使用 OpenWrt APK 连字符命名'
if grep -Fq 'routepolicy_*.apk' scripts/ci/prepare-release.sh; then fail 'Release 收集仍使用旧 IPK 风格下划线命名'; fi
grep -Fq -- "-name 'packages.adb'" scripts/ci/prepare-release.sh || fail 'OpenWrt 25.12 Release 必须收集 apk packages.adb 索引'
if grep -Fq -- "-name 'Packages'" scripts/ci/prepare-release.sh; then fail 'Release 收集仍使用旧 opkg Packages 索引名'; fi
grep -Fq "ubus list | grep -qx routepolicy" scripts/ci/prepare-release.sh || fail 'Release 安装说明缺少 rpcd 对象 smoke'
grep -Fq "ubus call routepolicy status '{}'" scripts/ci/prepare-release.sh || fail 'Release 安装说明缺少 RPC 执行 smoke'
grep -Fq "ubus call routepolicy status '{}'" README.md || fail 'README 升级流程缺少 RPC 执行 smoke'

# 发布树不得捆绑或引用仅供现场迁移后使用的本地清理脚本。
if grep -R -n -E 'cleanup-legacy-splitroute-after-package-install\.sh' \
    routepolicy luci-app-routepolicy .github README.md CONTRIBUTING.md SECURITY.md 2>/dev/null; then
    fail '公开发布树引用了本地清理脚本'
fi

printf '%s\n' '软件包安全契约测试通过。'
