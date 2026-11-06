#!/bin/sh
# Exercise the sourced value boundary with the selected real tr implementation.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-dns-structure.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root"
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/common"
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/init-dns"
if [ -z "${TEST_BUSYBOX:-}" ] && command -v busybox >/dev/null 2>&1; then TEST_BUSYBOX=$(command -v busybox); fi
if [ -n "${TEST_BUSYBOX:-}" ]; then
	[ -x "$TEST_BUSYBOX" ] || exit 1
	tr() { "$TEST_BUSYBOX" tr "$@"; }
fi
uci() { cat "$tmp/value"; printf '\n'; }
for name in '' br-lan 'Kitchen Router with ctrl letters' 'Living Room 路由器'; do
	printf '%s' "$name" >"$tmp/value"
	init_dns_audit_uci_line smartdns.main.server_name
done
# Valid shell/UCI strings cannot hold NUL. Test all other C0 bytes and DEL
# through the actual helper, including trailing newlines retained by its sentinel.
for control in 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037 177; do
	printf 'Kitchen%bRouter' "\\$control" >"$tmp/value"
	if init_dns_audit_uci_line smartdns.main.server_name >"$tmp/rejected" 2>&1; then
		printf 'control byte accepted: %s\n' "$control" >&2; exit 1
	fi
done
printf 'Kitchen Router\n' >"$tmp/value"
if init_dns_audit_uci_line smartdns.main.server_name >"$tmp/rejected" 2>&1; then exit 1; fi
# Also verify the tool handles the complete C0 range including NUL, plus DEL.
printf 'br-lan' >"$tmp/value"
for control in 000 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037 177; do
	printf '%b' "\\$control" >>"$tmp/value"
done
[ "$(tr -d '\000-\037\177' <"$tmp/value")" = br-lan ]
[ "$(printf ' \t\r\n\v\f12 \n' | tr -d ' \011-\015')" = 12 ]
printf '%s\n' 'DNS UCI structure tool contract: passed (ordinary names, all representable C0/DEL, trailing LF, full byte range)'
