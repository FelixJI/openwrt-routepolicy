#!/bin/sh
# GitHub runner 自带 Ruby/Psych；用其解析 YAML，避免另行下载 YAML 工具。
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

command -v ruby >/dev/null 2>&1 || {
    printf '%s\n' '需要 Ruby 才能解析 GitHub Actions YAML。' >&2
    exit 1
}

find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) -print | while IFS= read -r workflow; do
    ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0));' "$workflow"
done

printf '%s\n' 'GitHub Actions YAML 解析通过。'
