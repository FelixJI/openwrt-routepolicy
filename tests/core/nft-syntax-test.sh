#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)

if ! command -v nft >/dev/null 2>&1; then
	printf '%s\n' 'nft syntax test: skipped (nft not installed)'
	exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-nft-syntax-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" \
	"$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"

TEST_ROUTE_LOCAL_TRAFFIC=1 TEST_SOURCE_ACCOUNTING=1 \
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/render" >/dev/null

rules="$tmp/tmp/routepolicy/rules.nft"
if [ "$(id -u)" -eq 0 ]; then
	nft -c -f "$rules"
elif command -v sudo >/dev/null 2>&1; then
	sudo -- nft -c -f "$rules"
else
	printf '%s\n' 'nft syntax test: skipped (CAP_NET_ADMIN/root unavailable)'
	exit 0
fi

printf '%s\n' 'nft syntax test: passed'
