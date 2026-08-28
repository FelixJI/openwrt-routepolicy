#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
OBSERVE="$ROOT/routepolicy/files/usr/libexec/routepolicy/observe"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-observe-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$tmp/root/tmp/routepolicy/active"
for device in br-lan eth-test; do
	mkdir -p "$tmp/root/sys/class/net/$device/statistics"
	for counter in rx_bytes tx_bytes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped; do
		printf '%s\n' 0 >"$tmp/root/sys/class/net/$device/statistics/$counter"
	done
done
printf '%s\n' 18446744073709551615 >"$tmp/root/sys/class/net/br-lan/statistics/rx_bytes"
printf '%s\n' 9007199254740993 >"$tmp/root/sys/class/net/br-lan/statistics/tx_bytes"
printf '%s\n' malformed >"$tmp/root/sys/class/net/eth-test/statistics/tx_packets"
printf '%s\n' gen-42 >"$tmp/root/tmp/routepolicy/active/generation"
printf '%s\n' Example.COM sub.example.com >"$tmp/root/tmp/routepolicy/active/domain-policy.list"
printf '%s\n' default.example >"$tmp/root/tmp/routepolicy/active/domain-default.list"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = -q ] && shift
[ "${1:-}" = get ] || exit 1
case "$2" in
	routepolicy.main.lan_interface) echo lan ;;
	routepolicy.main.default_interface) echo wan ;;
		routepolicy.main.policy_interface) echo usbwan ;;
		routepolicy.main.source_accounting) echo 1 ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
case "$2" in
	network.interface.lan) echo '{"l3_device":"br-lan","up":true}' ;;
	network.interface.wan) echo '{"l3_device":"eth-test","up":true}' ;;
	network.interface.usbwan) [ "${TEST_BAD_DEVICE:-0}" = 1 ] && echo '{"l3_device":"..","up":true}' || echo '{"l3_device":"eth-test","up":true}' ;;
	*) echo '{}' ;;
esac
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
input=$(cat)
expr=${2:-}
case "$expr:$input" in
	'@.l3_device:'*'br-lan'*) echo br-lan ;;
	'@.l3_device:'*'eth-test'*) echo eth-test ;;
	'@.l3_device:'*'"l3_device":".."'*) echo .. ;;
	'@.up:'*'"up":true'*) echo true ;;
esac
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
[ "$1 $2 $3 $4 $5" = '-j list set inet routepolicy' ] || exit 1
case "$6" in
	domain_policy4)
		printf '%s\n' '{"nftables":[{"set":{"name":"domain_policy4","size":1024,"elem":[{"elem":{"val":"9.9.9.9","timeout":3600000,"expires":42000}}]}}]}' ;;
	domain_default4)
		printf '%s\n' '{"nftables":[{"set":{"name":"domain_default4","size":1024,"elem":[]}}]}' ;;
	static_policy4)
		printf '%s\n' '{"nftables":[{"set":{"name":"static_policy4","elem":[{"elem":{"val":{"prefix":{"addr":"8.8.8.0","len":24}}}}]}}]}' ;;
	static_default4)
		printf '%s\n' '{"nftables":[{"set":{"name":"static_default4","elem":[{"elem":{"val":"1.1.1.1"}}]}}]}' ;;
	source_ingress4)
		printf '%s\n' '{"nftables":[{"set":{"name":"source_ingress4","size":3,"elem":[{"elem":{"val":{"concat":["br-lan","192.168.1.2"]},"timeout":600000,"expires":599000,"counter":{"packets":7,"bytes":9007199254740993}}},{"elem":{"val":{"concat":["br-lan","192.168.1.3"]},"timeout":600000,"expires":598000,"counter":{"packets":8,"bytes":18446744073709551615}}},{"elem":{"val":{"concat":["old-wan","198.51.100.9"]},"timeout":600000,"expires":597000,"counter":{"packets":99,"bytes":18446744073709551615}}}]}}]}' ;;
	source_egress4)
		printf '%s\n' '{"nftables":[{"set":{"name":"source_egress4","size":4096,"elem":[]}}]}' ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/uci" "$tmp/bin/ubus" "$tmp/bin/jsonfilter" "$tmp/bin/nft"

