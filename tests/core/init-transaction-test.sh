#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
REAL_LIB="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-transaction.XXXXXX")
race_guard='' race_auto=''
cleanup() {
	[ ! -d "$tmp" ] || printf '%s' '' >"$tmp/auto-release"
	[ -z "$race_auto" ] || kill "$race_auto" 2>/dev/null || true
	[ -z "$race_guard" ] || { kill "$race_guard" 2>/dev/null || true; wait "$race_guard" 2>/dev/null || true; }
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
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
cp "$REAL_LIB/common" "$REAL_LIB/init-dns" "$REAL_LIB/init-transaction" "$tmp/lib/"
chmod +x "$tmp/lib/init-transaction"
export TEST_TX_DIR="$tmp" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_OUTPUT=json
TEST_NATIVE_UCI_PATH=$(command -v uci 2>/dev/null || true)
TEST_SYNC_BIN=$(command -v sync)
TEST_FLOCK_BIN=$(command -v flock)
TEST_DATE_BIN=$(command -v date)
TEST_SLEEP_BIN=$(command -v sleep)
TEST_OWNER_PID=$$
export TEST_NATIVE_UCI_PATH TEST_SYNC_BIN TEST_FLOCK_BIN TEST_DATE_BIN TEST_SLEEP_BIN TEST_OWNER_PID
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
		if [ "${5:--}" != - ]; then
			printf 'set\tnetwork.rp_init_%s\tinterface\nset\tnetwork.rp_init_%s.device\t%s\nset\tnetwork.rp_init_%s.proto\t%s\n' "$5" "$5" "$6" "$5" "$7"
		fi
		[ ! -f "$TEST_TX_DIR/extra-dhcp" ] || printf 'set\tdhcp.lan.ra\tdisabled\n'
		if [ -f "$TEST_TX_DIR/extra-zone" ]; then
			printf 'set\tfirewall.rp_init_policy\tzone\nset\tfirewall.rp_init_policy.name\trp_init_policy\nset\tfirewall.rp_init_policy.network\tusbwan\nset\tfirewall.rp_init_policy.input\tREJECT\nset\tfirewall.rp_init_policy.output\tACCEPT\nset\tfirewall.rp_init_policy.forward\tDROP\n'
		fi ;;
	verify)
		if [ -f "$TEST_TX_DIR/dhcp-test" ]; then
			printf '%s\n' verify >>"$TEST_TX_DIR/dhcp-verify-calls"
			current=$(ubus call network.interface dump)
			printf '%s\n' "$current" | grep -Fq '"up":true' || { printf '%s\n' 'new DHCP egress lacks lease/default gateway' >&2; exit 1; }
		fi
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
				wal-stage) mkdir "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/stage" ;;
				wal-boot) mkdir "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/boot-id" ;;
				wal-uptime) mkdir "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/uptime-start-cs" ;;
				wal-link) mkdir "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/link-expected-up" ;;
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
if [ "$1:$2:${3:-}" = call:network.interface:dump ]; then
	n=$(cat "$TEST_TX_DIR/dhcp-polls" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s\n' "$n" >"$TEST_TX_DIR/dhcp-polls"
	mode=$(cat "$TEST_TX_DIR/dhcp-mode" 2>/dev/null || printf ready)
	[ "$mode" != rpc-error ] || exit 1
	: >"$TEST_TX_DIR/dhcp-clock-active"
	if [ "$mode" = publish ] && [ "$n" -lt 3 ]; then printf '%s\n' '{"interface":[]}'; exit 0; fi
	after=$(cat "$TEST_TX_DIR/dhcp-ready-after" 2>/dev/null || printf 3)
	if [ "$mode" = warmup ] && [ "$n" -lt "$after" ]; then mode=pending; fi
	interface=$(cat "$TEST_TX_DIR/dhcp-interface" 2>/dev/null || printf rp_init_policy)
	if [ "$mode" = pending ]; then
		printf '{"interface":[{"interface":"%s","up":false,"pending":true,"proto":"dhcp","device":"eth9","l3_device":"eth9","ipv4-address":[],"route":[],"errors":[]}]}\n' "$interface"
	else
		device=eth9; [ "$mode" != wrong-device ] || device=eth99
		proto=dhcp; [ "$mode" != wrong-proto ] || proto=static
		gateway=198.51.100.1; [ "$mode" != bad-gateway ] || gateway=invalid
		routes="[{\"target\":\"0.0.0.0\",\"mask\":0,\"nexthop\":\"$gateway\"}]"
		if [ "$mode" = lease-pending ] && [ "$n" -lt 3 ]; then routes='[]'; fi
		errors='[]'; [ "$mode" != error ] || errors='[{"code":"NO_DEVICE"}]'
		printf '{"interface":[{"interface":"%s","up":true,"pending":false,"proto":"%s","device":"%s","l3_device":"%s","ipv4-address":[{"address":"198.51.100.2","mask":24}],"route":%s,"errors":%s}]}\n' "$interface" "$proto" "$device" "$device" "$routes" "$errors"
	fi
	exit 0
fi
case "$2" in network.interface.*)
	policy=${2#network.interface.}
	device="$policy-dev"; [ "$policy" != rp_init_policy ] || device=eth9
	printf '{"l3_device":"%s","route":[{"target":"0.0.0.0","nexthop":"198.51.100.1"}]}\n' "$device"
	exit 0 ;;
esac
[ ! -f "$TEST_TX_DIR/guard-down" ] || exit 1
[ "${3:-}" != delete ] || { printf '%s\n' delete >>"$TEST_TX_DIR/guard-delete"; exit 0; }
printf '%s\n' '{"routepolicy-initguard":{"instances":{"guard":{"running":true}}}}'
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
data=$(cat); expression=$2; result=
case "$expression" in
	*routepolicy-initguard*) result=true ;;
	@.interface) result=$(printf '%s\n' "$data" | sed -n 's/^{"interface":\(\[.*\]\)}$/\1/p') ;;
	@.interface\[*) result=$(printf '%s\n' "$data" | sed -n 's/^{"interface":\[\(.*\)\]}$/\1/p') ;;
	@.up|@.pending) field=${expression#@.}; result=$(printf '%s\n' "$data" | sed -n "s/.*\"$field\":\(true\|false\).*/\1/p") ;;
	@.proto|@.device|@.l3_device) field=${expression#@.}; result=$(printf '%s\n' "$data" | sed -n "s/.*\"$field\":\"\([^\"]*\)\".*/\1/p") ;;
	*ipv4-address*address) result=$(printf '%s\n' "$data" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p') ;;
	*ipv4-address*mask) result=$(printf '%s\n' "$data" | sed -n 's/.*"address":"[^"]*","mask":\([0-9]*\).*/\1/p') ;;
	@.route*) result=$(printf '%s\n' "$data" | sed -n 's/.*"nexthop":"\([^"]*\)".*/\1/p') ;;
	@.errors*) case "$data" in *NO_DEVICE*) result='{"code":"NO_DEVICE"}' ;; esac ;;
