#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-source-accounting-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" \
	"$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"

fail() {
	printf 'source accounting contract failed: %s\n' "$1" >&2
	exit 1
}

config="$ROOT/routepolicy/files/etc/config/routepolicy"
grep -Fq "option source_accounting '0'" "$config" || fail 'source accounting must default off'
grep -Fq "option source_idle_timeout '600'" "$config" || fail 'default idle timeout must be 600 seconds'
grep -Fq "option source_max_entries '4096'" "$config" || fail 'default per-direction capacity must be 4096'

run_render() {
	TEST_SOURCE_ACCOUNTING=$1 PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
		ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
		"$ROOT/routepolicy/files/usr/libexec/routepolicy/render" >/dev/null
}

run_render 0
rules="$tmp/tmp/routepolicy/rules.nft"
for fragment in \
	'set source_ingress4 {' \
	'set source_egress4 {' \
	'type ifname . ipv4_addr' \
	'flags dynamic,timeout' \
	'timeout 600s' \
	'gc-interval 60s' \
	'size 4096' \
	'policy memory' \
	'chain source_prerouting {' \
	'type filter hook prerouting priority mangle' \
	'chain source_postrouting {' \
	'type filter hook postrouting priority mangle; policy accept;' \
	'counter return comment "routepolicy: source accounting disabled"'; do
	grep -Fq "$fragment" "$rules" || fail "disabled topology missing: $fragment"
done

run_render 1
for fragment in \
	'iifname "br-test" update @source_ingress4 { iifname . ip saddr counter }' \
	'oifname "br-test" update @source_egress4 { oifname . ip saddr counter }'; do
	grep -Fq "$fragment" "$rules" || fail "enabled accounting missing: $fragment"
done

if TEST_SOURCE_IDLE_TIMEOUT=59 PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	sh -c '. "$1/common"; rp_validate_main' sh "$ROOT/routepolicy/files/usr/libexec/routepolicy" >/dev/null 2>&1; then
	fail 'idle timeout below 60 seconds was accepted'
fi
if TEST_SOURCE_MAX_ENTRIES=16385 PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	sh -c '. "$1/common"; rp_validate_main' sh "$ROOT/routepolicy/files/usr/libexec/routepolicy" >/dev/null 2>&1; then
	fail 'capacity above 16384 was accepted'
fi

printf '%s\n' 'source accounting tests: passed'
