#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
REAL_LIB="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-transaction.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if [ "${1:-}" = --native-uci ]; then
	if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
		uci() { "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/sbin/uci" "$@"; }
	fi
	native_id=$(sed 's/-//g' /proc/sys/kernel/random/uuid)
	native_package="rp_test_$native_id"; native_alias="rp_alias_$native_id"
	[ ! -e "/tmp/.uci/$native_package" ]
	trap 'rm -f "/tmp/.uci/$native_package"; rm -rf "$tmp"' EXIT HUP INT TERM
	mkdir -p "$tmp/config" "$tmp/private" "$tmp/aliases"
	printf "config interface 'lan'\n\tlist ipaddr '192.0.2.1/24'\nconfig dhcp 'other'\n\toption leasetime '12h'\n" >"$tmp/config/$native_package"
	uci -c "$tmp/config" set "$native_package.other.leasetime=2h"
	cp "/tmp/.uci/$native_package" "$tmp/external-pending"
	# -t alone still reads the default delta; the token-named package alias does not.
	[ "$(uci -c "$tmp/config" -t "$tmp/private" get "$native_package.other.leasetime")" = 2h ]
	ln -s "$tmp/config/$native_package" "$tmp/aliases/$native_alias"
	[ "$(uci -c "$tmp/aliases" -t "$tmp/private" get "$native_alias.other.leasetime")" = 12h ]
	uci -c "$tmp/aliases" -t "$tmp/private" set "$native_alias.lan.ipaddr=192.0.2.2"
	# A field committed after staging must survive the libuci locked reload/merge.
	printf "\toption concurrent 'kept'\n" >>"$tmp/config/$native_package"
	uci -c "$tmp/aliases" -t "$tmp/private" commit "$native_alias"
	[ "$(uci -c "$tmp/aliases" -t "$tmp/private" get "$native_alias.lan.ipaddr")" = 192.0.2.2 ]
	[ "$(uci -c "$tmp/aliases" -t "$tmp/private" get "$native_alias.other.concurrent")" = kept ]
	[ "$(uci -c "$tmp/aliases" -t "$tmp/private" get "$native_alias.other.leasetime")" = 12h ]
	cmp "$tmp/external-pending" "/tmp/.uci/$native_package"
	[ "$(uci -c "$tmp/config" get "$native_package.other.leasetime")" = 2h ]
	uci -c "$tmp/aliases" -t "$tmp/private" delete "$native_alias.lan.ipaddr"
	uci -c "$tmp/aliases" -t "$tmp/private" add_list "$native_alias.lan.ipaddr=192.0.2.1/24"
	uci -c "$tmp/aliases" -t "$tmp/private" commit "$native_alias"
	uci -c "$tmp/aliases" -t "$tmp/private" export "$native_alias" | grep -Fq "list ipaddr '192.0.2.1/24'"
	cmp "$tmp/external-pending" "/tmp/.uci/$native_package"
	printf '%s\n' 'native UCI alias isolation, concurrent-field merge and list restoration: passed'
	exit 0
fi
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/root/etc/init.d" "$tmp/db"
cp "$REAL_LIB/common" "$REAL_LIB/init-transaction" "$tmp/lib/"
chmod +x "$tmp/lib/init-transaction"
export TEST_TX_DIR="$tmp" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_OUTPUT=json
TEST_NATIVE_UCI_PATH=$(command -v uci 2>/dev/null || true)
export TEST_NATIVE_UCI_PATH
export PATH="$tmp/bin:$PATH"
TX="$tmp/lib/init-transaction"
WAL="$tmp/root/etc/routepolicy/state/init-transaction/current"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
set -eu
delta=
while [ "$#" -gt 0 ]; do
	case "$1" in -q) shift ;; -c) shift 2 ;; -t) delta=$2; shift 2 ;; -P) exit 1 ;; *) break ;; esac