esac
[ -n "$result" ] || exit 1
printf '%s\n' "$result"
EOF
if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
	cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/usr/bin/jsonfilter" "$@"
EOF
fi
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
[ -f "$TEST_TX_DIR/policy-running" ]
EOF
cat >"$tmp/lib/apply" <<'EOF'
#!/bin/sh
set -eu
[ ! -e /proc/self/fd/9 ] || { printf '%s\n' 'policy child inherited initialization lock' >&2; exit 1; }
mkdir -p "$ROUTEPOLICY_ROOT/tmp/routepolicy"
mkdir "$ROUTEPOLICY_ROOT/tmp/routepolicy/apply.lock" || exit 1
trap 'rmdir "$ROUTEPOLICY_ROOT/tmp/routepolicy/apply.lock"' EXIT
policy=$(cat "$TEST_TX_DIR/db/routepolicy.main.policy_interface")
printf '%s\n' "$policy" >>"$TEST_TX_DIR/policy-apply-calls"
if { [ "$policy" = wan2 ] && [ -f "$TEST_TX_DIR/policy-apply-fail" ]; } || { [ "$policy" = usbwan ] && [ -f "$TEST_TX_DIR/policy-restore-fail" ]; }; then printf '%s\n' 'fixture policy apply failed' >&2; exit 1; fi
[ -f "$TEST_TX_DIR/policy-route-stale" ] || printf '%s' "$policy" >"$TEST_TX_DIR/runtime-policy"
device="$policy-dev"; [ "$policy" != rp_init_policy ] || device=eth9
printf 'schema=1\nroute_table=200\npolicy_interface=%s\npolicy_device=%s\n' "$policy" "$device" >"$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied"
EOF
chmod +x "$tmp/lib/apply"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
set -eu
if [ "$1:$2:${3:-}:${4:-}" = -4:route:show:table ]; then
	if [ "$5" = main ]; then
		mode=$(cat "$TEST_TX_DIR/dhcp-mode" 2>/dev/null || printf ready)
		# Native ip omits dev after a dev filter; replay its captured output shape.
		if [ "${7:-}" = dev ]; then
			printf '%s\n' 'default via 198.51.100.1 proto static src 198.51.100.2 metric 200 '; exit 0
		fi
		printf '%s\n' 'default via 198.51.100.1 dev wan proto dhcp metric 10'
		if [ "$mode" = kernel-pending ] && [ "$(cat "$TEST_TX_DIR/dhcp-polls")" -lt 3 ]; then exit 0; fi
		[ "$mode" != kernel-other-only ] || exit 0
		gateway=198.51.100.1; [ "$mode" != wrong-route-gateway ] || gateway=198.51.100.99
		printf 'default via %s dev eth9 proto static src 198.51.100.2 metric 200 \n' "$gateway"
		[ "$mode" != duplicate-route ] || printf '%s\n' 'default via 198.51.100.1 dev eth9 metric 201'
		exit 0
	fi
	policy=$(cat "$TEST_TX_DIR/runtime-policy")
	device="$policy-dev"; [ "$policy" != rp_init_policy ] || device=eth9
	printf 'default via 198.51.100.1 dev %s metric 10\n' "$device"
	exit 0
