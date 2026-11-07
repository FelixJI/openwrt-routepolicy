#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
REAL_LIB="${TEST_INIT_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-dns.XXXXXX")
cleanup() {
	[ -z "${guard_pid:-}" ] || kill "$guard_pid" 2>/dev/null || true
	if [ "${TEST_KEEP_INIT_DNS:-0}" = 1 ]; then printf 'init DNS evidence: %s\n' "$tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT HUP INT TERM
export TEST_DNS_TMP=$tmp ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_OUTPUT=json
export TEST_DNS_REAL_APPLY="$REAL_LIB/apply"
export TEST_DNS_REAL_INIT="$ROOT/routepolicy/files/etc/init.d/routepolicy"
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/root/etc/config" "$tmp/root/etc/init.d" "$tmp/root/usr/sbin"
cp "$REAL_LIB/common" "$REAL_LIB/init-dns" "$REAL_LIB/init-transaction" "$tmp/lib/"
cp -R "$REAL_LIB/converters" "$tmp/lib/"
chmod +x "$tmp/lib/"*
cp "$ROOT/tests/core/stubs/smartdns-forward.sh" "$tmp/native-forward"
# The parser must preserve anonymous roots, list ordering, spaces and quotes.
. "$tmp/lib/common"
. "$tmp/lib/init-dns"
printf "config smartdns\n\tlist conf_files '/etc/one'\n\tlist conf_files 'two words'\n" >"$tmp/list.uci"
[ "$(rp_uci_field_data '@smartdns[0]' conf_files <"$tmp/list.uci")" = "$(printf 'list\t/etc/one|two words')" ]
printf "config smartdns 'root'\n\toption label 'can'\\\\''t'\n" >"$tmp/quote.uci"
[ "$(rp_uci_field_data root label <"$tmp/quote.uci")" = "$(printf "scalar\tcan't")" ]
printf "config smartdns\n\tlist conf_files 'ambiguous|value'\n" >"$tmp/bad.uci"
if rp_uci_field_data '@smartdns[0]' conf_files <"$tmp/bad.uci"; then exit 1; fi

# Refuse only native cache/cron side effects; do not edit either user resource.
get() { awk -F '\t' -v key="$1" '$1==key{value=$2;found=1}END{if(found)print value}' "$tmp/native-options"; }
fail() { rp_err "$*"; exit 1; }
native_reject() {
	if (init_dns_native_side_effects main "$1") >"$tmp/native-rejected" 2>&1; then exit 1; fi
	grep -Fq "$2" "$tmp/native-rejected"
}
: >"$tmp/native-options"
init_dns_native_side_effects main 1
mkdir -p "$tmp/root/etc/smartdns" "$tmp/root/etc/crontabs"
printf USER-CACHE >"$tmp/root/etc/smartdns/smartdns.cache"
native_reject 1 '原生回滚启动会删除'
init_dns_native_side_effects main 0
printf 'smartdns.main.cache_file\t/etc/smartdns/custom.cache\n' >"$tmp/native-options"
printf CUSTOM-CACHE >"$tmp/root/etc/smartdns/custom.cache"
for value in 0 off false no disabled invalid; do
	printf 'smartdns.main.cache_persist\t%s\n' "$value" >>"$tmp/native-options"
	native_reject 1 '原生回滚启动会删除'
done
for value in 1 on true yes enabled; do
	printf 'smartdns.main.cache_persist\t%s\n' "$value" >"$tmp/native-options"
	init_dns_native_side_effects main 1
	printf 'smartdns.main.enable_auto_update\t%s\n' "$value" >>"$tmp/native-options"
	native_reject 0 'enable_auto_update 已开启'
done
: >"$tmp/native-options"
for line in '0 5 * * * /etc/init.d/smartdns updatefiles' '# old /etc/initXd/smartdns updatefiles --unused'; do
	printf '%s\n' "$line" >"$tmp/root/etc/crontabs/root"
	cp "$tmp/root/etc/crontabs/root" "$tmp/cron-before"
	native_reject 0 '原生 SmartDNS 自动更新匹配项'
	cmp "$tmp/cron-before" "$tmp/root/etc/crontabs/root"
done
printf '0 5 * * * /usr/bin/other-update\n# smartdns updatefiles\n' >"$tmp/root/etc/crontabs/root"
cp "$tmp/root/etc/crontabs/root" "$tmp/cron-before"
init_dns_native_side_effects main 0
cmp "$tmp/cron-before" "$tmp/root/etc/crontabs/root"
[ "$(cat "$tmp/root/etc/smartdns/smartdns.cache")" = USER-CACHE ]
[ "$(cat "$tmp/root/etc/smartdns/custom.cache")" = CUSTOM-CACHE ]
rm -f "$tmp/root/etc/smartdns/smartdns.cache" "$tmp/root/etc/smartdns/custom.cache" "$tmp/root/etc/crontabs/root"
printf '%s\n' 'init DNS native cache/cron preflight: passed'
if [ "${1:-}" = --native-side-effects ]; then exit 0; fi

if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
	cat >"$tmp/bin/native-uci" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/sbin/uci" "$@"
EOF
	cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/usr/bin/jsonfilter" "$@"
EOF
elif command -v uci >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
	ln -s "$(command -v uci)" "$tmp/bin/native-uci"
else
	printf '%s\n' 'init DNS parser: passed; native WAL/service matrix skipped (provide TEST_UCI_SDK_ROOT)'
	exit 0
fi
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
native-uci -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_DNS_TMP/external" "$@" || exit $?
case " $* " in *' commit '*)
	if [ -f "$TEST_DNS_TMP/kill-stage" ] && [ "$(cat "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/stage")" = "$(cat "$TEST_DNS_TMP/kill-stage")" ]; then
		rm "$TEST_DNS_TMP/kill-stage"; kill -KILL "$PPID"
	fi ;;
esac
case "$(cat "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/stage" 2>/dev/null)" in
	commit:*)
		if [ "$(cat "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/phase")" = applying ] && [ ! -f "$TEST_DNS_TMP/svc/smartdns.absent" ]; then
			printf 'native SmartDNS writer still registered during candidate commit\n' >&2; exit 1
		fi ;;
esac
EOF
cat >"$tmp/bin/sync" <<'EOF'
#!/bin/sh
wal="$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current"
if [ -f "$TEST_DNS_TMP/kill-confirm" ] && [ "$(cat "$wal/phase" 2>/dev/null)" = confirming ]; then
	point=$(cat "$TEST_DNS_TMP/kill-confirm")
	if [ "$point" = intent ] || { [ "$point" = pointer ] && [ "$(cat "${wal%/current}/active" 2>/dev/null)" = "$(cat "$wal/token")" ]; }; then
		rm "$TEST_DNS_TMP/kill-confirm"; kill -KILL "$PPID"
	fi
fi
if [ -f "$TEST_DNS_TMP/kill-exit-identity" ]; then
	for stage in "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/"exit-preparing.*; do
		if [ "$(cat "$stage/token" 2>/dev/null)" = "${TEST_EXIT_TOKEN:-}" ] && [ "$(cat "$stage/kind" 2>/dev/null)" = exit ]; then
			rm "$TEST_DNS_TMP/kill-exit-identity"; kill -KILL "$PPID"
		fi
	done
fi
if [ -f "$TEST_DNS_TMP/kill-installed" ] && [ "$(cat "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/declarations/phase" 2>/dev/null)" = installed ]; then
	rm "$TEST_DNS_TMP/kill-installed"; kill -KILL "$PPID"
fi
exit 0
EOF
# Keep the real planner ownership decision at the transaction/service fixture seam.
sed -n '/^own_section() {/,/^}/p' "$REAL_LIB/init-topology" >"$tmp/ownership"
cat >"$tmp/lib/init-topology" <<'EOF'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
. "$ROUTEPOLICY_LIBEXEC/init-dns"
get() { uci -q get "$1" 2>/dev/null || true; }
sections() { uci -q show "$1" | sed -n "s/^$1\.\([^.=]*\)=$2$/\1/p"; }
field() { printf '%s\n' "$1" | jsonfilter -e "$2"; }
ident() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; }
fail() { rp_err "$*"; exit 1; }
set_value() { printf 'set\t%s\t%s\n' "$1" "$2"; }
. "$TEST_DNS_TMP/ownership"
operation=$1
access=lan default_if=wan policy=wan2 access_device=br-lan default_device=eth1 policy_device=eth2
[ ! -f "$TEST_DNS_TMP/source-new-policy" ] || policy=rp_init_policy
dns_default=${13:--} dns_policy=${14:--}
case "$1" in
	plan)
		own_section firewall.rp_init_dns
		set_value firewall.rp_init_dns rule
		set_value firewall.rp_init_dns.name routepolicy-init-dns
		set_value firewall.rp_init_dns.src lan
		set_value firewall.rp_init_dns.target ACCEPT
		set_value firewall.rp_init_dns.dest_port 53
		set_value routepolicy.main.enabled 1
		set_value routepolicy.main.policy_interface "$policy"
		if [ -f "$TEST_DNS_TMP/source-new-policy" ]; then
			set_value network.rp_init_policy interface
			set_value network.rp_init_policy.proto static
			set_value network.rp_init_policy.device eth2
			set_value network.rp_init_policy.ipaddr 198.51.100.2
			set_value network.rp_init_policy.netmask 255.255.255.0
			set_value network.rp_init_policy.gateway 198.51.100.1
		fi
		init_ipv4_plan
		init_dns_plan ;;
	link-plan) printf 'required\t0\n' ;;
	management-address) [ ! -f "$TEST_DNS_TMP/policy-down" ] || exit 1; uci -q get network.lan.ipaddr ;;
	verify) own_section firewall.rp_init_dns ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
case "$2:${3:-}" in
	service:list)
		service=$(printf '%s' "${4:-}" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
		[ "$service" != routepolicy-initguard ] || { printf '{"routepolicy-initguard":{"instances":{"guard":{"running":true}}}}'; exit 0; }
		[ -n "$service" ] || exit 1
		[ ! -f "$TEST_DNS_TMP/list-fail" ] || exit 1
		if [ "$service" = smartdns ] && [ -f "$TEST_DNS_TMP/svc/smartdns.absent" ]; then printf '{}\n'; exit 0; fi
		running=false; [ "$(cat "$TEST_DNS_TMP/svc/$service.running")" != 1 ] || running=true
		printf '{"%s":{"instances":{"main":{"running":%s}}}}\n' "$service" "$running" ;;
	service:delete)
		case "${4:-}" in *routepolicy-initguard*) exit 0 ;; esac
		[ ! -f "$TEST_DNS_TMP/delete-fail" ] || exit 1
		[ ! -f "$TEST_DNS_TMP/svc/smartdns.absent" ] || exit 4
		printf 0 >"$TEST_DNS_TMP/svc/smartdns.running"
		: >"$TEST_DNS_TMP/svc/smartdns.absent"
		if [ -f "$TEST_DNS_TMP/delete-race" ]; then rm "$TEST_DNS_TMP/delete-race"; exit 4; fi
		if [ -f "$TEST_DNS_TMP/quiesce-fault" ]; then
			wal="$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current"
			rm "$TEST_DNS_TMP/quiesce-fault" "$wal/dns-file-new"; mkdir "$wal/dns-file-new"
		fi ;;
	network.interface.rp_init_policy:status)
		[ "$(uci -q get network.rp_init_policy.proto 2>/dev/null)" = static ] || { printf '{"up":false}\n'; exit 0; }
		printf '{"up":true,"l3_device":"eth2","dns-server":["198.51.100.53"],"route":[{"target":"0.0.0.0","nexthop":"198.51.100.1"}]}\n' ;;
	network.interface.wan:status|network.interface.wan2:status)
		if [ "$2" = network.interface.wan2 ] && [ -f "$TEST_DNS_TMP/policy-down" ]; then printf '{"up":false}\n'; exit 0; fi
		device=eth1; [ "$2" != network.interface.wan2 ] || device=eth2
		printf '{"up":true,"l3_device":"%s","dns-server":["192.0.2.53"],"route":[{"target":"0.0.0.0","nexthop":"198.51.100.1"}]}\n' "$device" ;;
	network.interface.lan:status)
		printf '{"up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.0.2.1","mask":24}]}\n' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/netstat" <<'EOF'
#!/bin/sh
[ ! -f "$TEST_DNS_TMP/netstat-fail" ] || exit 1
for service in smartdns dnsmasq; do
	[ "$(cat "$TEST_DNS_TMP/svc/$service.running")" = 1 ] || continue
	port=$(cat "$TEST_DNS_TMP/svc/$service.port")
	[ "$port" != 0 ] || continue
	printf 'tcp 0 0 0.0.0.0:%s 0.0.0.0:* LISTEN 101/%s\nudp 0 0 0.0.0.0:%s 0.0.0.0:* 101/%s\n' "$port" "$service" "$port" "$service"
	if [ "$service" = dnsmasq ] && [ "${TEST_DNS_IPV6:-0}" = 1 ]; then
		printf 'tcp6 0 0 :::%s :::* LISTEN 101/dnsmasq\nudp6 0 0 :::%s :::* 101/dnsmasq\n' "$port" "$port"
	fi
