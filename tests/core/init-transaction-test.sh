#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
REAL_LIB="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-transaction.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if [ "${1:-}" = --native-uci ]; then
	mkdir -p "$tmp/config" "$tmp/private"
	printf "config interface 'lan'\n\tlist ipaddr '192.0.2.1/24'\n" >"$tmp/config/rp_init_contract"
	uci -c "$tmp/config" -t "$tmp/private" set rp_init_contract.lan.ipaddr=192.0.2.2
	[ "$(uci -c "$tmp/config" get rp_init_contract.lan.ipaddr)" = 192.0.2.1/24 ]
	[ -z "$(uci -c "$tmp/config" changes rp_init_contract)" ]
	[ "$(uci -c "$tmp/config" -t "$tmp/private" get rp_init_contract.lan.ipaddr)" = 192.0.2.2 ]
	uci -c "$tmp/config" -t "$tmp/private" commit rp_init_contract
	uci -c "$tmp/config" export rp_init_contract | grep -Fq "option ipaddr '192.0.2.2'"
	uci -c "$tmp/config" -t "$tmp/private" delete rp_init_contract.lan.ipaddr
	uci -c "$tmp/config" -t "$tmp/private" add_list rp_init_contract.lan.ipaddr=192.0.2.1/24
	uci -c "$tmp/config" -t "$tmp/private" commit rp_init_contract
	uci -c "$tmp/config" export rp_init_contract | grep -Fq "list ipaddr '192.0.2.1/24'"
	[ -z "$(uci -c "$tmp/config" changes rp_init_contract)" ]
	printf '%s\n' 'native UCI private delta/list restoration contract: passed'
	exit 0
fi
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/root/etc/init.d" "$tmp/db"
cp "$REAL_LIB/common" "$REAL_LIB/init-transaction" "$tmp/lib/"
chmod +x "$tmp/lib/init-transaction"
export TEST_TX_DIR="$tmp" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_OUTPUT=json
export PATH="$tmp/bin:$PATH"
TX="$tmp/lib/init-transaction"
WAL="$tmp/root/etc/routepolicy/state/init-transaction/current"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
set -eu
delta=
while [ "$#" -gt 0 ]; do
	case "$1" in -q) shift ;; -t) delta=$2; shift 2 ;; -P) exit 1 ;; *) break ;; esac
done
op=$1; key=${2:-}; db="$TEST_TX_DIR/db"
case "$op" in
	changes) [ ! -f "$TEST_TX_DIR/pending" ] || printf '%s\n' external-change ;;
	get)
		if [ -n "$delta" ] && [ -f "$delta/$key" ]; then cat "$delta/$key"
		elif [ -f "$db/$key" ]; then cat "$db/$key"; else exit 1; fi
		printf '\n' ;;
	export)
		for file in "$db/$key."*; do
			[ -f "$file" ] || continue
			full=${file##*/}; rest=${full#*.}; section=${rest%%.*}
			printf "config fixture '%s'\n" "$section"
			for option in "$db/$key.$section."*; do
				[ -f "$option" ] || continue
				full=${option##*/}; kind=option
				[ ! -f "$TEST_TX_DIR/list.$full" ] || kind=list
				printf "\t%s %s '%s'\n" "$kind" "${full##*.}" "$(cat "$option")"
			done
		done | awk '!seen[$0]++' ;;
	show)
		[ -f "$db/$key" ] || exit 1
		printf "%s='%s'\n" "$key" "$(cat "$db/$key")"
		case "$key" in *.*.*) ;; *)
			for child in "$db/$key."*; do
				[ -f "$child" ] || continue
				printf "%s='%s'\n" "${child##*/}" "$(cat "$child")"
			done ;;
		esac ;;
	set)
		[ -n "$delta" ] || exit 1
		full=${key%%=*}
		printf '%s' "${key#*=}" >"$delta/$full" ;;
	add_list)
		[ -n "$delta" ] || exit 1
		printf '%s' "${key#*=}" >"$delta/${key%%=*}"
		: >"$delta/LIST.${key%%=*}" ;;
	delete)
		[ -n "$delta" ] || exit 1
		: >"$delta/DELETE.$key" ;;
	commit)
		[ -n "$delta" ] || exit 1
		n=$(cat "$TEST_TX_DIR/commits" 2>/dev/null || printf 0); n=$((n + 1))
		printf '%s\n' "$n" >"$TEST_TX_DIR/commits"
		if [ -f "$TEST_TX_DIR/fail-at" ] && [ "$(cat "$TEST_TX_DIR/fail-at")" = "$n" ]; then exit 1; fi
		for file in "$delta/DELETE.$key."*; do
			[ -f "$file" ] || continue
			delete=${file##*/}; delete=${delete#DELETE.}; rm -f "$db/$delete" "$file" "$TEST_TX_DIR/list.$delete"
		done
		for file in "$delta/$key."*; do
			[ -f "$file" ] || continue
			full=${file##*/}; rm -f "$TEST_TX_DIR/list.$full"; mv "$file" "$db/"
		done
		for file in "$delta/LIST.$key."*; do
			[ -f "$file" ] || continue
			full=${file##*/}; mv "$file" "$TEST_TX_DIR/list.${full#LIST.}"
		done
		if [ -f "$TEST_TX_DIR/kill-at" ] && [ "$(cat "$TEST_TX_DIR/kill-at")" = "$n" ]; then kill -KILL "$PPID"; fi ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/lib/init-topology" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
	discover) printf '{"ok":true,"schema":1}\n' ;;
	plan)
		[ ! -f "$TEST_TX_DIR/bad-plan" ] || { printf 'set\tfirewall.defaults.forward\tunsafe\n'; exit 0; }
		printf 'set\troutepolicy.main.lan_interface\t%s\n' "$2"
		printf 'set\troutepolicy.main.default_interface\t%s\n' "$3"
		printf 'set\troutepolicy.main.policy_interface\t%s\n' "$4"
		printf 'set\tnetwork.lan.ipaddr\t192.0.2.2\n'
		printf 'set\tdhcp.lan.ignore\t1\n'
		printf 'set\tfirewall.rp_init_dns\trule\n'
		printf 'set\tfirewall.rp_init_dns.name\tinit-dns\n'
		printf 'set\tfirewall.rp_init_dns.target\tACCEPT\n' ;;
	verify)
		if [ -f "$TEST_TX_DIR/verify-fail" ]; then printf '%s\n' 'fixture runtime evidence unavailable' >&2; exit 1; fi ;;
	management-address) cat "$TEST_TX_DIR/db/network.lan.ipaddr" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/fw4" <<'EOF'
