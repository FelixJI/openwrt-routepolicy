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
	comment "legacy-snapshot"
	set domain_policy4 { type ipv4_addr; flags timeout; elements = { 1.1.1.1 timeout 1h expires 42m30s } }
	set domain_default4 { type ipv4_addr; flags timeout; elements = { 9.9.9.9 timeout 1h expires 995ms } }
}
TABLE
		;;
	'list set inet routepolicy domain_policy4')
		[ "${TEST_LIVE_SAVE_FAIL:-0}" != 1 ] || exit 1
		printf '%s\n' 'set domain_policy4 { elements = { 1.1.1.1 timeout 1h expires 42m30s } }'
		;;
	'list set inet routepolicy domain_default4')
		printf '%s\n' 'set domain_default4 { elements = { 9.9.9.9 timeout 1h expires 995ms } }'
		;;
	'list set inet routepolicy static_policy4'|'list set inet routepolicy static_default4'|\
	'list chain inet routepolicy prerouting'|'list chain inet routepolicy classify') exit 0 ;;
	'list chain inet routepolicy output') exit 1 ;;
	'-c -f '*) exit 0 ;;
	'-f '*)
		if grep -Fq 'add element inet routepolicy domain_policy4' "$2"; then
			printf '%s\n' LIVE_RESTORE >>"$TEST_NFT_LOG"
			[ "${TEST_LIVE_RESTORE_FAIL:-0}" != 1 ]
		elif grep -Fq 'legacy-snapshot' "$2"; then
			printf '%s\n' ROLLBACK_OLD_TABLE >>"$TEST_NFT_LOG"
			exit 0
		elif grep -Fq 'chain output {' "$2"; then
			printf '%s\n' FULL_APPLY >>"$TEST_NFT_LOG"
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

: >"$tmp/nft.log"
if TEST_LIVE_RESTORE_FAIL=1 TEST_NFT_LOG="$tmp/nft.log" PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null 2>&1; then
	printf 'full apply ignored a live snapshot restore failure\n' >&2; exit 1
fi
grep -Fxq FULL_APPLY "$tmp/nft.log" || { printf 'legacy topology did not use a full nft transaction\n' >&2; exit 1; }
grep -Fxq LIVE_RESTORE "$tmp/nft.log" || { printf 'full nft transaction did not restore its live snapshot\n' >&2; exit 1; }
grep -Fxq ROLLBACK_OLD_TABLE "$tmp/nft.log" || { printf 'live restore failure did not roll back the old nft table\n' >&2; exit 1; }
[ ! -e "$tmp/etc/routepolicy/state/applied" ] || { printf 'failed live restore published applied state\n' >&2; exit 1; }

: >"$tmp/nft.log"
if TEST_LIVE_SAVE_FAIL=1 TEST_NFT_LOG="$tmp/nft.log" PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null 2>&1; then
	printf 'full apply ignored a live snapshot collection failure\n' >&2; exit 1
fi
if grep -Fxq FULL_APPLY "$tmp/nft.log"; then
	printf 'full apply replaced the old table after live snapshot collection failed\n' >&2; exit 1
fi
printf 'live snapshot tests: passed\n'
