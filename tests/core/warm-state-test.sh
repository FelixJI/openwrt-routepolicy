#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-warm-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/routepolicy/state" "$tmp/tmp/routepolicy" "$tmp/proc/sys/kernel/random" "$tmp/bin"
export TEST_WARM_DIR=$tmp ROUTEPOLICY_ROOT=$tmp
export ROUTEPOLICY_LIBEXEC="${TEST_WARM_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}"
export PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH"
tool="$ROUTEPOLICY_LIBEXEC/warm-state"
boot=00000000-0000-4000-8000-000000000001
printf '%s\n' "$boot" >"$tmp/proc/sys/kernel/random/boot_id"
printf '100.00 0.00\n' >"$tmp/proc/uptime"
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list set inet routepolicy domain_policy4') cat "$TEST_WARM_DIR/policy.raw" ;;
	'list set inet routepolicy domain_default4') cat "$TEST_WARM_DIR/default.raw" ;;
	'-c -f '*)
		cp "$3" "$TEST_WARM_DIR/checked"
		[ -z "${TEST_WARM_AFTER_CHECK:-}" ] || printf '%s 0.00\n' "$TEST_WARM_AFTER_CHECK" >"$TEST_WARM_DIR/proc/uptime"
		[ "${TEST_WARM_CHECK_FAIL:-0}" = 0 ] ;;
	'-f '*) cp "$2" "$TEST_WARM_DIR/applied"; [ "${TEST_WARM_APPLY_FAIL:-0}" = 0 ] ;;
	*) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 99\n' >"$tmp/bin/date"
chmod +x "$tmp/bin/nft" "$tmp/bin/date"
printf 'set domain_policy4 {\n type ipv4_addr\n flags timeout\n elements = { 203.0.113.18 timeout 1h expires 1s, 198.51.100.10 timeout 1h expires 42m30s }\n}\n' >"$tmp/policy.raw"
printf 'set domain_default4 { type ipv4_addr; flags timeout; elements = { 192.0.2.19 timeout 1h expires 995ms } }\n' >"$tmp/default.raw"
"$tool" save
policy="$tmp/etc/routepolicy/state/warm-domain_policy4.list"
default="$tmp/etc/routepolicy/state/warm-domain_default4.list"
grep -Fxq "$(printf 'routepolicy-warm-v1\t%s\t100000' "$boot")" "$policy"
grep -Fxq "$(printf 'domain_policy4\t203.0.113.18\t1000')" "$policy"
[ "$(stat -c %a "$policy")" = 600 ]
cp "$policy" "$tmp/policy.good"; cp "$default" "$tmp/default.good"
touch -t 200001010000 "$policy" "$default"
printf '100.20 0.00\n' >"$tmp/proc/uptime"; "$tool" restore
grep -Fxq 'add element inet routepolicy domain_policy4 { 203.0.113.18 timeout 790ms }' "$tmp/applied"
grep -Fxq 'add element inet routepolicy domain_default4 { 192.0.2.19 timeout 785ms }' "$tmp/applied"
printf '100.60 0.00\n' >"$tmp/proc/uptime"; "$tool" restore
grep -Fxq 'add element inet routepolicy domain_policy4 { 203.0.113.18 timeout 390ms }' "$tmp/applied"
printf '101.00 0.00\n' >"$tmp/proc/uptime"; "$tool" restore
if grep -Eq '203.0.113.18|192.0.2.19' "$tmp/applied"; then exit 1; fi

# Validation latency also counts against the stored lifetime.
printf '100.20 0.00\n' >"$tmp/proc/uptime"
TEST_WARM_AFTER_CHECK=100.80 "$tool" restore
grep -Fxq 'add element inet routepolicy domain_policy4 { 203.0.113.18 timeout 190ms }' "$tmp/applied"
grep -Fxq 'add element inet routepolicy domain_policy4 { 203.0.113.18 timeout 790ms }' "$tmp/checked"
printf '100.20 0.00\n' >"$tmp/proc/uptime"; TEST_WARM_AFTER_CHECK=101.20 "$tool" restore
if grep -Eq '203.0.113.18|192.0.2.19' "$tmp/applied"; then exit 1; fi
rm "$tmp/applied"; printf '100.20 0.00\n' >"$tmp/proc/uptime"
TEST_WARM_AFTER_CHECK=99.99 "$tool" restore 2>"$tmp/skipped"
[ ! -e "$tmp/applied" ]; grep -Fq backwards "$tmp/skipped"
for clock in 3000.00 99.99 invalid; do
	rm -f "$tmp/applied"; printf '%s 0.00\n' "$clock" >"$tmp/proc/uptime"; "$tool" restore 2>"$tmp/skipped"
	[ ! -e "$tmp/applied" ]
