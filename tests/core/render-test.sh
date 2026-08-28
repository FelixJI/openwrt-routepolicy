#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-render-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"
grep -Fq "option route_local_traffic '0'" "$ROOT/routepolicy/files/etc/config/routepolicy" || {
	printf 'route_local_traffic is not disabled in the shipped defaults\n' >&2; exit 1
}
printf '8.8.8.8\n203.0.113.1\n' >"$tmp/etc/routepolicy/user.d/ipv4-policy.list"
printf 'example.com\n' >"$tmp/etc/routepolicy/user.d/domain-policy.list"
printf '%s\n' '192.168.1.10 nas nas.lan storage.lan' '2001:db8::10 nas6 nas6.lan' >"$tmp/etc/routepolicy/user.d/local-hosts.list"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/render" >/dev/null
rules="$tmp/tmp/routepolicy/rules.nft"; smartdns="$tmp/tmp/routepolicy/90-routepolicy.conf"
grep -Fq 'table inet routepolicy' "$rules"
grep -Fq 'chain prerouting {' "$rules"
grep -Fq 'type filter hook prerouting priority mangle; policy accept;' "$rules"
grep -Fq 'chain output {' "$rules"
grep -Fq 'type route hook output priority mangle; policy accept;' "$rules"
grep -Fq 'chain classify {' "$rules"
grep -Fq 'counter return comment "routepolicy: local IPv4 routing disabled"' "$rules"
if awk '/chain output \{/{inside=1;next} inside && /^\t}/{exit} inside && /jump classify/{found=1} END{exit found ? 0 : 1}' "$rules"; then
	printf 'disabled OUTPUT adapter still reached the shared classifier\n' >&2; exit 1
fi
grep -Fq 'jump classify comment "routepolicy: classify LAN destination"' "$rules"
grep -Fq 'ct mark set (ct mark & 0xfffffeff) | 0x100' "$rules"
grep -Fq '192.0.2.0/24' "$rules"; grep -Fq '203.0.113.0/24' "$rules"
grep -Fq '8.8.8.8' "$rules"
if grep -Fq '203.0.113.1' "$rules"; then printf 'reserved fixture address reached nft elements\n' >&2; exit 1; fi
grep -Fq 'nftset-timeout yes' "$smartdns"
if grep -Eq '^[[:space:]]*server[[:space:]]' "$smartdns"; then printf 'SmartDNS upstream was generated\n' >&2; exit 1; fi
if grep -Fq -- '-no-serve-expired' "$smartdns"; then
	printf 'RoutePolicy domain rules overrode the global serve-expired setting\n' >&2
	exit 1
fi
grep -Fq 'hosts-file /etc/routepolicy/user.d/local-hosts.list' "$smartdns"
grep -Fq 'expand-ptr-from-address yes' "$smartdns"
grep -Fq 'address /nas/192.168.1.10' "$smartdns"
grep -Fq 'address /nas6/2001:db8::10' "$smartdns"

# UCI is a system boundary. Override only the new option and keep the existing
# fixture behavior for every other query.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/uci" <<EOF
#!/bin/sh
if [ "\${1:-}" = -q ] && [ "\${2:-}" = get ] && [ "\${3:-}" = routepolicy.main.route_local_traffic ]; then
	[ "\${TEST_ROUTE_LOCAL_MISSING:-0}" != 1 ] || exit 1
	printf '%s\\n' "\${TEST_ROUTE_LOCAL_TRAFFIC:-0}"
	exit 0
fi
exec "$ROOT/tests/core/stubs/uci" "\$@"
EOF
chmod +x "$tmp/bin/uci"
TEST_ROUTE_LOCAL_TRAFFIC=1 PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/render" >/dev/null
established_line=$(grep -nF 'ct state established,related ct mark & 0x100 != 0' "$rules" | sed -n '1s/:.*//p')
socket_line=$(grep -nF 'ct state new meta mark & 0x100 != 0' "$rules" | sed -n '1s/:.*//p')
classify_line=$(grep -nF 'jump classify comment "routepolicy: classify local destination"' "$rules" | sed -n '1s/:.*//p')
[ -n "$established_line" ] && [ -n "$socket_line" ] && [ -n "$classify_line" ] && \
	[ "$established_line" -lt "$socket_line" ] && [ "$socket_line" -lt "$classify_line" ] || {
	printf 'enabled OUTPUT adapter does not preserve established/socket marks before classification\n' >&2; exit 1
}
grep -Fq 'meta mark set (meta mark & 0xfffffeff) | 0x100 return comment "routepolicy: restore local connection mark"' "$rules"
grep -Fq 'ct mark set (ct mark & 0xfffffeff) | 0x100 return comment "routepolicy: preserve local socket mark"' "$rules"
grep -Fq 'ct mark & 0x100 == 0 meta mark set meta mark & 0xfffffeff comment "routepolicy: clear default connection mark"' "$rules"
if grep -Eq 'comment "[^"]+"[[:space:]]+(return|accept|drop)' "$rules"; then
	printf 'a verdict was emitted after a rule comment\n' >&2; exit 1
fi
if grep -Fq '| (ct mark &' "$rules" || grep -Fq '| (meta mark &' "$rules"; then
	printf 'a mark assignment used a non-constant bitwise-or operand\n' >&2; exit 1
fi
for comment in \
	'routepolicy: excluded destination' \
	'routepolicy: dynamic default override' \
	'routepolicy: static default override' \
	'routepolicy: dynamic policy' \
	'routepolicy: static policy'; do
	count=$(grep -Fc "comment \"$comment\"" "$rules")
	[ "$count" -eq 1 ] || { printf 'shared classifier rule was duplicated for %s\n' "$comment" >&2; exit 1; }
done
status_json=$(ROUTEPOLICY_OUTPUT=json TEST_ROUTE_LOCAL_TRAFFIC=1 PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/status")
printf '%s\n' "$status_json" | grep -Fq '"route_local_traffic":true' || {
	printf 'status did not expose the effective local-routing switch\n' >&2; exit 1
}
printf '8.8.8.8\n' >"$tmp/etc/routepolicy/user.d/ipv4-policy.list"
TEST_ROUTE_LOCAL_MISSING=1 PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/validate" >/dev/null || {
	printf 'an upgraded config without route_local_traffic did not retain the disabled default\n' >&2; exit 1
}
invalid_value=$(TEST_ROUTE_LOCAL_TRAFFIC=2 "$tmp/bin/uci" -q get routepolicy.main.route_local_traffic)
[ "$invalid_value" = 2 ] || { printf 'route_local_traffic UCI fixture returned <%s> instead of <2>\n' "$invalid_value" >&2; exit 1; }
if TEST_ROUTE_LOCAL_TRAFFIC=2 PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/validate" >/dev/null 2>&1; then
	printf 'validation accepted a non-boolean route_local_traffic value\n' >&2; exit 1
fi
printf 'render tests: passed\n'
