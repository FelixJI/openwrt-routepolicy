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
		esac
		;;
	export:smartdns)
		[ "${TEST_SMARTDNS_ROOTS:-0}" -gt 0 ] || exit 1
		printf "package smartdns\n\nconfig smartdns 'main'\n\toption enabled '1'\n"
		;;
	batch:) cat >>"$TEST_UCI_LOG" ;;
	import:smartdns) cat >/dev/null; printf '%s\n' import >>"$TEST_UCI_LOG" ;;
	commit:smartdns) printf '%s\n' commit >>"$TEST_UCI_LOG" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/uci"

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

printf '%s\n' 'SmartDNS management tests: passed'
