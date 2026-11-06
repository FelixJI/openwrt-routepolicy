#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
REAL_LIB="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-dns.XXXXXX")
trap '[ -z "${guard_pid:-}" ] || kill "$guard_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT HUP INT TERM
export TEST_DNS_TMP=$tmp ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_OUTPUT=json
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/root/etc/config" "$tmp/root/etc/init.d" "$tmp/root/usr/sbin"
cp "$REAL_LIB/common" "$REAL_LIB/init-dns" "$REAL_LIB/init-transaction" "$tmp/lib/"
cp -R "$REAL_LIB/converters" "$tmp/lib/"
chmod +x "$tmp/lib/"*
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
exit 0
EOF
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
access=lan default_if=wan policy=wan2 access_device=br-lan default_device=eth1 policy_device=eth2
dns_default=${13:--} dns_policy=${14:--}
case "$1" in
	plan)
		set_value routepolicy.main.enabled 1
		set_value routepolicy.main.policy_interface wan2
		init_ipv4_plan
		init_dns_plan ;;
	link-plan) printf 'required\t0\n' ;;
	management-address) uci -q get network.lan.ipaddr ;;
	verify) : ;;
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
	network.interface.wan:status|network.interface.wan2:status)
		device=eth1; [ "$2" != network.interface.wan2 ] || device=eth2
		printf '{"up":true,"l3_device":"%s","dns-server":["192.0.2.53"],"route":[{"target":"0.0.0.0","nexthop":"198.51.100.1"}]}\n' "$device" ;;
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
if [ -f "$TEST_DNS_TMP/query-fail" ] && [ "$*" != "${*%routepolicy-init-restore.test*}" ]; then printf ';; ->>HEADER<<- status: NOERROR, id: 1\n'
elif [ -f "$TEST_DNS_TMP/query-fail" ]; then printf ';; ->>HEADER<<- status: SERVFAIL, id: 1\n'
else printf ';; ->>HEADER<<- status: NOERROR, id: 1\n'; fi
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
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
[ ! -e /proc/self/fd/9 ]
[ ! -f "$TEST_DNS_TMP/policy-fail" ] || exit 1
. "$ROUTEPOLICY_LIBEXEC/common"
if [ "${1:-}" = teardown ]; then
	[ "${ROUTEPOLICY_INIT_RESTORE:-0}" = 1 ]
	rm -f "$TEST_DNS_TMP/policy-running" "$RP_STATE_DIR/applied"
	rm -rf "$RP_ACTIVE_DIR"
	exit 0
fi
mkdir -p "$RP_ACTIVE_DIR"
: >"$RP_ACTIVE_DIR/domain-default.list"; : >"$RP_ACTIVE_DIR/domain-policy.list"
printf '%s\n' "${ROUTEPOLICY_INIT_GENERATION:-boot}" >"$RP_ACTIVE_DIR/generation"
rp_render_smartdns90 "$RP_SMARTDNS_FILE"
[ "${ROUTEPOLICY_DNS_DEFER:-0}" = 1 ] || rp_smartdns_set_registration "$RP_SMARTDNS_FILE" 1
printf 'policy_interface=wan2\npolicy_device=eth2\nroute_table=200\n' >"$RP_STATE_DIR/applied"
: >"$TEST_DNS_TMP/policy-running"
[ "${ROUTEPOLICY_DNS_DEFER:-0}" = 1 ] || "$RP_ROOT/etc/init.d/smartdns" reload
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
: >"$TEST_DNS_TMP/native-start-called"
rm -f "$TEST_DNS_TMP/svc/smartdns.absent"
enabled=$(uci -q get 'smartdns.@smartdns[0].enabled' || printf 0)
printf '%s' "$enabled" >"$TEST_DNS_TMP/svc/$service.running"
[ "$enabled" = 1 ] || exit 0
port=$(uci -q get 'smartdns.@smartdns[0].port' || printf 53)
printf '%s' "$port" >"$TEST_DNS_TMP/svc/smartdns.port"
auto=$(uci -q get 'smartdns.@smartdns[0].auto_set_dnsmasq' || printf 1)
uci set "smartdns.@smartdns[0].old_enabled=$enabled"
uci set "smartdns.@smartdns[0].old_port=$port"
uci set "smartdns.@smartdns[0].old_auto_set_dnsmasq=$auto"
uci commit smartdns
if [ "$port" = 53 ] && [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.running")" = 1 ]; then exit 1; fi
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
	printf "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'\nconf-file '/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf'\n"
} >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
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
	start|restart)
		printf 1 >"$TEST_DNS_TMP/svc/dnsmasq.running"
		[ ! -f "$TEST_DNS_TMP/stale-dnsmasq" ] || exit 0
		uci -q get 'dhcp.@dnsmasq[0].port' >"$TEST_DNS_TMP/svc/dnsmasq.port" ;;
	*) exit 1 ;;
