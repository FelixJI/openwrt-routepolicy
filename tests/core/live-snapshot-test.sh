#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-live-snapshot-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/routepolicy/state" "$tmp/tmp/routepolicy" "$tmp/bin"

cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list set inet routepolicy domain_policy4')
		cat <<'SET'
set domain_policy4 {
	type ipv4_addr
	flags timeout
	elements = { 1.1.1.1 timeout 1h expires 42m30s,
		8.8.8.8 timeout 1h expires 7s }
}
SET
		;;
	'list set inet routepolicy domain_default4')
		cat <<'SET'
set domain_default4 {
	type ipv4_addr
	flags timeout
	elements = { 9.9.9.9 timeout 1h expires 995ms }
}
SET
		;;
	'-c -f '*) cp "$3" "$TEST_LIVE_CHECK" ;;
	'-f '*) cp "$2" "$TEST_LIVE_APPLY" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/nft"

snapshot="$tmp/tmp/routepolicy/live.nft"
TEST_LIVE_CHECK="$tmp/live.checked" TEST_LIVE_APPLY="$tmp/live.applied" \
	PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/warm-state" live-save "$snapshot"
grep -Fxq 'add element inet routepolicy domain_policy4 { 1.1.1.1 timeout 42m30s }' "$snapshot"
grep -Fxq 'add element inet routepolicy domain_policy4 { 8.8.8.8 timeout 7s }' "$snapshot"
grep -Fxq 'add element inet routepolicy domain_default4 { 9.9.9.9 timeout 995ms }' "$snapshot"
if grep -Fq 'timeout 10m' "$snapshot"; then
	printf 'live snapshot replaced the remaining TTL with the warm-state fallback\n' >&2; exit 1
fi

TEST_LIVE_CHECK="$tmp/live.checked" TEST_LIVE_APPLY="$tmp/live.applied" \
	PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/warm-state" live-restore "$snapshot"
cmp "$snapshot" "$tmp/live.checked"
cmp "$snapshot" "$tmp/live.applied"

mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" \
	"$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
[ -z "${TEST_NFT_LOG:-}" ] || printf '%s\n' "$*" >>"$TEST_NFT_LOG"
case "$*" in
	'list table inet routepolicy')
		cat <<'TABLE'
table inet routepolicy {
	chain prerouting { counter comment "legacy-snapshot"; }
	set domain_policy4 { type ipv4_addr; flags timeout; elements = { 1.1.1.1 timeout 1h expires 42m30s } }
	set domain_default4 { type ipv4_addr; flags timeout; elements = { 9.9.9.9 timeout 1h expires 995ms } }
}
TABLE
		;;
	'list set inet routepolicy domain_policy4')
		[ "${TEST_LIVE_SAVE_FAIL:-0}" != 1 ] || exit 1
		printf '%s\n' 'set domain_policy4 { type ipv4_addr; flags timeout; elements = { 1.1.1.1 timeout 1h expires 42m30s } }'
		;;
	'list set inet routepolicy domain_default4')
		printf '%s\n' 'set domain_default4 { type ipv4_addr; flags timeout; elements = { 9.9.9.9 timeout 1h expires 995ms } }'
		;;
	'list set inet routepolicy static_policy4'|'list set inet routepolicy static_default4'|\
	'list chain inet routepolicy prerouting'|'list chain inet routepolicy classify') exit 0 ;;
	'list chain inet routepolicy output') exit 1 ;;
	'-c -f '*)
		[ -z "${TEST_NFT_CHECK:-}" ] || cp "$3" "$TEST_NFT_CHECK"
		exit 0
		;;
	'-f '*)
		if grep -Fq 'chain output {' "$2" && ! grep -Fq 'set domain_policy4 {' "$2" && ! grep -Fq 'delete table inet routepolicy' "$2"; then
			printf '%s\n' ATOMIC_APPLY >>"$TEST_NFT_LOG"
			[ -z "${TEST_NFT_ATOMIC:-}" ] || cp "$2" "$TEST_NFT_ATOMIC"
			[ "${TEST_LIVE_RESTORE_FAIL:-0}" != 1 ]
		elif grep -Fq 'legacy-snapshot' "$2"; then
			printf '%s\n' ROLLBACK_OLD_TABLE >>"$TEST_NFT_LOG"
			exit 0
		elif grep -Fq 'chain output {' "$2"; then
			printf '%s\n' EMPTY_TABLE_REBUILD >>"$TEST_NFT_LOG"
			exit 0
		else
			exit 0
		fi
		;;
	'delete table inet routepolicy') exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/nft"