fi
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
cat >"$tmp/bin/sync" <<'EOF'
#!/bin/sh
wal="$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current"
if [ -f "$TEST_TX_DIR/wal-fault" ] && [ "$(cat "$wal/stage" 2>/dev/null)" = commit:routepolicy.main.lan_interface ]; then
	fault=$(cat "$TEST_TX_DIR/wal-fault"); rm "$TEST_TX_DIR/wal-fault"
	case "$fault" in sync) exit 1 ;; attempted) mkdir "$wal/fields/1/attempted" || exit 1 ;; esac
fi
exec "$TEST_SYNC_BIN" "$@"
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/bin/sh
if [ -f "$TEST_TX_DIR/auto-arm" ] && [ "$1:${2:-}" = -n:9 ]; then
	parent_command=$(tr '\000' ' ' <"/proc/$PPID/cmdline")
	case "$parent_command" in *'init-transaction recover'*)
		rm "$TEST_TX_DIR/auto-arm"
		printf '%s\n' "$PPID" >"$TEST_TX_DIR/auto-parent"
		: >"$TEST_TX_DIR/auto-ready"
		while [ ! -f "$TEST_TX_DIR/auto-release" ]; do kill -0 "$TEST_OWNER_PID" 2>/dev/null || exit 1; sleep 0.02; done
		;;
	esac
fi
exec "$TEST_FLOCK_BIN" "$@"
EOF
cat >"$tmp/bin/date" <<'EOF'
#!/bin/sh
if [ "$#" = 1 ] && [ "$1" = +%s ] && [ -f "$TEST_TX_DIR/wall-clock" ]; then cat "$TEST_TX_DIR/wall-clock"
else exec "$TEST_DATE_BIN" "$@"; fi
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/bin/sh
if [ "$#" = 1 ] && [ "$1" = 1 ] && { [ -f "$TEST_TX_DIR/dhcp-clock-active" ] || [ -f "$TEST_TX_DIR/policy-clock-active" ]; }; then
	if [ -f "$TEST_TX_DIR/policy-owner-release" ]; then rmdir "$ROUTEPOLICY_ROOT/tmp/routepolicy/apply.lock"; rm "$TEST_TX_DIR/policy-owner-release"; fi
	awk '{printf "%.2f 0.00\n",$1+1}' "$ROUTEPOLICY_ROOT/proc/uptime" >"$TEST_TX_DIR/uptime-next"
	mv "$TEST_TX_DIR/uptime-next" "$ROUTEPOLICY_ROOT/proc/uptime"
