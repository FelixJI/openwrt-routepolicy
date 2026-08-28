#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-apply-route-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"; : >"$tmp/ip.log"; : >"$tmp/nft.log"
first_output=$(TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply")
printf '%s\n' "$first_output" | grep -Fq '完整原子事务' || {
	printf 'legacy nft topology did not force a full transaction: %s\n' "$first_output" >&2; exit 1
}
for object in \
	'list set inet routepolicy source_ingress4' \
	'list set inet routepolicy source_egress4' \
	'list chain inet routepolicy prerouting' \
	'list chain inet routepolicy output' \
	'list chain inet routepolicy classify' \
	'list chain inet routepolicy source_prerouting' \
	'list chain inet routepolicy source_postrouting'; do
	grep -Fxq "$object" "$tmp/nft.log" || { printf 'incremental gate did not check %s\n' "$object" >&2; exit 1; }
done
grep -Fq 'route replace table 200 192.0.2.0/24 dev br-test scope link src 192.0.2.1 metric 10' "$tmp/ip.log" || {
	printf 'policy connected route was not installed\n' >&2; cat "$tmp/ip.log" >&2; exit 1;
}
grep -Fq 'policy_cidr=192.0.2.0/24' "$tmp/etc/routepolicy/state/applied"
grep -Fq 'source_accounting=0' "$tmp/etc/routepolicy/state/applied"
grep -Fq 'source_idle_timeout=600' "$tmp/etc/routepolicy/state/applied"
grep -Fq 'source_max_entries=4096' "$tmp/etc/routepolicy/state/applied"

# A topology with every required object is incrementally eligible only while
# the normalized set of managed L3 devices is unchanged. Device changes must
# rebuild the source sets so stale device keys do not survive until timeout.
printf '%s\n' 'managed_devices=br-test' >>"$tmp/etc/routepolicy/state/applied"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
case "${2:-}" in
	'@.l3_device') echo "${TEST_L3_DEVICE:-br-test}" ;;
	'@["ipv4-address"][0].address') echo 192.0.2.1 ;;
	'@["ipv4-address"][0].mask') echo 24 ;;
	'@.up') echo true ;;
esac
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
[ -z "${TEST_NFT_LOG:-}" ] || printf '%s\n' "$*" >>"$TEST_NFT_LOG"
case "$*" in
	'list table inet routepolicy') echo 'table inet routepolicy { }' ;;
	'list set inet routepolicy domain_policy4'|'list set inet routepolicy domain_default4')
		printf 'set x {\n}\n' ;;
	'list set inet routepolicy '*|'list chain inet routepolicy '*) exit 0 ;;
	'-c -f '*|'-f '*) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/jsonfilter" "$tmp/bin/nft"
: >"$tmp/nft.log"
device_change_output=$(TEST_L3_DEVICE=br-next TEST_NFT_LOG="$tmp/nft.log" PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply")
printf '%s\n' "$device_change_output" | grep -Fq '完整原子事务' || {
	printf 'managed-device change did not force a full nft transaction: %s\n' "$device_change_output" >&2; exit 1
}
grep -Fxq 'managed_devices=br-next' "$tmp/etc/routepolicy/state/applied" || {
	printf 'applied state did not publish the normalized managed-device signature\n' >&2; exit 1
}

: >"$tmp/ip.log"
TEST_STRICT=0 TEST_IP_LOG="$tmp/ip.log" PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" >/dev/null
grep -Fq 'route del blackhole default table 200 metric 32760' "$tmp/ip.log" || {
	printf 'disabling strict enforcement did not remove blackhole\n' >&2; cat "$tmp/ip.log" >&2; exit 1;
}

: >"$tmp/ip.log"
TEST_ROUTE_TABLE=201 TEST_RULE_PRIORITY=12001 TEST_MARK=0x200 TEST_MARK_MASK=0x200 \
	TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" teardown >/dev/null
grep -Fq -- '-4 rule del priority 12000 fwmark 0x100/0x100 lookup 200' "$tmp/ip.log" || {
	printf 'teardown did not remove the actually applied rule after UCI identifiers changed\n' >&2; cat "$tmp/ip.log" >&2; exit 1;
}
grep -Fq -- '-4 route flush table 200' "$tmp/ip.log" || {
	printf 'teardown did not flush the actually applied table after UCI identifiers changed\n' >&2; cat "$tmp/ip.log" >&2; exit 1;
}
if grep -Fq -- '-4 route flush table 201' "$tmp/ip.log"; then
	printf 'teardown incorrectly flushed the newly configured, unapplied table\n' >&2; cat "$tmp/ip.log" >&2; exit 1
fi
[ ! -e "$tmp/etc/routepolicy/state/applied" ] || {
	printf 'teardown left a stale applied-state marker\n' >&2; exit 1
}

: >"$tmp/ip.log"; : >"$tmp/nft.log"
no_state_output=$(TEST_NFT_ABSENT=1 TEST_ROUTE_TABLE=201 TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" \
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" teardown)
[ "$no_state_output" = '未发现已应用的 RoutePolicy 状态；保持停用' ] || {
	printf 'empty teardown output was misleading: %s\n' "$no_state_output" >&2
	exit 1
}
if grep -Fq -- '-4 route flush table ' "$tmp/ip.log"; then
	printf 'teardown guessed and flushed a table without an applied ownership record\n' >&2; cat "$tmp/ip.log" >&2; exit 1
fi

printf '%s\n' 'route_table=broken' >"$tmp/etc/routepolicy/state/applied"
: >"$tmp/ip.log"; : >"$tmp/nft.log"
if TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" teardown >/dev/null 2>&1; then
	printf 'teardown unexpectedly accepted a damaged applied ownership record\n' >&2; exit 1
fi
if grep -Fq -- '-4 route flush table ' "$tmp/ip.log"; then
	printf 'teardown guessed and flushed a table from damaged applied state\n' >&2; cat "$tmp/ip.log" >&2; exit 1
fi
[ -f "$tmp/etc/routepolicy/state/applied" ] || {
	printf 'teardown discarded the damaged applied state needed for diagnosis\n' >&2; exit 1
}

rm -f "$tmp/etc/routepolicy/state/applied"
if ln -s missing-target "$tmp/etc/routepolicy/state/applied" 2>/dev/null; then
	: >"$tmp/ip.log"; : >"$tmp/nft.log"
	if TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
		ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
		"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" teardown >/dev/null 2>&1; then
		printf 'teardown unexpectedly accepted a dangling applied-state symlink\n' >&2; exit 1
	fi
	[ -L "$tmp/etc/routepolicy/state/applied" ] || {
		printf 'teardown discarded the dangling state link needed for diagnosis\n' >&2; exit 1
	}
	rm -f "$tmp/etc/routepolicy/state/applied"
fi

cat >"$tmp/etc/routepolicy/state/applied" <<'EOF'
schema=1
route_table=200
rule_priority=12000
mark=0x100
mark_mask=0x100
EOF
: >"$tmp/ip.log"; : >"$tmp/nft.log"
if TEST_IP_RULE_DELETE_FAIL=1 TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" \
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" \
	ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	"$ROOT/routepolicy/files/usr/libexec/routepolicy/apply" teardown >/dev/null 2>&1; then
	printf 'teardown unexpectedly succeeded while an owned rule remained\n' >&2; exit 1
fi
[ -f "$tmp/etc/routepolicy/state/applied" ] || {
	printf 'failed teardown discarded the ownership record needed for retry\n' >&2; exit 1
}
printf 'apply route tests: passed\n'