done
EOF
cat >"$tmp/bin/dig" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DNS_TMP/queries"
port=53; previous=
for argument do [ "$previous" != -p ] || port=$argument; previous=$argument; done
found=0
for service in smartdns dnsmasq; do
	[ "$(cat "$TEST_DNS_TMP/svc/$service.running")" != 1 ] || [ "$(cat "$TEST_DNS_TMP/svc/$service.port")" != "$port" ] || found=1
done
[ "$found" = 1 ] || exit 9
case "$*" in *routepolicy-init-resolver.test*)
	grep -Fxq 'address /routepolicy-init-resolver.test/127.0.0.1' "$ROUTEPOLICY_ROOT/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf" || exit 12
	case "$*" in *@127.0.0.1*) ;; *) [ "$(readlink "$ROUTEPOLICY_ROOT/tmp/resolv.conf")" = /tmp/resolv.conf.d/routepolicy.conf ] || exit 10 ;; esac
	[ "$(cat "$TEST_DNS_TMP/svc/smartdns.running")$(cat "$TEST_DNS_TMP/svc/smartdns.port")" = 153 ] || exit 11
	printf '127.0.0.1\n'; exit 0 ;;
esac
if [ -f "$TEST_DNS_TMP/query-fail" ] && [ "$*" != "${*%routepolicy-init-restore.test*}" ]; then printf ';; ->>HEADER<<- status: NOERROR, id: 1\n'
elif [ -f "$TEST_DNS_TMP/query-fail" ]; then printf ';; ->>HEADER<<- status: SERVFAIL, id: 1\n'
else printf ';; ->>HEADER<<- status: NOERROR, id: 1\n'; fi
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1:${2:-}" = list:tables ]; then [ ! -f "$TEST_DNS_TMP/policy-running" ] || printf 'table inet routepolicy\n'; exit 0; fi
[ -f "$TEST_DNS_TMP/policy-running" ]
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
printf 'default via 198.51.100.1 dev eth2 metric 10\n'
EOF
cat >"$tmp/bin/fw4" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/lib/apply" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in event|reconcile-event) exec "$TEST_DNS_REAL_APPLY" "$@" ;; esac
LIBEXEC=$ROUTEPOLICY_LIBEXEC
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter apply
rp_local_lock "$RP_RUN_DIR/apply.lock" || exit 1
trap 'rp_local_unlock "$RP_RUN_DIR/apply.lock"' EXIT
if [ -f "$TEST_DNS_TMP/kill-policy" ]; then rm "$TEST_DNS_TMP/kill-policy"; kill -KILL "$$"; fi
[ ! -f "$TEST_DNS_TMP/policy-fail" ] || exit 1
if [ -f "$TEST_DNS_TMP/policy-fail-once" ] && [ "${ROUTEPOLICY_SOURCE_BOOTSTRAP:-0}" != 1 ]; then rm "$TEST_DNS_TMP/policy-fail-once"; exit 1; fi
if [ "${1:-}" = teardown ]; then
	[ "${ROUTEPOLICY_INIT_RESTORE:-0}" = 1 ] || [ "$(uci -q get routepolicy.main.enabled)" = 0 ]
	rm -f "$TEST_DNS_TMP/policy-running" "$RP_STATE_DIR/applied"
	rm -rf "$RP_ACTIVE_DIR"
	exit 0
fi
mkdir -p "$RP_ACTIVE_DIR"
: >"$RP_ACTIVE_DIR/domain-default.list"; : >"$RP_ACTIVE_DIR/domain-policy.list"
printf '%s\n' "${ROUTEPOLICY_INIT_GENERATION:-boot}" >"$RP_ACTIVE_DIR/generation"
rp_render_smartdns90 "$RP_SMARTDNS_FILE"
[ "${ROUTEPOLICY_DNS_DEFER:-0}" = 1 ] || rp_smartdns_set_registration "$RP_SMARTDNS_FILE" 1
printf 'policy_interface=%s\npolicy_device=eth2\nroute_table=200\n' "$(uci -q get routepolicy.main.policy_interface)" >"$RP_STATE_DIR/applied"
: >"$TEST_DNS_TMP/policy-running"
[ "${ROUTEPOLICY_DNS_DEFER:-0}" = 1 ] || rp_native_service smartdns reload
if [ "${ROUTEPOLICY_SOURCE_BOOTSTRAP:-0}" = 1 ] && [ -f "$TEST_DNS_TMP/source-bootstrap-clock" ]; then
	cat "$TEST_DNS_TMP/source-bootstrap-clock" >"$ROUTEPOLICY_ROOT/proc/uptime"; rm "$TEST_DNS_TMP/source-bootstrap-clock"
fi
EOF
# FelixJI/smartdns c27671b set_main_dns; relocate its service path and tolerate absent
# options under this fixture set -e (the native script runs without errexit).
cat >"$tmp/native-main" <<'EOF'
set_main_dns()
{
	local hostip
	hostip="$(uci -q get network.lan.ipaddr)"
	dnsmasq_port="$(uci -q get dhcp.@dnsmasq[0].port || true)"
	[ -z "$dnsmasq_port" ] && dnsmasq_port="53"
	[ -z "$hostip" ] && return
	[ "$dnsmasq_port" = "53" ] && {
		uci -q set dhcp.@dnsmasq[0].port=0
		uci -q add_list dhcp.lan.dhcp_option="6,$hostip"
	}
	redir_dns="$(uci -q get dhcp.@dnsmasq[0].dns_redirect || true)"
	[ "$redir_dns" = "1" ] && {
		uci -q set dhcp.@dnsmasq[0].dns_redirect=0
		uci -q set dhcp.@dnsmasq[0].old_dns_redirect=1
	}
	uci commit dhcp
	"$ROUTEPOLICY_ROOT/etc/init.d/dnsmasq" reload
}
EOF
cat >"$tmp/root/etc/init.d/smartdns" <<'EOF'
#!/bin/sh
set -eu
service=smartdns
printf '%s %s\n' "$service" "$1" >>"$TEST_DNS_TMP/service-log"
case "$1" in
	enabled) [ "$(cat "$TEST_DNS_TMP/svc/$service.enabled")" = 1 ]; exit ;;
	enable) printf 1 >"$TEST_DNS_TMP/svc/$service.enabled"; exit ;;
	disable) printf 0 >"$TEST_DNS_TMP/svc/$service.enabled"; exit ;;
	stop) printf 0 >"$TEST_DNS_TMP/svc/$service.running"; exit ;;
	start|reload|restart) ;;
	*) exit 1 ;;
esac
if [ "$1" = restart ]; then
	. "$TEST_DNS_TMP/native-forward"
	config_get() { value=$(uci -q get "smartdns.$2.$3" || printf '%s' "${4:-}"); export "$1=$value"; }
	config_get_bool() { config_get "$@"; }
	DO_RELOAD=0; set +e; unload_service '@smartdns[0]'; set -e
fi
: >"$TEST_DNS_TMP/native-start-called"
rm -f "$TEST_DNS_TMP/svc/smartdns.absent"
enabled=$(uci -q get 'smartdns.@smartdns[0].enabled' || printf 0)
printf '%s' "$enabled" >"$TEST_DNS_TMP/svc/$service.running"
[ "$enabled" = 1 ] || exit 0
port=$(uci -q get 'smartdns.@smartdns[0].port' || printf 53)
port=${port:-53}
printf '%s' "$port" >"$TEST_DNS_TMP/svc/smartdns.port"
if [ "$port" = 53 ]; then
	. "$TEST_DNS_TMP/native-main"
	set_main_dns
fi
auto=$(uci -q get 'smartdns.@smartdns[0].auto_set_dnsmasq' || printf 1)
auto=${auto:-1}
if [ "$port" != 53 ] && [ "$auto" = 1 ]; then
	. "$TEST_DNS_TMP/native-forward"
	set +e; set_forward_dnsmasq "$port"; set -e
fi
uci set "smartdns.@smartdns[0].old_enabled=$enabled"
uci set "smartdns.@smartdns[0].old_port=$port"
uci set "smartdns.@smartdns[0].old_auto_set_dnsmasq=$auto"
uci commit smartdns
if [ "$port" = 53 ] && [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.running")" = 1 ] && [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.port")" = 53 ]; then exit 1; fi
cache=$(uci -q get 'smartdns.@smartdns[0].cache_file' || true)
if [ "$cache" = /tmp/routepolicy/smartdns.cache ]; then
	mkdir -p "$ROUTEPOLICY_ROOT/tmp/routepolicy"
	[ -e "$ROUTEPOLICY_ROOT$cache" ] || printf FRESH >"$ROUTEPOLICY_ROOT$cache"
fi
mkdir -p "$ROUTEPOLICY_ROOT/var/etc/smartdns"
{
	printf 'bind :%s@br-lan -group rp_init_default\nbind :%s@lo -group rp_init_default\n' "$port" "$port"
	printf 'bind-tcp :%s@br-lan -group rp_init_default\nbind-tcp :%s@lo -group rp_init_default\n' "$port" "$port"
	printf 'server 192.0.2.53:53 -group rp_init_default -exclude-default-group -interface eth1\nserver 198.51.100.53:53 -group rp_init_policy -exclude-default-group -interface eth2\n'
	case " $(uci -q get 'smartdns.@smartdns[0].conf_files') " in *' /etc/smartdns/conf.d/90-routepolicy.conf '*) printf "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'\n" ;; esac
	printf "conf-file '/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf'\n"
} >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
if [ -f "$TEST_DNS_TMP/source-dns-clock" ]; then
	cat "$TEST_DNS_TMP/source-dns-clock" >"$ROUTEPOLICY_ROOT/proc/uptime"; rm "$TEST_DNS_TMP/source-dns-clock"
fi
EOF
cat >"$tmp/root/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
set -eu
printf 'dnsmasq %s\n' "$1" >>"$TEST_DNS_TMP/service-log"
case "$1" in
	enabled) [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.enabled")" = 1 ] ;;
	enable) printf 1 >"$TEST_DNS_TMP/svc/dnsmasq.enabled" ;;
	disable) printf 0 >"$TEST_DNS_TMP/svc/dnsmasq.enabled" ;;
	stop) printf 0 >"$TEST_DNS_TMP/svc/dnsmasq.running" ;;
	start|restart|reload)
		# Native per-instance early return; rc disabled does not block reload_service.
		case "$(uci -q get 'dhcp.@dnsmasq[0].disabled' || true)" in
			1|on|true|yes|enabled) printf 0 >"$TEST_DNS_TMP/svc/dnsmasq.running"; exit 0 ;;
		esac
		printf 1 >"$TEST_DNS_TMP/svc/dnsmasq.running"
		[ ! -f "$TEST_DNS_TMP/stale-dnsmasq" ] || exit 0
		uci -q get 'dhcp.@dnsmasq[0].port' >"$TEST_DNS_TMP/svc/dnsmasq.port" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/root/etc/init.d/routepolicy" <<'EOF'
#!/bin/sh
set -eu
printf 'routepolicy %s\n' "$*" >>"$TEST_DNS_TMP/service-log"
case "$1" in
	enabled) [ "$(cat "$TEST_DNS_TMP/svc/routepolicy.enabled")" = 1 ]; exit ;;
	enable) printf 1 >"$TEST_DNS_TMP/svc/routepolicy.enabled"; exit ;;
	disable) printf 0 >"$TEST_DNS_TMP/svc/routepolicy.enabled"; exit ;;
	start) shift ;;
	*) exit 1 ;;
