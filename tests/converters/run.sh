#!/bin/sh

set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
CONVERTERS="$ROOT/routepolicy/files/usr/libexec/routepolicy/converters"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-converter-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_conversion() {
	name=$1 converter=$2 input=$3 expected=$4
	printf '%s' "$input" >"$tmp/input"
	"$CONVERTERS/$converter" "$tmp/input" >"$tmp/actual" || fail "$name converter exited nonzero"
	printf '%s' "$expected" >"$tmp/expected"
	cmp -s "$tmp/expected" "$tmp/actual" || { diff -u "$tmp/expected" "$tmp/actual" >&2 || true; fail "$name output mismatch"; }
	pass=$((pass + 1))
}

assert_conversion plain-domain plain-domain \
'Example.COM
*.sub.example.com.
bad_domain.example
example.com
' \
'example.com
sub.example.com
'

assert_conversion plain-ipv4 plain-ipv4 \
'8.8.8.8
1.2.3.99/24
10.0.0.1
100.64.1.1
203.0.113.1
2001:db8::1
' \
'1.2.3.0/24
8.8.8.8
'

assert_conversion hosts-domain hosts-domain \
'0.0.0.0 Ads.Example.com tracker.example.com
127.0.0.1 localhost
::1 ipv6.example.com
' \
'ads.example.com
tracker.example.com
'

assert_conversion adblock-domain adblock-domain \
'[Adblock Plus 2.0]
||Ads.Example.com^
@@||allowed.example.com^
! comment
' \
'ads.example.com
'

assert_conversion dnsmasq-domain dnsmasq-domain \
'server=/Example.com/1.1.1.1
address=/ads.example.com/#
bogus-nxdomain=1.2.3.4
' \
'ads.example.com
example.com
'

assert_conversion clash-domain clash-domain \
'DOMAIN-SUFFIX,Example.com
DOMAIN,www.example.net
DOMAIN-KEYWORD,unsafe
IP-CIDR,8.8.8.0/24
' \
'example.com
www.example.net
'

assert_conversion clash-ipv4 clash-ipv4 \
'IP-CIDR,8.8.8.8/24,no-resolve
IP-CIDR,192.168.0.0/16
IP-CIDR6,2001:db8::/32
DOMAIN-SUFFIX,example.com
' \
'8.8.8.0/24
'

printf '<!doctype html><html>error</html>\n' >"$tmp/html"
if "$CONVERTERS/plain-domain" "$tmp/html" >/dev/null 2>&1; then fail 'HTML page was accepted'; fi
pass=$((pass + 1))

printf 'good.example\nbad_domain.example\n' >"$tmp/strict"
if ROUTEPOLICY_CONVERTER_STRICT=1 "$CONVERTERS/plain-domain" "$tmp/strict" >/dev/null 2>&1; then fail 'strict mode accepted an invalid entry'; fi
pass=$((pass + 1))

printf 'converter tests: %s passed\n' "$pass"