done
printf '100.20 0.00\n' >"$tmp/proc/uptime"
printf '00000000-0000-4000-8000-000000000002\n' >"$tmp/proc/sys/kernel/random/boot_id"
"$tool" restore 2>"$tmp/skipped"; [ ! -e "$tmp/applied" ]; grep -Fq 'other-boot' "$tmp/skipped"
printf '%s\n' "$boot" >"$tmp/proc/sys/kernel/random/boot_id"
printf '203.0.113.18\n' >"$policy"; : >"$default"
"$tool" restore 2>"$tmp/skipped"; [ ! -e "$tmp/applied" ]; grep -Fq legacy "$tmp/skipped"
for row in 'domain_other 203.0.113.18 1000' 'domain_policy4 999.0.0.1 1000' 'domain_policy4 203.0.113.18 -1' 'domain_policy4 203.0.113.18 1s' 'domain_policy4 203.0.113.18 01000' 'domain_policy4 203.0.113.18 9007199254740992' 'domain_policy4 203.0.113.18 1000 extra' 'delete table inet fw4'; do
	printf 'routepolicy-warm-v1\t%s\t100000\n' "$boot" >"$policy"
	printf '%s\n' "$row" | tr ' ' '\t' >>"$policy"
	"$tool" restore 2>"$tmp/skipped"; [ ! -e "$tmp/applied" ]
done
while read -r version captured; do
	printf '%s\t%s\t%s\ndomain_policy4\t203.0.113.18\t1000\n' "$version" "$boot" "$captured" >"$policy"
	"$tool" restore 2>"$tmp/skipped"; [ ! -e "$tmp/applied" ]
done <<'HEADERS'
routepolicy-warm-v2 100000
routepolicy-warm-v1 -1
routepolicy-warm-v1 0100000
routepolicy-warm-v1 200000
HEADERS
cp "$tmp/policy.good" "$policy"; tail -n 1 "$policy" >"$tmp/duplicate"; cat "$tmp/duplicate" >>"$policy"
"$tool" restore 2>"$tmp/skipped"; [ ! -e "$tmp/applied" ]
rm "$policy"; ln -s "$tmp/policy.good" "$policy"
"$tool" restore 2>"$tmp/skipped"; [ ! -e "$tmp/applied" ]
if "$tool" save; then exit 1; fi
rm "$policy"
cp "$tmp/policy.good" "$policy"; cp "$tmp/default.good" "$default"
for expires in absent 1xs 1s1h 1ms2ms 1.5s; do
	if [ "$expires" = absent ]; then printf 'set x { elements = { 203.0.113.18 timeout 1h } }\n' >"$tmp/policy.raw"
	else printf 'set x { elements = { 203.0.113.18 timeout 1h expires %s } }\n' "$expires" >"$tmp/policy.raw"; fi
	if "$tool" save 2>"$tmp/save-error"; then exit 1; fi
	grep -Fq 'invalid expires' "$tmp/save-error"; cmp "$tmp/policy.good" "$policy"
done
printf 'set x { elements = { 203.0.113.20 expires 1d2h3m4s5ms, 203.0.113.21 expires 0ms } }\n' >"$tmp/policy.raw"
"$tool" save
grep -Fxq "$(printf 'domain_policy4\t203.0.113.20\t93784005')" "$policy"
if grep -Fq 203.0.113.21 "$policy"; then exit 1; fi
if TEST_WARM_CHECK_FAIL=1 "$tool" restore; then exit 1; fi
if TEST_WARM_APPLY_FAIL=1 "$tool" restore; then exit 1; fi
awk 'BEGIN{print "set x { elements = {";for(i=0;i<=4096;i++)printf "%s10.0.%d.%d timeout 1h expires 1s",i?", ":"",int(i/256),i%256;print " } }"}' >"$tmp/policy.raw"
"$tool" save
[ "$(awk -F '\t' '$1=="domain_policy4"{n++}END{print n}' "$policy")" = 4096 ]
"$tool" live-save "$tmp/tmp/routepolicy/large.snapshot"
[ "$(awk -F '\t' '$1=="domain_policy4"{n++}END{print n}' "$tmp/tmp/routepolicy/large.snapshot")" = 4097 ]
printf 'warm-state tests: passed\n'