esac
[ ! -f "$TEST_DNS_TMP/watch-fail" ] || exit 1
ROUTEPOLICY_INIT_TRANSACTION="$ROUTEPOLICY_LIBEXEC/init-transaction"
. "$TEST_DNS_REAL_INIT"
config_load() { :; }
config_get_bool() { enabled=$(uci -q get routepolicy.main.enabled); }
procd_open_instance() { :; }
procd_set_param() { printf '%s\n' "$*" >>"$TEST_DNS_TMP/watch-registration"; }
procd_close_instance() { printf 1 >"$TEST_DNS_TMP/svc/routepolicy.running"; }
start_service "$@"
EOF
for service in network firewall odhcpd routepolicy-initguard routepolicy-prerecover; do printf '#!/bin/sh\nexit 0\n' >"$tmp/root/etc/init.d/$service"; done
cat >"$tmp/root/etc/init.d/network" <<'EOF'
#!/bin/sh
if [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.running")" = 1 ]; then uci -q get 'dhcp.@dnsmasq[0].port' >"$TEST_DNS_TMP/svc/dnsmasq.port"; fi
EOF
cp "$tmp/root/etc/init.d/network" "$tmp/root/usr/sbin/smartdns"
chmod +x "$tmp/bin/"* "$tmp/lib/"* "$tmp/root/etc/init.d/"* "$tmp/root/usr/sbin/smartdns"
export PATH="$tmp/bin:$PATH"
TX="$tmp/lib/init-transaction"
canonical() {
	exported=$(native-uci -c "$tmp/root/etc/config" export "$1") || return 1
	printf '%s\n' "$exported" | awk '
		$1=="config"{section=$0;print "section " section;next}
		NF{key=section " " $1 " " $2;print key " " ($1=="list"?++sequence[key]:0) " " $0}' >"$tmp/canonical" || return 1
	LC_ALL=C sort "$tmp/canonical"
}
baseline() {
	rm -rf "$tmp/root/etc/routepolicy" "$tmp/root/tmp/routepolicy" "$tmp/root/etc/smartdns" "$tmp/root/var" "$tmp/svc" "$tmp/external"
	rm -f "$tmp/policy-running" "$tmp/query-fail" "$tmp/policy-fail" "$tmp/kill-stage" "$tmp/queries" "$tmp/service-log" "$tmp/list-fail" "$tmp/delete-fail" "$tmp/delete-race" "$tmp/quiesce-fault" "$tmp/native-start-called" "$tmp/stale-dnsmasq" "$tmp/kill-confirm" "$tmp/kill-policy" "$tmp/watch-fail" "$tmp/watch-registration"
	mkdir -p "$tmp/svc" "$tmp/external" "$tmp/root/etc/smartdns/conf.d" "$tmp/root/proc/sys/kernel/random"
	mkdir -p "$tmp/root/tmp/resolv.conf.d"
	rm -f "$tmp/root/etc/resolv.conf" "$tmp/root/tmp/resolv.conf" "$tmp/root/tmp/resolv.conf.d/routepolicy.conf"
	ln -s /tmp/resolv.conf "$tmp/root/etc/resolv.conf"
	ln -s /tmp/resolv.conf.d/resolv.conf.auto "$tmp/root/tmp/resolv.conf"
	printf 'nameserver 192.0.2.53\n' >"$tmp/root/tmp/resolv.conf.d/resolv.conf.auto"
	printf '100.00 0.00\n' >"$tmp/root/proc/uptime"
	printf '00000000-0000-4000-8000-000000000001\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
	printf "config interface 'lan'\n\toption proto 'static'\n\toption ipaddr '192.0.2.1'\n\tlist ip6addr '2001:db8::1/64'\nconfig interface 'wan'\n\toption proto 'dhcp'\nconfig interface 'wan2'\n\toption proto 'dhcp'\n" >"$tmp/root/etc/config/network"
	printf "config dnsmasq\n\toption port '53'\n\tlist server '192.0.2.99'\n\tlist server '/local/192.0.2.98'\n\toption unknown 'keep'\nconfig dhcp 'lan'\n\toption interface 'lan'\n" >"$tmp/root/etc/config/dhcp"
	printf "config smartdns\n\toption enabled '1'\n\toption port '6053'\n\toption cache_persist '1'\n\toption cache_file '/etc/smartdns/user.cache'\n\toption auto_set_dnsmasq '0'\n\toption old_port '6053'\n\toption old_enabled '1'\n\toption old_auto_set_dnsmasq '0'\n\tlist conf_files '/etc/smartdns/custom-a.conf'\n\tlist conf_files '/etc/smartdns/custom-b.conf'\n\toption unknown 'keep'\nconfig server 'user'\n\toption ip '192.0.2.88'\n" >"$tmp/root/etc/config/smartdns"
	printf "config main 'main'\n\toption enabled '0'\n\toption lan_interface 'lan'\n\toption default_interface 'wan'\n\toption policy_interface 'wan2'\n\toption route_table '200'\n" >"$tmp/root/etc/config/routepolicy"
	printf '# untouched\n' >"$tmp/root/etc/config/firewall"
	printf USER-CACHE >"$tmp/root/etc/smartdns/user.cache"
	for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
	printf 0 >"$tmp/svc/routepolicy.enabled"; printf 0 >"$tmp/svc/routepolicy.running"
	printf '%s' "$1" >"$tmp/svc/smartdns.enabled"; printf '%s' "$2" >"$tmp/svc/smartdns.running"
	printf '%s' "$3" >"$tmp/svc/dnsmasq.enabled"; printf '%s' "$4" >"$tmp/svc/dnsmasq.running"
	printf 6053 >"$tmp/svc/smartdns.port"; printf 53 >"$tmp/svc/dnsmasq.port"
}
prepare() {
	output=$("$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53)
	token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" = 32 ]
}
restored() {
	for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.after"; cmp "$tmp/$package.before" "$tmp/$package.after" || { diff -u "$tmp/$package.before" "$tmp/$package.after"; return 1; }; done
	[ ! -e "$tmp/root/etc/smartdns/conf.d/90-routepolicy.conf" ]
	[ ! -e "$tmp/root/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf" ]
	[ ! -e "$tmp/policy-running" ]
	[ "$(cat "$tmp/root/etc/smartdns/user.cache")" = USER-CACHE ]
	[ "$(cat "$tmp/svc/routepolicy.enabled")" = 0 ]
}
prepare_dns() {
	output=$("$TX" prepare lan wan wan2 - - - - - - - - "$1" 198.51.100.53)
	token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" = 32 ]
}
confirm_dns() {
	"$TX" apply "$token" >/dev/null
	if ! SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >"$tmp/confirm-result"; then cat "$tmp/confirm-result" >&2; return 1; fi
}
test_boot() {
	test_boot_sequence=$(( ${test_boot_sequence:-10} + 1 ))
	printf '00000000-0000-4000-8000-%012d\n' "$test_boot_sequence" >"$tmp/root/proc/sys/kernel/random/boot_id"
	rm -f "$RP_RESOLVER_ENTRY" "$RP_RESOLVER_FILE"
	ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
}
if [ "${1:-}" = --resolver-repair ]; then
	baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
	active=$(rp_init_active_record)
	rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
	if "$TX" repair >"$tmp/repair-auto-result" 2>&1; then printf 'confirmed repair overwrote external auto link\n' >&2; exit 1; fi
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ]
	[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")" = 11 ]
	"$TX" status >"$tmp/repair-status"; [ "$(jsonfilter -i "$tmp/repair-status" -e '@.active.dns_boot_state')" = resolver_conflict ]
	rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/routepolicy.conf "$RP_RESOLVER_ENTRY"
	"$TX" repair >/dev/null
	test_boot; printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
	"$TX" recover-early >/dev/null; "$TX" boot-dns >/dev/null
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/routepolicy.conf ]
	rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
	if "$TX" repair >/dev/null 2>&1; then printf 'post-reboot confirmed repair overwrote external auto link\n' >&2; exit 1; fi
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ]
	printf '%s\n' 'confirmed resolver repair: passed (external before preserved, manual restoration retries, genuine new boot rebuilds, ready-boot external rollback rejected)'
	exit 0
fi
if [ "${1:-}" = --resolver-probes ]; then
	for probe_case in legacy no-header complete duplicate-role conflict-role duplicate-address conflict-address; do
		baseline 0 0 1 1
		path="$RP_SMARTDNS_EXTRA_FILE"
		printf '# USER_KEEP unknown fragment\nprefetch-domain yes\n' >"$path"
		case "$probe_case" in no-header) rp_smartdns_init_probes | tail -n +2 >>"$path" ;; complete) rp_smartdns_init_probes >>"$path" ;; *) rp_smartdns_init_probes | head -n 3 >>"$path" ;; esac
		case "$probe_case" in
			duplicate-role) printf 'domain-rules /routepolicy-init-default.test/ -nameserver rp_init_default -speed-check-mode none\n' >>"$path" ;;
			conflict-role) printf 'domain-rules /routepolicy-init-policy.test/ -nameserver wrong\n' >>"$path" ;;
			duplicate-address) printf 'address /routepolicy-init-resolver.test/127.0.0.1\naddress /routepolicy-init-resolver.test/127.0.0.1\n' >>"$path" ;;
			conflict-address) printf 'address /routepolicy-init-resolver.test/192.0.2.99\n' >>"$path" ;;
		esac
		cp "$path" "$tmp/probe.before"
		case "$probe_case" in
			legacy|no-header|complete)
				prepare_dns 192.0.2.53
				new="$RP_STATE_DIR/init-transaction/current/dns-file-new"
				head -c "$(wc -c <"$tmp/probe.before")" "$new" >"$tmp/probe.prefix"; cmp "$tmp/probe.before" "$tmp/probe.prefix"
				for probe in default policy resolver; do expected=$(rp_smartdns_init_probes | grep -F "/routepolicy-init-$probe.test/"); [ "$(grep -Fxc "$expected" "$new")" = 1 ]; done
				confirm_dns ;;
			*) if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >/dev/null 2>&1; then printf 'duplicate/conflicting probe accepted: %s\n' "$probe_case" >&2; exit 1; fi
				cmp "$tmp/probe.before" "$path" ;;
		esac
	done
	printf '%s\n' 'resolver probe upgrade: passed (legacy/headerless/complete, unique role/address rules, unknown byte prefix preserved, duplicates/conflicts rejected before public write)'
	exit 0
fi
if [ "${1:-}" = --legacy-resolver ]; then
	[ -n "${TEST_LEGACY_INIT_LIBEXEC:-}" ] || { printf 'legacy resolver: skipped (provide frozen old libexec)\n'; exit 0; }
	baseline 0 0 1 1
	cp -R "$tmp/lib" "$tmp/legacy-lib"
	cp "$TEST_LEGACY_INIT_LIBEXEC/common" "$TEST_LEGACY_INIT_LIBEXEC/init-dns" "$TEST_LEGACY_INIT_LIBEXEC/init-transaction" "$tmp/legacy-lib/"
	chmod +x "$tmp/legacy-lib/init-transaction"
	output=$(ROUTEPOLICY_LIBEXEC="$tmp/legacy-lib" "$tmp/legacy-lib/init-transaction" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53)
	token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	ROUTEPOLICY_LIBEXEC="$tmp/legacy-lib" "$tmp/legacy-lib/init-transaction" apply "$token" >/dev/null
	SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' ROUTEPOLICY_LIBEXEC="$tmp/legacy-lib" "$tmp/legacy-lib/init-transaction" confirm "$token" >/dev/null
	test_boot; "$TX" recover-early >/dev/null
	active=$(rp_init_active_record)
	if "$TX" boot-dns >/dev/null 2>&1; then printf 'legacy resolver boot adopted without authority\n' >&2; exit 1; fi
	[ "$(cat "$active/failed-stage")" = boot-resolver-contract-missing ] && [ -f "$active/dns-boot-pending" ]
	for failure in boot-dns-start boot-dns-admission; do
		printf '%s\n' "$failure" >"$active/failed-stage"
		if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >/dev/null 2>&1; then printf 'unrelated boot failure bypassed prepare gate\n' >&2; exit 1; fi
	done
	printf 'boot-resolver-contract-missing\n' >"$active/failed-stage"
	uci set 'dhcp.@dnsmasq[0].port=53'; uci commit dhcp
	if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >/dev/null 2>&1; then printf 'legacy external conflict bypassed prepare gate\n' >&2; exit 1; fi
	uci set 'dhcp.@dnsmasq[0].port=0'; uci commit dhcp
	prepare_dns 192.0.2.53; : >"$tmp/query-fail"
	if "$TX" apply "$token" >/dev/null; then printf 'new initialization failure accepted\n' >&2; exit 1; fi
	[ -f "$active/dns-boot-pending" ] && [ ! -f "$active/dns-boot-ready" ]
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ] && [ ! -e "$RP_RESOLVER_FILE" ]
	rm "$tmp/query-fail"; prepare_dns 192.0.2.53; confirm_dns
	[ "$(rp_init_active_record)" != "$active" ]; (WAL=$(rp_init_active_record); export WAL; init_resolver_verify)
	printf '%s\n' 'legacy resolver reinitialization: passed (precise missing-contract gate; other failures/conflicts denied; failed apply retains old pending; new confirmed contract ready)'
	exit 0