done
op=$1; key=${2:-}; db="$TEST_TX_DIR/db"
case "$key" in rp_*) key=${key#rp_}; key=${key#*_} ;; esac
case "$op" in
	changes)
		[ ! -f "$TEST_TX_DIR/pending" ] || printf '%s\n' external-change
		[ ! -f "$TEST_TX_DIR/pending-$key" ] || cat "$TEST_TX_DIR/pending-$key" ;;
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
		printf 'set\tfirewall.rp_init_dns.target\tACCEPT\n'
		[ ! -f "$TEST_TX_DIR/extra-dhcp" ] || printf 'set\tdhcp.lan.ra\tdisabled\n' ;;
	verify)
		if [ -f "$TEST_TX_DIR/verify-fail" ]; then printf '%s\n' 'fixture runtime evidence unavailable' >&2; exit 1; fi ;;
	management-address) cat "$TEST_TX_DIR/db/network.lan.ipaddr" ;;
	link-plan)
		if [ -f "$TEST_TX_DIR/window-change" ] && [ -f "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/baseline-now" ]; then
			case "$(cat "$TEST_TX_DIR/window-change")" in
				scalar)
					if [ "${TEST_NATIVE_TRANSACTION:-0}" = 1 ]; then
						uci -t "$TEST_TX_DIR/concurrent" set routepolicy.main.lan_interface=foreign
						uci -t "$TEST_TX_DIR/concurrent" commit routepolicy
					else printf foreign >"$TEST_TX_DIR/db/routepolicy.main.lan_interface"; fi ;;
				absent) printf rule >"$TEST_TX_DIR/db/firewall.rp_init_dns" ;;
				list) : >"$TEST_TX_DIR/list.network.lan.ipaddr" ;;
			esac
			rm "$TEST_TX_DIR/window-change"
		fi
		if [ ! -f "$TEST_TX_DIR/link-enabled" ]; then printf 'required\t0\n'; exit 0; fi
		link="$ROUTEPOLICY_ROOT/sys/class/net/eth9"
		up=0; [ "$(cat "$link/flags")" != 0x1 ] || up=1
		dad=pending-link-up; [ "$up" = 0 ] || dad=clear
		dad_required=1; target=198.51.100.2
		if [ -f "$TEST_TX_DIR/link-dhcp" ]; then dad_required=0; target=-; dad=not-required; fi
		printf 'required\t1\ndad_required\t%s\ndevice\teth9\nifindex\t%s\nmac\t%s\ndevice_path\t%s\nup\t%s\ncarrier\t1\ntarget\t%s\ndad\t%s\n' \
			"$dad_required" "$(cat "$link/ifindex")" "$(cat "$link/address")" "$(readlink -f "$link/device")" "$up" "$target" "$dad" ;;
	link-unclaimed) [ ! -f "$TEST_TX_DIR/link-claimed" ] ;;
	link-dad)
		[ ! -f "$TEST_TX_DIR/link-dhcp" ] || { printf '%s\n' 'DHCP creation must not invoke static DAD' >&2; exit 1; }
		[ "$(cat "$ROUTEPOLICY_ROOT/sys/class/net/eth9/flags")" = 0x1 ]
		[ ! -f "$TEST_TX_DIR/commits" ] || { printf '%s\n' 'DAD occurred after UCI commit' >&2; exit 1; }
		if [ -f "$TEST_TX_DIR/link-kill" ]; then
			owner_pid=$(awk '$1=="PPid:" {print $2}' "/proc/$PPID/status")
			kill -KILL "$owner_pid"
		fi
		if [ -f "$TEST_TX_DIR/link-dad-fail" ]; then printf '%s\n' 'ARP-DAD conflict or missing carrier' >&2; exit 1; fi ;;
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
[ "${3:-}" != delete ] || { printf '%s\n' delete >>"$TEST_TX_DIR/guard-delete"; exit 0; }
printf '%s\n' '{"routepolicy-initguard":{"instances":{"guard":{"running":true}}}}'
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' true
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
set -eu
[ "$1:$2:$3:$4" = link:set:dev:eth9 ] || exit 1
wal="$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current"
[ -f "$wal/link-attempted" ] && [ -f "$wal/link-boot" ] && [ "$(cat "$wal/phase")" != prepared ] || exit 1
printf '%s\n' "$*" >>"$TEST_TX_DIR/link-log"
if [ "$5" = up ] && [ -f "$TEST_TX_DIR/link-up-fail" ]; then printf '%s\n' 'link UP failed' >&2; exit 1; fi
if [ "$5" = up ] && [ -f "$TEST_TX_DIR/link-delay-kill" ]; then
	owner_pid=$(awk '$1=="PPid:" {print $2}' "/proc/$PPID/status")
	kill -KILL "$owner_pid"
	: >"$TEST_TX_DIR/link-writer-active"
	sleep 2
