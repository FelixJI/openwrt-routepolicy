#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-render-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"
printf '8.8.8.8\n203.0.113.1\n' >"$tmp/etc/routepolicy/user.d/ipv4-policy.list"
printf 'example.com\n' >"$tmp/etc/routepolicy/user.d/domain-policy.list"
printf '%s\n' '192.168.1.10 nas nas.lan storage.lan' '2001:db8::10 nas6 nas6.lan' >"$tmp/etc/routepolicy/user.d/local-hosts.list"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/render" >/dev/null
rules="$tmp/tmp/routepolicy/rules.nft"; smartdns="$tmp/tmp/routepolicy/90-routepolicy.conf"
grep -Fq 'table inet routepolicy' "$rules"
grep -Fq 'ct mark set (ct mark & 0xfffffeff) | 0x100' "$rules"
grep -Fq '192.0.2.0/24' "$rules"; grep -Fq '203.0.113.0/24' "$rules"
grep -Fq '8.8.8.8' "$rules"
if grep -Fq '203.0.113.1' "$rules"; then printf 'reserved fixture address reached nft elements\n' >&2; exit 1; fi
grep -Fq 'nftset-timeout yes' "$smartdns"
if grep -Eq '^[[:space:]]*server[[:space:]]' "$smartdns"; then printf 'SmartDNS upstream was generated\n' >&2; exit 1; fi
if grep -Fq -- '-no-serve-expired' "$smartdns"; then
	printf 'RoutePolicy domain rules overrode the global serve-expired setting\n' >&2
	exit 1
fi
grep -Fq 'hosts-file /etc/routepolicy/user.d/local-hosts.list' "$smartdns"
grep -Fq 'expand-ptr-from-address yes' "$smartdns"
grep -Fq 'address /nas/192.168.1.10' "$smartdns"
grep -Fq 'address /nas6/2001:db8::10' "$smartdns"
printf 'render tests: passed\n'
