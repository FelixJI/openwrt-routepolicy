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
grep -q "^config main 'main'$" routepolicy/files/etc/config/routepolicy || fail '缺少 main 配置段'
grep -q "^[[:space:]]*option enabled '0'$" routepolicy/files/etc/config/routepolicy || fail '安装默认必须禁用'

# 发布树不得捆绑或引用仅供现场迁移后使用的本地清理脚本。
if grep -R -n -E 'cleanup-legacy-splitroute-after-package-install\.sh' \
    routepolicy luci-app-routepolicy .github README.md CONTRIBUTING.md SECURITY.md 2>/dev/null; then
    fail '公开发布树引用了本地清理脚本'
fi

printf '%s\n' '软件包安全契约测试通过。'
