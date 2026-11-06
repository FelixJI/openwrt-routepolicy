#!/bin/sh
# Exercise official rc.common/procd dispatch without touching host services.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
if [ -z "${TEST_UCI_SDK_ROOT:-}" ]; then
 printf 'native init lock order: skipped (provide official TEST_UCI_SDK_ROOT)\n'
 exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-native-lock.XXXXXX")
cleanup() {
 for job in ${owner_job:-} ${startup_job:-}; do kill "$job" 2>/dev/null || true; done
 for job in ${owner_job:-} ${startup_job:-}; do wait "$job" 2>/dev/null || true; done
 rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
export TEST_NATIVE_LOCK_DIR=$tmp ROUTEPOLICY_ROOT="$tmp/root"
export ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
export TEST_NATIVE_INIT="$ROOT/routepolicy/files/etc/init.d/routepolicy"
export IPKG_INSTROOT="$tmp/root"
mkdir -p "$tmp/bin" "$tmp/root/lib/functions" "$tmp/root/usr/share/libubox" "$tmp/root/var/lock" "$tmp/root/etc/rc.d"
cp "$TEST_UCI_SDK_ROOT/lib/functions/procd.sh" "$tmp/root/lib/functions/procd.sh"
cp "$TEST_UCI_SDK_ROOT/usr/share/libubox/jshn.sh" "$tmp/root/usr/share/libubox/jshn.sh"
# Configuration and ubus are fixture boundaries; native lock/dispatch stay real.
cat >"$tmp/root/lib/functions.sh" <<'EOF'
list_contains() { eval "case \" \$$1 \" in *\" $2 \"*) return 0 ;; *) return 1 ;; esac"; }
config_load() { :; }
config_get_bool() { [ "$1" = enabled ] && enabled=1; }
EOF
: >"$tmp/root/lib/functions/service.sh"
cat >"$tmp/bin/target-ash" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/bin/busybox" ash "$@"
EOF
cat >"$tmp/bin/target-rc" <<'EOF'
#!/bin/sh
exec target-ash "$TEST_UCI_SDK_ROOT/etc/rc.common" "$@"
EOF
cat >"$tmp/bin/jshn" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/usr/bin/jshn" "$@"
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/usr/bin/jsonfilter" "$@"
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_NATIVE_LOCK_DIR/ubus"
EOF
cat >"$tmp/bin/ctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_NATIVE_LOCK_DIR/apply"
EOF
cat >"$tmp/bin/transaction" <<'EOF'
#!/bin/sh
case "$1" in
 boot-pending) exit 1 ;;
 watch-ready) exit 1 ;;
 recover-startup)
  printf '%s\n' "$$" >"$TEST_NATIVE_LOCK_DIR/waiting-pid"
  awk '/^PPid:/{print $2}' "/proc/$$/status" >"$TEST_NATIVE_LOCK_DIR/startup-pid"
  . "$ROUTEPOLICY_LIBEXEC/common"
  operation=recover-startup
  rp_writer_enter init || exit 1
  [ "${TEST_NATIVE_RECOVERY_FAIL:-0}" != 1 ] || exit 42
  printf 'recovered\n' >"$TEST_NATIVE_LOCK_DIR/recovered"
  ;;
 *) exit 1 ;;
esac
EOF
cat >"$tmp/owner" <<'EOF'
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter init || exit 1
printf '%s\n' "$$" >"$TEST_NATIVE_LOCK_DIR/owner-pid"
read -r _go <"$TEST_NATIVE_LOCK_DIR/go"
# The two-second bound makes the old lock inversion deterministic and fast.
rp_native_run 2 target-rc "$TEST_NATIVE_INIT" enable
printf '%s\n' "$?" >"$TEST_NATIVE_LOCK_DIR/enable-rc"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" ROUTEPOLICY_CTL="$tmp/bin/ctl" ROUTEPOLICY_INIT_TRANSACTION="$tmp/bin/transaction" ROUTEPOLICY_WATCH="$tmp/watch"
mkfifo "$tmp/go"
wait_file() {
 remaining=500
 while [ ! -s "$1" ]; do [ "$remaining" -gt 0 ] || { printf 'missing checkpoint: %s\n' "$1" >&2; exit 1; }; sleep 0.01; remaining=$((remaining-1)); done
}
timeout -k 2 12 target-ash "$tmp/owner" >"$tmp/owner.log" 2>&1 & owner_job=$!
wait_file "$tmp/owner-pid"
timeout -k 2 12 target-rc "$TEST_NATIVE_INIT" start >"$tmp/startup.log" 2>&1 & startup_job=$!
wait_file "$tmp/waiting-pid"
owner_pid=$(cat "$tmp/owner-pid"); startup_pid=$(cat "$tmp/startup-pid")
printf 'recovery gate before native enable:\n'
cat "/proc/$owner_pid/fdinfo/9"
if [ -e "/proc/$startup_pid/fd/1000" ]; then
 printf 'startup procd lock before recovery completed:\n'
 cat "/proc/$startup_pid/fdinfo/1000"
else printf 'startup has not acquired procd FD1000 while waiting for recovery\n'; fi
printf 'go\n' >"$tmp/go"
wait "$owner_job"; owner_job=
wait "$startup_job"; startup_job=
printf 'native enable RC=%s\n' "$(cat "$tmp/enable-rc")"
cat "$tmp/owner.log" "$tmp/startup.log"
[ "$(cat "$tmp/enable-rc")" = 0 ] || { printf 'native enable blocked behind startup waiting for the recovery gate\n' >&2; exit 1; }
[ -s "$tmp/recovered" ] && grep -Fxq apply "$tmp/apply"
sed -n 's/^call service set //p' "$tmp/ubus" | jsonfilter -e '@.instances.*.command[0]' >"$tmp/commands"
grep -Fxq "$tmp/watch" "$tmp/commands"
: >"$tmp/apply"; : >"$tmp/ubus"
failure_rc=0
TEST_NATIVE_RECOVERY_FAIL=1 timeout -k 2 5 target-rc "$TEST_NATIVE_INIT" start >"$tmp/failure.log" 2>&1 || failure_rc=$?
[ "$failure_rc" = 42 ] && [ ! -s "$tmp/apply" ] && [ ! -s "$tmp/ubus" ] || { printf 'failed recovery reached native procd/apply/watch (RC=%s)\n' "$failure_rc" >&2; exit 1; }
printf 'native recovery failure RC=%s; no apply/watch dispatch\n' "$failure_rc"
printf 'native init lock order: passed (official rc.common, ash, FD9 and FD1000)\n'