fi
case "$5" in up) printf 0x1 >"$ROUTEPOLICY_ROOT/sys/class/net/eth9/flags" ;; down) printf 0x0 >"$ROUTEPOLICY_ROOT/sys/class/net/eth9/flags" ;; *) exit 1 ;; esac
EOF
for service in network firewall dnsmasq odhcpd routepolicy-initguard; do
	cat >"$tmp/root/etc/init.d/$service" <<'EOF'
#!/bin/sh
name=${0##*/}
printf '%s %s\n' "$name" "$1" >>"$TEST_TX_DIR/services"
[ ! -f "$TEST_TX_DIR/service-fail" ] || [ "$name" != firewall ] || exit 1
[ ! -f "$TEST_TX_DIR/service-fail-odhcpd" ] || [ "$name" != odhcpd ] || exit 1
case "$name" in
	network) cat "$TEST_TX_DIR/db/network.lan.ipaddr" >"$TEST_TX_DIR/runtime-management" ;;
	dnsmasq) cat "$TEST_TX_DIR/db/dhcp.lan.ignore" >"$TEST_TX_DIR/runtime-ignore" ;;
esac
EOF
done
chmod +x "$tmp/bin/"* "$tmp/lib/init-topology" "$tmp/root/etc/init.d/"*

reset() {
	rm -rf "$tmp/root/etc/routepolicy" "$tmp/db"
	mkdir "$tmp/db"
	rm -f "$tmp/fail-at" "$tmp/kill-at" "$tmp/fw4-fail" "$tmp/verify-fail" "$tmp/service-fail" "$tmp/service-fail-odhcpd" "$tmp/pending" "$tmp/commits" "$tmp/bad-plan" "$tmp/guard-down" "$tmp/services"
	rm -f "$tmp/"list.*
	rm -f "$tmp/"link-*
	rm -f "$tmp/guard-delete"
	rm -f "$tmp/"pending-* "$tmp/window-change" "$tmp/extra-dhcp"
	mkdir -p "$tmp/root/etc/config"
	for config_package in network dhcp firewall routepolicy; do printf '# isolated fixture\n' >"$tmp/root/etc/config/$config_package"; done
	mkdir -p "$tmp/root/sys/class/net/eth9" "$tmp/physical/eth9" "$tmp/root/proc/sys/kernel/random"
	rm -f "$tmp/root/sys/class/net/eth9/device"
	ln -s "$tmp/physical/eth9" "$tmp/root/sys/class/net/eth9/device"
	printf 0x0 >"$tmp/root/sys/class/net/eth9/flags"
	printf 9 >"$tmp/root/sys/class/net/eth9/ifindex"
	printf '02:00:00:00:00:09' >"$tmp/root/sys/class/net/eth9/address"
	printf '00000000-0000-4000-8000-000000000001' >"$tmp/root/proc/sys/kernel/random/boot_id"
	printf lan >"$tmp/db/routepolicy.main.lan_interface"
	printf wan >"$tmp/db/routepolicy.main.default_interface"
	printf usbwan >"$tmp/db/routepolicy.main.policy_interface"
	printf 192.0.2.1 >"$tmp/db/network.lan.ipaddr"
	printf 0 >"$tmp/db/dhcp.lan.ignore"
	printf untouched >"$tmp/db/dhcp.other.ignore"
	printf server >"$tmp/db/dhcp.lan.ra"
	printf 192.0.2.1 >"$tmp/runtime-management"
	printf 0 >"$tmp/runtime-ignore"
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

if [ "${1:-}" = --native-transaction ]; then
	[ -n "${TEST_UCI_SDK_ROOT:-}" ] || [ -n "$TEST_NATIVE_UCI_PATH" ]
	export TEST_NATIVE_TRANSACTION=1
	cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
	exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/sbin/uci" -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_TX_DIR/external" "$@"
fi
exec "$TEST_NATIVE_UCI_PATH" -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_TX_DIR/external" "$@"
EOF
	native_reset() {
		reset
		rm -rf "$tmp/external" "$tmp/concurrent"
		mkdir "$tmp/external" "$tmp/concurrent"
		printf "config interface 'lan'\n\toption ipaddr '192.0.2.1'\n" >"$tmp/root/etc/config/network"
		printf "config main 'main'\n\toption lan_interface 'lan'\n\toption default_interface 'wan'\n\toption policy_interface 'usbwan'\n" >"$tmp/root/etc/config/routepolicy"
		printf "config dhcp 'lan'\n\toption ignore '0'\n\toption ra 'server'\nconfig dhcp 'other'\n\toption leasetime '12h'\n" >"$tmp/root/etc/config/dhcp"
	}
	native_get() {
		native_pkg=${1%%.*}
		uci -c "$WAL/config" -t "$WAL/read-delta" get "rp_${token}_${native_pkg}${1#"$native_pkg"}"
	}
	native_reset; prepare; "$TX" apply "$token" >/dev/null
	uci set dhcp.other.leasetime=2h
	cp "$tmp/external/dhcp" "$tmp/external-original"
	: >"$tmp/services"
	bad "$TX" recover; phase_is conflict
	[ "$(native_get network.lan.ipaddr)" = 192.0.2.1 ]
	[ "$(native_get dhcp.lan.ignore)" = 0 ]
	[ "$(native_get dhcp.other.leasetime)" = 12h ]
	[ "$(uci get dhcp.other.leasetime)" = 2h ]
	cmp "$tmp/external-original" "$tmp/external/dhcp"
	grep -Fxq 'network reload' "$tmp/services"
	if grep -Eq '^(dnsmasq|odhcpd) ' "$tmp/services"; then exit 1; fi
	uci revert dhcp.other.leasetime
	"$TX" recover >/dev/null; phase_is rolled_back
	native_reset; touch "$tmp/extra-dhcp"; prepare; "$TX" apply "$token" >/dev/null
	uci set dhcp.lan.ignore=0
	cp "$tmp/external/dhcp" "$tmp/external-original"
	bad "$TX" recover; phase_is conflict
	[ "$(native_get dhcp.lan.ignore)" = 1 ]
	[ "$(native_get dhcp.lan.ra)" = server ]
	[ "$(native_get network.lan.ipaddr)" = 192.0.2.1 ]
	cmp "$tmp/external-original" "$tmp/external/dhcp"
	uci revert dhcp.lan.ignore
	"$TX" recover >/dev/null; phase_is rolled_back
	native_reset; prepare; printf scalar >"$tmp/window-change"
	bad "$TX" apply "$token"; phase_is rolled_back
	[ "$(native_get routepolicy.main.lan_interface)" = foreign ]
	[ "$(cat "$WAL/fields/1/old")" = lan ]
	"$TX" status | grep -Fq '"failed_stage":"concurrent-write"'
	printf '%s\n' 'native UCI transaction: unrelated/owned pending isolated, sibling recovery continues, prepare baseline frozen (services mocked)'
	exit 0
fi

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

# WAL old values/existence/list type remain the prepare baseline across the last-read window.
for window_kind in scalar absent list; do
	reset; prepare; printf '%s\n' "$window_kind" >"$tmp/window-change"
	bad "$TX" apply "$token"
	phase_is rolled_back
	"$TX" status | grep -Fq '"failed_stage":"concurrent-write"'
	case "$window_kind" in
		scalar) [ "$(cat "$tmp/db/routepolicy.main.lan_interface")" = foreign ]; [ "$(cat "$WAL/fields/1/old")" = lan ] ;;
		absent) [ "$(cat "$tmp/db/firewall.rp_init_dns")" = rule ]; [ "$(cat "$WAL/fields/6/existed")" = 0 ] ;;
		list) [ -f "$tmp/list.network.lan.ipaddr" ]; [ "$(cat "$WAL/fields/4/type")" = scalar ] ;;
	esac
