#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-managed-recovery.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root"
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
. "$LIBEXEC/common"
wal="$RP_STATE_DIR/init-transaction/current"
reset() {
	rm -rf "$tmp/root"
	mkdir -p "$wal" "$RP_MANAGED_CURRENT" "$RP_MANAGED_PREVIOUS" "$tmp/expected"
	printf 'old.example\n' >"$RP_MANAGED_CURRENT/feed.domain-policy.list"
	printf 'unknown old current\n' >"$RP_MANAGED_CURRENT/unknown file.keep"
	printf 'unknown old previous\n' >"$RP_MANAGED_PREVIOUS/unknown.previous"
	printf 'new.example\n' >"$tmp/expected/feed.domain-policy.list"
	rp_managed_prepare "$wal"
	cp -pR "$tmp/expected" "$wal/managed-expected"
	printf 'previous.next.123\n' >"$wal/managed-swap-name"
}
published() {
	mv "$RP_MANAGED_CURRENT" "$RP_ETC/managed.d/previous.next.123"
	cp -pR "$wal/managed-expected" "$RP_MANAGED_CURRENT"
	rm -rf "$RP_MANAGED_PREVIOUS"
	mv "$RP_ETC/managed.d/previous.next.123" "$RP_MANAGED_PREVIOUS"
	rp_managed_phase "$wal" published
}
restored() {
	rp_managed_restore "$wal"
	rp_managed_equal "$RP_MANAGED_CURRENT" "$wal/managed-before-current"
	rp_managed_equal "$RP_MANAGED_PREVIOUS" "$wal/managed-before-previous"
	rp_managed_restore "$wal"
}
reset; restored
reset; rp_managed_phase "$wal" publishing
mv "$RP_MANAGED_CURRENT" "$RP_ETC/managed.d/previous.next.123"; restored
reset; rp_managed_phase "$wal" publishing
mv "$RP_MANAGED_CURRENT" "$RP_ETC/managed.d/previous.next.123"
cp -pR "$wal/managed-expected" "$RP_MANAGED_CURRENT"; restored
reset; published; restored
reset; published; rp_managed_phase "$wal" restoring
mv "$RP_MANAGED_CURRENT" "$wal/managed-displaced-current"; restored
reset; published; rp_managed_phase "$wal" restoring
rm -rf "$RP_MANAGED_CURRENT"; cp -pR "$wal/managed-before-current" "$RP_MANAGED_CURRENT"
mv "$RP_MANAGED_PREVIOUS" "$wal/managed-displaced-previous"; restored
for external in current previous; do
	reset; published
	printf 'external\n' >"$RP_ETC/managed.d/$external/external.keep"
	if rp_managed_restore "$wal"; then printf 'managed recovery overwrote external %s\n' "$external" >&2; exit 1; fi
	grep -Fxq external "$RP_ETC/managed.d/$external/external.keep"
	grep -Fxq new.example "$RP_MANAGED_CURRENT/feed.domain-policy.list"
done
TEST_MANAGED_MV=$(command -v mv); export TEST_MANAGED_MV
mkdir "$tmp/bin"
cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
"$TEST_MANAGED_MV" "$@" || exit $?
for target do :; done
if [ -f "$TEST_MANAGED_KILL" ]; then
	case "$(cat "$TEST_MANAGED_KILL"):$target" in
		swap:*/previous.next.*|current:*/current|retired:*/managed-retired-previous|previous:*/previous) rm "$TEST_MANAGED_KILL"; kill -KILL "$PPID" ;;
	esac
fi
SH
chmod +x "$tmp/bin/mv"
export PATH="$tmp/bin:$PATH" TEST_MANAGED_KILL="$tmp/kill" ROUTEPOLICY_LIBEXEC="$LIBEXEC"
for boundary in swap current retired previous; do
	reset
	rm -rf "$wal/managed-expected"; rm "$wal/managed-swap-name"
	mkdir -p "$ROUTEPOLICY_ROOT/proc"
	printf '100.00 0.00\n' >"$ROUTEPOLICY_ROOT/proc/uptime"; printf '10000\n' >"$wal/uptime-start-cs"
	empty=$(mktemp -d "$RP_ETC/managed.d/candidate.XXXXXX")
	printf '%s\n' "$boundary" >"$TEST_MANAGED_KILL"
	if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; rp_managed_publish "$1" "$2"' routepolicy-empty-publication "$wal" "$empty"; then
		printf 'empty publication kill not reached: %s\n' "$boundary" >&2; exit 1
	fi
	[ ! -e "$TEST_MANAGED_KILL" ]; restored
done
TEST_MANAGED_RM=$(command -v rm); export TEST_MANAGED_RM
cat >"$tmp/bin/rm" <<'SH'
#!/bin/sh
for target do :; done
case "$target" in
 */managed.d/previous)
  if [ "${TEST_MANAGED_PUBLIC_GUARD:-0}" = 1 ]; then "$TEST_MANAGED_RM" "$target/unknown.previous"; kill -KILL "$PPID"; exit 99; fi ;;
 */previous.next.*)
  if [ -f "$TEST_MANAGED_KILL" ]; then "$TEST_MANAGED_RM" "$TEST_MANAGED_KILL" "$target/unknown file.keep"; kill -KILL "$PPID"; exit 99; fi ;;
esac
exec "$TEST_MANAGED_RM" "$@"
SH
chmod +x "$tmp/bin/rm"
reset; rm -rf "$wal/managed-expected"; rm "$wal/managed-swap-name"
mkdir -p "$ROUTEPOLICY_ROOT/proc"; printf '100.00 0.00\n' >"$ROUTEPOLICY_ROOT/proc/uptime"; printf '10000\n' >"$wal/uptime-start-cs"
empty=$(mktemp -d "$RP_ETC/managed.d/candidate.XXXXXX")
TEST_MANAGED_PUBLIC_GUARD=1 rp_managed_publish "$wal" "$empty"
rp_managed_equal "$wal/managed-retired-previous" "$wal/managed-before-previous"
restored
# Cleanup can be killed after partial unlink only after public state is terminal.
reset; rp_managed_phase "$wal" publishing
mv "$RP_MANAGED_CURRENT" "$RP_ETC/managed.d/previous.next.123"
cp -pR "$wal/managed-expected" "$RP_MANAGED_CURRENT"
: >"$TEST_MANAGED_KILL"
if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; rp_managed_restore "$1"' routepolicy-cleanup "$wal"; then printf 'partial cleanup kill missing\n' >&2; exit 1; fi
[ "$(cat "$wal/managed-phase")" = restored ]; restored
printf '%s\n' 'managed WAL recovery: passed (publication/restore rename gaps, idempotence, exact bytes, unknown names, external conflicts)'
printf '%s\n' 'empty snapshot publication: passed (four atomic renames, no public recursive deletion, partial cleanup kill after terminal restore)'
