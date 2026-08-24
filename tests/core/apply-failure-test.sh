#!/bin/sh

set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-apply-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous" "$tmp/etc/smartdns/conf.d"
: >"$tmp/etc/config/routepolicy"; printf 'sentinel\n' >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
if TEST_NFT_FAIL_CHECK=1 PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null 2>&1; then
	printf 'apply unexpectedly succeeded after nft preflight failure\n' >&2; exit 1
fi
grep -Fxq sentinel "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" || { printf 'failed apply changed SmartDNS fragment\n' >&2; exit 1; }
[ ! -e "$tmp/etc/routepolicy/state/applied" ] || { printf 'failed apply wrote applied state\n' >&2; exit 1; }
printf 'apply failure tests: passed\n'
