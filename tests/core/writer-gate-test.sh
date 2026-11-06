#!/bin/sh
# Real writer entry points and kernel flock; routing/DNS commands stay isolated stubs.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-writer.XXXXXX")
cleanup() {
	for active in ${owner:-} ${killed:-} ${timed:-}; do kill "$active" 2>/dev/null || true; done
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
export TEST_WRITER_DIR=$tmp ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib"
export TEST_NFT_ABSENT=1 TEST_NFT_LOG="$tmp/nft.log" TEST_IP_LOG="$tmp/ip.log"
export BASE_WRITER_UCI="$ROOT/tests/core/stubs/uci" BASE_WRITER_NFT="$ROOT/tests/core/stubs/nft"
export REAL_WRITER_RENDER="${TEST_WRITER_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}/render"
mkdir -p "$tmp/bin" "$tmp/root/etc/config" "$tmp/root/etc/init.d" "$tmp/root/etc/routepolicy/user.d" "$tmp/root/etc/routepolicy/managed.d/current" "$tmp/root/etc/routepolicy/managed.d/previous"
cp -R "${TEST_WRITER_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}" "$tmp/lib"
: >"$tmp/root/etc/config/routepolicy"; : >"$tmp/nft.log"; : >"$tmp/native.log"
printf 'initial.example\n' >"$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
cat >"$tmp/lib/render" <<'EOF'
#!/bin/sh
printf '%s\n' "${ROUTEPOLICY_WRITER_OWNER:-none}" >>"$TEST_WRITER_DIR/render-entered"
if [ -f "$TEST_WRITER_DIR/hold-render" ]; then read -r _release <"$TEST_WRITER_DIR/release"; fi
exec "$REAL_WRITER_RENDER" "$@"
EOF
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q export smartdns')
		if [ -f "$TEST_WRITER_DIR/timeout-uci" ]; then rm "$TEST_WRITER_DIR/timeout-uci"; sleep 60; fi ;;
	'-q show routepolicy') printf 'routepolicy.main=main\nroutepolicy.feed=source\n'; exit ;;
	'-q get routepolicy.feed.enabled') printf '1\n'; exit ;;
	'-q get routepolicy.feed.url') printf 'https://example.invalid/list\n'; exit ;;
	'-q get routepolicy.feed.format') printf 'plain-domain\n'; exit ;;
	'-q get routepolicy.feed.target') printf 'domain-policy\n'; exit ;;
	'-q get routepolicy.feed.min_entries') printf '1\n'; exit ;;
	'-q get routepolicy.feed.max_shrink_percent') printf '100\n'; exit ;;
esac
exec "$BASE_WRITER_UCI" "$@"
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
while [ "$1" != --output ]; do shift; done
printf 'updated.example\n' >"$2"
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in '-f '*)
	if [ -f "$TEST_WRITER_DIR/nft-fail" ]; then rm "$TEST_WRITER_DIR/nft-fail"; printf 'controlled nft42\n' >&2; exit 42; fi
	if [ -f "$TEST_WRITER_DIR/nft-hang" ]; then
		printf '%s\n' "$$" >"$TEST_WRITER_DIR/nft-hang-pid"
		trap '' TERM
		sleep 60
		printf 'late write\n' >"$TEST_WRITER_DIR/late-write"
	fi ;;
esac
exec "$BASE_WRITER_NFT" "$@"
EOF
cat >"$tmp/root/etc/init.d/smartdns" <<'EOF'
#!/bin/sh
[ ! -e /proc/self/fd/9 ] && [ -z "${ROUTEPOLICY_WRITER_OWNER:-}" ] && [ -z "${ROUTEPOLICY_WRITER_KIND:-}" ] || exit 71
printf '%s\n' "$*" >>"$TEST_WRITER_DIR/native.log"
mkdir -p "$ROUTEPOLICY_ROOT/var/etc/smartdns"
printf 'conf-file /etc/smartdns/conf.d/90-routepolicy.conf\n' >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
if [ -f "$TEST_WRITER_DIR/late-event" ]; then rm "$TEST_WRITER_DIR/late-event"; "$ROUTEPOLICY_LIBEXEC/apply" event; fi
if [ -f "$TEST_WRITER_DIR/native-background" ]; then
	rm "$TEST_WRITER_DIR/native-background"
	(sleep 2; [ ! -e /proc/self/fd/9 ] && [ -z "${ROUTEPOLICY_WRITER_OWNER:-}" ] && printf 'isolated\n' >"$TEST_WRITER_DIR/background-ok") &
