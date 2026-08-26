#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
INIT="$ROOT/routepolicy/files/etc/init.d/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat >"$tmp/routepolicyctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_LIFECYCLE_LOG"
[ "${TEST_APPLY_FAIL:-0}" != 1 ] || exit 1
printf '%s\n' 'RoutePolicy 配置已成功应用'
EOF
chmod +x "$tmp/routepolicyctl"

run_start() (
	TEST_ENABLED=$1
	export TEST_ENABLED TEST_LIFECYCLE_LOG="$tmp/lifecycle.log"
	ROUTEPOLICY_CTL="$tmp/routepolicyctl"
	ROUTEPOLICY_WATCH="$tmp/watch"
	export ROUTEPOLICY_CTL ROUTEPOLICY_WATCH
	. "$INIT"
	config_load() { :; }
	config_get_bool() {
		[ "$1" = enabled ] || return 1
		enabled=$TEST_ENABLED
	}
	procd_open_instance() { printf '%s\n' open >>"$TEST_LIFECYCLE_LOG"; }
	procd_set_param() { printf '%s\n' "$*" >>"$TEST_LIFECYCLE_LOG"; }
	procd_close_instance() { printf '%s\n' close >>"$TEST_LIFECYCLE_LOG"; }
	start_service
)

: >"$tmp/lifecycle.log"
disabled_output=$(run_start 0)
[ "$disabled_output" = 'RoutePolicy 未启用；已跳过应用并保持停用' ] || {
	printf 'disabled lifecycle output was ambiguous: %s\n' "$disabled_output" >&2
	exit 1
}
[ ! -s "$tmp/lifecycle.log" ] || {
	printf '%s\n' 'disabled lifecycle unexpectedly applied state or registered a watcher' >&2
	exit 1
}

: >"$tmp/lifecycle.log"
enabled_output=$(run_start 1)
[ "$enabled_output" = 'RoutePolicy 配置已成功应用' ] || {
	printf 'enabled lifecycle did not expose apply success: %s\n' "$enabled_output" >&2
	exit 1
}
grep -Fxq apply "$tmp/lifecycle.log"
grep -Fxq "command $tmp/watch" "$tmp/lifecycle.log"

: >"$tmp/lifecycle.log"
if TEST_APPLY_FAIL=1 run_start 1 >/dev/null 2>&1; then
	printf '%s\n' 'failed apply unexpectedly started the service' >&2
	exit 1
fi
if grep -Fq open "$tmp/lifecycle.log"; then
	printf '%s\n' 'failed apply unexpectedly registered a watcher' >&2
	exit 1
fi

printf '%s\n' 'init lifecycle tests: passed'