fi
if [ "${1:-}" = --restore-prior-confirmed ] || [ "${1:-}" = --migrate ]; then
	cp "$REAL_LIB/lifecycle" "$REAL_LIB/validate" "$REAL_LIB/converter-lib" "$tmp/lib/"
	chmod +x "$tmp/lib/lifecycle" "$tmp/lib/validate" "$tmp/lib/converter-lib"
	baseline 0 0 1 1
	cp "$ROOT/routepolicy/files/etc/config/routepolicy" "$RP_UCI_CONFIG"
	uci set routepolicy.main.policy_interface=wan2; uci commit routepolicy
	if [ "${1:-}" = --migrate ]; then
		uci -q delete routepolicy.main.config_schema || true; uci commit routepolicy
		"$tmp/lib/lifecycle" migrate >/dev/null
		[ "$(uci get routepolicy.main.config_schema)" = 1 ]
	fi
	prepare_dns 192.0.2.53; confirm_dns
	if [ "${1:-}" = --migrate ]; then
		"$tmp/lib/lifecycle" migrate >/dev/null
		printf 'pending\n' >"$RP_STATE_DIR/init-transaction/current/phase"
		cp "$RP_UCI_CONFIG" "$tmp/migrate-pending.before"
		if "$tmp/lib/lifecycle" migrate >/dev/null 2>&1; then printf 'pending init migrated\n' >&2; exit 1; fi
		cmp "$tmp/migrate-pending.before" "$RP_UCI_CONFIG"; printf 'confirmed\n' >"$RP_STATE_DIR/init-transaction/current/phase"
		uci set routepolicy.main.config_schema=2; uci commit routepolicy
		if "$tmp/lib/lifecycle" migrate >/dev/null 2>&1; then printf 'future schema migrated\n' >&2; exit 1; fi
		uci set routepolicy.main.config_schema=1; uci commit routepolicy
		uci set network.lan.user_pending=keep
		if "$tmp/lib/lifecycle" migrate >/dev/null 2>&1; then printf 'pending configuration migrated\n' >&2; exit 1; fi
		[ "$(uci changes network)" != '' ]
		printf '%s\n' 'native migrate: passed (real nested archive, no/archive legacy paths, schema and pending rejection)'; exit 0
	fi
	# Restore now requires explicit policy disable; retain the confirmed DNS contract.
	uci set routepolicy.main.enabled=0; uci commit routepolicy
	ROUTEPOLICY_INIT_RESTORE=1 "$tmp/lib/apply" teardown
	mkdir -p "$RP_USER_DIR"; cp "$ROOT/routepolicy/files/etc/routepolicy/user.d/"*.list "$RP_USER_DIR/"
	ROUTEPOLICY_OUTPUT=text "$tmp/lib/lifecycle" config-export >"$tmp/prior-export"
	"$tmp/lib/lifecycle" config-import <"$tmp/prior-export" >/dev/null
	cp "$RP_UCI_CONFIG" "$tmp/prior-app.before"
	: >"$tmp/kill-installed"
	mapping=$(printf 'lan\twan\twan2\t-\t-\t-\t-\t-\t-\t-\t-\t192.0.2.53\t198.51.100.53\t1\t1\n')
	if printf '%s\n' "$mapping" | "$tmp/lib/lifecycle" restore-prepare >/dev/null 2>&1; then printf 'installed kill missing\n' >&2; exit 1; fi
	decl="$RP_STATE_DIR/init-transaction/declarations"
	[ ! -e "$decl/init-token" ] && [ "$(cat "$decl/phase")" = installed ]
	"$tmp/lib/lifecycle" restore-recover >/dev/null
	cmp "$tmp/prior-app.before" "$RP_UCI_CONFIG"; [ "$(cat "$decl/phase")" = rolled_back ]
	(WAL=$(rp_init_active_record); export WAL; init_resolver_verify)
	printf '%s\n' 'prior confirmed declaration recovery: passed (real installed sync kill, no new token, original declarations and resolver preserved)'
	exit 0
fi
if [ "${1:-}" = --restore-empty ] || [ "${1:-}" = --restore-confirmed ]; then
	cp "$REAL_LIB/lifecycle" "$REAL_LIB/validate" "$REAL_LIB/converter-lib" "$tmp/lib/"
	chmod +x "$tmp/lib/lifecycle" "$tmp/lib/validate" "$tmp/lib/converter-lib"
	for restore_case in success failure; do
		baseline 0 0 1 1
		cp "$ROOT/routepolicy/files/etc/config/routepolicy" "$tmp/root/etc/config/routepolicy"
		uci set routepolicy.main.policy_interface=wan2; uci commit routepolicy
		mkdir -p "$RP_USER_DIR" "$RP_MANAGED_CURRENT" "$RP_MANAGED_PREVIOUS"
		cp "$ROOT/routepolicy/files/etc/routepolicy/user.d/"*.list "$RP_USER_DIR/"
		printf 'stale.example\n' >"$RP_MANAGED_CURRENT/old.domain-policy.list"
		printf 'unknown\n' >"$RP_MANAGED_CURRENT/user.keep"
		printf 'previous\n' >"$RP_MANAGED_PREVIOUS/old.keep"
		cp -pR "$tmp/root/etc/routepolicy/managed.d" "$tmp/restore-before-$restore_case"
		ROUTEPOLICY_OUTPUT=text "$tmp/lib/lifecycle" config-export >"$tmp/restore-export"
		"$tmp/lib/lifecycle" config-import <"$tmp/restore-export" >/dev/null
		mapping=$(printf 'lan\twan\twan2\t-\t-\t-\t-\t-\t-\t-\t-\t192.0.2.53\t198.51.100.53\t1\t1\n')
		output=$(printf '%s\n' "$mapping" | "$tmp/lib/lifecycle" restore-prepare)
		token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		decl="$tmp/root/etc/routepolicy/state/init-transaction/declarations"
		if [ "${1:-}" = --restore-confirmed ]; then
			confirm_dns
			# Durable network commit exists; declaration phase publication was interrupted.
			printf 'installed\n' >"$decl/phase"
			cp "$RP_UCI_CONFIG" "$tmp/confirmed-app"
			"$tmp/lib/lifecycle" restore-recover >"$tmp/confirmed-recover"
			cmp "$RP_UCI_CONFIG" "$tmp/confirmed-app"
			[ "$(cat "$decl/phase")" = committed ]
			printf 'installed\n' >"$decl/phase"; printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$decl/init-token"
			if "$tmp/lib/lifecycle" restore-recover >/dev/null 2>&1; then printf 'mismatched confirmed token recovered declarations\n' >&2; exit 1; fi
			cmp "$RP_UCI_CONFIG" "$tmp/confirmed-app"
			printf '%s\n' 'confirmed declaration recovery: passed (commit gap converged; mismatched token preserves declarations)'
			exit 0
		fi
		if [ "$restore_case" = failure ]; then
			: >"$tmp/query-fail"
			if "$TX" apply "$token" >"$tmp/restore-failure"; then printf 'restore DNS failure accepted\n' >&2; exit 1; fi
			diff -r "$tmp/restore-before-$restore_case" "$tmp/root/etc/routepolicy/managed.d"
			"$tmp/lib/lifecycle" restore-recover >/dev/null
		else
			confirm_dns
			[ -z "$(find "$RP_MANAGED_CURRENT" -mindepth 1)" ] || { printf 'source-free restore retained old snapshots\n' >&2; exit 1; }
			rp_merge_lists domain-policy "$tmp/restored-merged"
			[ ! -s "$tmp/restored-merged" ]
		fi
	done
	printf '%s\n' 'source-free restore: passed (empty published snapshot; failure restores current/previous and unknown files)'
	exit 0
fi
if [ "${1:-}" = --exit-archive ]; then
	for archive_case in sameboot reboot conflict; do
		baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
		txroot="$RP_STATE_DIR/init-transaction"
		rm -rf "$txroot/current"
		if [ "$archive_case" = reboot ]; then test_boot; "$TX" recover-early >/dev/null; "$TX" boot-dns >/dev/null; fi
		origin="$txroot/confirmed/$(cat "$txroot/active")/origin"
		cp -R "$origin" "$tmp/origin-$archive_case"
		"$TX" exit-preview >"$tmp/archive-preview"; [ ! -e "$txroot/current" ]
		output=$("$TX" exit-prepare); [ ! -e "$txroot/current" ]
		exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		if [ "$archive_case" = conflict ]; then
			uci set smartdns.rp_init_default_1.user_note=KEEP; uci commit smartdns
			cp "$RP_SMARTDNS_UCI" "$tmp/archive-conflict.before"
			if "$TX" exit-apply "$exit_token" >"$tmp/archive-conflict" 2>&1; then printf 'archive exit overwrote unknown child\n' >&2; exit 1; fi
			cmp "$RP_SMARTDNS_UCI" "$tmp/archive-conflict.before"
			[ ! -e "$txroot/current" ] && [ -f "$txroot/active" ]
			diff -r "$origin" "$tmp/origin-$archive_case"
			continue
		fi
		"$TX" exit-apply "$exit_token" >"$tmp/archive-exit"
		[ "$(cat "$txroot/current/phase")" = exited ] && [ "$(cat "$txroot/current/kind")" = exit ]
		[ ! -e "$txroot/active" ]; [ ! -f "$tmp/policy-running" ]
		[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 11 ]
		diff -r "$origin" "$tmp/origin-$archive_case"
	done
	printf '%s\n' 'confirmed-only exit: passed (no current, same/new boot, preview/prepare create no current, real exit, unknown child preserved)'
	exit 0
fi
if [ "${1:-}" = --exit-stage ]; then
	TEST_EXIT_CP=$(command -v cp); export TEST_EXIT_CP
	cat >"$tmp/bin/cp" <<'SH'
#!/bin/sh
"$TEST_EXIT_CP" "$@" || exit $?
for argument do
	case "$argument" in */origin/.)
		if [ -f "$TEST_DNS_TMP/kill-exit-copy" ]; then rm "$TEST_DNS_TMP/kill-exit-copy"; kill -KILL "$PPID"; fi ;;
		*/candidate)
		if [ -f "$TEST_DNS_TMP/kill-exit-candidate" ]; then rm "$TEST_DNS_TMP/kill-exit-candidate"; kill -KILL "$PPID"; fi ;;
	esac
done
SH
	TEST_EXIT_MV=$(command -v mv); export TEST_EXIT_MV
	cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
"$TEST_EXIT_MV" "$@" || exit $?
for target do :; done
if [ "$target" = "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/previous" ] && [ -f "$TEST_DNS_TMP/kill-exit-promotion" ]; then
	rm "$TEST_DNS_TMP/kill-exit-promotion"; kill -KILL "$PPID"
fi
SH
	chmod +x "$tmp/bin/cp"
	chmod +x "$tmp/bin/mv"
	for boundary in identity copy candidate promotion; do
		baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
		txroot="$tmp/root/etc/routepolicy/state/init-transaction"
		mkdir "$txroot/exiting"; printf 'unknown legacy stage\n' >"$txroot/exiting/user.keep"
		output=$("$TX" exit-prepare); exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		TEST_EXIT_TOKEN=$exit_token; export TEST_EXIT_TOKEN
		: >"$tmp/kill-exit-$boundary"
		if "$TX" exit-apply "$exit_token" >"$tmp/exit-killed" 2>&1; then printf 'exit kill not reached: %s\n' "$boundary" >&2; exit 1; fi
		if [ "$boundary" = copy ]; then
			printf 'external\n' >"$txroot/exiting-$exit_token/user.keep"
			if "$TX" exit-apply "$exit_token" >/dev/null 2>&1; then printf 'exit deleted unknown stage child\n' >&2; exit 1; fi
			grep -Fxq external "$txroot/exiting-$exit_token/user.keep"
			rm "$txroot/exiting-$exit_token/user.keep"
		fi
		"$TX" exit-apply "$exit_token" >"$tmp/exit-retry" || { printf 'exit stage retry blocked at %s\n' "$boundary" >&2; exit 1; }
		[ ! -e "$txroot/active" ]; grep -Fxq 'unknown legacy stage' "$txroot/exiting/user.keep"
	done
	printf '%s\n' 'exit stage recovery: passed (identity/copy/candidate/promotion kill retry; unknown stages preserved)'
	exit 0
fi
if [ "${1:-}" = --lifecycle ]; then
	baseline 0 0 1 1
	prepare_dns 192.0.2.53; confirm_dns
	prepare_dns 192.0.2.53,192.0.2.54; confirm_dns
	prepare_dns 192.0.2.53; confirm_dns
	active=$(rp_init_active_record)
	# A crash between network confirmation and declaration commit must converge.
	decl="$tmp/root/etc/routepolicy/state/init-transaction/declarations"
	mkdir "$decl"; printf 'installed\n' >"$decl/phase"; printf '%s\n' "$token" >"$decl/init-token"
	"$TX" recover >/dev/null; [ "$(cat "$decl/phase")" = committed ]
	rm "$tmp/policy-running"
	"$TX" repair >/dev/null; [ -f "$tmp/policy-running" ]
	entry=$(find "$active/origin/fields" -name key -exec grep -lFx smartdns.rp_init_default_2.ip '{}' ';')
	[ -n "$entry" ] && [ "$(cat "${entry%/key}/existed")" = 0 ] && [ "$(cat "${entry%/key}/expected")" = 192.0.2.54 ]
	"$TX" exit-preview >"$tmp/exit-preview"
	output=$("$TX" exit-prepare)
	exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	"$TX" exit-apply "$exit_token" >"$tmp/exit-result"
	grep -Fq '"phase":"exited"' "$tmp/exit-result"
	restored
	[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 11 ]
	[ ! -e "$tmp/root/etc/routepolicy/state/init-transaction/active" ]
	baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
	uci set smartdns.rp_init_default_1.user_note=KEEP; uci commit smartdns
	canonical smartdns >"$tmp/exit-before"
	if "$TX" exit-preview >"$tmp/exit-conflict"; then printf 'exit adopted unknown child\n' >&2; exit 1; fi
	grep -Fq 'unknown-child:smartdns.rp_init_default_1.user_note' "$tmp/exit-conflict"
	canonical smartdns >"$tmp/exit-after"; cmp "$tmp/exit-before" "$tmp/exit-after"
	active=$(rp_init_active_record); printf 'legacy-confirmation-history\n' >"$active/origin/incomplete"
	if "$TX" exit-prepare >"$tmp/exit-incomplete"; then printf 'exit guessed incomplete history\n' >&2; exit 1; fi
	printf '%s\n' 'native lifecycle: passed (1 -> 2 -> 1 cumulative origin, actual reversible exit, service state, unknown child, incomplete legacy)'
	exit 0
