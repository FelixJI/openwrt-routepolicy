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
cat >"$tmp/init-transaction" <<'EOF'
#!/bin/sh
if [ "$1" = boot-pending ]; then [ "${TEST_BOOT_PENDING:-0}" = 1 ]; exit; fi
if [ "$1" = watch-ready ]; then [ "${TEST_WATCH_READY:-0}" = 1 ]; exit; fi
[ "$1" = recover-startup ] || exit 1
printf '%s\n' "$1" >>"$TEST_RECOVERY_LOG"
[ "${TEST_RECOVERY_FAIL:-0}" != 1 ]
EOF
chmod +x "$tmp/init-transaction"

run_start() (
	TEST_ENABLED=$1
	export TEST_ENABLED TEST_LIFECYCLE_LOG="$tmp/lifecycle.log"
	ROUTEPOLICY_CTL="$tmp/routepolicyctl"
	ROUTEPOLICY_WATCH="$tmp/watch"
	ROUTEPOLICY_INIT_TRANSACTION="$tmp/init-transaction"
	export ROUTEPOLICY_CTL ROUTEPOLICY_WATCH ROUTEPOLICY_INIT_TRANSACTION TEST_RECOVERY_LOG="$tmp/recovery.log"
	# The test resolves this repository-owned fixture before sourcing it.
	# shellcheck disable=SC1090
	. "$INIT"
	config_load() { :; }
	config_get_bool() {
		[ "$1" = enabled ] || return 1
		# Consumed by start_service() from the sourced init script.
		# shellcheck disable=SC2034
		enabled=$TEST_ENABLED
	}
	procd_open_instance() { printf '%s\n' open >>"$TEST_LIFECYCLE_LOG"; }
	procd_set_param() { printf '%s\n' "$*" >>"$TEST_LIFECYCLE_LOG"; }
	procd_close_instance() { printf '%s\n' close >>"$TEST_LIFECYCLE_LOG"; }
	start_service "${2:-}"
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

: >"$tmp/lifecycle.log"
if TEST_RECOVERY_FAIL=1 run_start 1 >/dev/null 2>&1; then
	printf '%s\n' 'conflicted startup recovery unexpectedly allowed normal apply/watch' >&2
	exit 1
fi
[ ! -s "$tmp/lifecycle.log" ]
grep -Fxq recover-startup "$tmp/recovery.log"

: >"$tmp/lifecycle.log"
TEST_BOOT_PENDING=1 run_start 1 >/dev/null
if grep -Fxq apply "$tmp/lifecycle.log"; then printf 'S95 bypassed boot coordinator\n' >&2; exit 1; fi
grep -Fxq "command $tmp/watch" "$tmp/lifecycle.log"

if run_start 1 init-confirmed >/dev/null 2>&1; then printf 'unowned watcher admission accepted\n' >&2; exit 1; fi
: >"$tmp/lifecycle.log"; : >"$tmp/recovery.log"
TEST_WATCH_READY=1 run_start 1 init-confirmed >/dev/null
grep -Fxq "command $tmp/watch" "$tmp/lifecycle.log"
if grep -Fxq apply "$tmp/lifecycle.log" || [ -s "$tmp/recovery.log" ]; then printf 'confirmation repeated recovery/apply\n' >&2; exit 1; fi

printf '%s\n' 'init lifecycle tests: passed'
