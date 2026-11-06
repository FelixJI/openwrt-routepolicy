#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
CTL="$ROOT/routepolicy/files/usr/sbin/routepolicyctl"
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-smartdns-management.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/root/etc/config" "$tmp/root/etc/routepolicy/user.d" "$tmp/root/tmp/routepolicy"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = -q ] && shift
case "${1:-}:${2:-}" in
	show:smartdns)
		case "${TEST_SMARTDNS_ROOTS:-0}" in
			0) exit 1 ;;
			1) printf "smartdns.main=smartdns\nsmartdns.main.enabled='1'\nsmartdns.main.port='6053'\n" ;;
			2) printf "smartdns.main=smartdns\nsmartdns.other=smartdns\n" ;;
			anonymous) printf '%s\n' \
				'smartdns.@smartdns[0]=smartdns' \
				"smartdns.@smartdns[0].enabled='1'" \
				"smartdns.@smartdns[0].port='6053'" \
				'smartdns.@server[0]=server' \
				"smartdns.@server[0].enabled='1'" \
				"smartdns.@server[0].type='udp'" \
				"smartdns.@server[0].ip='1.1.1.1'" \
				"smartdns.@server[0].server_group='default'" \
				'smartdns.@server[1]=server' \
				"smartdns.@server[1].enabled='1'" \
				"smartdns.@server[1].type='udp'" \
				"smartdns.@server[1].ip='9.9.9.9'" \
				"smartdns.@server[1].server_group='policy'" \
				'smartdns.@server[2]=server' \
				"smartdns.@server[2].enabled='1'" \
				"smartdns.@server[2].type='udp'" \
				"smartdns.@server[2].ip='8.8.8.8'" \
				"smartdns.@server[2].server_group='default'" ;;
		esac
		;;
	export:smartdns)
		case "${TEST_SMARTDNS_ROOTS:-0}" in
			0) exit 1 ;;
			anonymous) printf "package smartdns\n\nconfig smartdns\n\toption enabled '1'\n\nconfig server\n\toption ip '1.1.1.1'\n\nconfig server\n\toption ip '9.9.9.9'\n\nconfig server\n\toption ip '8.8.8.8'\n" ;;
			*) printf "package smartdns\n\nconfig smartdns 'main'\n\toption enabled '1'\n" ;;
		esac
		;;
	"get:smartdns.@smartdns[0].enabled") printf '%s\n' 1 ;;
	"get:smartdns.@smartdns[0].port") printf '%s\n' 6053 ;;
	"get:smartdns.@server[0].enabled"|"get:smartdns.@server[1].enabled"|"get:smartdns.@server[2].enabled") printf '%s\n' 1 ;;
	"get:smartdns.@server[0].type"|"get:smartdns.@server[1].type"|"get:smartdns.@server[2].type") printf '%s\n' udp ;;
	"get:smartdns.@server[0].ip") printf '%s\n' 1.1.1.1 ;;
	"get:smartdns.@server[1].ip") printf '%s\n' 9.9.9.9 ;;
	"get:smartdns.@server[2].ip") printf '%s\n' 8.8.8.8 ;;
	"get:smartdns.@server[0].server_group"|"get:smartdns.@server[2].server_group") printf '%s\n' default ;;
	"get:smartdns.@server[1].server_group") printf '%s\n' policy ;;
	"get:smartdns.policy1.interface") printf '%s\n' "${TEST_POLICY1_IFACE:-}" ;;
	"get:smartdns.policy1.addition_arg") printf '%s\n' "${TEST_POLICY1_ADDITION_ARG:-}" ;;
	"get:smartdns.policy1.routepolicy_bound_device") printf '%s\n' "${TEST_POLICY1_BOUND:-}" ;;
	batch:) cat >>"$TEST_UCI_LOG" ;;
	import:smartdns) cat >/dev/null; printf '%s\n' import >>"$TEST_UCI_LOG" ;;
	commit:smartdns) printf '%s\n' commit >>"$TEST_UCI_LOG" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/uci"

cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
[ "${1:-}" = call ] || exit 0
case "${2:-}" in
	network.interface.wan) printf '{"l3_device":"eth0"}\n' ;;
	network.interface.lan) printf '{"l3_device":"br-lan"}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/ubus"

cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
[ "${1:-}" = -e ] || exit 0
case "$2" in
	'@.l3_device') sed -n 's/.*"l3_device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/jsonfilter"

mkdir -p "$tmp/root/etc/init.d"
cat >"$tmp/root/etc/init.d/smartdns" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_SMARTDNS_LOG"
mkdir -p "$ROUTEPOLICY_ROOT/var/etc/smartdns"
printf '%s\n' \
	'conf-file /etc/smartdns/conf.d/90-routepolicy.conf' \
	'conf-file /etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf' \
	>"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
[ "${TEST_SMARTDNS_RELOAD_FAIL:-0}" != 1 ]
EOF
chmod +x "$tmp/root/etc/init.d/smartdns"

out=$(TEST_SMARTDNS_ROOTS=0 PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-status --json)
printf '%s\n' "$out" | grep -Fq '"initialized":false'
printf '%s\n' "$out" | grep -Fq '"root_count":0'
[ ! -s "$tmp/root/etc/config/smartdns" ]

out=$(TEST_SMARTDNS_ROOTS=2 PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-status --json)
printf '%s\n' "$out" | grep -Fq '"ambiguous":true'
printf '%s\n' "$out" | grep -Fq '"root_count":2'

out=$(TEST_SMARTDNS_ROOTS=anonymous PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-status --json)
printf '%s\n' "$out" | grep -Fq '"initialized":true' || {
	printf '%s\n' 'anonymous SmartDNS root was not recognized as initialized' >&2
	exit 1
}
printf '%s\n' "$out" | grep -Fq '"root_count":1'
printf '%s\n' "$out" | grep -Fq '"root":"@smartdns[0]"'
printf '%s\n' "$out" | grep -Fq '"enabled":{"explicit":"1","source":"explicit"}'
printf '%s\n' "$out" | grep -Fq '"id":"@server[1]"'
printf '%s\n' "$out" | grep -Fq '"server_group":"policy"'
version=$(printf '%s\n' "$out" | sed -n 's/.*"version":"\([0-9][0-9]*\)".*/\1/p')
{
	printf 'version\t%s\n' "$version"
	printf '%s\t%s\n' initialize 0 enabled 1 port 5353 \
		'server.@server[1].enabled' 1 'server.@server[1].type' udp \
		'server.@server[1].ip' 9.9.9.10 'server.@server[1].server_group' policy \
		'server.@server[0].delete' 1 'server.@server[2].delete' 1 confirm_danger 1
} | TEST_SMARTDNS_ROOTS=anonymous TEST_UCI_LOG="$tmp/uci.log" PATH="$tmp/bin:$PATH" \
	ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$CTL" smartdns-save --json >"$tmp/anonymous-save.json"
grep -Fq '"ok":true' "$tmp/anonymous-save.json"
: >"$tmp/uci.log"; : >"$tmp/smartdns.log"
mkdir -p "$tmp/root/etc/smartdns/conf.d"
TEST_SMARTDNS_ROOTS=anonymous TEST_UCI_LOG="$tmp/uci.log" TEST_SMARTDNS_LOG="$tmp/smartdns.log" \
	PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-apply --json >"$tmp/anonymous-apply.json"
grep -Fq '"ok":true' "$tmp/anonymous-apply.json"
grep -Fq "set smartdns.@smartdns[0].port='5353'" "$tmp/uci.log"
grep -Fq "set smartdns.@server[1].ip='9.9.9.10'" "$tmp/uci.log"
if grep -Fq 'set smartdns.main=smartdns' "$tmp/uci.log" || grep -Fq 'set smartdns.@server[1]=server' "$tmp/uci.log"; then
	printf '%s\n' 'anonymous SmartDNS apply created or retyped a section' >&2
	exit 1
fi
awk '/delete smartdns\.@server\[2\]/{two=NR} /delete smartdns\.@server\[0\]/{zero=NR} END{exit !(two && zero && two < zero)}' "$tmp/uci.log" || {
	printf '%s\n' 'anonymous SmartDNS servers were not deleted in descending index order' >&2
	exit 1
}