done

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

# Unrelated same-package pending is neither committed nor discarded; runtime reload is deferred.
reset; prepare; "$TX" apply "$token" >/dev/null
printf "dhcp.other.leasetime='2h'\n" >"$tmp/pending-dhcp"
cp "$tmp/pending-dhcp" "$tmp/pending-original"
: >"$tmp/services"
bad "$TX" recover
phase_is conflict
restored
cmp "$tmp/pending-original" "$tmp/pending-dhcp"
[ ! -f "$tmp/db/dhcp.other.leasetime" ]
[ "$(cat "$tmp/runtime-management")" = 192.0.2.1 ]
[ "$(cat "$tmp/runtime-ignore")" = 1 ]
grep -Fxq 'network reload' "$tmp/services"
grep -Fxq 'firewall reload' "$tmp/services"
if grep -Eq '^(dnsmasq|odhcpd) ' "$tmp/services"; then exit 1; fi
"$TX" status | grep -Fq 'dnsmasq:dhcp'
rm "$tmp/pending-dhcp"
"$TX" recover >/dev/null
phase_is rolled_back
[ "$(cat "$tmp/runtime-ignore")" = 0 ]

# Pending on one owned key preserves that committed key but does not block sibling restoration.
reset; touch "$tmp/extra-dhcp"; prepare; "$TX" apply "$token" >/dev/null
printf "dhcp.lan.ignore='0'\n" >"$tmp/pending-dhcp"
cp "$tmp/pending-dhcp" "$tmp/pending-original"
bad "$TX" recover
phase_is conflict
[ "$(cat "$tmp/db/dhcp.lan.ignore")" = 1 ]
[ "$(cat "$tmp/db/dhcp.lan.ra")" = server ]
[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.1 ]
cmp "$tmp/pending-original" "$tmp/pending-dhcp"
"$TX" status | grep -Fq pending:dhcp.lan.ignore
rm "$tmp/pending-dhcp"; "$TX" recover >/dev/null; phase_is rolled_back