else exec "$TEST_SLEEP_BIN" "$@"; fi
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
[ "$name" != dnsmasq ] || [ ! -f "$TEST_TX_DIR/dhcp-short-window" ] || printf '1119.00 0.00\n' >"$ROUTEPOLICY_ROOT/proc/uptime"
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
	rm -f "$tmp/"pending-* "$tmp/window-change" "$tmp/extra-dhcp" "$tmp/extra-zone" "$tmp/wal-fault"
	rm -f "$tmp/"auto-*
	rm -f "$tmp/"dhcp-* "$tmp/"policy-* "$tmp/runtime-policy"
	mkdir -p "$tmp/root/etc/config"
	for config_package in network dhcp firewall routepolicy smartdns; do printf '# isolated fixture\n' >"$tmp/root/etc/config/$config_package"; done
	mkdir -p "$tmp/root/sys/class/net/eth9" "$tmp/physical/eth9" "$tmp/root/proc/sys/kernel/random"
	rm -f "$tmp/root/sys/class/net/eth9/device"
	ln -s "$tmp/physical/eth9" "$tmp/root/sys/class/net/eth9/device"
	printf 0x0 >"$tmp/root/sys/class/net/eth9/flags"
	printf 9 >"$tmp/root/sys/class/net/eth9/ifindex"
	printf '02:00:00:00:00:09' >"$tmp/root/sys/class/net/eth9/address"
	printf '00000000-0000-4000-8000-000000000001' >"$tmp/root/proc/sys/kernel/random/boot_id"
	printf '1000.00 0.00\n' >"$tmp/root/proc/uptime"
	printf 1700000000 >"$tmp/wall-clock"
	printf lan >"$tmp/db/routepolicy.main.lan_interface"
	printf wan >"$tmp/db/routepolicy.main.default_interface"
	printf usbwan >"$tmp/db/routepolicy.main.policy_interface"
	printf 0 >"$tmp/db/routepolicy.main.enabled"
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
prepare_policy() {
	out=$("$TX" prepare lan wan wan2 - - - - - - 192.0.2.2 24)
	token=$(printf '%s\n' "$out" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" = 32 ]
}
prepare_dhcp() {
	if [ "${1:-policy}" = default ]; then
		printf rp_init_default >"$tmp/dhcp-interface"
		out=$("$TX" prepare lan rp_init_default usbwan default eth9 dhcp - - - - -)
	else
		printf rp_init_policy >"$tmp/dhcp-interface"
		out=$("$TX" prepare lan wan rp_init_policy policy eth9 dhcp - - - - -)
	fi
	token=$(printf '%s\n' "$out" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" = 32 ]
}
enable_policy_fixture() {
	printf 1 >"$tmp/db/routepolicy.main.enabled"
	mkdir -p "$tmp/root/etc/routepolicy/state"
	printf 'schema=1\nroute_table=200\npolicy_interface=usbwan\npolicy_device=usbwan-dev\n' >"$tmp/root/etc/routepolicy/state/applied"
	printf usbwan >"$tmp/runtime-policy"; : >"$tmp/policy-running"
}
policy_apply_test() {
	reset; enable_policy_fixture; prepare_policy; "$TX" apply "$token" >/dev/null
	printf 'policy after apply: configured=%s runtime=%s\n' "$(cat "$tmp/db/routepolicy.main.policy_interface")" "$(cat "$tmp/runtime-policy")"
	[ "$(cat "$tmp/runtime-policy")" = wan2 ]
}
policy_rollback_test() {
	reset; enable_policy_fixture; prepare_policy; "$TX" apply "$token" >/dev/null
	printf wan2 >"$tmp/runtime-policy"
	"$TX" recover >/dev/null
	printf 'policy after rollback: configured=%s runtime=%s\n' "$(cat "$tmp/db/routepolicy.main.policy_interface")" "$(cat "$tmp/runtime-policy")"
	[ "$(cat "$tmp/runtime-policy")" = usbwan ]
}
dhcp_readiness_test() {
	reset; touch "$tmp/link-enabled" "$tmp/link-dhcp" "$tmp/dhcp-test"; printf warmup >"$tmp/dhcp-mode"
	printf 17 >"$tmp/dhcp-ready-after"
	prepare_dhcp
	if ! "$TX" apply "$token" >"$tmp/dhcp-apply-output"; then
		printf 'new DHCP after first incomplete lease: phase=%s\n' "$(cat "$WAL/phase")" >&2; return 1
	fi
	phase_is pending
	[ "$(cat "$tmp/dhcp-polls")" -ge 17 ]
	[ "$(wc -l <"$tmp/dhcp-verify-calls")" = 1 ]
	[ "$(cat "$WAL/uptime-start-cs")" = 100000 ]
	[ "$(cat "$WAL/deadline")" = 1700000120 ]
}
policy_runtime_tests() {
	policy_apply_test
	policy_rollback_test
	# Disabled stays disabled; enabled-but-missing runtime must fail before any network write.
	reset; prepare_policy; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null
	[ ! -f "$tmp/policy-apply-calls" ]
	for missing in state table; do
		reset; enable_policy_fixture
		if [ "$missing" = state ]; then rm "$tmp/root/etc/routepolicy/state/applied"; else rm "$tmp/policy-running"; fi
		prepare_policy; bad "$TX" apply "$token"; phase_is prepared
		[ ! -f "$tmp/commits" ]; [ ! -f "$tmp/policy-apply-calls" ]
	done
	for policy_fault in policy-apply-fail policy-route-stale; do
		reset; enable_policy_fixture; touch "$tmp/$policy_fault"; prepare_policy
		bad "$TX" apply "$token"; phase_is rolled_back
		[ "$(cat "$tmp/runtime-policy")" = usbwan ]
		[ "$(cat "$tmp/db/routepolicy.main.policy_interface")" = usbwan ]
		"$TX" status | grep -Fq '"failed_stage":"policy-runtime"'
	done
	reset; enable_policy_fixture; prepare_policy; "$TX" apply "$token" >/dev/null
	printf usbwan >"$tmp/runtime-policy"
	bad env SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token"; phase_is pending
	[ "$(wc -l <"$tmp/policy-apply-calls")" = 1 ]
	"$TX" recover >/dev/null; phase_is rolled_back
	reset; enable_policy_fixture; prepare_policy; "$TX" apply "$token" >/dev/null
	touch "$tmp/policy-restore-fail"; bad "$TX" recover; phase_is conflict
	[ "$(cat "$tmp/runtime-policy")" = wan2 ]
	[ "$(cat "$tmp/db/routepolicy.main.policy_interface")" = usbwan ]
	rm "$tmp/policy-restore-fail"; "$TX" recover >/dev/null; phase_is rolled_back
	[ "$(cat "$tmp/runtime-policy")" = usbwan ]
	reset; enable_policy_fixture; prepare_policy; "$TX" apply "$token" >/dev/null
	rm "$WAL/policy-active"; "$TX" recover >/dev/null; phase_is rolled_back
	[ "$(cat "$tmp/runtime-policy")" = usbwan ]
	reset; enable_policy_fixture; prepare_policy
	mkdir -p "$tmp/root/tmp/routepolicy/apply.lock"
	touch "$tmp/policy-clock-active"
	bad "$TX" apply "$token"; phase_is conflict
	[ -d "$tmp/root/tmp/routepolicy/apply.lock" ]
	rmdir "$tmp/root/tmp/routepolicy/apply.lock"; "$TX" recover >/dev/null; phase_is rolled_back
	reset; enable_policy_fixture; prepare_policy
	mkdir -p "$tmp/root/tmp/routepolicy/apply.lock"; touch "$tmp/policy-clock-active" "$tmp/policy-owner-release"
	"$TX" apply "$token" >/dev/null; phase_is pending
	[ "$(cat "$tmp/runtime-policy")" = wan2 ]; [ ! -f "$tmp/policy-owner-release" ]
}
dhcp_readiness_tests() {
	dhcp_readiness_test
	for transient in publish lease-pending kernel-pending; do
		reset; touch "$tmp/link-enabled" "$tmp/link-dhcp" "$tmp/dhcp-test"; printf '%s' "$transient" >"$tmp/dhcp-mode"
		prepare_dhcp; "$TX" apply "$token" >/dev/null; phase_is pending
		[ "$(cat "$tmp/dhcp-polls")" -ge 3 ]
		[ "$(wc -l <"$tmp/dhcp-verify-calls")" = 1 ]
	done
	reset; touch "$tmp/link-enabled" "$tmp/link-dhcp" "$tmp/dhcp-test"; printf warmup >"$tmp/dhcp-mode"
	prepare_dhcp default; "$TX" apply "$token" >/dev/null; phase_is pending
	[ "$(cat "$tmp/db/routepolicy.main.default_interface")" = rp_init_default ]
	for dhcp_fault in wrong-device wrong-proto bad-gateway error rpc-error wrong-route-gateway duplicate-route; do
		reset; touch "$tmp/link-enabled" "$tmp/link-dhcp" "$tmp/dhcp-test"; printf '%s' "$dhcp_fault" >"$tmp/dhcp-mode"
		prepare_dhcp; bad "$TX" apply "$token"; phase_is rolled_back
		[ "$(cat "$tmp/dhcp-polls")" = 1 ]
		[ ! -f "$tmp/dhcp-verify-calls" ]
		[ "$(cat "$tmp/root/proc/uptime")" = '1000.00 0.00' ]
	done
	reset; touch "$tmp/link-enabled" "$tmp/link-dhcp" "$tmp/dhcp-test" "$tmp/verify-fail"
	prepare_dhcp; bad "$TX" apply "$token"; phase_is rolled_back
	[ "$(wc -l <"$tmp/dhcp-verify-calls")" = 1 ]
	"$TX" status | grep -Fq '"failed_stage":"runtime-verify"'
	for incomplete in pending kernel-other-only; do
		reset; touch "$tmp/link-enabled" "$tmp/link-dhcp" "$tmp/dhcp-test"; printf '%s' "$incomplete" >"$tmp/dhcp-mode"
		prepare_dhcp; bad "$TX" apply "$token"; phase_is rolled_back
		[ "$(cat "$tmp/root/proc/uptime")" = '1100.00 0.00' ]
		[ "$(cat "$WAL/uptime-start-cs")" = 100000 ]; [ "$(cat "$WAL/deadline")" = 1700000120 ]
	done
	reset; touch "$tmp/link-enabled" "$tmp/link-dhcp" "$tmp/dhcp-test" "$tmp/dhcp-short-window"
	prepare_dhcp; bad "$TX" apply "$token"; phase_is rolled_back
	[ ! -f "$tmp/dhcp-polls" ]
	[ "$(cat "$WAL/uptime-start-cs")" = 100000 ]; [ "$(cat "$WAL/deadline")" = 1700000120 ]
}
phase_is() { [ "$(cat "$WAL/phase")" = "$1" ]; }
restored() {
	[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.1 ]
	[ "$(cat "$tmp/db/dhcp.lan.ignore")" = 0 ]
	[ "$(cat "$tmp/db/dhcp.other.ignore")" = untouched ]
	[ ! -f "$tmp/db/firewall.rp_init_dns" ]
}
bad() { if "$@" >"$tmp/failure" 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
wait_auto_ready() {
	tries=0
	while [ ! -f "$tmp/auto-ready" ]; do [ "$tries" -lt 500 ] || return 1; tries=$((tries + 1)); sleep 0.02; done
	race_auto=$(cat "$tmp/auto-parent")
}
wait_auto_done() {
	tries=0
	while kill -0 "$race_auto" 2>/dev/null; do [ "$tries" -lt 500 ] || return 1; tries=$((tries + 1)); sleep 0.02; done
	race_auto=
}
stop_race_guard() { kill "$race_guard"; wait "$race_guard" 2>/dev/null || true; race_guard=; }
guard_race_tests() {
	# Healthy pending polling does not compete with confirm for the writer lock.
	reset; prepare; "$TX" apply "$token" >/dev/null
	printf 9999999999 >"$WAL/deadline"; : >"$tmp/auto-arm"
	"$TX" guard >"$tmp/auto-guard-output" 2>&1 & race_guard=$!
	sleep 2
	[ ! -f "$tmp/auto-ready" ]
	stop_race_guard; rm "$tmp/auto-arm"
	"$TX" recover >/dev/null; phase_is rolled_back
	# Guard saw applying; apply publishes a healthy pending state before auto recovery gets its lock.
	reset; prepare; "$TX" apply "$token" >/dev/null
	printf applying >"$WAL/phase"
	exec 6>"$tmp/root/etc/routepolicy/state/init-transaction/lock"; flock -x 6
	: >"$tmp/auto-arm"
	"$TX" guard 6>&- >"$tmp/auto-guard-output" 2>&1 & race_guard=$!
	wait_auto_ready
	printf pending >"$WAL/phase"; printf 9999999999 >"$WAL/deadline"
	flock -u 6; exec 6>&-
	: >"$tmp/auto-release"
	wait_auto_done
	printf 'guard applying-to-pending result: %s\n' "$(cat "$WAL/phase")"
	phase_is pending
	[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.2 ]
	stop_race_guard
	"$TX" recover >/dev/null; phase_is rolled_back; restored
	# A delayed expiry observation must not roll back the next healthy prepared/applied generation.
	reset; prepare; "$TX" apply "$token" >/dev/null
	old_token=$token; printf '1120.00 0.00\n' >"$tmp/root/proc/uptime"; : >"$tmp/auto-arm"
	"$TX" guard >"$tmp/auto-guard-output" 2>&1 & race_guard=$!
	wait_auto_ready
	"$TX" recover >/dev/null; phase_is rolled_back
	prepare; [ "$token" != "$old_token" ]; "$TX" apply "$token" >/dev/null
	: >"$tmp/auto-release"
	wait_auto_done
	phase_is pending
	[ "$(cat "$tmp/db/network.lan.ipaddr")" = 192.0.2.2 ]
	stop_race_guard
	"$TX" recover >/dev/null; phase_is rolled_back; restored
}
confirm_boot_tests() {
	for confirm_boot_fault in changed missing; do
		reset; prepare; "$TX" apply "$token" >/dev/null
		printf 9999999999 >"$WAL/deadline"
		if [ "$confirm_boot_fault" = changed ]; then
			printf '00000000-0000-4000-8000-000000000002' >"$tmp/root/proc/sys/kernel/random/boot_id"
		else rm "$WAL/boot-id"; fi
		if SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token" >"$tmp/confirm-boot-output"; then
			printf 'cross-boot confirm unexpectedly succeeded: %s\n' "$(cat "$WAL/phase")" >&2; return 1
		fi
		phase_is rolled_back; restored
	done
}
backward_clock_test() {
	reset; prepare; "$TX" apply "$token" >/dev/null
	[ "$(cat "$WAL/deadline")" = 1700000120 ]
	printf 1699996400 >"$tmp/wall-clock"
	printf '1120.00 0.00\n' >"$tmp/root/proc/uptime"
	"$TX" recover-auto >/dev/null
	printf 'wall-clock backward at elapsed 120s: %s\n' "$(cat "$WAL/phase")"
	phase_is rolled_back; restored
}
forward_clock_test() {
	reset; prepare; "$TX" apply "$token" >/dev/null
	printf 1700003600 >"$tmp/wall-clock"
	printf '1001.00 0.00\n' >"$tmp/root/proc/uptime"
	"$TX" recover-auto >/dev/null
	printf 'wall-clock forward at elapsed 1s: %s\n' "$(cat "$WAL/phase")"
	phase_is pending
	[ "$(cat "$WAL/deadline")" = 1700000120 ]
	SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token" >/dev/null
	phase_is confirmed
}
monotonic_clock_tests() {
	backward_clock_test
	forward_clock_test
	# Fractional uptime must preserve a full 120-second window, including the last centisecond.
	reset; printf '1000.25 0.00\n' >"$tmp/root/proc/uptime"; prepare; "$TX" apply "$token" >/dev/null
	[ "$(cat "$WAL/uptime-start-cs")" = 100025 ]
	printf '1120.24 0.00\n' >"$tmp/root/proc/uptime"; "$TX" recover-auto >/dev/null; phase_is pending
	printf '1120.25 0.00\n' >"$tmp/root/proc/uptime"; "$TX" recover-auto >/dev/null; phase_is rolled_back; restored
	# Old WAL and unreadable/corrupt monotonic evidence cannot extend the window via epoch time.
	for clock_fault in legacy invalid regressed unreadable; do
		reset; prepare; "$TX" apply "$token" >/dev/null; printf 9999999999 >"$WAL/deadline"
		case "$clock_fault" in
			legacy) rm "$WAL/uptime-start-cs" ;;
			invalid) printf 000009 >"$WAL/uptime-start-cs" ;;
			regressed) printf '999.99 0.00\n' >"$tmp/root/proc/uptime" ;;
			unreadable) printf unavailable >"$tmp/root/proc/uptime" ;;
		esac
		"$TX" recover-auto >/dev/null; phase_is rolled_back; restored
	done
	reset; prepare; "$TX" apply "$token" >/dev/null; rm "$WAL/uptime-start-cs"
	bad env SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token"
	phase_is rolled_back; restored
	reset; prepare; rm "$tmp/root/proc/uptime"
	bad "$TX" apply "$token"; phase_is prepared
	[ ! -f "$tmp/commits" ]; [ ! -f "$tmp/link-log" ]; restored
}

