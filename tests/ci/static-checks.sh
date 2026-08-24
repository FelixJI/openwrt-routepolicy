#!/bin/sh
# 离线静态检查：只检查仓库内可执行脚本和 Web 资源，不下载依赖。
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

shell_files=$(find routepolicy luci-app-routepolicy scripts tests -type f 2>/dev/null | while IFS= read -r file; do
    case "$file" in
        *.sh)
            printf '%s\n' "$file"
            ;;
        *)
            # OpenWrt 安装树中既有 ash 脚本，也有 ucode 与 JSON；只将带
            # shell shebang 的文件交给 sh -n/ShellCheck。
            first_line=$(sed -n '1p' "$file")
            case "$first_line" in
                '#!'*'/sh'*|'#!'*'/ash'*|'#!'*'env sh'*|'#!'*'env ash'*)
                    printf '%s\n' "$file"
                    ;;
            esac
            ;;
    esac
done)
if [ -n "$shell_files" ]; then
    printf '%s\n' "$shell_files" | while IFS= read -r file; do
        [ -n "$file" ] || continue
        sh -n "$file"
    done
fi

if command -v shellcheck >/dev/null 2>&1 && [ -n "$shell_files" ]; then
    # OpenWrt 脚本由 BusyBox ash 执行。依赖目标机绝对路径的 source 会在 SDK
    # 构建阶段实际解析；这里忽略 ShellCheck 的信息级“未跟随 source”提示。
    printf '%s\n' "$shell_files" | while IFS= read -r file; do
        shellcheck --shell=sh --severity=warning "$file"
    done
fi

if command -v ucode >/dev/null 2>&1; then
    find routepolicy luci-app-routepolicy -type f -name '*.uc' -print 2>/dev/null | while IFS= read -r file; do
        ucode -c "$file"
    done
fi

if command -v node >/dev/null 2>&1; then
    find luci-app-routepolicy -type f -name '*.js' -print 2>/dev/null | while IFS= read -r file; do
        node --check "$file"
    done
fi

printf '%s\n' '静态检查通过。'