#!/bin/sh
[ ! -f "$TEST_TX_DIR/fw4-fail" ]
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
[ ! -f "$TEST_TX_DIR/guard-down" ] || exit 1
printf '%s\n' '{"routepolicy-initguard":{"instances":{"guard":{"running":true}}}}'
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' true
EOF
for service in network firewall dnsmasq odhcpd routepolicy-initguard; do
	cat >"$tmp/root/etc/init.d/$service" <<'EOF'
#!/bin/sh
name=${0##*/}
printf '%s %s\n' "$name" "$1" >>"$TEST_TX_DIR/services"
[ ! -f "$TEST_TX_DIR/service-fail" ] || [ "$name" != firewall ]
EOF
done
chmod +x "$tmp/bin/"* "$tmp/lib/init-topology" "$tmp/root/etc/init.d/"*

reset() {
	rm -rf "$tmp/root/etc/routepolicy" "$tmp/db"
	mkdir "$tmp/db"
	rm -f "$tmp/fail-at" "$tmp/kill-at" "$tmp/fw4-fail" "$tmp/verify-fail" "$tmp/service-fail" "$tmp/pending" "$tmp/commits" "$tmp/bad-plan" "$tmp/guard-down" "$tmp/services"
	rm -f "$tmp/"list.*
	printf lan >"$tmp/db/routepolicy.main.lan_interface"
	printf wan >"$tmp/db/routepolicy.main.default_interface"
	printf usbwan >"$tmp/db/routepolicy.main.policy_interface"
	printf 192.0.2.1 >"$tmp/db/network.lan.ipaddr"
	printf 0 >"$tmp/db/dhcp.lan.ignore"
	printf untouched >"$tmp/db/dhcp.other.ignore"
}
prepare() {
	out=$("$TX" prepare lan wan usbwan - - - - - - 192.0.2.2 24)
	token=$(printf '%s\n' "$out" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" -eq 32 ]
}
phase_is() { [ "$(cat "$WAL/phase")" = "$1" ]; }
restored() {
	[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.1 ]
	[ "$(cat "$tmp/db/dhcp.lan.ignore")" = 0 ]
	[ "$(cat "$tmp/db/dhcp.other.ignore")" = untouched ]
	[ ! -f "$tmp/db/firewall.rp_init_dns" ]
}
bad() { if "$@" >"$tmp/failure" 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }

reset
"$TX" recover >/dev/null
[ ! -d "$tmp/root/etc/routepolicy" ]
mkdir -p "$tmp/root/etc/routepolicy/state"
chmod 755 "$tmp/root/etc/routepolicy" "$tmp/root/etc/routepolicy/state"
"$TX" recover >/dev/null
[ "$(stat -c %a "$tmp/root/etc/routepolicy")" = 755 ]
[ "$(stat -c %a "$tmp/root/etc/routepolicy/state")" = 755 ]
reset
"$TX" discover >/dev/null
"$TX" preview lan wan usbwan - - - - - - 192.0.2.2 24 >/dev/null
[ ! -d "$tmp/root/etc/routepolicy" ]
restored
touch "$tmp/bad-plan"
bad "$TX" preview lan wan usbwan - - - - - - 192.0.2.2 24
rm "$tmp/bad-plan"
touch "$tmp/pending"
bad "$TX" prepare lan wan usbwan - - - - - - 192.0.2.2 24
rm "$tmp/pending"
prepare
touch "$tmp/guard-down"
bad "$TX" apply "$token"
phase_is prepared
restored
rm "$tmp/guard-down"
[ "$(stat -c %a "$WAL")" = 700 ]
touch "$tmp/bad-plan"
bad "$TX" prepare lan wan usbwan - - - - - - 192.0.2.2 24
[ "$(cat "$WAL/token")" = "$token" ]
phase_is prepared
rm "$tmp/bad-plan"
printf external >"$tmp/db/dhcp.lan.ignore"
bad "$TX" apply "$token"
phase_is prepared
[ "$(cat "$tmp/db/dhcp.lan.ignore")" = external ]

reset; prepare
touch "$tmp/guard-down"
bad "$TX" apply "$token"
phase_is prepared
rm "$tmp/guard-down"
"$TX" apply "$token" >/dev/null
phase_is pending
bad "$TX" confirm "$token"
bad env SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token"
SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token" >/dev/null
phase_is confirmed
printf 'prepare\napply\nverify\n' >"$tmp/expected-stages"
cmp "$tmp/expected-stages" "$WAL/smartdns-stages"
"$TX" apply "$token" >/dev/null
"$TX" recover >/dev/null
phase_is confirmed

# Every field commit can fail, including after staging private UCI changes.
for fail_at in 1 2 3 4 5 6 7 8; do
	reset; prepare; printf '%s\n' "$fail_at" >"$tmp/fail-at"
	bad "$TX" apply "$token"
	phase_is rolled_back
	restored
done
for fault in fw4-fail service-fail verify-fail; do
	reset; prepare; touch "$tmp/$fault"
	bad "$TX" apply "$token"
	# A reload failure remains a conflict until service recovery succeeds.
	if [ "$fault" = service-fail ]; then phase_is conflict; else phase_is rolled_back; fi
	restored
	if [ "$fault" = verify-fail ]; then "$TX" status | grep -Fq 'fixture runtime evidence unavailable'; fi
	if [ "$fault" = service-fail ]; then rm "$tmp/service-fail"; "$TX" recover >/dev/null; phase_is rolled_back; fi
done

reset; prepare; printf 5 >"$tmp/kill-at"
bad "$TX" apply "$token"
phase_is applying
"$TX" recover >/dev/null
phase_is rolled_back
restored
grep -Fxq rollback "$WAL/smartdns-stages"

# Preserve single-element CIDR list type, and reject values with invisible/trailing bytes.
reset
printf 192.0.2.1/24 >"$tmp/db/network.lan.ipaddr"
touch "$tmp/list.network.lan.ipaddr"
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null
[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.1/24 ]
[ -f "$tmp/list.network.lan.ipaddr" ]
reset
printf '192.0.2.1\n' >"$tmp/db/network.lan.ipaddr"
bad "$TX" prepare lan wan usbwan - - - - - - 192.0.2.2 24

reset; prepare; "$TX" apply "$token" >/dev/null
printf 0 >"$WAL/deadline"
"$TX" guard & guard_pid=$!
wait "$guard_pid"
phase_is rolled_back
restored

reset; prepare; "$TX" apply "$token" >/dev/null
printf external >"$tmp/db/dhcp.lan.ignore"
printf keep >"$tmp/db/firewall.rp_init_dns.custom"
bad "$TX" recover
phase_is conflict
[ "$(cat "$tmp/db/dhcp.lan.ignore")" = external ]
[ "$(cat "$tmp/db/firewall.rp_init_dns.custom")" = keep ]
[ "$(cat "$tmp/db/firewall.rp_init_dns")" = rule ]
[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.1 ]
printf 0 >"$tmp/db/dhcp.lan.ignore"
rm "$tmp/db/firewall.rp_init_dns.custom"
"$TX" recover >/dev/null
phase_is rolled_back
restored

reset; prepare
(flock -x 8; printf ready >"$tmp/locked"; sleep 3) 8>"$tmp/root/etc/routepolicy/state/init-transaction/lock" & lock_pid=$!
while [ ! -f "$tmp/locked" ]; do sleep 0.1; done
bad "$TX" apply "$token"
wait "$lock_pid"
phase_is prepared
printf '%s\n' 'init transaction tests: passed (mock UCI/services; packet evidence remains EVIDENCE_MISSING)'