# Network pending keeps the currently reachable management path until it can be reconciled.
reset; prepare; "$TX" apply "$token" >/dev/null
printf "network.lan.ipaddr='192.0.2.99'\n" >"$tmp/pending-network"
cp "$tmp/pending-network" "$tmp/pending-original"
: >"$tmp/services"
bad "$TX" recover
phase_is conflict
[ "$(cat "$tmp/runtime-management")" = 192.0.2.2 ]
[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.2 ]
[ "$(cat "$tmp/db/dhcp.lan.ignore")" = 0 ]
[ ! -s "$tmp/services" ]
cmp "$tmp/pending-original" "$tmp/pending-network"
"$TX" status | grep -Fq network:network
rm "$tmp/pending-network"; "$TX" recover >/dev/null; phase_is rolled_back
[ "$(cat "$tmp/runtime-management")" = 192.0.2.1 ]

# An absent optional IPv6 daemon is skipped; an installed failing daemon is a real failure.
reset; mv "$tmp/root/etc/init.d/odhcpd" "$tmp/odhcpd-installed"
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; phase_is rolled_back
mv "$tmp/odhcpd-installed" "$tmp/root/etc/init.d/odhcpd"
reset; touch "$tmp/service-fail-odhcpd"; prepare
bad "$TX" apply "$token"
phase_is conflict
"$TX" status | grep -Fq '"failed_stage":"reload:odhcpd"'
rm "$tmp/service-fail-odhcpd"; "$TX" recover >/dev/null; phase_is rolled_back

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
	if [ "$fault" = service-fail ]; then
		"$TX" status | grep -Fq '"failed_stage":"reload:firewall"'
		rm "$tmp/service-fail"; "$TX" recover >/dev/null; phase_is rolled_back
	fi
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

for boot_fault in changed missing; do
	reset; prepare; "$TX" apply "$token" >/dev/null
	printf 9999999999 >"$WAL/deadline"
	if [ "$boot_fault" = changed ]; then
		printf '00000000-0000-4000-8000-000000000002' >"$tmp/root/proc/sys/kernel/random/boot_id"
	else rm "$WAL/boot-id"; fi
	"$TX" guard & boot_guard=$!
	wait "$boot_guard"
	phase_is rolled_back
	restored
done

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

# Startup waits for the boot guard's in-flight recovery, then permits the normal service.
reset; prepare; "$TX" apply "$token" >/dev/null
exec 6>"$tmp/root/etc/routepolicy/state/init-transaction/lock"
flock -x 6
"$TX" recover-startup 6>&- >"$tmp/startup-recover-output" & startup_recover=$!
sleep 1
kill -0 "$startup_recover"
printf rolled_back >"$WAL/phase"
flock -u 6; exec 6>&-
wait "$startup_recover"
phase_is rolled_back
printf conflict >"$WAL/phase"
bad "$TX" recover-startup
phase_is conflict