run_observe() {
	PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
		ROUTEPOLICY_SYS_CLASS_NET="$tmp/root/sys/class/net" ROUTEPOLICY_OUTPUT=json "$OBSERVE" "$@"
}

mkdir "$tmp/root/tmp/routepolicy/apply.lock"
if run_observe interfaces >"$tmp/apply-locked.json" 2>/dev/null; then
	printf '%s\n' 'observe unexpectedly read a catalog during apply transaction' >&2
	exit 1
fi
grep -Fq '"ok":false' "$tmp/apply-locked.json"
rmdir "$tmp/root/tmp/routepolicy/apply.lock"

run_observe interfaces >"$tmp/interfaces.json"
grep -Fq '"generation":"gen-42"' "$tmp/interfaces.json"
grep -Fq '"device":"br-lan","roles":[{"role":"lan","interface":"lan"}]' "$tmp/interfaces.json"
grep -Fq '"rx_bytes":"18446744073709551615"' "$tmp/interfaces.json"
grep -Fq '"tx_bytes":"9007199254740993"' "$tmp/interfaces.json"
grep -Fq '"device":"eth-test","roles":[{"role":"default","interface":"wan"},{"role":"policy","interface":"usbwan"}]' "$tmp/interfaces.json"
grep -Fq '"device":"eth-test","roles":[{"role":"default","interface":"wan"},{"role":"policy","interface":"usbwan"}],"online":true,"available":false' "$tmp/interfaces.json"
grep -Fq '"tx_packets":null' "$tmp/interfaces.json"
TEST_BAD_DEVICE=1 run_observe interfaces >"$tmp/interfaces-bad-device.json"
grep -Fq '"unavailable_roles":["policy"]' "$tmp/interfaces-bad-device.json"
! grep -Fq '"device":".."' "$tmp/interfaces-bad-device.json"

run_observe sets >"$tmp/sets.json"
grep -Fq '"source_accounting":true' "$tmp/sets.json"
grep -Fq '"dataset":"source_ingress4","name":"source_ingress4","enabled":true,"available":true,"count":3,"capacity":3,"saturated":true' "$tmp/sets.json"
grep -Fq '"dataset":"domain_policy","name":"domain_policy","enabled":true,"available":true,"count":2' "$tmp/sets.json"

run_observe export dynamic_policy4 address >"$tmp/dynamic.json"
grep -Fq '"address":"9.9.9.9","permanent":false,"timeout":"3600","expires":"42"' "$tmp/dynamic.json" || { cat "$tmp/dynamic.json" >&2; exit 1; }
run_observe export static_policy4 address >"$tmp/static.json"
grep -Fq '"address":"8.8.8.0/24","permanent":true,"timeout":null,"expires":null' "$tmp/static.json"
run_observe export source_ingress4 bytes >"$tmp/source.json"
grep -Fq '"bytes":"18446744073709551615"' "$tmp/source.json"
grep -Fq '"bytes":"9007199254740993"' "$tmp/source.json"
if grep -Fq 'old-wan' "$tmp/source.json" || grep -Fq '198.51.100.9' "$tmp/source.json"; then
	printf '%s\n' 'source query without a device leaked an element from a formerly managed device' >&2
	exit 1
fi
[ "$(grep -bo '192.168.1.[23]' "$tmp/source.json" | sed -n '1p' | cut -d: -f2)" = '192.168.1.3' ] || {
	printf '%s\n' 'source byte sorting did not preserve unsigned decimal order' >&2; exit 1;
}

if run_observe export 'source_ingress4;reboot' bytes >/dev/null 2>&1; then
	printf '%s\n' 'unknown dataset unexpectedly reached nft' >&2
	exit 1
fi

printf 'observe contract tests: passed\n'
