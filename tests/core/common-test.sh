#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/common"

pass=0
assert_ok() { "$@" || { printf 'FAIL expected success: %s\n' "$*" >&2; exit 1; }; pass=$((pass + 1)); }
assert_bad() { if "$@"; then printf 'FAIL expected failure: %s\n' "$*" >&2; exit 1; fi; pass=$((pass + 1)); }
assert_eq() { [ "$1" = "$2" ] || { printf 'FAIL expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }; pass=$((pass + 1)); }

assert_ok rp_is_name usbwan 32
assert_bad rp_is_name 'wan;reboot' 32
assert_bad rp_is_name '../wan' 32
assert_ok rp_is_mark_bit 0x100
assert_bad rp_is_mark_bit 0x101
assert_bad rp_is_mark_bit 0x0
assert_ok rp_is_https_url 'https://example.invalid/list.txt'
assert_bad rp_is_https_url 'http://example.invalid/list.txt'
assert_bad rp_is_https_url 'https://example.invalid/a b'
assert_bad rp_is_https_url "https://example.invalid/a
b"
assert_ok rp_is_ipv4 192.168.1.1
assert_bad rp_is_ipv4 999.1.1.1
assert_eq "$(rp_inverse_mask 0x100)" 0xfffffeff
assert_ok rp_schedule_due 2026-08-24 4 17 4 17 2026-08-23
assert_ok rp_schedule_due 2026-08-24 23 59 4 17 ''
assert_bad rp_schedule_due 2026-08-24 4 16 4 17 2026-08-23
assert_bad rp_schedule_due 2026-08-24 4 17 4 17 2026-08-24
assert_eq "$(rp_network_cidr 192.168.7.23 24)" 192.168.7.0/24

printf 'common tests: %s passed\n' "$pass"