out=$(TEST_SMARTDNS_ROOTS=1 PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-status --json)
version=$(printf '%s\n' "$out" | sed -n 's/.*"version":"\([0-9][0-9]*\)".*/\1/p')
[ -n "$version" ]
if {
	printf 'version\t%s\n' "$version"
	printf '%s\n' 'initialize	0' 'dashboard_enabled	1' 'dashboard_port	6080' 'confirm_danger	1'
} | TEST_SMARTDNS_ROOTS=1 TEST_UCI_LOG="$tmp/uci.log" PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-save --json >/dev/null 2>&1; then
	printf '%s\n' 'missing smartdns-ui unexpectedly allowed dashboard enable' >&2
	exit 1
fi
if {
	printf 'version\t%s\n' "$version"
	printf '%s\n' 'initialize	0' 'server.only.enabled	1' 'server.only.type	udp' 'server.only.ip	1.1.1.1' 'server.only.server_group	default' 'confirm_danger	1'
} | TEST_SMARTDNS_ROOTS=1 TEST_UCI_LOG="$tmp/uci.log" PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-save --json >/dev/null 2>&1; then
	printf '%s\n' 'upstream change unexpectedly emptied the RoutePolicy policy group' >&2
	exit 1
fi
{
	printf 'version\t%s\n' "$version"
	printf '%s\n' 'initialize	0' 'enabled	1' 'port	6053' 'tcp_server	1' \
		'cache_size	-1' 'serve_expired	1' 'rr_ttl_min	600' 'rr_ttl_max	1800' \
		'serve_expired_reply_ttl	3' 'force_aaaa_soa	0' \
		'server.policy1.enabled	1' 'server.policy1.type	https' 'server.policy1.ip	https://dns.example/dns-query' \
		'server.policy1.port	443' 'server.policy1.server_group	policy' 'server.policy1.host_name	dns.example' \
		'server.policy1.http_host	dns.example' 'server.policy1.exclude_default_group	0' \
		'server.policy1.fallback	0' 'server.policy1.proxy	proxy1' 'server.policy1.interface	wan' \
		'server.policy1.set_mark	0x100' 'confirm_danger	1'
} | TEST_SMARTDNS_ROOTS=1 TEST_UCI_LOG="$tmp/uci.log" PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-save --json >"$tmp/save.json"
grep -Fq '"ok":true' "$tmp/save.json"
[ -s "$tmp/root/tmp/routepolicy/smartdns-candidate.tsv" ]
TEST_SMARTDNS_ROOTS=1 PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-validate --json >"$tmp/validate.json"
grep -Fq '"ok":true' "$tmp/validate.json"
grep -Fq '"preview":{"changes":' "$tmp/validate.json"

: >"$tmp/uci.log"; : >"$tmp/smartdns.log"
mkdir -p "$tmp/root/etc/smartdns/conf.d"
: >"$tmp/root/etc/smartdns/conf.d/90-routepolicy.conf"
TEST_SMARTDNS_ROOTS=1 TEST_UCI_LOG="$tmp/uci.log" TEST_SMARTDNS_LOG="$tmp/smartdns.log" \
	PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-apply --json >"$tmp/apply.json"
grep -Fq '"ok":true' "$tmp/apply.json"
grep -Fq "set smartdns.main.port='6053'" "$tmp/uci.log"
grep -Fq "set smartdns.policy1.type='https'" "$tmp/uci.log"
grep -Fq "add_list smartdns.main.conf_files='/etc/smartdns/conf.d/90-routepolicy.conf'" "$tmp/uci.log"
grep -Fq 'serve-expired-reply-ttl 3' "$tmp/root/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf"
grep -Fxq start "$tmp/smartdns.log"
[ ! -e "$tmp/root/tmp/routepolicy/smartdns-candidate.tsv" ]
[ -s "$tmp/root/etc/routepolicy/user.d/local-hosts.list" ] || true

if {
	printf 'version\t%s\n' "$version"
	printf '%s\n' 'initialize	0' 'port	70000'
} | TEST_SMARTDNS_ROOTS=1 PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-save --json >/dev/null 2>&1; then
	printf '%s\n' 'invalid SmartDNS port unexpectedly saved' >&2
	exit 1
