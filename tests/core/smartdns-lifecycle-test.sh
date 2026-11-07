#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
LIBEXEC="${TEST_SMARTDNS_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}"
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
TEST_SMARTDNS_LOG="$log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" >/dev/null
TEST_SMARTDNS_POLICY_GROUP=changed TEST_SMARTDNS_LOG="$log" TEST_UCI_LOG="$tmp/uci.log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" teardown >/dev/null
[ ! -e "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" ]
grep -Fxq reload "$log"

: >"$log"; : >"$tmp/ip.log"; : >"$tmp/nft.log"
TEST_SMARTDNS_LOG="$log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" >/dev/null
cp "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" "$tmp/fragment-before"
if TEST_SMARTDNS_RELOAD_FAIL=1 TEST_SMARTDNS_LOG="$log" TEST_UCI_LOG="$tmp/uci.log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" teardown >/dev/null 2>&1; then
	printf 'teardown ignored native reload failure\n' >&2; exit 1
fi
cmp "$tmp/fragment-before" "$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
grep -Fxq reload "$log"

cp "$tmp/etc/routepolicy/state/applied" "$tmp/receipt-good"
for corruption in duplicate missing-content absent-with-content unknown-key duplicate-schema bad-table bad-mark bad-bootstrap bad-token legacy; do
	cp "$tmp/receipt-good" "$tmp/etc/routepolicy/state/applied"
	case "$corruption" in
		duplicate) printf 'smartdns90_present=1\n' >>"$tmp/etc/routepolicy/state/applied" ;;
		missing-content) sed '/^smartdns90:/d' "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied" ;;
		absent-with-content) sed 's/^smartdns90_present=1$/smartdns90_present=0/' "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied" ;;
		unknown-key) printf 'smartdns90_unknown=1\n' >>"$tmp/etc/routepolicy/state/applied" ;;
		duplicate-schema) printf 'schema=1\n' >>"$tmp/etc/routepolicy/state/applied" ;;
		bad-table) sed 's/^route_table=.*/route_table=999/' "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied" ;;
		bad-mark) sed 's/^mark=.*/mark=0x3/' "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied" ;;
		bad-bootstrap) sed 's/^source_bootstrap=.*/source_bootstrap=invalid/' "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied" ;;
		bad-token) sed 's/^init_generation=.*/init_generation=invalid/' "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied" ;;
		legacy) sed '/^smartdns90/d' "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied" ;;
	esac
	if TEST_SMARTDNS_LOG="$log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" teardown >/dev/null 2>&1; then
		printf 'teardown accepted malformed or unproven fragment receipt: %s\n' "$corruption" >&2; exit 1
	fi
	cmp "$tmp/fragment-before" "$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
done
cp "$tmp/receipt-good" "$tmp/etc/routepolicy/state/applied"

# Older same-boot initialization receipts may use their confirmed exact content.
token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
record="$tmp/etc/routepolicy/state/init-transaction/confirmed/$token"
mkdir -p "$record/origin"
printf '%s\n' "$token" >"$record/token"; printf 'confirmed\n' >"$record/phase"
sed -n 's/^boot_id=//p' "$tmp/receipt-good" >"$record/boot-id"
printf '%s\n' "$token" >"$tmp/etc/routepolicy/state/init-transaction/active"
cp "$tmp/fragment-before" "$record/origin/dns90-new"
sed -e '/^smartdns90/d' -e "s/^init_generation=.*/init_generation=$token/" "$tmp/receipt-good" >"$tmp/etc/routepolicy/state/applied"
TEST_SMARTDNS_POLICY_GROUP=changed TEST_SMARTDNS_LOG="$log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" teardown >/dev/null
[ ! -e "$tmp/etc/smartdns/conf.d/90-routepolicy.conf" ]

printf '%s\n' 'must survive' >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
if TEST_SMARTDNS_RELOAD_FAIL=1 TEST_SMARTDNS_LOG="$log" TEST_UCI_LOG="$tmp/uci.log" TEST_IP_LOG="$tmp/ip.log" TEST_NFT_LOG="$tmp/nft.log" PATH="$ROOT/tests/core/stubs:$PATH" \
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$LIBEXEC/apply" teardown >/dev/null 2>&1; then
	printf '%s\n' 'teardown unexpectedly succeeded after SmartDNS reload failure' >&2
	exit 1
fi
grep -Fxq 'must survive' "$tmp/etc/smartdns/conf.d/90-routepolicy.conf"

printf '%s\n' 'SmartDNS lifecycle tests: passed'