case "${1:-}" in
	--guard-races) guard_race_tests; exit 0 ;;
	--confirm-boot) confirm_boot_tests; exit 0 ;;
	--clock-backward) backward_clock_test; exit 0 ;;
	--clock-forward) forward_clock_test; exit 0 ;;
	--clock-tests) monotonic_clock_tests; confirm_boot_tests; exit 0 ;;
	--policy-apply) policy_apply_test; exit 0 ;;
	--policy-rollback) policy_rollback_test; exit 0 ;;
	--dhcp-readiness) dhcp_readiness_test; exit 0 ;;
	--policy-runtime-tests) policy_runtime_tests; exit 0 ;;
	--dhcp-readiness-tests) dhcp_readiness_tests; exit 0 ;;
esac

if [ "${1:-}" = --native-transaction ] || [ "${1:-}" = --native-cas-audit ]; then
	[ -n "${TEST_UCI_SDK_ROOT:-}" ] || [ -n "$TEST_NATIVE_UCI_PATH" ]
	export TEST_NATIVE_TRANSACTION=1
	cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
native_set=0; native_managed=0
for native_arg do
	[ "$native_arg" != set ] || native_set=1
	case "$native_arg" in rp_*_network.lan.ipaddr=*) native_managed=1 ;; esac
done
if [ "$native_set:$native_managed" = 1:1 ] && [ -f "$TEST_TX_DIR/cas-arm" ]; then
	rm "$TEST_TX_DIR/cas-arm"
	: >"$TEST_TX_DIR/cas-ready"
	while [ ! -f "$TEST_TX_DIR/cas-release" ]; do sleep 0.02; done