fi
if [ "${1:-}" = --sources ]; then
	cp "$REAL_LIB/update" "$REAL_LIB/validate" "$REAL_LIB/converter-lib" "$tmp/lib/"
	cat >"$tmp/bin/timeout" <<'SH'
#!/bin/sh
case "$*" in *routepolicy-init-sources*) printf '%s\n' "$*" >>"$TEST_DNS_TMP/source-budget" ;; esac
exec /usr/bin/timeout "$@"
SH
	cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DNS_TMP/source-curl"
[ "$(uci -q get network.rp_init_policy.proto)" = static ] || exit 91
case " $* " in *' --interface if!eth2 '*) ;; *) exit 92 ;; esac
[ ! -f "$TEST_DNS_TMP/source-download-fail" ] || exit 22
[ ! -f "$TEST_DNS_TMP/source-download-slow" ] || sleep 2
if [ -f "$TEST_DNS_TMP/source-download-clock" ]; then cat "$TEST_DNS_TMP/source-download-clock" >"$ROUTEPOLICY_ROOT/proc/uptime"; fi
output=
while [ "$#" -gt 0 ]; do if [ "$1" = --output ]; then output=$2; shift; fi; shift; done
[ -n "$output" ] || exit 93
printf 'new.example\n' >"$output"
SH
	chmod +x "$tmp/bin/curl" "$tmp/bin/timeout" "$tmp/lib/update" "$tmp/lib/validate"
	for source_case in download-failure later-policy-failure success budget-success expired-bootstrap expired-dns expired-download slow-download-timeout; do
		baseline 0 0 1 1
		: >"$tmp/source-new-policy"; rm -f "$tmp/source-curl" "$tmp/source-download-fail" "$tmp/source-bootstrap-clock" "$tmp/source-dns-clock" "$tmp/source-download-clock" "$tmp/source-download-slow" "$tmp/source-budget"
		while read -r field value; do uci set "routepolicy.main.$field=$value"; done <<'EOF'
strict_enforcement 1
dns_redirect 1
warm_restore 1
auto_update 1
update_via_policy_interface 1
rule_priority 12000
mark 0x100
mark_mask 0x100
smartdns_enabled 1
smartdns_policy_group policy
update_hour 4
update_minute 17
EOF
		uci set routepolicy.feed=source
		for item in enabled:1 url:https://example.invalid/new format:plain-domain target:domain-policy min_entries:1 max_shrink_percent:100 update_via_policy_interface:1; do uci set "routepolicy.feed.${item%%:*}=${item#*:}"; done
		uci commit routepolicy
		mkdir -p "$tmp/root/etc/routepolicy/managed.d/current" "$tmp/root/etc/routepolicy/managed.d/previous"
		printf 'old.example\n' >"$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
		printf 'unknown-current\n' >"$tmp/root/etc/routepolicy/managed.d/current/unknown.keep"
		printf 'unknown-previous\n' >"$tmp/root/etc/routepolicy/managed.d/previous/previous.keep"
		cp -R "$tmp/root/etc/routepolicy/managed.d" "$tmp/managed-$source_case"
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
		output=$("$TX" prepare lan wan rp_init_policy policy eth2 static 198.51.100.2 24 198.51.100.1 - - 192.0.2.53 198.51.100.53)
		token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		decl="$tmp/root/etc/routepolicy/state/init-transaction/declarations"; mkdir "$decl"
		printf 'installed\n' >"$decl/phase"; printf '%s\n' "$token" >"$decl/init-token"; : >"$decl/source-refresh"
		case "$source_case" in download-failure) : >"$tmp/source-download-fail" ;; later-policy-failure) : >"$tmp/policy-fail-once" ;; esac
		case "$source_case" in
			budget-success|expired-dns|expired-download)
				printf '170.00 0.00\n' >"$tmp/source-bootstrap-clock"; printf '230.00 0.00\n' >"$tmp/source-dns-clock" ;;
			expired-bootstrap) printf '281.00 0.00\n' >"$tmp/source-bootstrap-clock" ;;
			slow-download-timeout) printf '269.00 0.00\n' >"$tmp/source-bootstrap-clock"; : >"$tmp/source-download-slow" ;;
		esac
		case "$source_case" in expired-dns) printf '281.00 0.00\n' >"$tmp/source-dns-clock" ;; expired-download) printf '281.00 0.00\n' >"$tmp/source-download-clock" ;; esac
		if [ "$source_case" = success ] || [ "$source_case" = budget-success ]; then
			confirm_dns
			grep -Fxq new.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
			[ "$(uci -q get network.rp_init_policy.proto)" = static ]
		else
			if "$TX" apply "$token" >"$tmp/source-result"; then printf 'source failure confirmed success: %s\n' "$source_case" >&2; exit 1; fi
			[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ] || { cat "$tmp/source-result"; exit 1; }
			for snapshot in current previous; do diff -r "$tmp/managed-$source_case/$snapshot" "$tmp/root/etc/routepolicy/managed.d/$snapshot"; done
			if [ "$source_case" = slow-download-timeout ]; then
				unpublished=$(find "$tmp/root/etc/routepolicy/managed.d" -mindepth 1 -maxdepth 1 ! -name current ! -name previous)
				case "$unpublished" in "$tmp/root/etc/routepolicy/managed.d/candidate."*) ;; *) printf 'unexpected timeout artifact\n' >&2; exit 1 ;; esac
				[ -d "$unpublished" ] && [ ! -L "$unpublished" ] && [ "$(stat -c %a "$unpublished")" = 700 ] && [ -z "$(find "$unpublished" -mindepth 1)" ]
				grep -Fxq old.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
				(export LIBEXEC="$REAL_LIB"; rp_sources_ready)
				printf '%s\n' 'source timeout artifact: one private empty unpublished candidate; current/previous remain authoritative'
			else diff -r "$tmp/managed-$source_case" "$tmp/root/etc/routepolicy/managed.d"; fi
			restored
		fi
		case "$source_case" in
			expired-bootstrap|expired-dns) [ ! -e "$tmp/source-curl" ] && [ ! -e "$tmp/source-budget" ] ;;
			*) grep -Fq -- '--interface if!eth2' "$tmp/source-curl" ;;
		esac
		case "$source_case" in
			budget-success|expired-download) grep -Fq -- '-s KILL 40 ' "$tmp/source-budget" || { cat "$tmp/source-budget"; printf 'bootstrap/DNS time was not deducted\n' >&2; exit 1; } ;;
			slow-download-timeout) grep -Fq -- '-s KILL 1 ' "$tmp/source-budget" || { cat "$tmp/source-budget"; printf 'slow download exceeded remaining budget\n' >&2; exit 1; } ;;
		esac
	done
	if "$REAL_LIB/update" init-stage >/dev/null 2>&1; then printf 'unauthenticated init-stage accepted\n' >&2; exit 1; fi
	printf '%s\n' 'native staged sources: passed (new policy before bound download, forced same-name refresh, HTTPS failure, later policy failure, exact current/previous rollback, unknown files, authentication)'
	printf '%s\n' 'native source deadline: passed (bootstrap + DNS budget deducted; expired stages skip download; expired conversion cannot publish; slow download killed in remaining budget)'
	exit 0
fi
native_auto_defaults_test() {
	# The official start callback destroys an uncoordinated list even without native stop.
	baseline 1 1 1 1
	uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq'
	uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'; uci commit smartdns
	uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'; uci commit dhcp
	"$tmp/root/etc/init.d/smartdns" start
	[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053' ]
	printf '%s\n' 'native default-on start control: reproduced conditional forwarding deletion'
	for auto_state in missing empty 1; do
		baseline 1 1 1 1
		case "$auto_state" in missing) uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq' ;; empty) uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=' ;; *) uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=1' ;; esac
		uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'; uci commit smartdns
		uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'; uci commit dhcp
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
		if prepare >"$tmp/default-auto-error" 2>&1; then printf 'unsafe native auto default accepted: %s\n' "$auto_state" >&2; exit 1; fi
		grep -Fq '原生 SmartDNS 自动转发与 DHCP 上游不一致' "$tmp/default-auto-error"
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.after"; cmp "$tmp/$package.before" "$tmp/$package.after"; done
		[ ! -s "$tmp/service-log" ]
	done
	for safe_state in explicit-off inherited-forward port-missing port-empty; do
		baseline 1 1 1 1
		uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'
		case "$safe_state" in
			explicit-off) ;;
			inherited-forward)
				uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq'; uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'
				uci delete 'dhcp.@dnsmasq[0].server'; uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#6053'; uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53' ;;
			port-*)
				if [ "$safe_state" = port-missing ]; then uci delete 'smartdns.@smartdns[0].port'; else uci set 'smartdns.@smartdns[0].port='; fi
				uci set 'smartdns.@smartdns[0].old_port=53'; uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=1'; uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'
				uci set 'dhcp.@dnsmasq[0].port=0'; printf 53 >"$tmp/svc/smartdns.port"; printf 0 >"$tmp/svc/dnsmasq.port"; printf 0 >"$tmp/svc/dnsmasq.running" ;;
		esac
		uci commit smartdns; uci commit dhcp
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
		prepare; : >"$tmp/query-fail"
		if "$TX" apply "$token" >"$tmp/default-auto-rollback" 2>&1; then exit 1; fi
		[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ]
		restored
		uci -q get 'dhcp.@dnsmasq[0].server' | grep -Fq '/corp.example/10.20.0.53'
	done
	printf '%s\n' 'native auto/port defaults: passed (missing/empty auto=1, explicit0, port=53, conditional forwarding and full rollback preservation)'
}
native_auto_defaults_test
management_auto_defaults_test() {
	control="$REAL_LIB/smartdns-control"
	while read -r current requested dns_running accepted; do
		baseline 1 1 1 "$dns_running"
		case "$current" in missing) uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq' ;; empty) uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=' ;; *) uci set "smartdns.@smartdns[0].auto_set_dnsmasq=$current" ;; esac
		uci commit smartdns
		# A deliberate return to default-on may safely retain an existing forwarder.
		if [ "$requested:$dns_running" = inherit:1 ]; then
			uci delete 'dhcp.@dnsmasq[0].server'; uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#6053'; uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'; uci commit dhcp
		fi
		canonical smartdns >"$tmp/control-before"
		"$control" status >"$tmp/control-status"
		version=$(jsonfilter -i "$tmp/control-status" -e '@.version')
		printf 'version\t%s\ninitialize\t0\nconfirm_danger\t1\n' "$version" >"$tmp/control-candidate"
		case "$requested" in omit) ;; inherit) printf 'auto_set_dnsmasq\t\n' >>"$tmp/control-candidate" ;; *) printf 'auto_set_dnsmasq\t%s\n' "$requested" >>"$tmp/control-candidate" ;; esac
		if [ "$accepted" = 1 ]; then "$control" save <"$tmp/control-candidate" >"$tmp/control-save" 2>"$tmp/control-error"
		else
			if "$control" save <"$tmp/control-candidate" >"$tmp/control-save" 2>"$tmp/control-error"; then printf 'unsafe effective auto accepted: %s/%s\n' "$current" "$requested" >&2; exit 1; fi
			grep -Fq 'dnsmasq 未运行' "$tmp/control-error"
		fi
		canonical smartdns >"$tmp/control-after"; cmp "$tmp/control-before" "$tmp/control-after"
		if [ "$current:$requested:$accepted" = 0:omit:1 ]; then
			"$control" apply >"$tmp/control-apply"
			[ "$(uci -q get 'smartdns.@smartdns[0].auto_set_dnsmasq')" = 0 ]
		elif [ "$current:$requested:$dns_running" = 0:inherit:1 ]; then
			"$control" apply >"$tmp/control-apply"
			if uci -q get 'smartdns.@smartdns[0].auto_set_dnsmasq'; then exit 1; fi
			[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053 /corp.example/10.20.0.53' ]
		fi
	done <<'CASES'
missing omit 0 0
empty omit 0 0
0 omit 0 1
1 omit 0 0
0 inherit 0 0
1 inherit 0 0
missing 0 0 1
1 0 0 1
0 1 0 0
0 inherit 1 1
missing omit 1 1
0 omit 1 1
CASES
	baseline 1 1 1 1
	"$control" status >"$tmp/control-status"; version=$(jsonfilter -i "$tmp/control-status" -e '@.version')
	if printf 'version\t%s\ninitialize\t0\nauto_set_dnsmasq\t\n' "$version" | "$control" save >"$tmp/control-save" 2>"$tmp/control-error"; then exit 1; fi
	grep -Fq '危险操作缺少明确确认' "$tmp/control-error"
	if printf 'version\t%s\ninitialize\t0\nconfirm_danger\t1\nauto_set_dnsmasq\t0\nauto_set_dnsmasq\t\n' "$version" | "$control" save >"$tmp/control-save" 2>"$tmp/control-error"; then exit 1; fi
	grep -Fq 'auto_set_dnsmasq 不能重复' "$tmp/control-error"
	printf '%s\n' 'management effective auto: passed (missing row preserves explicit0, blank deletes to native1, running prerequisite and danger confirmation, real UCI apply)'
}
management_auto_defaults_test
if [ "${1:-}" = --native-auto-defaults ]; then exit 0; fi
# Surplus servers remain owned by the original applied source, after active shrinks.
baseline 0 0 1 1
prepare_dns 192.0.2.53,192.0.2.54; confirm_dns
uci set 'smartdns.rp_init_default_2.user_note=Keep this surplus'; uci commit smartdns
prepare_dns 192.0.2.53; confirm_dns
[ "$(uci -q get smartdns.rp_init_default_2.enabled)" = 0 ]
canonical smartdns >"$tmp/repeated-before"
prepare_dns 192.0.2.53
canonical smartdns >"$tmp/repeated-after"; cmp "$tmp/repeated-before" "$tmp/repeated-after"
confirm_dns
[ "$(uci -q get smartdns.rp_init_default_2.user_note)" = 'Keep this surplus' ]
baseline 0 0 1 1
prepare_dns 192.0.2.53; confirm_dns
prepare_dns 192.0.2.53,192.0.2.54; confirm_dns
prepare_dns 192.0.2.53; confirm_dns
prepare_dns 192.0.2.53; confirm_dns
[ "$(uci -q get smartdns.rp_init_default_2.enabled)" = 0 ]
baseline 0 0 1 1; prepare
uci set smartdns.rp_init_default_1=server; uci set smartdns.rp_init_default_1.routepolicy_init=1
uci set smartdns.rp_init_default_1.user_note=USER; uci commit smartdns
canonical smartdns >"$tmp/preview-before"
if prepare >"$tmp/preview-error" 2>&1; then printf 'preview claimed uncommitted DNS server\n' >&2; exit 1; fi
canonical smartdns >"$tmp/preview-after"; cmp "$tmp/preview-before" "$tmp/preview-after"
printf '%s\n' 'init DNS source ownership: passed (2 -> 1 -> 1 and 1 -> 2 -> 1 -> 1, applied source/active, preview rejection, unknown fields)'

