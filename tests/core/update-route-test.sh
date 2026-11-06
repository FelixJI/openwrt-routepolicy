#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-update-route-tests.XXXXXX")
trap '[ -z "${owner:-}" ] || kill "$owner" 2>/dev/null || true; rm -rf "$tmp"' EXIT HUP INT TERM
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
	get:routepolicy.main.enabled) echo "${TEST_UPDATE_ENABLED:-0}" ;;
	get:routepolicy.main.auto_update) echo "${TEST_UPDATE_AUTO:-1}" ;;
	get:routepolicy.main.lan_interface) echo lan ;;
	get:routepolicy.main.default_interface) echo wan ;;
	get:routepolicy.main.policy_interface) echo "${TEST_UPDATE_POLICY:-usbwan}" ;;
	get:routepolicy.main.strict_enforcement|\
	get:routepolicy.main.dns_redirect|\
	get:routepolicy.main.warm_restore|\
	get:routepolicy.main.smartdns_enabled|\
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
printf 'download\n' >>"$TEST_CURL_LOG.calls"
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
		ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="${TEST_UPDATE_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}" \
		"${TEST_UPDATE_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}/update" "$@"
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

# Exercise the real watch, update and validation; only download/runtime application are isolated.
cp -R "${TEST_UPDATE_REAL_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}" "$tmp/scheduled-lib"
cat >"$tmp/scheduled-lib/apply" <<'EOF'
#!/bin/sh
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter apply
EOF
TEST_REAL_DATE=$(command -v date)
export TEST_REAL_DATE
cat >"$tmp/bin/date" <<'EOF'
#!/bin/sh
case "$*" in
	+%Y-%m-%d) printf '2026-11-06\n' ;;
	+%H) printf '04\n' ;;
	+%M) printf '%s\n' "${TEST_UPDATE_MINUTE:-17}" ;;
	*) exec "$TEST_REAL_DATE" "$@" ;;
esac
EOF
chmod +x "$tmp/scheduled-lib/apply" "$tmp/bin/date"
export TEST_UPDATE_LIBEXEC="$tmp/scheduled-lib" TEST_UPDATE_ENABLED=1
export TEST_CURL_LOG="$tmp/curl.log" PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH"
export ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/scheduled-lib"
day="$tmp/root/etc/routepolicy/state/last-update-attempt-day"
rm -f "$tmp/curl.log.calls"
TEST_UPDATE_MINUTE=16 run_update scheduled >/dev/null
TEST_UPDATE_AUTO=0 run_update scheduled >/dev/null
TEST_UPDATE_ENABLED=0 run_update scheduled >/dev/null
[ ! -e "$day" ] && [ ! -e "$tmp/curl.log.calls" ]
if ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_WRITER_OWNER=999999:1 run_update scheduled >"$tmp/invalid-owner" 2>&1; then exit 1; fi
grep -Fq 'writer owner 已失效' "$tmp/invalid-owner"
[ ! -e "$day" ]
watch_once() {
	result=0
	timeout -k 1 2 "$tmp/scheduled-lib/watch" || result=$?
	[ "$result" = 124 ]
}
mkfifo "$tmp/release"
export TEST_UPDATE_TMP=$tmp
sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; rp_writer_enter init || exit 1; printf ready >"$TEST_UPDATE_TMP/gate-ready"; read -r release <"$TEST_UPDATE_TMP/release"' &
owner=$!
remaining=100
while [ ! -s "$tmp/gate-ready" ]; do [ "$remaining" -gt 0 ] || exit 1; sleep 0.01; remaining=$((remaining-1)); done
watch_once
[ ! -e "$day" ] && [ ! -e "$tmp/curl.log.calls" ]
grep -Fq '写入门禁忙' "$tmp/root/tmp/routepolicy/scheduled-update.log"
grep -Fq 'scheduled update failed' "$tmp/root/etc/routepolicy/state/last-error"
printf 'release\n' >"$tmp/release"; wait "$owner"; owner=
watch_once
[ "$(cat "$day")" = 2026-11-06 ] && [ "$(wc -l <"$tmp/curl.log.calls")" = 1 ]
grep -Fxq new.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
watch_once
[ "$(wc -l <"$tmp/curl.log.calls")" = 1 ]
run_update >/dev/null
[ "$(wc -l <"$tmp/curl.log.calls")" = 2 ]

# Actual validation/download failures consume one admitted daily attempt, as before.
rm "$day"
TEST_CURL_FAIL=1 watch_once
[ "$(cat "$day")" = 2026-11-06 ] && [ "$(wc -l <"$tmp/curl.log.calls")" = 3 ]
grep -Fq '下载失败' "$tmp/root/tmp/routepolicy/scheduled-update.log"
TEST_CURL_FAIL=1 watch_once
[ "$(wc -l <"$tmp/curl.log.calls")" = 3 ]
grep -Fq '下载失败' "$tmp/root/tmp/routepolicy/scheduled-update.log"
rm "$day"
TEST_UPDATE_POLICY='bad interface' watch_once
[ "$(cat "$day")" = 2026-11-06 ] && [ "$(wc -l <"$tmp/curl.log.calls")" = 3 ]
grep -Fq '更新前校验失败' "$tmp/root/tmp/routepolicy/scheduled-update.log"

rm "$day"
watch_once >"$tmp/concurrent-one" 2>&1 & first=$!
watch_once >"$tmp/concurrent-two" 2>&1 & second=$!
wait "$first"; wait "$second"
[ "$(cat "$day")" = 2026-11-06 ] && [ "$(wc -l <"$tmp/curl.log.calls")" = 4 ]
run_update scheduled >/dev/null
[ "$(wc -l <"$tmp/curl.log.calls")" = 4 ]
printf 'scheduled update admission: passed (held gate retry, concurrent daily claim, validation/download failure limit, manual update)\n'