fi
if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
	exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/sbin/uci" -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_TX_DIR/external" "$@"
fi
exec "$TEST_NATIVE_UCI_PATH" -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_TX_DIR/external" "$@"
EOF
	native_reset() {
		reset
		rm -f "$tmp/"cas-*
		rm -rf "$tmp/external" "$tmp/concurrent"
		mkdir "$tmp/external" "$tmp/concurrent"
		printf "config interface 'lan'\n\toption ipaddr '192.0.2.1'\n" >"$tmp/root/etc/config/network"
		printf "config main 'main'\n\toption enabled '0'\n\toption lan_interface 'lan'\n\toption default_interface 'wan'\n\toption policy_interface 'usbwan'\n" >"$tmp/root/etc/config/routepolicy"
		printf "config dhcp 'lan'\n\toption ignore '0'\n\toption ra 'server'\nconfig dhcp 'other'\n\toption leasetime '12h'\n" >"$tmp/root/etc/config/dhcp"
	}
	native_get() {
		native_pkg=${1%%.*}
		uci -c "$WAL/config" -t "$WAL/read-delta" get "rp_${token}_${native_pkg}${1#"$native_pkg"}"
	}
	if [ "${1:-}" = --native-cas-audit ]; then
		for cas_phase in apply recover; do
			native_reset; prepare
			[ "$cas_phase" = apply ] || "$TX" apply "$token" >/dev/null
			: >"$tmp/cas-arm"
			if [ "$cas_phase" = apply ]; then "$TX" apply "$token" >"$tmp/cas-command-output" 2>&1 &
			else "$TX" recover >"$tmp/cas-command-output" 2>&1 & fi
			cas_owner=$!
			while [ ! -f "$tmp/cas-ready" ]; do kill -0 "$cas_owner" || { cat "$tmp/cas-command-output"; exit 1; }; sleep 0.02; done
			uci -t "$tmp/concurrent" set network.lan.ipaddr=192.0.2.99
			uci -t "$tmp/concurrent" commit network
			[ "$(native_get network.lan.ipaddr)" = 192.0.2.99 ]
			: >"$tmp/cas-release"
			wait "$cas_owner"
			cas_after=$(native_get network.lan.ipaddr)
			printf 'CAS AUDIT %s: external committed=192.0.2.99, final=%s, phase=%s\n' "$cas_phase" "$cas_after" "$(cat "$WAL/phase")"
			[ "$cas_after" != 192.0.2.99 ] || exit 1
		done
		exit 0
	fi
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
	native_reset; touch "$tmp/extra-zone"; prepare; "$TX" apply "$token" >/dev/null
	uci -t "$tmp/concurrent" set firewall.rp_init_policy.output=DROP
	uci -t "$tmp/concurrent" commit firewall
	printf 192.0.2.2 >"$tmp/db/network.lan.ipaddr"
	bad env SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token"
	phase_is pending
	"$TX" status | grep -Fq 'prepared candidate differs: firewall.rp_init_policy.output'
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