# Confirmation registers the real init script watcher under its inherited gate.
baseline 0 0 1 1; prepare
if "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
if ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_WRITER_OWNER="$$:1" "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
if ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_WRITER_OWNER="$$:$(rp_process_start "$$")" "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
"$TX" apply "$token" >/dev/null
[ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
if "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; rp_writer_enter init || exit 1; exec "$ROUTEPOLICY_ROOT/etc/init.d/routepolicy" start init-confirmed' >"$tmp/watch-rejected" 2>&1; then exit 1; fi
: >"$tmp/watch-fail"
if SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >"$tmp/watch-error" 2>&1; then exit 1; fi
grep -Fq '确认已保存' "$tmp/watch-error"
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = confirmed ]
[ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
if "$TX" recover >"$tmp/watch-recovery-error" 2>&1; then exit 1; fi
grep -Fq '确认已保存' "$tmp/watch-recovery-error"
rm "$tmp/watch-fail"
"$TX" recover >/dev/null
[ "$(cat "$tmp/svc/routepolicy.running")" = 1 ]
grep -Fxq 'command /usr/libexec/routepolicy/watch' "$tmp/watch-registration"
"$TX" confirm "$token" >/dev/null
[ "$(grep -c '^command ' "$tmp/watch-registration")" = 1 ]
uci set routepolicy.main.enabled=0; uci commit routepolicy; printf 0 >"$tmp/svc/routepolicy.running"
"$TX" recover >/dev/null
[ "$(grep -c '^command ' "$tmp/watch-registration")" = 1 ] && [ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
uci set routepolicy.main.enabled=1
if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; rp_writer_enter init || exit 1; exec "$ROUTEPOLICY_LIBEXEC/init-transaction" watch-ready' >"$tmp/watch-rejected" 2>&1; then printf 'pending switch bypassed committed disabled policy\n' >&2; exit 1; fi
uci revert routepolicy; uci set routepolicy.main.enabled=1; uci commit routepolicy; printf 1 >"$tmp/svc/routepolicy.running"
mkdir -p "$tmp/watch-lib"
cp "$REAL_LIB/common" "$tmp/watch-lib/common"
cat >"$tmp/watch-lib/update" <<'EOF'
#!/bin/sh
set -eu
[ -z "${ROUTEPOLICY_WRITER_OWNER:-}" ] && [ ! -e "/proc/$$/fd/9" ]
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter update
printf updated >"$TEST_DNS_TMP/watch-updated"
EOF
chmod +x "$tmp/watch-lib/update"
uci set routepolicy.main.auto_update=1; uci set routepolicy.main.update_hour=0; uci set routepolicy.main.update_minute=0; uci commit routepolicy
watch_result=0
(unset ROUTEPOLICY_WRITER_OWNER ROUTEPOLICY_WRITER_KIND; exec 9>&-; ROUTEPOLICY_LIBEXEC="$tmp/watch-lib" timeout -k 1 2 "$REAL_LIB/watch") || watch_result=$?
[ "$watch_result" = 124 ] && [ "$(cat "$tmp/watch-updated")" = updated ]
test_boot
printf 0 >"$tmp/svc/routepolicy.running"
"$TX" confirm "$token" >/dev/null
[ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
printf '%s\n' 'init DNS confirmation watcher: passed (pending/forged caller rejection, durable failure, retry, idempotent real init registration)'

# A native restart really deletes conditional forwarding; rollback must only start.
baseline 1 1 1 1
uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=1'; uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'; uci commit smartdns
uci delete 'dhcp.@dnsmasq[0].server'
uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#6053'
uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'
uci set 'dhcp.@dnsmasq[0].noresolv=1'; uci set 'dhcp.@dnsmasq[0].rebind_protection=0'; uci set 'dhcp.@dnsmasq[0].domainneeded=0'; uci commit dhcp
cp "$tmp/root/etc/config/dhcp" "$tmp/native-dhcp-before"
"$tmp/root/etc/init.d/smartdns" restart
[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053' ]
cp "$tmp/native-dhcp-before" "$tmp/root/etc/config/dhcp"
for package in dhcp smartdns; do canonical "$package" >"$tmp/$package.before"; done
prepare; : >"$tmp/query-fail"; : >"$tmp/service-log"
if "$TX" apply "$token" >"$tmp/native-rollback-error" 2>&1; then exit 1; fi
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ]
restored
[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053 /corp.example/10.20.0.53' ]
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 1111 ]
grep -Fxq 'smartdns start' "$tmp/service-log"
if grep -Eq '^smartdns (stop|restart)$' "$tmp/service-log"; then exit 1; fi
printf '%s\n' 'init DNS native forwarding rollback: passed (real destructive callback control, full DHCP/SmartDNS preservation, original enabled/running)'
if [ "${1:-}" = --review-fixes ]; then exit 0; fi
# A discarded preview cannot authorize a later, ordinary user resource.
printer_rule() {
	uci set firewall.rp_init_dns=rule
	uci set 'firewall.rp_init_dns.name=Living Room Printer'
	uci set firewall.rp_init_dns.target=REJECT; uci set firewall.rp_init_dns.dest_port=9100
	uci set 'firewall.rp_init_dns.user_note=Keep this printer rule'; uci commit firewall
	canonical firewall >"$tmp/firewall.before"
}
for ownership_phase in prepared expired rolled_back; do
	baseline 0 0 1 1; prepare
	case "$ownership_phase" in expired) "$TX" recover >/dev/null ;; rolled_back) "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null ;; esac
	printer_rule
	if prepare >"$tmp/ownership-error" 2>&1; then printf 'unapplied/rolled-back plan adopted printer: %s\n' "$ownership_phase" >&2; exit 1; fi
	if [ "$ownership_phase" = prepared ]; then
		if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
	fi
	restored
	[ "$(uci -q get firewall.rp_init_dns.user_note)" = 'Keep this printer rule' ]
done
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
uci set 'firewall.rp_init_dns.user_note=Keep this DNS note'; uci commit firewall
ownership_active=$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")
prepare; "$TX" recover >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")" = "$ownership_active" ]
prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
test_boot
"$TX" recover-early >/dev/null; "$TX" boot-dns >/dev/null
prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
[ "$(uci -q get firewall.rp_init_dns.user_note)" = 'Keep this DNS note' ]
printf '%s\n' 'init section ownership: passed (discarded/prepared/rolled-back rejection, actual applying/pending, active after cancel/reboot, unknown fields)'
if [ "${1:-}" = --ownership ]; then exit 0; fi
# Harmless names must remain single configuration-line values across native init.
for structure_case in newline crlf tab control del trailing-newline; do
	baseline 0 0 1 1
	case "$structure_case" in
		newline) name=$(printf 'Kitchen Router\nLiving Router.') ;;
		crlf) name=$(printf 'Kitchen Router\r\nLiving Router.') ;;
		tab) name=$(printf 'Kitchen\tRouter.') ;;
		control) name=$(printf 'Kitchen\001Router.') ;;
		del) name=$(printf 'Kitchen\177Router.') ;;
		trailing-newline) name=$(printf 'Kitchen Router\n.') ;;
	esac
	name=${name%.}
	if ! uci set "smartdns.@smartdns[0].server_name=$name" >"$tmp/structure-set-error" 2>&1; then
		# libuci itself rejects some C0/DEL bytes before they become valid UCI data.
		case "$structure_case" in control|del) restored; continue ;; *) exit 1 ;; esac
	fi
	uci commit smartdns
	canonical smartdns >"$tmp/smartdns.before"
	if prepare >"$tmp/structure-error" 2>&1; then printf 'unsafe multiline/control name accepted: %s\n' "$structure_case" >&2; exit 1; fi
	restored
	[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")" = 01 ]
	baseline 0 0 1 1; prepare
	uci set "smartdns.@smartdns[0].server_name=$name"; uci commit smartdns
	canonical smartdns >"$tmp/smartdns.before"
	if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
	[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
	restored
done
# Check the shared value boundary too, without claiming libuci accepts these bytes.
if (uci() { printf 'Kitchen\001Router\n'; }; init_dns_audit_uci_line smartdns.main.server_name) >"$tmp/structure-error" 2>&1; then exit 1; fi
if (uci() { printf 'Kitchen\177Router\n'; }; init_dns_audit_uci_line smartdns.main.server_name) >"$tmp/structure-error" 2>&1; then exit 1; fi
# Lists and other native rule classes share the same structure check.
for structure_kind in client-list rule-value; do
	baseline 0 0 1 1
	name=$(printf 'Living Room\nKitchen Room')
	if [ "$structure_kind" = client-list ]; then
		uci set smartdns.room=client-rule; uci set smartdns.room.enabled=1
		uci add_list "smartdns.room.client_addr=$name"
	else
		uci set smartdns.room=domain-rule; uci set smartdns.room.enabled=1
		uci set "smartdns.room.speed_check_mode=$name"
	fi
	uci commit smartdns; canonical smartdns >"$tmp/smartdns.before"
	if prepare >"$tmp/structure-error" 2>&1; then exit 1; fi
	restored
done
for external_option in leasefile resolvfile; do
	baseline 0 0 1 1
	name=$(printf '/tmp/Kitchen\nRouter')
	uci set "dhcp.@dnsmasq[0].$external_option=$name"; uci commit dhcp
	canonical dhcp >"$tmp/dhcp.before"
	if prepare >"$tmp/structure-error" 2>&1; then exit 1; fi
	restored
done
baseline 0 0 1 1
uci set 'smartdns.@smartdns[0].server_name=Kitchen Router'
uci add_list 'smartdns.@smartdns[0].display_labels=Kitchen Router'
uci add_list 'smartdns.@smartdns[0].display_labels=Living Router'
uci set smartdns.room=client-rule; uci set 'smartdns.room.client_ip=192.0.2.10'
uci set 'smartdns.room.description=Living Room Router'; uci commit smartdns
uci set 'dhcp.@dnsmasq[0].leasefile=/tmp/Kitchen Router.leases'; uci commit dhcp
canonical dhcp >"$tmp/dhcp.before"
canonical smartdns >"$tmp/smartdns.before"; prepare; restored
"$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
printf '%s\n' 'init DNS UCI line structure: passed (harmless names, CRLF/control/trailing newline, spaces/lists, pre-write zero changes)'
if [ "${1:-}" = --line-structure ]; then exit 0; fi
# Exercise every enabled/running combination for both pre-existing services.
# Native reload_service starts an rc-disabled daemon; per-instance disabled prevents it.
baseline 0 0 1 1
"$tmp/root/etc/init.d/dnsmasq" stop; "$tmp/root/etc/init.d/dnsmasq" disable
uci set 'dhcp.@dnsmasq[0].port=0'; uci commit dhcp
. "$tmp/native-main"; set_main_dns
[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 10 ]
uci set 'dhcp.@dnsmasq[0].disabled=1'; uci commit dhcp
"$tmp/root/etc/init.d/dnsmasq" stop
set_main_dns; "$tmp/root/etc/init.d/dnsmasq" reload
[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
for disabled in absent 0 1; do
	baseline 0 0 1 0
	if [ "$disabled" != absent ]; then uci set "dhcp.@dnsmasq[0].disabled=$disabled"; uci commit dhcp; fi
	canonical dhcp >"$tmp/dhcp.before"
	prepare; "$TX" apply "$token" >/dev/null
	[ "$(uci -q get 'dhcp.@dnsmasq[0].disabled')" = 1 ]
	"$TX" recover >/dev/null; restored
	[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 01 ]
done
# Original port53 SmartDNS reload finishes before stopped dnsmasq convergence.
baseline 1 1 1 0
uci set 'smartdns.@smartdns[0].port=53'; uci set 'smartdns.@smartdns[0].old_port=53'
uci set 'dhcp.@dnsmasq[0].port=0'; uci commit smartdns; uci commit dhcp
printf 53 >"$tmp/svc/smartdns.port"
for package in dhcp smartdns; do canonical "$package" >"$tmp/$package.before"; done
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/smartdns.running")" = 011 ]
for option in dns_redirect old_dns_redirect; do
	baseline 0 0 1 1; uci set "dhcp.@dnsmasq[0].$option=1"; uci commit dhcp
	canonical dhcp >"$tmp/user.before"
	if prepare >/dev/null 2>&1; then exit 1; fi
	canonical dhcp >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
done
# Refuse inconsistent original states before touching a field or user option6.
baseline 1 1 1 0
uci delete 'smartdns.@smartdns[0].port'; uci set 'smartdns.@smartdns[0].old_port=53'; uci commit smartdns
canonical dhcp >"$tmp/user.before"
if prepare >"$tmp/original-main-error" 2>&1; then exit 1; fi
grep -Fq 'DHCP option6' "$tmp/original-main-error"
canonical dhcp >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
baseline 0 0 1 1; uci set 'dhcp.@dnsmasq[0].disabled=1'; uci commit dhcp
if prepare >"$tmp/original-main-error" 2>&1; then exit 1; fi
grep -Fq '不一致原态' "$tmp/original-main-error"
printf '%s\n' 'init DNS native dnsmasq reload isolation: passed (rc disabled counterexample, UCI disabled, original53 stopped restore)'
if [ "${1:-}" = --native-reload ]; then exit 0; fi
if [ "${1:-}" != --killed-policy ]; then
for argument in '-g rp_init_policy' '--group=rp_init_default' '--gr=rp_init_policy' '-grp_init_default' '-egrp_init_policy' '-g "rp_init_policy"'; do
	baseline 0 0 1 1
	uci set smartdns.user.server_group=user_group; uci set "smartdns.user.addition_arg=$argument"; uci commit smartdns
	canonical smartdns >"$tmp/user.before"
	if prepare >"$tmp/uci-group-error" 2>&1; then printf 'unsafe native addition_arg accepted: %s\n' "$argument" >&2; exit 1; fi
	canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
done
for option in ip port tls_host_verify host_name http_host server_group spki_pin set_mark; do
	baseline 0 0 1 1
	uci set "smartdns.user.$option=ordinary --group=rp_init_policy"; uci commit smartdns
	if prepare >"$tmp/uci-group-error" 2>&1; then printf 'unsafe native field accepted: %s\n' "$option" >&2; exit 1; fi
done
baseline 0 0 1 1
uci set smartdns.user.routepolicy_init=1; uci set 'smartdns.user.addition_arg=-g rp_init_policy'; uci commit smartdns
if prepare >"$tmp/uci-group-error" 2>&1; then exit 1; fi
baseline 0 0 1 1
uci set smartdns.user.server_group=user_group; uci set 'smartdns.user.addition_arg=-g ordinary -interface eth1'; uci commit smartdns
prepare
uci set 'smartdns.user.addition_arg=--group=rp_init_policy'; uci commit smartdns
canonical smartdns >"$tmp/user.before"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
# A managed section still retains unknown native string options. Only the four
# fields overwritten by the plan may bypass the reserved-group audit.
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
owned_active=$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")
for option in set_mark tls_host_verify host_name http_host spki_pin; do
	uci set "smartdns.rp_init_policy_1.$option=0 -g rp_init_default"; uci commit smartdns
	canonical smartdns >"$tmp/user.before"
	if prepare >"$tmp/owned-group-error" 2>&1; then printf 'unsafe managed native field accepted: %s\n' "$option" >&2; exit 1; fi
	canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
	uci delete "smartdns.rp_init_policy_1.$option"; uci commit smartdns
done
# Native renderer semantics: set_mark is appended before our controlled addition_arg.
if printf '%s\n' 'server 198.51.100.53:53 -group rp_init_policy -set-mark 0 -g rp_init_default -interface eth2' | init_dns_audit_lines 53 br-lan 1 >/dev/null; then exit 1; fi
uci set smartdns.rp_init_policy_1.set_mark=0; uci commit smartdns
prepare
uci set 'smartdns.rp_init_policy_1.set_mark=0 --group=rp_init_default'; uci commit smartdns
canonical smartdns >"$tmp/user.before"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")" = "$owned_active" ]
printf '%s\n' 'init DNS managed native unknown arguments: passed (prepare, generated syntax, pre-write, user values preserved)'
if [ "${1:-}" = --owned-args ]; then exit 0; fi
printf '%s\n' 'init DNS native UCI upstream arguments: passed (group aliases, raw native fields, ownership and pre-write recheck)'
if [ "${1:-}" = --uci-args ]; then exit 0; fi
baseline 0 0 1 1
include="$tmp/root/etc/smartdns/custom-a.conf"
child="$tmp/root/etc/smartdns/nested child.conf"
printf 'server 203.0.113.53 -group rp_init_policy\n' >"$include"
cp "$include" "$tmp/include.before"
if prepare >"$tmp/include-error" 2>&1; then exit 1; fi
cmp "$tmp/include.before" "$include"
printf "conf-file 'nested child.conf'\n" >"$include"
printf 'server 203.0.113.53 --gr=rp_init_default\n' >"$child"
cp "$child" "$tmp/child.before"
if prepare >"$tmp/include-error" 2>&1; then exit 1; fi
cmp "$tmp/child.before" "$child"
printf 'server 203.0.113.53 -group ordinary\n' >"$child"
prepare
printf 'server 203.0.113.53 -grp_init_policy\n' >"$child"
cp "$child" "$tmp/child.before"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
cmp "$tmp/child.before" "$child"; restored
printf '%s\n' 'init DNS include preflight: passed (prepare and pre-write recheck, no UCI/file changes)'
if [ "${1:-}" = --include-audit ]; then exit 0; fi
fi
# Both teardown (previously disabled) and apply (previously active) restore paths
# must recover the child marker automatically without weakening active-table checks.
for previous_policy in 0 1; do
	baseline 0 0 1 1
	if [ "$previous_policy" = 1 ]; then
		uci set routepolicy.main.enabled=1; uci commit routepolicy
		canonical routepolicy >"$tmp/routepolicy.before"
		mkdir -p "$tmp/root/etc/routepolicy/state"
		printf 'policy_interface=wan2\npolicy_device=eth2\nroute_table=200\n' >"$tmp/root/etc/routepolicy/state/applied"
		: >"$tmp/policy-running"
	fi
	prepare; : >"$tmp/kill-policy"
	if "$TX" apply "$token" >"$tmp/policy-kill.out" 2>&1; then exit 1; fi
	"$TX" recover-auto >/dev/null
	[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ]
	if [ "$previous_policy" = 0 ]; then restored
	else
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.after"; cmp "$tmp/$package.before" "$tmp/$package.after"; done
		[ -f "$tmp/policy-running" ]
		[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")" = 01 ]
	fi
	[ ! -e "$tmp/root/tmp/routepolicy/apply.lock" ]
