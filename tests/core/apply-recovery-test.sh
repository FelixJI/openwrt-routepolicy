#!/bin/sh
# The real inherited flock admits recovery; kernel commands remain isolated.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-apply-recovery.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
export TEST_RECOVERY_DIR=$tmp BASE_RECOVERY_UCI="$ROOT/tests/core/stubs/uci" BASE_RECOVERY_IP="$ROOT/tests/core/stubs/ip"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >>"$TEST_RECOVERY_DIR/commands"
case "$*" in
 '-4 rule show'|'-4 -N rule show')
  case "$(cat "$TEST_RECOVERY_DIR/scenario")" in
   priority) echo '12000: from all lookup 201' ;;
   reference) echo '12001: from all lookup 200' ;;
   rules-error) exit 2 ;;
   rules-malformed) echo 'unexpected diagnostic' ;;
  esac ;;
 '-4 route show table 200')
  case "$(cat "$TEST_RECOVERY_DIR/scenario")" in
   route) echo 'default via 192.0.2.1 dev eth0' ;;
   route-error) echo 'RTNETLINK answers: Operation not permitted' >&2; exit 2 ;;
   wrong-rc) printf 'Error: ipv4: FIB table does not exist.\nDump terminated\n' >&2; exit 1 ;;
   mixed-error) printf 'Error: ipv4: FIB table does not exist.\nUnexpected failure\n' >&2; exit 2 ;;
   *) printf 'Error: ipv4: FIB table does not exist.\nDump terminated\n' >&2; exit 2 ;;
  esac ;;
 *) exec "$BASE_RECOVERY_IP" "$@" ;;
esac
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$TEST_RECOVERY_DIR/commands"
case "$*" in
 'list table inet routepolicy') [ "$(cat "$TEST_RECOVERY_DIR/scenario")" = nft ] ;;
 'list tables')
  case "$(cat "$TEST_RECOVERY_DIR/scenario")" in nft-error) exit 2 ;; nft) echo 'table inet routepolicy' ;; *) echo 'table inet fw4' ;; esac ;;