# Reported WAL writes/flush failures must stop before a configuration or link write.
for wal_kind in wal-stage wal-boot wal-uptime; do
	reset; prepare; printf '%s\n' "$wal_kind" >"$tmp/window-change"
	bad "$TX" apply "$token"
	[ ! -f "$tmp/commits" ]
	[ ! -f "$tmp/link-log" ]
	restored
done
for wal_kind in sync attempted; do
	reset; prepare; printf '%s\n' "$wal_kind" >"$tmp/wal-fault"
	bad "$TX" apply "$token"
	phase_is rolled_back
	[ ! -f "$tmp/commits" ]
	restored
done
reset; touch "$tmp/link-enabled"; prepare; printf wal-link >"$tmp/window-change"
bad "$TX" apply "$token"
phase_is rolled_back
[ ! -f "$tmp/commits" ]
[ ! -f "$tmp/link-log" ]
[ "$(cat "$tmp/root/sys/class/net/eth9/flags")" = 0x0 ]

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

# Rebuilt topology plans may omit an adopted zone; the original prepared rows remain binding.
for zone_edit in changed removed; do
	reset; touch "$tmp/extra-zone"; prepare; "$TX" apply "$token" >/dev/null
	if [ "$zone_edit" = changed ]; then printf DROP >"$tmp/db/firewall.rp_init_policy.output"
	else rm "$tmp/db/firewall.rp_init_policy.output"; fi
	bad env SSH_CONNECTION='198.51.100.9 1234 192.0.2.2 22' "$TX" confirm "$token"
	phase_is pending
	"$TX" status | grep -Fq 'prepared candidate differs: firewall.rp_init_policy.output'
done

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
printf '1120.00 0.00\n' >"$tmp/root/proc/uptime"
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
guard_race_tests
confirm_boot_tests
monotonic_clock_tests
policy_runtime_tests
dhcp_readiness_tests

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
