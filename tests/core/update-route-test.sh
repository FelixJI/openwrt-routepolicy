#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-update-route-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/root/etc/config" "$tmp/root/etc/routepolicy/user.d" \
	"$tmp/root/etc/routepolicy/managed.d/current" "$tmp/root/etc/routepolicy/managed.d/previous" \
	"$tmp/bin"
: >"$tmp/root/etc/config/routepolicy"
printf '%s\n' old.example >"$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = -q ] && shift
case "${1:-}:${2:-}" in
	show:routepolicy) printf '%s\n' 'routepolicy.main=main' 'routepolicy.feed=source' ;;
	show:smartdns) printf '%s\n' 'smartdns.main=smartdns' ;;
	export:smartdns) printf "package smartdns\n\nconfig smartdns 'main'\n" ;;
	get:routepolicy.main.enabled) echo 0 ;;
	get:routepolicy.main.lan_interface) echo lan ;;
	get:routepolicy.main.default_interface) echo wan ;;
	get:routepolicy.main.policy_interface) echo usbwan ;;
	get:routepolicy.main.strict_enforcement|\
	get:routepolicy.main.dns_redirect|\
	get:routepolicy.main.warm_restore|\
	get:routepolicy.main.smartdns_enabled|\
	get:routepolicy.main.auto_update|\
	get:routepolicy.main.update_via_policy_interface) echo 1 ;;
	get:routepolicy.main.route_local_traffic) echo 0 ;;
	get:routepolicy.main.route_table) echo 200 ;;
	get:routepolicy.main.rule_priority) echo 12000 ;;
	get:routepolicy.main.mark|\
	get:routepolicy.main.mark_mask) echo 0x100 ;;
	get:routepolicy.main.smartdns_policy_group) echo policy ;;
	get:routepolicy.main.update_hour) echo 4 ;;
	get:routepolicy.main.update_minute) echo 17 ;;
	get:routepolicy.feed.enabled|\
	get:routepolicy.feed.update_via_policy_interface) echo 1 ;;
	get:routepolicy.feed.url) echo https://example.invalid/list.txt ;;
	get:routepolicy.feed.format) echo plain-domain ;;
	get:routepolicy.feed.target) echo domain-policy ;;
	get:routepolicy.feed.min_entries) echo 1 ;;
	get:routepolicy.feed.max_shrink_percent) echo 100 ;;
	import:*|commit:*|add_list:*|del_list:*) exit 0 ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
case "${2:-}" in
	'@.l3_device') echo br-test ;;
	'@.up') [ "${TEST_POLICY_UP:-1}" = 1 ] && echo true || echo false ;;
	'@.route[@.target="0.0.0.0"].nexthop') echo 192.0.2.254 ;;
	'@["ipv4-address"][0].address') echo 192.0.2.1 ;;
	'@["ipv4-address"][0].mask') echo 24 ;;
esac
EOF

cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$TEST_CURL_LOG"
[ "${TEST_CURL_FAIL:-0}" != 1 ] || exit 22
output=
while [ "$#" -gt 0 ]; do
	if [ "$1" = --output ]; then shift; output=${1:-}; break; fi
	shift
done
[ -n "$output" ] || exit 2
printf '%s\n' new.example >"$output"
EOF
chmod +x "$tmp/bin/uci" "$tmp/bin/jsonfilter" "$tmp/bin/curl"

run_update() {
	TEST_CURL_LOG="$tmp/curl.log" PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" \
		ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
		"$ROOT/routepolicy/files/usr/libexec/routepolicy/update"
}

run_update >/dev/null
grep -Fxq -- '--interface' "$tmp/curl.log"
grep -Fxq 'if!br-test' "$tmp/curl.log" || {
	printf 'policy-bound updater did not use curl if!device fail-closed binding\n' >&2; exit 1
}
grep -Fxq new.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"

printf '%s\n' keep-on-download-failure.example >"$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
if TEST_CURL_FAIL=1 run_update >/dev/null 2>&1; then
	printf 'updater unexpectedly accepted a curl failure\n' >&2; exit 1
fi
grep -Fxq keep-on-download-failure.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list" || {
	printf 'curl failure replaced the current managed list\n' >&2; exit 1
}

printf '%s\n' keep-while-offline.example >"$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
rm -f "$tmp/curl.log"
if TEST_POLICY_UP=0 run_update >/dev/null 2>&1; then
	printf 'updater unexpectedly downloaded while the policy interface was offline\n' >&2; exit 1
fi
[ ! -e "$tmp/curl.log" ] || { printf 'offline updater still invoked curl\n' >&2; exit 1; }
grep -Fxq keep-while-offline.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list" || {
	printf 'offline update replaced the current managed list\n' >&2; exit 1
}
printf 'update route tests: passed\n'