esac
EOF
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
exec "$BASE_RECOVERY_UCI" "$@"
EOF
cat >"$tmp/owner" <<'EOF'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter init
ROUTEPOLICY_INIT_RESTORE=1 ROUTEPOLICY_INIT_GENERATION="$(cat "$RP_STATE_DIR/init-transaction/current/token")" "$ROUTEPOLICY_LIBEXEC/apply" "${1:-teardown}"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH"
state="$ROUTEPOLICY_ROOT/etc/routepolicy/state"; wal="$state/init-transaction/current"
reset() {
 rm -rf "$tmp/root"
 mkdir -p "$wal" "$ROUTEPOLICY_ROOT/etc/config" "$ROUTEPOLICY_ROOT/proc/sys/kernel/random"
 : >"$ROUTEPOLICY_ROOT/etc/config/routepolicy"
 printf 'rolling_back\n' >"$wal/phase"
 printf '11111111-1111-1111-1111-111111111111\n' >"$wal/boot-id"
 printf '22222222-2222-2222-2222-222222222222\n' >"$ROUTEPOLICY_ROOT/proc/sys/kernel/random/boot_id"
 printf '0123456789abcdef0123456789abcdef\n' >"$wal/token"
 printf '0\n' >"$wal/policy-active"; : >"$wal/policy-attempted"
 printf 'set\troutepolicy.main.policy_interface\tpolicy\n' >"$wal/candidate"
 cat >"$state/applied" <<'EOF'
schema=1
route_table=200
rule_priority=12000
mark=0x100
mark_mask=0x100
policy_interface=policy
policy_device=old-device
policy_cidr=198.51.100.0/24
EOF
 printf '%s\n' "${1:-absent}" >"$tmp/scenario"; : >"$tmp/commands"
}
no_mutation() {
 if grep -Eq '^(ip .* (del|flush|replace|add) |nft (delete|add|flush|destroy|replace) )' "$tmp/commands"; then
  printf 'cross-boot recovery issued a kernel mutation\n' >&2; cat "$tmp/commands" >&2; exit 1
 fi
}
accept() {
 sh "$tmp/owner" >"$tmp/result" 2>&1 || { cat "$tmp/result" >&2; exit 1; }
 [ ! -e "$state/applied" ]; no_mutation
}
reject() {
 if sh "$tmp/owner" >"$tmp/result" 2>&1; then printf 'unsafe cross-boot recovery accepted: %s\n' "$1" >&2; exit 1; fi
 [ -f "$state/applied" ]; no_mutation
}
reset; accept
reset; rm "$state/applied"; accept
for scenario in priority reference route nft rules-error rules-malformed route-error wrong-rc mixed-error nft-error; do reset "$scenario"; reject "$scenario"; done
for marker in policy-attempted policy-active phase boot-id token candidate; do reset; rm "$wal/$marker"; reject "missing $marker"; done
reset; printf 1 >"$wal/policy-active"; reject 'previously active policy'
reset; sed -i 's/route_table=200/route_table=201/' "$state/applied"; reject 'foreign applied tuple'
reset; sed -i 's/policy_interface=policy/policy_interface=foreign/' "$state/applied"; reject 'foreign applied interface'
reset; rm "$wal/policy-attempted"; ln -s candidate "$wal/policy-attempted"; reject 'symlink marker'
reset; mkdir -p "$ROUTEPOLICY_ROOT/tmp/routepolicy/active"; printf 'new-boot-generation\n' >"$ROUTEPOLICY_ROOT/tmp/routepolicy/active/generation"; reject 'unknown active catalog'
[ -f "$ROUTEPOLICY_ROOT/tmp/routepolicy/active/generation" ]
reset; mkdir -p "$wal/dns-active-old" "$ROUTEPOLICY_ROOT/tmp/routepolicy/active"
for file in generation domain-policy.list domain-default.list; do printf 'old-%s\n' "$file" >"$wal/dns-active-old/$file"; cp "$wal/dns-active-old/$file" "$ROUTEPOLICY_ROOT/tmp/routepolicy/active/$file"; done
accept
cmp "$wal/dns-active-old/generation" "$ROUTEPOLICY_ROOT/tmp/routepolicy/active/generation"
reset
if ROUTEPOLICY_WRITER_OWNER='1:1' ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_INIT_RESTORE=1 "$ROUTEPOLICY_LIBEXEC/apply" teardown >"$tmp/result" 2>&1; then exit 1; fi
[ -f "$state/applied" ]; no_mutation
reset
if ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_INIT_RESTORE=1 "$ROUTEPOLICY_LIBEXEC/apply" teardown >"$tmp/result" 2>&1; then exit 1; fi
[ -f "$state/applied" ]; no_mutation
# The enabled-policy restore calls apply, and must make the same admission check.
reset reference; printf 1 >"$wal/policy-active"
if sh "$tmp/owner" apply >"$tmp/result" 2>&1; then printf 'enabled cross-boot restore adopted a foreign table reference\n' >&2; exit 1; fi
[ -f "$state/applied" ]; no_mutation
reset; printf 1 >"$wal/policy-active"
sh "$tmp/owner" apply >"$tmp/result" 2>&1 || { cat "$tmp/result" >&2; exit 1; }
grep -Fxq 'policy_interface=usbwan' "$state/applied"
# Normal apply may replace its new default, but cannot delete the old saved CIDR
# or an old tuple/table after the boot changed.
if grep -Eq '^ip -4 (rule del|route flush)|198\.51\.100\.0/24' "$tmp/commands"; then cat "$tmp/commands" >&2; exit 1; fi
# A failed later DNS restore can retry the already published original policy.
# Persistent policy-restore-result alone never admits a runtime publication.
: >"$tmp/commands"
sh "$tmp/owner" apply >"$tmp/result" 2>&1 || { cat "$tmp/result" >&2; exit 1; }
no_mutation
active="$ROUTEPOLICY_ROOT/tmp/routepolicy/active"
cp "$active/generation" "$tmp/current-generation"
printf 'other-generation\n' >"$active/generation"
: >"$tmp/commands"; printf 'old success\n' >"$wal/policy-restore-result"
if sh "$tmp/owner" apply >"$tmp/result" 2>&1; then printf 'foreign publication was adopted\n' >&2; exit 1; fi
[ -f "$state/applied" ]; no_mutation
cp "$tmp/current-generation" "$active/generation"
mkdir "$wal/dns-active-old"; cp "$active/generation" "$wal/dns-active-old/generation"
if sh "$tmp/owner" apply >"$tmp/result" 2>&1; then printf 'old token publication was adopted as this boot\n' >&2; exit 1; fi
[ -f "$state/applied" ]; no_mutation
printf 'previous-confirmed-generation\n' >"$wal/dns-active-old/generation"
sh "$tmp/owner" apply >"$tmp/result" 2>&1 || { cat "$tmp/result" >&2; exit 1; }
no_mutation
rm -rf "$wal/dns-active-old"
rm "$active/domain-default.list"; ln -s "$active/domain-policy.list" "$active/domain-default.list"
if sh "$tmp/owner" apply >"$tmp/result" 2>&1; then printf 'unsafe publication was adopted\n' >&2; exit 1; fi
[ -f "$state/applied" ]; no_mutation
# Same-boot schema-1 cleanup still performs and verifies normal owned deletion.
reset; cp "$wal/boot-id" "$ROUTEPOLICY_ROOT/proc/sys/kernel/random/boot_id"
printf 'boot_id=%s\n' "$(cat "$wal/boot-id")" >>"$state/applied"
printf nft >"$tmp/scenario"
printf 1 >"$wal/policy-active"
sh "$tmp/owner" >"$tmp/result" 2>&1
[ ! -e "$state/applied" ]
grep -Fxq 'ip -4 rule del priority 12000 fwmark 0x100/0x100 lookup 200' "$tmp/commands"
grep -Fxq 'ip -4 route flush table 200' "$tmp/commands"
grep -Fxq 'nft delete table inet routepolicy' "$tmp/commands"
printf 'cross-boot applied cleanup: passed (real gate, absent FIB, foreign objects and failure preservation)\n'