fi
EOF
cat >"$tmp/root/etc/init.d/routepolicy-initguard" <<'EOF'
#!/bin/sh
[ ! -e /proc/self/fd/9 ] && [ -z "${ROUTEPOLICY_WRITER_OWNER:-}" ] || exit 72
exit 0
EOF
chmod +x "$tmp/bin/"* "$tmp/lib/"* "$tmp/root/etc/init.d/"*
export PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH"
apply="$tmp/lib/apply"
wait_file() {
	remaining=200
	while [ ! -s "$1" ]; do [ "$remaining" -gt 0 ] || exit 90; sleep 0.01; remaining=$((remaining-1)); done
}
busy() { if "$@" >"$tmp/busy.out" 2>&1; then printf 'competing writer admitted: %s\n' "$*" >&2; exit 1; fi; }
cat >"$tmp/owner" <<'EOF'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
if command -v rp_writer_enter >/dev/null; then rp_writer_enter init
else mkdir -p "$RP_STATE_DIR/init-transaction"; exec 9>"$RP_STATE_DIR/init-transaction/lock"; flock -n 9; fi
printf 'ready\n' >"$TEST_WRITER_DIR/owner-ready"
read -r _release <"$TEST_WRITER_DIR/release"
ROUTEPOLICY_DNS_DEFER=1 "$ROUTEPOLICY_LIBEXEC/apply"
EOF
chmod +x "$tmp/owner"; mkfifo "$tmp/release"
if [ "${1:-}" = --same-owner-timeout ]; then
	sh -c '
		set -eu
		. "$ROUTEPOLICY_LIBEXEC/common"
		rp_writer_enter init
		rp_local_lock "$RP_RUN_DIR/update.lock"
		: >"$TEST_WRITER_DIR/timeout-uci"
		set +e
		timeout -s KILL 3 "$ROUTEPOLICY_LIBEXEC/apply" >"$TEST_WRITER_DIR/initial-timeout.out" 2>&1
		initial=$?
		set -e
		[ "$initial" = 137 ] && [ -f "$RP_RUN_DIR/apply.lock/owner" ]
		remaining=20
		until rp_writer_idle; do [ "$remaining" -gt 0 ] || exit 1; sleep 0.05; remaining=$((remaining-1)); done
		# Even a dead local owner cannot be reaped while another inherited child survives.
		sleep 1 & descendant=$!
		if ROUTEPOLICY_INIT_RESTORE=1 "$ROUTEPOLICY_LIBEXEC/apply" teardown >/dev/null 2>&1; then exit 1; fi
		[ -f "$RP_RUN_DIR/apply.lock/owner" ]
		wait "$descendant"
		ROUTEPOLICY_INIT_RESTORE=1 "$ROUTEPOLICY_LIBEXEC/apply" teardown >/dev/null
		[ ! -e "$RP_RUN_DIR/apply.lock" ] && [ -f "$RP_RUN_DIR/update.lock/owner" ]
		rp_local_unlock "$RP_RUN_DIR/update.lock"
	'
	printf 'same-owner timeout recovery: passed\n'
	exit 0
fi
if [ "${1:-}" = --dns-defer-only ]; then
	sh -c '
		set -eu
		. "$ROUTEPOLICY_LIBEXEC/common"
		rp_writer_enter init
		mkdir -p "$(dirname "$RP_SMARTDNS_FILE")"
		printf "coordinator-owned\n" >"$RP_SMARTDNS_FILE"
		"$ROUTEPOLICY_LIBEXEC/apply" teardown >/dev/null
		grep -Fxq coordinator-owned "$RP_SMARTDNS_FILE"
		[ ! -s "$TEST_WRITER_DIR/native.log" ]
	'
	ROUTEPOLICY_DNS_DEFER=1 ROUTEPOLICY_INIT_RESTORE=1 "$apply" >/dev/null
	grep -Fxq reload "$tmp/native.log"
	printf 'authenticated internal teardown leaves DNS to coordinator: passed\n'
	exit 0