# Admin-DOWN static egress: review stays read-only; DAD precedes every UCI commit.
reset; touch "$tmp/link-enabled"
"$TX" preview lan wan usbwan - - - - - - 192.0.2.2 24 >"$tmp/link-preview"
grep -Fq pending-link-up "$tmp/link-preview"
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x0 ]
prepare
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x0 ]
"$TX" apply "$token" >/dev/null
phase_is pending
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x1 ]
"$TX" recover >/dev/null
phase_is rolled_back
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x0 ]
restored
for link_fault in link-up-fail link-dad-fail link-kill; do
	reset; touch "$tmp/link-enabled" "$tmp/$link_fault"; prepare
	bad "$TX" apply "$token"
	[ ! -f "$tmp/commits" ]
	if [ "$link_fault" = link-kill ]; then phase_is applying; "$TX" recover >/dev/null; fi
	phase_is rolled_back
	if [ "$link_fault" = link-dad-fail ]; then
		"$TX" status | grep -Fq '"failed_stage":"link-dad"'
		"$TX" status | grep -Fq 'ARP-DAD conflict or missing carrier'
	fi
	[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x0 ]
	restored
done

reset; touch "$tmp/link-enabled"; printf 0x1 >"$tmp/root/sys/class/net/eth9/flags"; prepare
"$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null
phase_is rolled_back
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x1 ]
[ ! -f "$tmp/link-log" ]

# A surviving finite writer must finish before crash recovery can acquire the lock.
reset; touch "$tmp/link-enabled" "$tmp/link-delay-kill"; prepare
bad "$TX" apply "$token"
phase_is applying
while [ ! -f "$tmp/link-writer-active" ]; do sleep 0.1; done
bad "$TX" recover
sleep 3
"$TX" recover >/dev/null
phase_is rolled_back
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x0 ]
[ ! -f "$tmp/commits" ]

# Reboot recovery uses physical identity; same-boot ifindex reuse/foreign ownership is preserved.
reset; touch "$tmp/link-enabled"; prepare; "$TX" apply "$token" >/dev/null
printf '00000000-0000-4000-8000-000000000002' >"$tmp/root/proc/sys/kernel/random/boot_id"
printf 19 >"$tmp/root/sys/class/net/eth9/ifindex"
"$TX" recover >/dev/null
phase_is rolled_back
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x0 ]
for takeover in link-claimed ifindex; do
	reset; touch "$tmp/link-enabled"; prepare; "$TX" apply "$token" >/dev/null
	if [ "$takeover" = ifindex ]; then printf 19 >"$tmp/root/sys/class/net/eth9/ifindex"; else touch "$tmp/link-claimed"; fi
	bad "$TX" recover
	phase_is conflict
	[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x1 ]
	restored
done

# A confirmed new path belongs to netifd; recovery must not lower it.
reset; touch "$tmp/link-enabled"; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token" >/dev/null
"$TX" recover >/dev/null
phase_is confirmed
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x1 ]

# DHCP freezes the same physical identity, without static link-UP or ARP-DAD actions.
reset; touch "$tmp/link-enabled" "$tmp/link-dhcp"; prepare
printf '02:00:00:00:00:19' >"$tmp/root/sys/class/net/eth9/address"
bad "$TX" apply "$token"
phase_is prepared
[ ! -f "$tmp/commits" ]
[ ! -f "$tmp/link-log" ]
reset; touch "$tmp/link-enabled" "$tmp/link-dhcp"; prepare
"$TX" apply "$token" >/dev/null
phase_is pending
[ ! -f "$tmp/link-log" ]
printf '02:00:00:00:00:19' >"$tmp/root/sys/class/net/eth9/address"
bad env SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token"
phase_is pending
"$TX" status | grep -Fq 'physical identity differs'
printf '02:00:00:00:00:09' >"$tmp/root/sys/class/net/eth9/address"
"$TX" recover >/dev/null
phase_is rolled_back

# An old terminal guard cannot unregister a fresh apply while the writer owns its lock.
rm -f "$tmp/guard-delete"
exec 7>"$tmp/root/etc/routepolicy/state/init-transaction/lock"
flock -x 7
"$TX" guard 7>&- & old_guard=$!
sleep 2
[ ! -f "$tmp/guard-delete" ]
flock -u 7
exec 7>&-
wait "$old_guard"
[ -f "$tmp/guard-delete" ]
printf '%s\n' 'init transaction tests: passed (mock UCI/services; packet evidence remains EVIDENCE_MISSING)'
