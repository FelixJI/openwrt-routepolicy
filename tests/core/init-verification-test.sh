#!/bin/sh
# One verification context reuses committed exports, then detects every later change.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
[ -n "${TEST_UCI_SDK_ROOT:-}" ] || { printf 'native verification context: skipped (provide official TEST_UCI_SDK_ROOT)\n'; exit 0; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-verify.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
LIBEXEC=$ROUTEPOLICY_LIBEXEC
sed '/^operation=/,$d' "$LIBEXEC/init-transaction" >"$tmp/functions"
if [ "${1:-}" != --measure ]; then VERIFY_EXPORT_DIR=/untrusted-caller-context; export VERIFY_EXPORT_DIR; fi
. "$tmp/functions"
[ -z "${VERIFY_EXPORT_DIR:-}" ] || { printf 'caller supplied a verification cache\n' >&2; exit 1; }
mkdir -p "$RP_ROOT/etc/config" "$WAL" "$RP_RUN_DIR" "$tmp/external"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$WAL/token"
for package in $PACKAGES; do printf "config test 'main'\n" >"$RP_ROOT/etc/config/$package"; done
printf "config interface 'lan'\n\tlist ipaddr '192.0.2.1/24'\n\tlist ipaddr '192.0.2.2/24'\n\toption proto 'static'\n" >"$RP_ROOT/etc/config/network"
printf "config dnsmasq\n\toption port '0'\n" >"$RP_ROOT/etc/config/dhcp"
n=0; while [ "$n" -lt 150 ]; do n=$((n+1)); printf "\toption k%s 'v%s'\n" "$n" "$n" >>"$RP_ROOT/etc/config/network"; done
uci() {
	printf '%s\n' "$*" >>"$tmp/uci-calls"
	"$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/sbin/uci" -c "$RP_ROOT/etc/config" -t "$tmp/external" "$@"
}
uci_layout
printf 'list\tnetwork.lan.ipaddr\t192.0.2.1/24|192.0.2.2/24\nset\tnetwork.lan.proto\tstatic\ndelete\tnetwork.lan.missing\t-\nset\tdhcp.@dnsmasq[0].port\t0\nset\tfirewall.main\ttest\n' >"$WAL/candidate"
n=0; while [ "$n" -lt 150 ]; do n=$((n+1)); printf 'set\tnetwork.lan.k%s\tv%s\n' "$n" "$n" >>"$WAL/candidate"; done
printf 'required\t0\n' >"$WAL/link-plan"
topology() {
	[ "$1" = verify ] || return 1
	printf called >"$tmp/runtime-verified"
	case "${mode:-clean}" in
		change) uci set network.lan.unknown=external && uci commit network ;;
		pending) uci set network.lan.unknown=pending ;;
	esac
}
: >"$tmp/uci-calls"
verify_runtime
[ -f "$tmp/runtime-verified" ]
if [ "${1:-}" = --measure ]; then printf 'verification exports: %s\n' "$(grep -c ' export rp_' "$tmp/uci-calls")"; exit 0; fi
[ "$(grep -c ' export rp_' "$tmp/uci-calls")" = 10 ] || { printf 'verification repeatedly exported packages instead of one context\n' >&2; exit 1; }
[ -z "${VERIFY_EXPORT_DIR:-}" ]
[ -z "$(find "$RP_RUN_DIR" -name 'init-verify.*' -print)" ]
for mode in change pending; do
	if verify_runtime; then printf 'verification accepted concurrent %s\n' "$mode" >&2; exit 1; fi
	uci revert network || true
	uci -q delete network.lan.unknown || true; uci commit network
done
mode=clean
cp "$RP_ROOT/etc/config/network" "$tmp/network.good"
for mismatch in scalar list-order missing; do
	cp "$tmp/network.good" "$RP_ROOT/etc/config/network"
	case "$mismatch" in
		scalar) uci delete network.lan.ipaddr; uci set 'network.lan.ipaddr=192.0.2.1/24 192.0.2.2/24' ;;
		list-order) uci delete network.lan.ipaddr; uci add_list network.lan.ipaddr=192.0.2.2/24; uci add_list network.lan.ipaddr=192.0.2.1/24 ;;
		missing) uci set network.lan.missing=external ;;
	esac
	uci commit network
	if verify_runtime; then printf 'verification accepted %s mismatch\n' "$mismatch" >&2; exit 1; fi
done
cp "$tmp/network.good" "$RP_ROOT/etc/config/network"
verify_runtime
printf '%s\n' 'native verification context: passed (10 exports, full runtime verifier called, committed alias, missing/type/list order/anonymous fields, concurrent unknown field/pending, no cross-call cache)'