fi

# 官方 init 脚本的 load_server 不读取 server.interface，只把 addition_arg 附加到
# server 行；结构化接口字段必须解析为字面设备并通过受管理的 -interface 落地，
# 并随受管值一并持久化私有归属标记 routepolicy_bound_device。
grep -Fq "set smartdns.policy1.addition_arg='-interface eth0'" "$tmp/uci.log" || {
	printf '%s\n' 'structured interface field did not materialize the -interface binding' >&2
	exit 1
}
grep -Fq "set smartdns.policy1.routepolicy_bound_device='-interface eth0'" "$tmp/uci.log" || {
	printf '%s\n' 'managed binding was installed without the private ownership marker' >&2
	exit 1
}

out=$(TEST_SMARTDNS_ROOTS=1 PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-status --json)
version=$(printf '%s\n' "$out" | sed -n 's/.*"version":"\([0-9][0-9]*\)".*/\1/p')
[ -n "$version" ]

# $1=候选接口字段；$2/$3/$4=既有 interface/addition_arg/routepolicy_bound_device
policy1_candidate() {
	printf 'version\t%s\ninitialize\t0\n' "$version"
	printf 'server.policy1.enabled\t1\nserver.policy1.type\thttps\nserver.policy1.ip\thttps://dns.example/dns-query\nserver.policy1.port\t443\nserver.policy1.server_group\tpolicy\nserver.policy1.interface\t%s\n' "${1:-}"
}
policy1_save() {
	TEST_SMARTDNS_ROOTS=1 TEST_POLICY1_IFACE="${2:-}" TEST_POLICY1_ADDITION_ARG="${3:-}" TEST_POLICY1_BOUND="${4:-}" \
		TEST_UCI_LOG="$tmp/uci.log" PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
		"$CTL" smartdns-save --json
}
policy1_apply() {
	: >"$tmp/uci.log"
	TEST_SMARTDNS_ROOTS=1 TEST_POLICY1_IFACE="${1:-}" TEST_POLICY1_ADDITION_ARG="${2:-}" TEST_POLICY1_BOUND="${3:-}" \
		TEST_UCI_LOG="$tmp/uci.log" TEST_SMARTDNS_LOG="$tmp/smartdns.log" \
		PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
		"$CTL" smartdns-apply --json
}
policy1_reject() {
	if policy1_candidate "$1" | policy1_save "$1" "$2" "$3" "$4" >"$tmp/reject.json" 2>"$tmp/reject.err"; then
		printf '%s\n' "binding request '$1' with state '$2|$3|$4' unexpectedly accepted" >&2
		exit 1
	fi
	grep -Fq '"ok":false' "$tmp/reject.json"
	grep -Fq "$5" "$tmp/reject.err"
}

# 重复应用：归属一致的受管绑定不重写（幂等）
policy1_candidate wan | policy1_save wan wan '-interface eth0' '-interface eth0' >"$tmp/save.json"
grep -Fq '"ok":true' "$tmp/save.json"
policy1_apply wan '-interface eth0' '-interface eth0' >"$tmp/apply.json"
grep -Fq '"ok":true' "$tmp/apply.json"
grep -Fq "set smartdns.policy1.interface='wan'" "$tmp/uci.log"
if grep -q 'addition_arg' "$tmp/uci.log" || grep -q 'routepolicy_bound_device' "$tmp/uci.log"; then
	printf '%s\n' 'an already matching managed binding was rewritten on repeated apply' >&2
	exit 1
fi

# 变更逻辑接口：归属一致的整段受管绑定替换为新设备
policy1_candidate lan | policy1_save lan wan '-interface eth0' '-interface eth0' >/dev/null
policy1_apply wan '-interface eth0' '-interface eth0' >/dev/null
grep -Fq "set smartdns.policy1.addition_arg='-interface br-lan'" "$tmp/uci.log"
grep -Fq "set smartdns.policy1.routepolicy_bound_device='-interface br-lan'" "$tmp/uci.log"