done
printf '%s\n' 'init DNS killed policy writer recovery: passed (automatic same-owner compensation, originally disabled and active)'
if [ "${1:-}" = --killed-policy ]; then exit 0; fi
# An unapplied candidate has no same-boot TTL; explicit recovery only cancels it.
baseline 0 0 1 1; prepare; preview_token=$token
printf '3600.00 0.00\n' >"$tmp/root/proc/uptime"
"$TX" recover-auto >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = prepared ]
"$TX" apply "$preview_token" >/dev/null; "$TX" recover >/dev/null; restored
baseline 0 0 1 1; prepare; preview_token=$token
cp "$tmp/service-log" "$tmp/prepared-services"
"$TX" recover >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = expired ]
cmp "$tmp/prepared-services" "$tmp/service-log"; restored
if "$TX" apply "$preview_token" >/dev/null 2>&1; then exit 1; fi
baseline 0 0 1 1; prepare; preview_token=$token
"$REAL_LIB/apply" event >/dev/null
cp "$tmp/service-log" "$tmp/prepared-services"
test_boot
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = expired ]
cmp "$tmp/prepared-services" "$tmp/service-log"; restored
[ -f "$tmp/root/tmp/routepolicy/events.pending" ]
"$REAL_LIB/apply" reconcile-event >/dev/null
[ ! -f "$tmp/root/tmp/routepolicy/events.pending" ]
if "$TX" apply "$preview_token" >/dev/null 2>&1; then exit 1; fi
baseline 0 0 1 1; prepare
: >"$tmp/root/etc/routepolicy/state/init-transaction/current/dns-service-attempted"
test_boot
if "$TX" recover-early >/dev/null 2>&1; then exit 1; fi
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = prepared ]
printf '%s\n' 'init DNS unapplied candidate lifecycle: passed (same-boot preview, explicit cancel, cross-boot and zero-write evidence)'
if [ "${1:-}" = --review-regressions ]; then exit 0; fi
matrix_count=0
if [ "${1:-}" != --boot-smoke ] && [ "${1:-}" != --quiesce-smoke ] && [ "${1:-}" != --lifecycle-smoke ] && [ "${1:-}" != --restore-smoke ]; then
for se in 0 1; do for sr in 0 1; do for de in 0 1; do for dr in 0 1; do
	case "${1:-}:$se$sr$de$dr" in --recovery-smoke:0000|--recovery-smoke:0111|--recovery-smoke:1001|--recovery-smoke:1110) ;; --recovery-smoke:*) continue ;; esac
	baseline "$se" "$sr" "$de" "$dr"; prepare
	queries_before=0; [ ! -f "$tmp/queries" ] || queries_before=$(wc -l <"$tmp/queries")
	"$TX" apply "$token" >/dev/null
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = 1100 ]
	[ "$(( $(wc -l <"$tmp/queries") - queries_before ))" = 9 ]
	[ "$(cat "$tmp/svc/routepolicy.enabled")" = 1 ]
	"$TX" recover >/dev/null; restored
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = "$se$sr$de$dr" ]
	matrix_count=$((matrix_count+1))
done; done; done; done
fi
baseline 0 0 1 1
: >"$tmp/delete-fail"
if init_dns_stop; then exit 1; fi
rm "$tmp/delete-fail"; : >"$tmp/list-fail"
if init_dns_stop; then exit 1; fi
rm "$tmp/list-fail"; : >"$tmp/delete-race"
init_dns_stop; init_dns_stop
# Stopping before the first field must restore running state after a later failure.
baseline 0 1 1 1; prepare; : >"$tmp/quiesce-fault"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
restored
[ "$(cat "$tmp/svc/smartdns.running")" = 1 ]
# Stopped UCI-disabled service must stay stopped without native start adding old_*.
baseline 1 0 1 1
uci set 'smartdns.@smartdns[0].enabled=0'
for option in old_enabled old_port old_auto_set_dnsmasq; do uci delete "smartdns.@smartdns[0].$option"; done
uci commit smartdns; canonical smartdns >"$tmp/smartdns.before"
prepare; : >"$tmp/quiesce-fault"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
restored; [ ! -e "$tmp/native-start-called" ]
if [ "${1:-}" = --quiesce-smoke ]; then
	printf '%s\n' 'init DNS quiesce recovery: passed (no field attempted, native metadata absent, stopped UCI-disabled service, NotFound and real errors)'; exit 0
