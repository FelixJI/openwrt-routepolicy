#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-status-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/state" "$tmp/etc/smartdns/conf.d"
: >"$tmp/etc/config/routepolicy"; : >"$tmp/etc/routepolicy/state/applied"; : >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status.json"
for fragment in \
	'"service":{"running":true,"applied":true,"enabled":true}' \
	'"routing":{"real_default":true,"blackhole":true' \
	'"smartdns":{"running":true,"fragment_loaded":false}' \
	'"interfaces":{"lan":{"name":"lan","device":"br-test","address":"192.0.2.1","online":true' \
	'"sets":{"domain_policy4":2'; do
	grep -Fq "$fragment" "$tmp/status.json" || { printf 'missing status contract fragment: %s\n' "$fragment" >&2; cat "$tmp/status.json" >&2; exit 1; }
done
mkdir -p "$tmp/var/etc/smartdns"
printf '%s\n' 'conf-file /etc/smartdns/conf.d/90-routepolicy.conf' >"$tmp/var/etc/smartdns/smartdns.conf"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status-loaded.json"
grep -Fq '"smartdns":{"running":true,"fragment_loaded":true}' "$tmp/status-loaded.json" || {
	printf '%s\n' 'generated SmartDNS configuration did not prove fragment loading' >&2
	cat "$tmp/status-loaded.json" >&2
	exit 1
}
TEST_BAD_CONFIG=1 PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status-bad.json"
grep -Fq '"enabled":false' "$tmp/status-bad.json" || { cat "$tmp/status-bad.json" >&2; exit 1; }
grep -Fq '"table":200' "$tmp/status-bad.json" || { cat "$tmp/status-bad.json" >&2; exit 1; }
printf 'status contract tests: passed\n'
