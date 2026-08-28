#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-active-catalog-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/init.d" "$tmp/etc/smartdns/conf.d" \
	"$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" \
	"$tmp/etc/routepolicy/managed.d/previous" "$tmp/tmp/routepolicy/active"
: >"$tmp/etc/config/routepolicy"

fail() {
	printf 'active catalog contract failed: %s\n' "$1" >&2
	exit 1
}

cat >"$tmp/etc/init.d/smartdns" <<'EOF'
#!/bin/sh
mkdir -p "$ROUTEPOLICY_ROOT/var/etc/smartdns"
if [ -f "$ROUTEPOLICY_ROOT/etc/smartdns/conf.d/90-routepolicy.conf" ]; then
	printf '%s\n' 'conf-file /etc/smartdns/conf.d/90-routepolicy.conf' >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
else
	: >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
fi
[ "${TEST_SMARTDNS_RELOAD_FAIL:-0}" != 1 ]
EOF
chmod +x "$tmp/etc/init.d/smartdns"

printf '%s\n' old.example >"$tmp/tmp/routepolicy/active/domain-policy.list"
printf '%s\n' old-default.example >"$tmp/tmp/routepolicy/active/domain-default.list"
printf '%s\n' old-generation >"$tmp/tmp/routepolicy/active/generation"
printf '%s\n' new.example >"$tmp/etc/routepolicy/user.d/domain-policy.list"
printf '%s\n' new-default.example >"$tmp/etc/routepolicy/user.d/domain-default.list"
: >"$tmp/ip.log"; : >"$tmp/nft.log"; : >"$tmp/uci.log"

run_apply() {
	TEST_NFT_ABSENT=1 TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" TEST_UCI_LOG="$tmp/uci.log" \
		PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
		"$LIBEXEC/apply"
}

run_apply >/dev/null
grep -Fxq new.example "$tmp/tmp/routepolicy/active/domain-policy.list" || fail 'successful apply did not publish policy domains'
grep -Fxq new-default.example "$tmp/tmp/routepolicy/active/domain-default.list" || fail 'successful apply did not publish default domains'
generation=$(sed -n '1p' "$tmp/tmp/routepolicy/active/generation")
case "$generation" in ''|old-generation|*[!A-Za-z0-9_.-]*|?????????????????????????????????????????????????????????????????*) fail 'successful apply did not publish a valid new generation' ;; esac
grep -Fq '/tmp/routepolicy/active/domain-policy.list' "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" || fail 'SmartDNS still reads render candidates instead of active catalog'
grep -Fq '/tmp/routepolicy/active/domain-default.list' "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" || fail 'SmartDNS default domain-set does not read active catalog'

printf '%s\n' render-only.example >"$tmp/etc/routepolicy/user.d/domain-policy.list"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/render" >/dev/null
grep -Fxq new.example "$tmp/tmp/routepolicy/active/domain-policy.list" || fail 'render-only candidate replaced the active catalog'
[ "$(sed -n '1p' "$tmp/tmp/routepolicy/active/generation")" = "$generation" ] || fail 'render-only candidate changed generation'

printf '%s\n' failed.example >"$tmp/etc/routepolicy/user.d/domain-policy.list"
if TEST_SMARTDNS_RELOAD_FAIL=1 run_apply >/dev/null 2>&1; then
	fail 'apply unexpectedly succeeded after SmartDNS reload failure'
fi
grep -Fxq new.example "$tmp/tmp/routepolicy/active/domain-policy.list" || fail 'failed apply leaked candidate policy domains'
grep -Fxq new-default.example "$tmp/tmp/routepolicy/active/domain-default.list" || fail 'failed apply changed default domains'
[ "$(sed -n '1p' "$tmp/tmp/routepolicy/active/generation")" = "$generation" ] || fail 'failed apply changed active generation'

TEST_NFT_ABSENT=1 TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" TEST_UCI_LOG="$tmp/uci.log" \
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$LIBEXEC/apply" teardown >/dev/null
[ ! -e "$tmp/tmp/routepolicy/active" ] || fail 'successful teardown left an active catalog behind'

printf '%s\n' 'active catalog tests: passed'
