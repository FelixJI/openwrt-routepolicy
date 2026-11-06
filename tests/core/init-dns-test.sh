#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
REAL_LIB="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-dns.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export TEST_DNS_TMP=$tmp ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_OUTPUT=json
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/root/etc/config" "$tmp/root/etc/init.d" "$tmp/root/usr/sbin"
cp "$REAL_LIB/common" "$REAL_LIB/init-dns" "$REAL_LIB/init-transaction" "$tmp/lib/"
cp -R "$REAL_LIB/converters" "$tmp/lib/"
chmod +x "$tmp/lib/"*
# The parser must preserve anonymous roots, list ordering, spaces and quotes.
. "$tmp/lib/common"
printf "config smartdns\n\tlist conf_files '/etc/one'\n\tlist conf_files 'two words'\n" >"$tmp/list.uci"
[ "$(rp_uci_field_data '@smartdns[0]' conf_files <"$tmp/list.uci")" = "$(printf 'list\t/etc/one|two words')" ]
printf "config smartdns 'root'\n\toption label 'can'\\\\''t'\n" >"$tmp/quote.uci"
[ "$(rp_uci_field_data root label <"$tmp/quote.uci")" = "$(printf "scalar\tcan't")" ]
printf "config smartdns\n\tlist conf_files 'ambiguous|value'\n" >"$tmp/bad.uci"
if rp_uci_field_data '@smartdns[0]' conf_files <"$tmp/bad.uci"; then exit 1; fi

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
EOF
cat >"$tmp/bin/sync" <<'EOF'
#!/bin/sh
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
		running=false; [ "$(cat "$TEST_DNS_TMP/svc/$service.running")" != 1 ] || running=true
		printf '{"%s":{"instances":{"main":{"running":%s}}}}\n' "$service" "$running" ;;
	service:delete) printf 0 >"$TEST_DNS_TMP/svc/smartdns.running" ;;
	network.interface.wan:status|network.interface.wan2:status)
		device=eth1; [ "$2" != network.interface.wan2 ] || device=eth2
		printf '{"up":true,"l3_device":"%s","dns-server":["192.0.2.53"],"route":[{"target":"0.0.0.0","nexthop":"198.51.100.1"}]}\n' "$device" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/netstat" <<'EOF'
#!/bin/sh
[ "$(cat "$TEST_DNS_TMP/svc/smartdns.running")" = 1 ] || exit 0
printf '%s\n' 'tcp 0 0 0.0.0.0:53 0.0.0.0:* LISTEN 101/smartdns' 'udp 0 0 0.0.0.0:53 0.0.0.0:* 101/smartdns'
EOF
cat >"$tmp/bin/dig" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DNS_TMP/queries"
if [ -f "$TEST_DNS_TMP/query-fail" ]; then printf ';; ->>HEADER<<- status: SERVFAIL, id: 1\n'
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
	start|reload) ;;
	*) exit 1 ;;
esac
enabled=$(uci -q get 'smartdns.@smartdns[0].enabled' || printf 0)
printf '%s' "$enabled" >"$TEST_DNS_TMP/svc/$service.running"
[ "$enabled" = 1 ] || exit 0
port=$(uci -q get 'smartdns.@smartdns[0].port' || printf 53)
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
	start) printf 1 >"$TEST_DNS_TMP/svc/dnsmasq.running" ;;
	*) exit 1 ;;
esac
EOF
cp "$tmp/root/etc/init.d/dnsmasq" "$tmp/root/etc/init.d/routepolicy"
sed -i 's/dnsmasq/routepolicy/g' "$tmp/root/etc/init.d/routepolicy"
for service in network firewall odhcpd routepolicy-initguard routepolicy-prerecover; do printf '#!/bin/sh\nexit 0\n' >"$tmp/root/etc/init.d/$service"; done
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
	rm -f "$tmp/policy-running" "$tmp/query-fail" "$tmp/policy-fail" "$tmp/kill-stage" "$tmp/queries" "$tmp/service-log"
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
matrix_count=0
if [ "${1:-}" != --boot-smoke ]; then
for se in 0 1; do for sr in 0 1; do for de in 0 1; do for dr in 0 1; do
	baseline "$se" "$sr" "$de" "$dr"; prepare
	"$TX" apply "$token" >/dev/null
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = 1100 ]
	[ "$(wc -l <"$tmp/queries")" = 4 ]
	[ "$(cat "$tmp/svc/routepolicy.enabled")" = 1 ]
	"$TX" recover >/dev/null; restored
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = "$se$sr$de$dr" ]
done; done; done; done
matrix_count=16
fi
baseline 0 0 1 1; prepare; : >"$tmp/query-fail"
if "$TX" apply "$token" >/dev/null; then printf 'SERVFAIL was accepted\n' >&2; exit 1; fi
restored
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
rm -rf "$tmp/root/tmp/routepolicy"; rm -f "$tmp/policy-running"
printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
printf 'confirmed-reboot\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
: >"$tmp/policy-fail"
if "$TX" boot-dns >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")" = 00 ]
rm "$tmp/policy-fail"
"$TX" boot-dns >/dev/null
[ -f "$tmp/policy-running" ]
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 1100 ]
[ "$(cat "$tmp/root/etc/smartdns/user.cache")" = USER-CACHE ]
[ ! -f "$tmp/root/etc/routepolicy/state/init-transaction/current/dns-boot-pending" ]
printf 'init DNS native WAL: passed (matrix=%s; distinct UCI flag, kill, conflict, pending and confirmed reboot)\n' "$matrix_count"