fi
baseline 0 0 1 1; prepare; : >"$tmp/query-fail"
if "$TX" apply "$token" >/dev/null; then printf 'SERVFAIL was accepted\n' >&2; exit 1; fi
restored
baseline 0 0 1 1; : >"$tmp/netstat-fail"
if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >"$tmp/listener-error" 2>&1; then exit 1; fi
grep -Fq 'SmartDNS 协调准备阶段失败' "$tmp/listener-error"
rm "$tmp/netstat-fail"
baseline 0 0 1 1; export TEST_DNS_IPV6=1
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
grep -Fq -- '-6 +tcp' "$tmp/queries"; grep -Fq -- '-6 +notcp' "$tmp/queries"
unset TEST_DNS_IPV6
# A successful init-script return cannot hide a dnsmasq process still using port=0.
baseline 0 0 1 1; prepare; : >"$tmp/query-fail"; : >"$tmp/stale-dnsmasq"
if "$TX" apply "$token" >/dev/null; then exit 1; fi
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = conflict ]
grep -Fq smartdns-service "$tmp/root/etc/routepolicy/state/init-transaction/current/conflicts"
rm "$tmp/stale-dnsmasq" "$tmp/query-fail"; "$TX" recover >/dev/null; restored
# A running, originally DNS-disabled dnsmasq has no invented port-53 obligation.
baseline 0 0 1 1
uci set 'dhcp.@dnsmasq[0].port=0'; uci commit dhcp; printf 0 >"$tmp/svc/dnsmasq.port"
canonical dhcp >"$tmp/dhcp.before"
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
# Reserved names are never adopted by replacing an unknown upstream section type.
baseline 0 0 1 1
printf "config server 'rp_init'\n\toption ip '192.0.2.88'\n" >"$tmp/root/etc/config/smartdns"
canonical smartdns >"$tmp/smartdns.before"
if prepare >"$tmp/reserved-error" 2>&1; then exit 1; fi
grep -Fq '保留根段 rp_init' "$tmp/reserved-error"
canonical smartdns >"$tmp/smartdns.after"; cmp "$tmp/smartdns.before" "$tmp/smartdns.after"
printf '%s\n' 'init DNS restore functionality and reserved-root protection: passed'
if [ "${1:-}" = --restore-smoke ]; then exit 0; fi
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
test_boot
printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
rm -f "$tmp/policy-running"
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolling_back ]
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
# Emulate a boot entry captured before S18 removed its link. S94 must converge.
printf 1 >"$tmp/svc/smartdns.running"
"$TX" recover-startup >/dev/null; restored
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 011 ]
# The native UCI enable flag is distinct from rc-enabled and running.
baseline 1 0 1 1
uci set 'smartdns.@smartdns[0].enabled=0'; uci set 'smartdns.@smartdns[0].old_enabled=0'; uci commit smartdns
canonical smartdns >"$tmp/smartdns.before"
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")" = 10 ]
# A killed partial field commit is undone before native S19 entries can run.
baseline 1 0 1 1; prepare
printf 'commit:smartdns.@smartdns[0].port' >"$tmp/kill-stage"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
test_boot
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
"$TX" recover-startup >/dev/null; restored
# A true conflict also quarantines both native DNS startup entries.
baseline 1 0 1 1; prepare; "$TX" apply "$token" >/dev/null
uci set 'smartdns.@smartdns[0].port=9999'; uci commit smartdns
test_boot
if "$TX" recover-early >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
[ "$(uci -q get 'smartdns.@smartdns[0].port')" = 9999 ]
# Confirmed reboot: cold application cache, sets before DNS, and failure stays closed.
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
active="$tmp/root/etc/routepolicy/state/init-transaction/confirmed/$token"
canonical dhcp >"$tmp/shutdown-dhcp.before"
"$TX" shutdown-dns >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")" = 0 ]
canonical dhcp >"$tmp/shutdown-dhcp.after"; cmp "$tmp/shutdown-dhcp.before" "$tmp/shutdown-dhcp.after"
rm -rf "$tmp/root/tmp/routepolicy"; rm -f "$tmp/policy-running"
printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
test_boot
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
# Admission precedes policy writes and native start; it never repairs DHCP drift.
cp "$tmp/root/etc/config/dhcp" "$tmp/boot-dhcp.good"
for drift in missing port53 list disabled pending; do
	cp "$tmp/boot-dhcp.good" "$tmp/root/etc/config/dhcp"
	case "$drift" in
		missing) uci delete 'dhcp.@dnsmasq[0].port' ;;
		port53) uci set 'dhcp.@dnsmasq[0].port=53' ;;
		list) uci delete 'dhcp.@dnsmasq[0].port'; uci add_list 'dhcp.@dnsmasq[0].port=0' ;;
		disabled) uci set 'dhcp.@dnsmasq[0].disabled=0' ;;
		pending) uci set 'dhcp.@dnsmasq[0].port=53' ;;
	esac
	[ "$drift" = pending ] || uci commit dhcp
	cp "$tmp/root/etc/config/dhcp" "$tmp/boot-dhcp.drift"
	starts_before=$(grep -Ec '^smartdns (start|reload)$' "$tmp/service-log" || true)
	if "$TX" boot-dns >/dev/null 2>&1; then printf 'boot accepted DHCP drift: %s\n' "$drift" >&2; exit 1; fi
	[ "$(grep -Ec '^smartdns (start|reload)$' "$tmp/service-log" || true)" = "$starts_before" ]
	cmp "$tmp/boot-dhcp.drift" "$tmp/root/etc/config/dhcp"
	[ -f "$active/dns-boot-pending" ] && [ ! -f "$active/dns-boot-ready" ]
	[ ! -f "$tmp/policy-running" ]
	[ "$drift" != pending ] || uci revert dhcp
done
cp "$tmp/boot-dhcp.good" "$tmp/root/etc/config/dhcp"
: >"$tmp/policy-fail"
if "$TX" boot-dns >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")" = 00 ]
rm "$tmp/policy-fail"
: >"$tmp/query-fail"
if "$TX" boot-dns >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")" = 00 ]
[ -f "$active/dns-boot-pending" ]
rm "$tmp/query-fail"
"$TX" boot-dns >/dev/null
[ -f "$tmp/policy-running" ]
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 1100 ]
[ "$(cat "$tmp/root/etc/smartdns/user.cache")" = USER-CACHE ]
[ ! -f "$active/dns-boot-pending" ]

# Drive retries through the real S94 entry and its supervised guard command.
guard_entry() {
	guard_pid=
	export ROUTEPOLICY_INIT_TRANSACTION=$TX
	. "$ROOT/routepolicy/files/etc/init.d/routepolicy-initguard"
	procd_open_instance() { :; }
	procd_set_param() { [ "$1" != command ] || guard_command=$2; }
	procd_close_instance() { "$guard_command" guard >"$tmp/guard.log" 2>&1 & guard_pid=$!; }
	start_service
}
wait_guard() {
	remaining=20
	while [ -f "$active/dns-boot-pending" ]; do
		[ "$remaining" -gt 0 ] || { cat "$tmp/guard.log"; kill "$guard_pid"; return 1; }
		sleep 1; remaining=$((remaining-1))
	done
	[ -z "$guard_pid" ] || wait "$guard_pid"
}
reboot_services() {
	rm -rf "$tmp/root/tmp/routepolicy"; rm -f "$tmp/policy-running"
	printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
	test_boot
	"$TX" recover-early >/dev/null
}
# Policy off keeps DNS, even when the policy NIC is down and apply cannot run.
for adapter in 1 0; do
	uci set routepolicy.main.enabled=0; uci set "routepolicy.main.smartdns_enabled=$adapter"; uci commit routepolicy
	: >"$tmp/policy-down"; : >"$tmp/policy-fail"; : >"$tmp/queries"; rm -f "$tmp/watch-registration"
	reboot_services "dns-only-$adapter"
	"$TX" boot-dns >/dev/null
	[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")" = 10 ]
	[ ! -f "$tmp/policy-running" ] && [ ! -e "$tmp/root/tmp/routepolicy/active" ] && [ ! -e "$tmp/watch-registration" ]
	[ "$(wc -l <"$tmp/queries")" = 4 ]
	if grep -Fq routepolicy-init-policy.test "$tmp/queries" || grep -Fq "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'" "$tmp/root/var/etc/smartdns/smartdns.conf"; then exit 1; fi
	[ "$(uci -q get routepolicy.main.enabled):$(uci -q get routepolicy.main.smartdns_enabled)" = "0:$adapter" ]
done
rm "$tmp/policy-down" "$tmp/policy-fail"
uci set routepolicy.main.enabled=1; uci set routepolicy.main.smartdns_enabled=0; uci commit routepolicy
reboot_services policy-without-adapter; "$TX" boot-dns >/dev/null
[ -f "$tmp/policy-running" ]
if grep -Fq "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'" "$tmp/root/var/etc/smartdns/smartdns.conf"; then exit 1; fi
uci set routepolicy.main.smartdns_enabled=1; uci commit routepolicy
reboot_services policy-with-adapter; "$TX" boot-dns >/dev/null
grep -Fq "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'" "$tmp/root/var/etc/smartdns/smartdns.conf"
printf 'DNS ownership/policy switches: passed (DNS-only with policy down, both adapter values, no policy apply/90/watch, policy enabled unchanged)\n'
txdir="$tmp/root/etc/routepolicy/state/init-transaction"
origin=$(cat "$txdir/source"); cp -R "$txdir/confirmed/$origin/fields" "$tmp/origin-fields"
prepare
[ "$(cat "$txdir/active")" = "$origin" ]
reboot_services prepared-after-confirm
"$REAL_LIB/apply" event >/dev/null
: >"$tmp/policy-fail"; guard_entry
[ -f "$active/dns-boot-pending" ] && [ "$(cat "$tmp/svc/smartdns.running")" = 0 ]
"$TX" status >"$tmp/active-status"
[ "$(jsonfilter -i "$tmp/active-status" -e '@.phase')" = expired ]
[ "$(jsonfilter -i "$tmp/active-status" -e '@.active.dns_boot_state')" = retrying ]
rm "$tmp/policy-fail"; : >"$tmp/query-fail"
remaining=30
while [ "$(cat "$active/failed-stage")" != boot-dns-start ]; do
	[ "$remaining" -gt 0 ] || { cat "$tmp/guard.log"; exit 1; }
	sleep 1; remaining=$((remaining-1))
done
[ -f "$active/dns-boot-pending" ] && [ "$(cat "$tmp/svc/smartdns.running")" = 0 ]
rm "$tmp/query-fail"; wait_guard
[ ! -f "$tmp/root/tmp/routepolicy/events.pending" ] && [ ! -f "$tmp/root/tmp/routepolicy/events.inflight" ]
[ "$(cat "$txdir/current/phase")" = expired ]
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
"$TX" status | grep -Fq '"prepared_expired_reason":"boot-changed"'
diff -r "$tmp/origin-fields" "$txdir/confirmed/$origin/fields"
# A repeated apply rollback keeps the first accepted boot and provenance contract.
prepare; : >"$tmp/query-fail"
if "$TX" apply "$token" >/dev/null; then exit 1; fi
[ "$(cat "$txdir/current/phase")" = rolled_back ]
rm "$tmp/query-fail"
reboot_services rollback-after-confirm; guard_entry; wait_guard
[ "$(cat "$txdir/active")" = "$origin" ]
# Both sides of the pointer commit converge after a power loss in confirmation.
mkdir "$txdir/confirmed-foreign"; printf USER >"$txdir/confirmed-foreign/keep"
for point in intent pointer; do
	prepare; "$TX" apply "$token" >/dev/null
	printf '%s\n' "$point" >"$tmp/kill-confirm"
	if SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null 2>&1; then exit 1; fi
	[ "$(cat "$txdir/current/phase")" = confirming ]
	reboot_services "confirm-interrupted-$point"
	[ "$(cat "$txdir/current/phase")" = confirmed ] && [ "$(cat "$txdir/active")" = "$token" ]
	active="$txdir/confirmed/$token"; guard_entry; wait_guard
	[ "$(find "$txdir/confirmed" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 2 ]
	[ "$(cat "$txdir/confirmed-foreign/keep")" = USER ]
	[ "$(cat "$txdir/source")" = "$origin" ]
	diff -r "$tmp/origin-fields" "$txdir/confirmed/$origin/fields"
done
mv "$txdir/active" "$tmp/active.value"; ln -s "$tmp/active.value" "$txdir/active"
if "$TX" recover-early >/dev/null; then exit 1; fi
[ "$(cat "$tmp/active.value")" = "$token" ]
rm "$txdir/active"; mv "$tmp/active.value" "$txdir/active"
mv "$active" "$tmp/active.record"; ln -s "$tmp/active.record" "$active"
if "$TX" recover-early >/dev/null; then exit 1; fi
rm "$active"; mv "$tmp/active.record" "$active"
printf 'init DNS native WAL: passed (matrix=%s; distinct UCI flag, kill, conflict, pending and confirmed reboot)\n' "$matrix_count"
