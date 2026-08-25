#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-smartdns-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/init.d" "$tmp/etc/smartdns/conf.d" \
	"$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" \
	"$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"

cat >"$tmp/etc/init.d/smartdns" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_SMARTDNS_LOG"
mkdir -p "$ROUTEPOLICY_ROOT/var/etc/smartdns"
if [ -f "$ROUTEPOLICY_ROOT/etc/smartdns/conf.d/90-routepolicy.conf" ]; then
	printf '%s\n' 'conf-file /etc/smartdns/conf.d/90-routepolicy.conf' >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
else
	: >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
fi
[ "${TEST_SMARTDNS_RELOAD_FAIL:-0}" != 1 ]
EOF
chmod +x "$tmp/etc/init.d/smartdns"

log="$tmp/smartdns.log"
: >"$log"; : >"$tmp/ip.log"; : >"$tmp/nft.log"; : >"$tmp/uci.log"
printf '%s\n' 'old fragment' >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
TEST_SMARTDNS_ENABLED=0 TEST_SMARTDNS_LOG="$log" TEST_UCI_LOG="$tmp/uci.log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" >/dev/null
[ ! -e "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" ]
grep -Fxq reload "$log"
grep -Fq 'del_list smartdns.main.conf_files=/etc/smartdns/conf.d/90-routepolicy.conf' "$tmp/uci.log"

: >"$log"; : >"$tmp/ip.log"; : >"$tmp/nft.log"
printf '%s\n' 'active fragment' >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
TEST_SMARTDNS_LOG="$log" TEST_UCI_LOG="$tmp/uci.log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" teardown >/dev/null
[ ! -e "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" ]
grep -Fxq reload "$log"

: >"$log"; : >"$tmp/ip.log"; : >"$tmp/nft.log"
printf '%s\n' 'must survive' >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
if TEST_SMARTDNS_RELOAD_FAIL=1 TEST_SMARTDNS_LOG="$log" TEST_UCI_LOG="$tmp/uci.log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" teardown >/dev/null 2>&1; then
	printf '%s\n' 'teardown unexpectedly succeeded after SmartDNS reload failure' >&2
	exit 1
fi
grep -Fxq 'must survive' "$tmp/etc/smartdns/conf.d/90-routepolicy.conf"

printf '%s\n' 'SmartDNS lifecycle tests: passed'