esac
EOF
cp "$tmp/root/etc/init.d/dnsmasq" "$tmp/root/etc/init.d/routepolicy"
sed -i 's/dnsmasq/routepolicy/g' "$tmp/root/etc/init.d/routepolicy"
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
	rm -f "$tmp/policy-running" "$tmp/query-fail" "$tmp/policy-fail" "$tmp/kill-stage" "$tmp/queries" "$tmp/service-log" "$tmp/list-fail" "$tmp/delete-fail" "$tmp/delete-race" "$tmp/quiesce-fault" "$tmp/native-start-called" "$tmp/stale-dnsmasq" "$tmp/kill-confirm"
	mkdir -p "$tmp/svc" "$tmp/external" "$tmp/root/etc/smartdns/conf.d" "$tmp/root/proc/sys/kernel/random"
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
# Exercise every enabled/running combination for both pre-existing services.
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
matrix_count=0
if [ "${1:-}" != --boot-smoke ] && [ "${1:-}" != --quiesce-smoke ] && [ "${1:-}" != --lifecycle-smoke ] && [ "${1:-}" != --restore-smoke ]; then
for se in 0 1; do for sr in 0 1; do for de in 0 1; do for dr in 0 1; do
	case "${1:-}:$se$sr$de$dr" in --recovery-smoke:0000|--recovery-smoke:0111|--recovery-smoke:1001|--recovery-smoke:1110) ;; --recovery-smoke:*) continue ;; esac
	baseline "$se" "$sr" "$de" "$dr"; prepare
	"$TX" apply "$token" >/dev/null
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = 1100 ]
	[ "$(wc -l <"$tmp/queries")" = 4 ]
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
printf 'different-boot\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
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
printf 'reboot-after-kill\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
"$TX" recover-startup >/dev/null; restored
# A true conflict also quarantines both native DNS startup entries.
baseline 1 0 1 1; prepare; "$TX" apply "$token" >/dev/null
uci set 'smartdns.@smartdns[0].port=9999'; uci commit smartdns
printf 'reboot-conflict\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
if "$TX" recover-early >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
[ "$(uci -q get 'smartdns.@smartdns[0].port')" = 9999 ]
# Confirmed reboot: cold application cache, sets before DNS, and failure stays closed.
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
active="$tmp/root/etc/routepolicy/state/init-transaction/confirmed-$token"
rm -rf "$tmp/root/tmp/routepolicy"; rm -f "$tmp/policy-running"
printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
printf 'confirmed-reboot\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
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
	printf '%s\n' "$1" >"$tmp/root/proc/sys/kernel/random/boot_id"
	"$TX" recover-early >/dev/null
}
txdir="$tmp/root/etc/routepolicy/state/init-transaction"
origin=$(cat "$txdir/source"); cp -R "$txdir/confirmed-$origin/fields" "$tmp/origin-fields"
prepare
[ "$(cat "$txdir/active")" = "$origin" ]
reboot_services prepared-after-confirm
: >"$tmp/policy-fail"; guard_entry
[ -f "$active/dns-boot-pending" ] && [ "$(cat "$tmp/svc/smartdns.running")" = 0 ]
"$TX" status >"$tmp/active-status"
[ "$(jsonfilter -i "$tmp/active-status" -e '@.phase')" = prepared ]
[ "$(jsonfilter -i "$tmp/active-status" -e '@.active.dns_boot_state')" = retrying ]
rm "$tmp/policy-fail"; : >"$tmp/query-fail"
remaining=30
while [ "$(cat "$active/failed-stage")" != boot-dns-start ]; do
	[ "$remaining" -gt 0 ] || { cat "$tmp/guard.log"; exit 1; }
	sleep 1; remaining=$((remaining-1))
done
[ -f "$active/dns-boot-pending" ] && [ "$(cat "$tmp/svc/smartdns.running")" = 0 ]
rm "$tmp/query-fail"; wait_guard
[ "$(cat "$txdir/current/phase")" = prepared ]
diff -r "$tmp/origin-fields" "$txdir/confirmed-$origin/fields"
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
	active="$txdir/confirmed-$token"; guard_entry; wait_guard
	[ "$(find "$txdir" -maxdepth 1 -type d -name 'confirmed-????????????????????????????????' | wc -l)" = 2 ]
	[ "$(cat "$txdir/confirmed-foreign/keep")" = USER ]
	[ "$(cat "$txdir/source")" = "$origin" ]
	diff -r "$tmp/origin-fields" "$txdir/confirmed-$origin/fields"
done
mv "$txdir/active" "$tmp/active.value"; ln -s "$tmp/active.value" "$txdir/active"
if "$TX" recover-early >/dev/null; then exit 1; fi
[ "$(cat "$tmp/active.value")" = "$token" ]
rm "$txdir/active"; mv "$tmp/active.value" "$txdir/active"
mv "$active" "$tmp/active.record"; ln -s "$tmp/active.record" "$active"
if "$TX" recover-early >/dev/null; then exit 1; fi
rm "$active"; mv "$tmp/active.record" "$active"
printf 'init DNS native WAL: passed (matrix=%s; distinct UCI flag, kill, conflict, pending and confirmed reboot)\n' "$matrix_count"