fi
"$tmp/owner" >"$tmp/owner.out" 2>&1 & owner=$!
wait_file "$tmp/owner-ready"
busy "$apply"; busy "$apply" teardown; busy "$tmp/lib/update"; busy "$tmp/lib/rollback"
[ ! -e "$tmp/render-entered" ] && [ ! -s "$tmp/nft.log" ]
"$apply" event
[ -f "$tmp/root/tmp/routepolicy/events.pending" ]
printf 'go\n' >"$tmp/release"; wait "$owner"; owner=
[ ! -s "$tmp/native.log" ] || { printf 'init-owned apply called native DNS\n' >&2; exit 1; }
printf 'gate-held race and teardown: passed\n'

# A callback during reconciliation becomes a new pending event, not a lost event.
: >"$tmp/late-event"
"$apply" reconcile-event >/dev/null
[ -f "$tmp/root/tmp/routepolicy/events.pending" ]
"$apply" reconcile-event >/dev/null
[ ! -e "$tmp/root/tmp/routepolicy/events.pending" ] && [ ! -e "$tmp/root/tmp/routepolicy/events.inflight" ]
for phase in prepared applying pending rolling_back confirming conflict; do
	printf '%s\n' "$phase" >"$tmp/root/etc/routepolicy/state/init-transaction/current.phase"
	mkdir -p "$tmp/root/etc/routepolicy/state/init-transaction/current"
	mv "$tmp/root/etc/routepolicy/state/init-transaction/current.phase" "$tmp/root/etc/routepolicy/state/init-transaction/current/phase"
	"$apply" event; busy "$apply" reconcile-event
	[ -f "$tmp/root/tmp/routepolicy/events.pending" ]
done
printf confirmed >"$tmp/root/etc/routepolicy/state/init-transaction/current/phase"
: >"$tmp/root/etc/routepolicy/state/init-transaction/current/dns-boot-pending"
busy "$apply" reconcile-event
rm "$tmp/root/etc/routepolicy/state/init-transaction/current/dns-boot-pending"
"$apply" reconcile-event >/dev/null
printf 'late events and nonterminal admission: passed\n'

# Parent death invalidates nested identity but cannot drop another writer's OFD.
: >"$tmp/hold-render"; rm "$tmp/render-entered"
"$apply" >"$tmp/killed.out" 2>&1 & killed=$!
wait_file "$tmp/render-entered"
read -r identity <"$tmp/render-entered"; actual_owner=${identity%:*}
kill -KILL "$actual_owner"; wait "$killed" 2>/dev/null || true; killed=
busy "$apply"; busy "$apply" teardown
rm "$tmp/hold-render"; printf 'go\n' >"$tmp/release"
remaining=100
while ! "$apply" >"$tmp/after-kill.out" 2>&1; do [ "$remaining" -gt 0 ] || { cat "$tmp/after-kill.out"; exit 1; }; sleep 0.05; remaining=$((remaining-1)); done
busy env ROUTEPOLICY_WRITER_OWNER=999999:1 ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_INIT_GENERATION=forged "$apply"
printf 'parent death, stale local marker and forged owner: passed\n'
: >"$tmp/native-background"
"$apply" >/dev/null
"$apply" >/dev/null
wait_file "$tmp/background-ok"

# Directory exchange and both nested apply/compensation paths share the same OFD.
printf 'old.example\n' >"$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
"$tmp/lib/update" >/dev/null
grep -Fxq updated.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
"$tmp/lib/rollback" >/dev/null
grep -Fxq old.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
: >"$tmp/nft-fail"; busy "$tmp/lib/update"
grep -Fxq old.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
printf 'update/rollback nested success and compensation: passed\n'

# A killed invoker leaves a bounded kernel writer holding admission until timeout.
: >"$tmp/nft-hang"
"$apply" >"$tmp/timeout.out" 2>&1 & timed=$!
wait_file "$tmp/nft-hang-pid"
busy "$apply" teardown
kill -KILL "$timed"; wait "$timed" 2>/dev/null || true; timed=
busy "$apply"
read -r hung <"$tmp/nft-hang-pid"
remaining=22
while [ -e "/proc/$hung/fd/9" ]; do [ "$remaining" -gt 0 ] || { printf 'timed writer retained FD9\n' >&2; exit 1; }; sleep 1; remaining=$((remaining-1)); done
rm "$tmp/nft-hang"
"$apply" >/dev/null
[ ! -e "$tmp/late-write" ]
sh "$0" --dns-defer-only
sh "$0" --same-owner-timeout
printf '%s\n' 'writer gate: passed (real apply callers, teardown, events, nested publication, timeout and parent death)'