# 变更且保留用户前缀：逐字节保留用户参数，仅替换受管后缀
policy1_candidate lan | policy1_save lan wan '-http-host api.example.com -interface eth0' '-http-host api.example.com -interface eth0' >/dev/null
policy1_apply wan '-http-host api.example.com -interface eth0' '-http-host api.example.com -interface eth0' >/dev/null
grep -Fq "set smartdns.policy1.addition_arg='-http-host api.example.com -interface br-lan'" "$tmp/uci.log"
grep -Fq "set smartdns.policy1.routepolicy_bound_device='-http-host api.example.com -interface br-lan'" "$tmp/uci.log"

# 纯用户参数：原样保留并追加受管绑定
policy1_candidate wan | policy1_save wan '' '-exclude-default-group' '' >/dev/null
policy1_apply '' '-exclude-default-group' '' >/dev/null
grep -Fq "set smartdns.policy1.addition_arg='-exclude-default-group -interface eth0'" "$tmp/uci.log"
grep -Fq "set smartdns.policy1.routepolicy_bound_device='-exclude-default-group -interface eth0'" "$tmp/uci.log"

# 清空本应用安装的整段绑定：必须真正删除，不得暗中保留
policy1_candidate '' | policy1_save '' wan '-interface eth0' '-interface eth0' >"$tmp/clear.json"
grep -Fq '"ok":true' "$tmp/clear.json"
policy1_apply wan '-interface eth0' '-interface eth0' >/dev/null
grep -Fxq 'delete smartdns.policy1.interface' "$tmp/uci.log"
grep -Fxq 'delete smartdns.policy1.addition_arg' "$tmp/uci.log"
grep -Fxq 'delete smartdns.policy1.routepolicy_bound_device' "$tmp/uci.log"

# 清空时保留用户前缀：只删除受管后缀与归属标记
policy1_candidate '' | policy1_save '' wan '-http-host api.example.com -interface eth0' '-http-host api.example.com -interface eth0' >/dev/null
policy1_apply wan '-http-host api.example.com -interface eth0' '-http-host api.example.com -interface eth0' >/dev/null
grep -Fq "set smartdns.policy1.addition_arg='-http-host api.example.com'" "$tmp/uci.log"
grep -Fxq 'delete smartdns.policy1.routepolicy_bound_device' "$tmp/uci.log"

# 手写同值但没有归属标记：一律视为用户所有，清空与重复设置都不改写、不认领
policy1_candidate '' | policy1_save '' '' '-interface eth0' '' >"$tmp/foreign-clear.json"
grep -Fq '"ok":true' "$tmp/foreign-clear.json"
policy1_apply '' '-interface eth0' '' >/dev/null
grep -Fxq 'delete smartdns.policy1.interface' "$tmp/uci.log"
if grep -q 'addition_arg' "$tmp/uci.log" || grep -q 'routepolicy_bound_device' "$tmp/uci.log"; then
	printf '%s\n' 'a handwritten same-value binding without the marker was deleted while clearing' >&2
	exit 1
fi
policy1_candidate wan | policy1_save wan '' '-interface eth0' '' >/dev/null
policy1_apply '' '-interface eth0' '' >/dev/null
if grep -q 'addition_arg' "$tmp/uci.log" || grep -q 'routepolicy_bound_device' "$tmp/uci.log"; then
	printf '%s\n' 'a handwritten same-value binding without the marker was claimed by a matching request' >&2
	exit 1
fi

# 无法归属且无法证明安全的既有内容：请求绑定时写前拒绝，且不落候选
policy1_reject wan '' '-exclude-default-group -interface eth9' '' '无法安全合并'
[ ! -e "$tmp/root/tmp/routepolicy/smartdns-candidate.tsv" ]
for unsafe_addition_arg in "can't merge" '-interface' '-interface=eth0' '--interface eth0' '-interface eth0 -interface eth1' 'foo"bar' 'abc #comment' "$(printf 'one\ntwo')"; do
	policy1_reject wan '' "$unsafe_addition_arg" '' '无法安全合并'
done
policy1_reject usbwan '' '' '' '无法解析为合法实际设备'
policy1_reject 'wan;reboot' '' '' '' '必须为空或合法逻辑接口名'

printf '%s\n' '192.168.1.10 nas nas.lan storage.lan' '2001:db8::10 nas6 nas6.lan' | \
	ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$CTL" smartdns-write-local-hosts --json >"$tmp/hosts-write.json"