# Full rebuild preserves kernel DNS set objects: concurrent inserts and expiry
# continue without a snapshot/reinsert window, even when a chain was missing.
: >"$tmp/nft.log"; rm -f "$tmp/nft.check" "$tmp/nft.atomic"
if TEST_NFT_LOG="$tmp/nft.log" TEST_NFT_CHECK="$tmp/nft.check" TEST_NFT_ATOMIC="$tmp/nft.atomic" \
	PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null 2>&1; then
	:
else
	printf 'full apply with a live snapshot failed\n' >&2; exit 1
fi
grep -Fxq ATOMIC_APPLY "$tmp/nft.log" || { printf 'full transaction did not commit one merged nft batch\n' >&2; exit 1; }
if grep -Fxq EMPTY_TABLE_REBUILD "$tmp/nft.log"; then
	printf 'full transaction rebuilt the policy table without its dynamic members\n' >&2; exit 1
fi
if grep -Fxq ROLLBACK_OLD_TABLE "$tmp/nft.log"; then
	printf 'successful full apply rolled the old table back\n' >&2; exit 1
fi
[ "$(grep -c -- '^-f ' "$tmp/nft.log")" -eq 1 ] || {
	printf 'full apply used %s commit batches instead of one\n' "$(grep -c -- '^-f ' "$tmp/nft.log")" >&2; exit 1
}
[ "$(grep -c -- '^-c -f ' "$tmp/nft.log")" -eq 1 ] || {
	printf 'full apply validated %s batches instead of one\n' "$(grep -c -- '^-c -f ' "$tmp/nft.log")" >&2; exit 1
}
if grep -Eq '(delete|flush) table.*routepolicy|(delete|flush) set.*routepolicy domain_(policy|default)4|set domain_(policy|default)4 \{|add element .*domain_(policy|default)4' "$tmp/nft.atomic"; then
	printf 'full rebuild destroyed or repopulated a live DNS set\n' >&2; exit 1
fi
cmp -s "$tmp/nft.check" "$tmp/nft.atomic" || { printf 'validated batch differed from the committed batch\n' >&2; exit 1; }
[ -e "$tmp/etc/routepolicy/state/applied" ] || { printf 'successful full apply published no state\n' >&2; exit 1; }

# Failure regression: a kernel rejection of the merged batch must fail the
# apply and restore the previous table, never leave a member-less rebuild.
rm -f "$tmp/etc/routepolicy/state/applied"
: >"$tmp/nft.log"; rm -f "$tmp/nft.check" "$tmp/nft.atomic"
if TEST_LIVE_RESTORE_FAIL=1 TEST_NFT_LOG="$tmp/nft.log" TEST_NFT_CHECK="$tmp/nft.check" TEST_NFT_ATOMIC="$tmp/nft.atomic" \
	PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null 2>&1; then
	printf 'full apply ignored the rejected atomic snapshot batch\n' >&2; exit 1
fi
grep -Fxq ATOMIC_APPLY "$tmp/nft.log" || { printf 'legacy topology did not attempt the merged nft batch\n' >&2; exit 1; }
if grep -Fxq EMPTY_TABLE_REBUILD "$tmp/nft.log"; then
	printf 'rejected apply still committed a member-less table rebuild\n' >&2; exit 1
fi
grep -Fxq ROLLBACK_OLD_TABLE "$tmp/nft.log" || { printf 'atomic batch failure did not roll back the old nft table\n' >&2; exit 1; }
[ "$(grep -c -- '^-f ' "$tmp/nft.log")" -eq 2 ] || {
	printf 'expected the rejected merged batch plus rollback only, got %s commits\n' "$(grep -c -- '^-f ' "$tmp/nft.log")" >&2; exit 1
}
cmp -s "$tmp/nft.check" "$tmp/nft.atomic" || { printf 'validated batch differed from the committed batch\n' >&2; exit 1; }
[ ! -e "$tmp/etc/routepolicy/state/applied" ] || { printf 'failed atomic apply published applied state\n' >&2; exit 1; }

: >"$tmp/nft.log"
if TEST_LIVE_SAVE_FAIL=1 TEST_NFT_LOG="$tmp/nft.log" PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null 2>&1; then
	printf 'full apply ignored a live snapshot collection failure\n' >&2; exit 1
fi
if grep -Fxq ATOMIC_APPLY "$tmp/nft.log"; then
	printf 'full apply replaced the old table after live snapshot collection failed\n' >&2; exit 1
fi
printf 'live snapshot tests: passed\n'
