#!/bin/sh
# 将 SDK 生成的 APK 与 apk 仓库索引收集为 GitHub Release 附件。
set -eu

SDK_DIR=${1:?需要 SDK 目录}
OUT_DIR=${2:?需要输出目录}
mkdir -p "$OUT_DIR"

find "$SDK_DIR/bin/packages/x86_64" -type f \( -name 'routepolicy-*.apk' -o -name 'luci-app-routepolicy-*.apk' \) -exec cp {} "$OUT_DIR" \;

# OpenWrt 25.12 的 apk 索引名为 packages.adb；各 feed 会生成同名文件，
# 因此保留 feed 前缀，避免在 Release 目录中相互覆盖。index.json 仅作为
# 人类可读的审计辅助，不是 apk 客户端使用的仓库数据库。
find "$SDK_DIR/bin/packages/x86_64" -type f \( -name 'packages.adb' -o -name 'index.json' \) -print | while IFS= read -r index; do
    feed=$(basename "$(dirname "$index")")
    cp "$index" "$OUT_DIR/$feed-$(basename "$index")"
done

routepolicy_count=$(find "$OUT_DIR" -maxdepth 1 -type f -name 'routepolicy-*.apk' | wc -l | tr -d '[:space:]')
luci_count=$(find "$OUT_DIR" -maxdepth 1 -type f -name 'luci-app-routepolicy-*.apk' | wc -l | tr -d '[:space:]')
index_count=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*-packages.adb' | wc -l | tr -d '[:space:]')
[ "$routepolicy_count" -eq 1 ] || {
    printf '应恰好收集一个 routepolicy APK，实际为 %s。\n' "$routepolicy_count" >&2
    exit 1
}
[ "$luci_count" -eq 1 ] || {
    printf '应恰好收集一个 luci-app-routepolicy APK，实际为 %s。\n' "$luci_count" >&2
    exit 1
}
[ "$index_count" -ge 1 ] || {
    printf '未收集到 OpenWrt apk packages.adb 索引。\n' >&2
    exit 1
}

cat > "$OUT_DIR/INSTALL.txt" <<'EOF'
RoutePolicy 安装说明（仅 OpenWrt 25.12 x86_64）

从本 Release 下载 routepolicy-*.apk 和 luci-app-routepolicy-*.apk，上传到目标设备后：
  apk add --allow-untrusted ./routepolicy-*.apk
  apk add --allow-untrusted ./luci-app-routepolicy-*.apk
  routepolicyctl validate
  ubus list | grep -qx routepolicy
  ubus call routepolicy status '{}'

最后一条应返回包含 "ok": true 的状态对象。LuCI 包安装流程会清理 LuCI 服务端缓存并同步重启 rpcd；重启失败会使包脚本报错，不需要重启路由器。若对象检查仍失败，请先运行 logread | grep -Ei 'rpcd|ucode|routepolicy' | tail -n 100 保存插件加载错误，不要启用 RoutePolicy。安装后 RoutePolicy 保持默认禁用状态，先在 LuCI/UCI 核对接口与 SmartDNS 配置。不要在未验证的版本或架构上安装。
*-packages.adb 是本次构建产生的 apk 仓库索引，*-index.json 供人工审计；发布 APK 未签名，直接安装时仅应使用本仓库 Release 中的文件。
下载全部 Release 附件后，先运行：
  sha256sum -c SHA256SUMS
若任一文件校验失败，请停止安装并重新下载。
EOF

{
    printf 'OpenWrt SDK: %s\n' "${OPENWRT_SDK_VERSION:-unknown}"
    printf 'Source revision: %s\n' "${GITHUB_SHA:-unknown}"
    printf 'Build timestamp (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\nAttached APK files:\n'
    find "$OUT_DIR" -maxdepth 1 -type f -name '*.apk' -printf '%f\n' | sort
} > "$OUT_DIR/BUILD-INFO.txt"

# Release workflow 是这一份摘要清单的权威生产者；下载者用它拒绝在传输或
# 交接过程中发生字节损坏的附件。SDK 本身的完整性校验仍只消费 OpenWrt 官方摘要。
(
    cd "$OUT_DIR"
    find . -maxdepth 1 -type f ! -name 'SHA256SUMS' -printf '%f\n' | sort | xargs -r sha256sum
) > "$OUT_DIR/SHA256SUMS"