grep -Fq '"ok":true' "$tmp/hosts-write.json"
ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$CTL" smartdns-read-local-hosts --json >"$tmp/hosts-read.json"
grep -Fq '192.168.1.10 nas nas.lan storage.lan' "$tmp/hosts-read.json"
grep -Fq '2001:db8::10 nas6 nas6.lan' "$tmp/hosts-read.json"
[ -s "$tmp/root/tmp/routepolicy/local-hosts-candidate.list" ]
if printf '%s\n' '192.168.1.10 duplicate' '192.168.1.11 duplicate' | \
	ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$CTL" smartdns-write-local-hosts --json >/dev/null 2>&1; then
	printf '%s\n' 'conflicting local host name unexpectedly accepted' >&2
	exit 1
fi

printf '%s\n' '192.168.1.20 old-host' >"$tmp/root/etc/routepolicy/user.d/local-hosts.list"
out=$(TEST_SMARTDNS_ROOTS=1 TEST_UCI_LOG="$tmp/uci.log" PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-status --json)
version=$(printf '%s\n' "$out" | sed -n 's/.*"version":"\([0-9][0-9]*\)".*/\1/p')
{
	printf 'version\t%s\n' "$version"
	printf '%s\n' 'initialize	0' 'enabled	1' 'port	5353' 'serve_expired_reply_ttl	4' 'confirm_danger	1'
} | TEST_SMARTDNS_ROOTS=1 TEST_UCI_LOG="$tmp/uci.log" PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-save --json >/dev/null
if TEST_SMARTDNS_RELOAD_FAIL=1 TEST_SMARTDNS_ROOTS=1 TEST_UCI_LOG="$tmp/uci.log" TEST_SMARTDNS_LOG="$tmp/smartdns.log" \
	PATH="$tmp/bin:$PATH" ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$CTL" smartdns-apply --json >/dev/null 2>&1; then
	printf '%s\n' 'SmartDNS apply unexpectedly succeeded after reload failure' >&2
	exit 1
fi
grep -Fxq '192.168.1.20 old-host' "$tmp/root/etc/routepolicy/user.d/local-hosts.list"
grep -Fxq import "$tmp/uci.log"
[ -s "$tmp/root/tmp/routepolicy/smartdns-candidate.tsv" ]
[ -s "$tmp/root/tmp/routepolicy/local-hosts-candidate.list" ]

# Initialization's persistent lock and pending phase exclude independent writes.
mkdir -p "$tmp/root/etc/routepolicy/state/init-transaction/current"
for phase in prepared applying pending rolling_back conflict confirming; do
	printf '%s\n' "$phase" >"$tmp/root/etc/routepolicy/state/init-transaction/current/phase"
	if printf 'version\t1\ninitialize\t1\n' | ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$CTL" smartdns-save --json >"$tmp/locked.json"; then exit 1; fi
	grep -Fq '初始化事务' "$tmp/locked.json"
done
printf confirmed >"$tmp/root/etc/routepolicy/state/init-transaction/current/phase"
: >"$tmp/root/etc/routepolicy/state/init-transaction/current/dns-boot-pending"
if printf 'version\t1\ninitialize\t1\n' | ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$CTL" smartdns-save --json >"$tmp/locked.json"; then exit 1; fi
grep -Fq '初始化事务' "$tmp/locked.json"
rm "$tmp/root/etc/routepolicy/state/init-transaction/current/dns-boot-pending"
token=11111111111111111111111111111111
record="$tmp/root/etc/routepolicy/state/init-transaction/confirmed-$token"
mkdir "$record"; printf '%s\n' "$token" >"$record/token"
printf confirmed >"$record/phase"; : >"$record/dns-boot-pending"
printf '%s\n' "$token" >"$tmp/root/etc/routepolicy/state/init-transaction/active"
if printf 'version\t1\ninitialize\t1\n' | ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$CTL" smartdns-save --json >"$tmp/locked.json"; then exit 1; fi
grep -Fq '初始化事务' "$tmp/locked.json"
printf '%s\n' 'SmartDNS management tests: passed'
