#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
LIBEXEC=${TEST_APPLY_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-apply-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous" "$tmp/etc/smartdns/conf.d"
: >"$tmp/etc/config/routepolicy"; printf 'sentinel\n' >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
if TEST_NFT_ABSENT=1 TEST_NFT_FAIL_CHECK=1 PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null 2>&1; then
	printf 'apply unexpectedly succeeded after nft preflight failure\n' >&2; exit 1
fi
grep -Fxq sentinel "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" || { printf 'failed apply changed SmartDNS fragment\n' >&2; exit 1; }
[ ! -e "$tmp/etc/routepolicy/state/applied" ] || { printf 'failed apply wrote applied state\n' >&2; exit 1; }
# Validation must reject before any kernel mutation, even when sources are ready.
: >"$tmp/ip.log"; : >"$tmp/nft.log"
if TEST_STRICT=broken TEST_NFT_ABSENT=1 TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" \
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$LIBEXEC/apply" >"$tmp/invalid-result" 2>&1; then
	printf 'apply ignored invalid strict_enforcement\n' >&2; exit 1
fi
grep -Fq 'strict_enforcement' "$tmp/invalid-result"
if grep -Eq ' (add|del|replace|flush) |^-f |^delete ' "$tmp/ip.log" "$tmp/nft.log"; then
	printf 'invalid configuration caused kernel mutation\n' >&2; exit 1
fi
[ ! -e "$tmp/etc/routepolicy/state/applied" ]
printf 'apply failure tests: passed (nft preflight and invalid configuration preserve runtime)\n'
