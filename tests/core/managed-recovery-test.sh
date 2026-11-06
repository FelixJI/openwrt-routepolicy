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
printf '%s\n' 'managed WAL recovery: passed (publication/restore rename gaps, idempotence, exact bytes, unknown names, external conflicts)'
