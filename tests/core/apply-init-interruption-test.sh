#!/bin/sh
# Actual apply/common and inherited flock; only kernel commands are modeled.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-interruption.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export TEST_INTERRUPTION_DIR=$tmp BASE_INTERRUPTION_UCI="$ROOT/tests/core/stubs/uci"
export ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_ROOT="$tmp/root"
mkdir -p "$tmp/bin"
cp -R "${TEST_INIT_RUNTIME_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}" "$tmp/lib"
TEST_REAL_MV=$(command -v mv); TEST_REAL_MKTEMP=$(command -v mktemp)
TEST_REAL_RM=$(command -v rm)
export TEST_REAL_MV TEST_REAL_MKTEMP TEST_REAL_RM
if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
 mv "$tmp/lib/apply" "$tmp/lib/apply-implementation"
 cat >"$tmp/lib/apply" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/bin/busybox" ash "$ROUTEPOLICY_LIBEXEC/apply-implementation" "$@"
EOF
 cat >"$tmp/bin/awk" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/bin/busybox" awk "$@"
EOF
 chmod +x "$tmp/lib/apply"
fi
cat >"$tmp/bin/kill-check" <<'EOF'
#!/bin/sh
[ "$(cat "$TEST_INTERRUPTION_DIR/kill-at" 2>/dev/null)" = "$1" ] || exit 0
rm "$TEST_INTERRUPTION_DIR/kill-at"
printf '%s\n' "$1" >"$TEST_INTERRUPTION_DIR/killed-at"
kill -KILL "$(cat "$TEST_INTERRUPTION_DIR/child-pid")"
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >>"$TEST_INTERRUPTION_DIR/commands"
case "$*" in
 '-4 rule show'|'-4 -N rule show')
  [ ! -e "$TEST_INTERRUPTION_DIR/fail-rules" ] || exit 23
  printf '0: from all lookup 255\n32766: from all lookup 254\n32767: from all lookup 253\n'
  [ ! -f "$TEST_INTERRUPTION_DIR/rule" ] || cat "$TEST_INTERRUPTION_DIR/rule" ;;
 '-4 rule add '*) printf '12000: from all fwmark 0x100/0x100 lookup 200\n' >"$TEST_INTERRUPTION_DIR/rule"; kill-check rule ;;
 '-4 rule del '*) rm -f "$TEST_INTERRUPTION_DIR/rule" ;;
 '-4 route show table 200')
  [ ! -e "$TEST_INTERRUPTION_DIR/fail-routes" ] || exit 23
  cat "$TEST_INTERRUPTION_DIR/routes" ;;
 '-4 -N route show table all') sed 's/$/ table 200/' "$TEST_INTERRUPTION_DIR/routes" ;;
 '-4 route show table main') printf 'default via 10.17.1.2 dev eth0 proto static\n' ;;
 '-4 route flush table 200') : >"$TEST_INTERRUPTION_DIR/routes" ;;
 '-4 route replace '*|'-4 route del '*|'-4 route add '*)
  operation=$3
  [ "$operation" != del ] || [ ! -e "$TEST_INTERRUPTION_DIR/fail-delete" ] || exit 23
  shift 3
  kind=unicast; prefix=; device=; gateway=; address=; metric=0; scope=
  if [ "$1" = blackhole ]; then kind=$1; shift; fi
  while [ "$#" -gt 0 ]; do
   case "$1" in
    table) shift ;;
    dev) shift; device=$1 ;;
    via) shift; gateway=$1 ;;
    src) shift; address=$1 ;;
    metric) shift; metric=$1 ;;
    scope) shift; scope=$1 ;;
    proto) shift ;;
    *) [ -n "$prefix" ] || prefix=$1 ;;
   esac
   shift
  done
  awk -v p="$prefix" -v m="$metric" '{prefix=($1=="blackhole"?$2:$1);metric=0;for(i=1;i<NF;i++)if($i=="metric")metric=$(i+1);if(prefix!=p||metric!=m)print}' "$TEST_INTERRUPTION_DIR/routes" >"$TEST_INTERRUPTION_DIR/routes.new"
  mv "$TEST_INTERRUPTION_DIR/routes.new" "$TEST_INTERRUPTION_DIR/routes"
  [ "$operation" != del ] || kill-check compensate
  if [ "$operation" != del ]; then
   # Shape copied from the official 419 POLICY_ROUTE capture, not command argv:
   # default via ... dev ... metric 10; blackhole default metric 32760;
   # CIDR dev ... scope link src ... metric 10 (native trailing spaces retained).
   if [ "$kind" = blackhole ]; then printf 'blackhole default metric 32760 \n'
   elif [ "$prefix" = default ] && [ -n "$gateway" ]; then printf 'default via %s dev %s metric 10 \n' "$gateway" "$device"
   elif [ "$prefix" = default ]; then printf 'default dev %s scope link metric 10 \n' "$device"
   else printf '%s dev %s scope link src %s metric 10 \n' "$prefix" "$device" "$address"; fi >>"$TEST_INTERRUPTION_DIR/routes"
   if [ "$kind" = blackhole ]; then kill-check blackhole
   elif [ "$prefix" = default ]; then kill-check default
   else kill-check connected; fi
  fi ;;
esac
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$TEST_INTERRUPTION_DIR/commands"
case "$*" in
 'list table inet routepolicy')
  [ ! -e "$TEST_INTERRUPTION_DIR/fail-nft" ] || exit 23
  if [ -f "$TEST_INTERRUPTION_DIR/fail-first-nft" ]; then rm "$TEST_INTERRUPTION_DIR/fail-first-nft"; exit 23; fi
  [ -f "$TEST_INTERRUPTION_DIR/nft" ] && printf 'table inet routepolicy { }\n' ;;
 'list tables') [ ! -e "$TEST_INTERRUPTION_DIR/fail-nft" ] || exit 23; [ ! -f "$TEST_INTERRUPTION_DIR/nft" ] || printf 'table inet routepolicy\n' ;;
 'list set '*) [ -f "$TEST_INTERRUPTION_DIR/nft" ] && printf 'set x {\n type ipv4_addr\n flags timeout\n}\n' ;;
 'list chain '*) exit 1 ;;
 '-c -f '*) exit 0 ;;
 '-f '*) : >"$TEST_INTERRUPTION_DIR/nft"; kill-check nft ;;
 'delete table inet routepolicy') rm -f "$TEST_INTERRUPTION_DIR/nft" ;;
 *) exit 1 ;;
esac
EOF
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
 '-q get routepolicy.main.route_table') if [ -f "$TEST_INTERRUPTION_DIR/route-table" ]; then cat "$TEST_INTERRUPTION_DIR/route-table"; exit; fi ;;
 '-q get routepolicy.main.rule_priority') if [ -f "$TEST_INTERRUPTION_DIR/rule-priority" ]; then cat "$TEST_INTERRUPTION_DIR/rule-priority"; exit; fi ;;
esac
case "$*" in '-q get routepolicy.main.policy_interface') cat "$TEST_INTERRUPTION_DIR/current-if" ;; *) exec "$BASE_INTERRUPTION_UCI" "$@" ;; esac
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' "$2"
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
interface=$(cat)
case "$interface" in *wanold*) device=eth0; address=10.17.1.15; gateway=10.17.1.2 ;; *) device=eth2; address=10.17.2.15; gateway=10.17.2.2 ;; esac
case "$2" in
 '@.l3_device') echo "$device" ;; '@["ipv4-address"][0].address') echo "$address" ;; '@["ipv4-address"][0].mask') echo 24 ;;
 '@.route[@.target="0.0.0.0"].nexthop') echo "$gateway" ;; '@.up') echo true ;;
esac
EOF
cat >"$tmp/bin/mv" <<'EOF'
#!/bin/sh
for destination do :; done
case "$destination" in
 */policy-runtime-intent) [ ! -f "$TEST_INTERRUPTION_DIR/fail-intent-publish" ] || exit 23 ;;
 "$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied") [ ! -f "$TEST_INTERRUPTION_DIR/fail-applied-publish" ] || exit 23 ;;
esac
"$TEST_REAL_MV" "$@" || exit $?
case "$destination" in "$ROUTEPOLICY_ROOT/tmp/routepolicy/active") kill-check catalog ;; "$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied") kill-check published ;; esac
EOF
cat >"$tmp/bin/mktemp" <<'EOF'
#!/bin/sh
"$TEST_REAL_MKTEMP" "$@" || exit $?
case "$*" in */state/applied.XXXXXX) kill-check before-applied ;; esac
EOF
cat >"$tmp/bin/rm" <<'EOF'
#!/bin/sh
for target do
 case "$target" in
  */policy-runtime-intent) [ ! -f "$TEST_INTERRUPTION_DIR/fail-intent-finish" ] || exit 23 ;;
  "$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied") [ ! -f "$TEST_INTERRUPTION_DIR/fail-applied-delete" ] || exit 23 ;;
  "$ROUTEPOLICY_ROOT/tmp/routepolicy/active") [ ! -f "$TEST_INTERRUPTION_DIR/fail-catalog-delete" ] || exit 23 ;;
 esac
done
exec "$TEST_REAL_RM" "$@"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH"
cat >"$tmp/owner" <<'EOF'
#!/bin/sh
set -u
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter init || exit 1
run_apply() {
 if [ "${scenario:-}" = missing-generation ] || [ "${scenario:-}" = plain-init ]; then
  (unset ROUTEPOLICY_INIT_GENERATION; exec "$ROUTEPOLICY_LIBEXEC/apply" "$@") >"$TEST_INTERRUPTION_DIR/result" 2>&1 & child=$!
 else
  ROUTEPOLICY_INIT_GENERATION="$(cat "$RP_STATE_DIR/init-transaction/current/token")" "$ROUTEPOLICY_LIBEXEC/apply" "$@" >"$TEST_INTERRUPTION_DIR/result" 2>&1 & child=$!
 fi
 printf '%s\n' "$child" >"$TEST_INTERRUPTION_DIR/child-pid"
 wait "$child"; result=$?
 remaining=100
 until rp_writer_idle; do [ "$remaining" -gt 0 ] || exit 91; sleep 0.01; remaining=$((remaining-1)); done
 return "$result"
}
scenario=$(cat "$TEST_INTERRUPTION_DIR/scenario")
case "$scenario" in stopped-*)
 export ROUTEPOLICY_INIT_RESTORE=1 ROUTEPOLICY_DNS_DEFER=1
 run_apply apply; result=$?
 case "$scenario" in stopped-kill|stopped-boot)
  [ "$result" = 137 ] || { cat "$TEST_INTERRUPTION_DIR/result"; exit 97; }
  wal="$RP_STATE_DIR/init-transaction/current"
  cp "$wal/policy-runtime-intent" "$TEST_INTERRUPTION_DIR/exit-intent"
  if [ "$scenario" = stopped-boot ]; then
   rm -rf "$RP_RUN_DIR"; rm -f "$TEST_INTERRUPTION_DIR/rule" "$TEST_INTERRUPTION_DIR/nft"
   : >"$TEST_INTERRUPTION_DIR/routes"
   printf '22222222-2222-2222-2222-222222222222\n' >"$RP_ROOT/proc/sys/kernel/random/boot_id"
  fi
  run_apply apply; result=$?
 esac
 exit "$result" ;;
esac
run_apply; result=$?
printf '%s\n' "$result" >"$TEST_INTERRUPTION_DIR/initial-rc"
if [ "$scenario" = prewrite ] || [ "$scenario" = missing-generation ]; then [ "$result" != 0 ] || exit 92; exit 0; fi
if [ "$scenario" = plain-init ]; then [ "$result" = 0 ] || { cat "$TEST_INTERRUPTION_DIR/result"; exit 92; }; exit 0; fi
expected=137; [ "$scenario" != failed-publication ] || expected=1
[ "$result" = "$expected" ] || { cat "$TEST_INTERRUPTION_DIR/result"; exit 92; }
if [ -f "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent" ]; then cp "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent" "$TEST_INTERRUPTION_DIR/intent-after-initial"; fi
printf 'rolling_back\n' >"$RP_STATE_DIR/init-transaction/current/phase"
if [ "$(cat "$RP_STATE_DIR/init-transaction/current/policy-active")" = 1 ]; then printf 'wanold\n' >"$TEST_INTERRUPTION_DIR/current-if"; restore_mode=apply
else restore_mode=teardown; fi
export ROUTEPOLICY_INIT_RESTORE=1
cp "$TEST_INTERRUPTION_DIR/commands" "$TEST_INTERRUPTION_DIR/initial.commands"
: >"$TEST_INTERRUPTION_DIR/commands"
reject=0
case "$scenario" in
 foreign-route) printf '198.51.100.0/24 dev eth9 scope link src 198.51.100.1 metric 10\n' >>"$TEST_INTERRUPTION_DIR/routes"; reject=1 ;;
 foreign-rule) printf '12001: from all lookup 200\n' >>"$TEST_INTERRUPTION_DIR/rule"; reject=1 ;;
 changed-gateway) sed -i 's/via 10.17.2.2/via 203.0.113.99/' "$TEST_INTERRUPTION_DIR/routes"; reject=1 ;;
 unknown-field) sed -i '/10.17.2.0\/24/s/$/ onlink/' "$TEST_INTERRUPTION_DIR/routes"; reject=1 ;;
 missing-intent) rm "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent"; reject=1 ;;
 bad-record) printf 'unexpected\tcommand\ttouch PWN\n' >>"$RP_STATE_DIR/init-transaction/current/policy-runtime-intent"; reject=1 ;;
 intent-leading-table|intent-leading-priority)
  column=6; [ "$scenario" != intent-leading-priority ] || column=7
  value=0200; [ "$scenario" != intent-leading-priority ] || value=012000
  awk -F '\t' -v OFS='\t' -v column="$column" -v value="$value" 'NR==1{$column=value}{print}' "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent" >"$TEST_INTERRUPTION_DIR/changed-intent"
  mv "$TEST_INTERRUPTION_DIR/changed-intent" "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent"; reject=1 ;;
 bad-token) printf 'fedcba9876543210fedcba9876543210\n' >"$RP_STATE_DIR/init-transaction/current/token"; reject=1 ;;
 bad-owner) export ROUTEPOLICY_WRITER_OWNER="$$:1"; reject=1 ;;
 missing-marker) rm "$RP_STATE_DIR/init-transaction/current/policy-attempted"; reject=1 ;;
 wrong-phase) printf 'confirmed\n' >"$RP_STATE_DIR/init-transaction/current/phase"; reject=1 ;;
 symlink-intent) mv "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent" "$TEST_INTERRUPTION_DIR/saved-intent"; ln -s "$TEST_INTERRUPTION_DIR/saved-intent" "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent"; reject=1 ;;
 unknown-catalog)
  mkdir -p "$RP_ACTIVE_DIR"; printf 'external-publication\n' >"$RP_ACTIVE_DIR/generation"
  : >"$RP_ACTIVE_DIR/domain-policy.list"; : >"$RP_ACTIVE_DIR/domain-default.list"; reject=1 ;;
 foreign-applied) printf 'schema=1\nroute_table=201\n' >"$RP_STATE_DIR/applied"; reject=1 ;;
 fail-rules) : >"$TEST_INTERRUPTION_DIR/fail-rules"; reject=1 ;;
 fail-routes) : >"$TEST_INTERRUPTION_DIR/fail-routes"; reject=1 ;;
 fail-nft) : >"$TEST_INTERRUPTION_DIR/fail-nft"; reject=1 ;;
 failed-publication) rm "$TEST_INTERRUPTION_DIR/fail-applied-publish" ;;
 finish-failure|applied-delete|catalog-delete)
  export ROUTEPOLICY_OUTPUT=json
  case "$scenario" in finish-failure) : >"$TEST_INTERRUPTION_DIR/fail-intent-finish" ;;
   applied-delete) : >"$TEST_INTERRUPTION_DIR/fail-applied-delete" ;; catalog-delete) : >"$TEST_INTERRUPTION_DIR/fail-catalog-delete" ;; esac ;;
 compensate-again) printf 'compensate\n' >"$TEST_INTERRUPTION_DIR/kill-at" ;;
 newboot-foreign|newboot-retry|newboot-finish|newboot-leading-table|newboot-leading-priority)
  rm -rf "$RP_RUN_DIR"; rm -f "$TEST_INTERRUPTION_DIR/rule" "$TEST_INTERRUPTION_DIR/nft"; : >"$TEST_INTERRUPTION_DIR/routes"
  printf '22222222-2222-2222-2222-222222222222\n' >"$RP_ROOT/proc/sys/kernel/random/boot_id"
  if [ "$scenario" = newboot-foreign ]; then
   printf '12000: from all fwmark 0x100/0x100 lookup 200\n' >"$TEST_INTERRUPTION_DIR/rule"
   printf '198.51.100.0/24 dev eth9 scope link src 198.51.100.1 metric 10\n' >"$TEST_INTERRUPTION_DIR/routes"
   : >"$TEST_INTERRUPTION_DIR/nft"; reject=1
  elif [ "$scenario" = newboot-leading-table ]; then printf '0200\n' >"$TEST_INTERRUPTION_DIR/route-table"; reject=1
  elif [ "$scenario" = newboot-leading-priority ]; then printf '012000\n' >"$TEST_INTERRUPTION_DIR/rule-priority"; reject=1
  elif [ "$scenario" = newboot-finish ]; then export ROUTEPOLICY_OUTPUT=json; : >"$TEST_INTERRUPTION_DIR/fail-intent-finish"
  else printf 'catalog\n' >"$TEST_INTERRUPTION_DIR/kill-at"; fi ;;
esac
run_apply "$restore_mode"; result=$?
case "$scenario" in finish-failure|newboot-finish|applied-delete|catalog-delete)
 [ "$result" != 0 ] && [ -f "$RP_STATE_DIR/init-transaction/current/policy-runtime-intent" ] || exit 96
 cp "$TEST_INTERRUPTION_DIR/result" "$TEST_INTERRUPTION_DIR/finish-failure-result"
 if grep -Fq '"ok":true' "$TEST_INTERRUPTION_DIR/finish-failure-result"; then cat "$TEST_INTERRUPTION_DIR/finish-failure-result"; exit 96; fi
 [ "$(grep -Fc '"ok":false' "$TEST_INTERRUPTION_DIR/finish-failure-result")" = 1 ] || exit 96
 rm -f "$TEST_INTERRUPTION_DIR/fail-intent-finish" "$TEST_INTERRUPTION_DIR/fail-applied-delete" "$TEST_INTERRUPTION_DIR/fail-catalog-delete"
 run_apply "$restore_mode"; result=$?
 ;;
esac
if [ "$scenario" = compensate-again ] || [ "$scenario" = newboot-retry ]; then
 [ "$result" = 137 ] || { cat "$TEST_INTERRUPTION_DIR/result"; exit 94; }
 if [ "$scenario" = newboot-retry ]; then
  [ ! -e "$RP_STATE_DIR/applied" ] && [ "$(cat "$RP_ACTIVE_DIR/generation")" = "$(cat "$RP_STATE_DIR/init-transaction/current/token")" ] || exit 94
  printf 'connected\n' >"$TEST_INTERRUPTION_DIR/kill-at"
  run_apply "$restore_mode"; result=$?
  [ "$result" = 137 ] || { cat "$TEST_INTERRUPTION_DIR/result"; exit 94; }
 fi
 run_apply "$restore_mode"; result=$?
fi
printf '%s\n' "$result" >"$TEST_INTERRUPTION_DIR/recovery-rc"
if [ "$reject" = 1 ]; then [ "$result" != 0 ] || exit 95; exit 0; fi
[ "$result" = 0 ] || { cat "$TEST_INTERRUPTION_DIR/result"; exit 93; }
EOF
state="$ROUTEPOLICY_ROOT/etc/routepolicy/state"; wal="$state/init-transaction/current"
reset() {
 rm -rf "$tmp/root"; rm -f "$tmp/rule" "$tmp/nft" "$tmp/killed-at" "$tmp/fail-rules" "$tmp/fail-routes" "$tmp/fail-nft" "$tmp/fail-first-nft" "$tmp/fail-delete" "$tmp/fail-intent-publish" "$tmp/fail-applied-publish" "$tmp/intent-after-initial" "$tmp/fail-intent-finish" "$tmp/fail-applied-delete" "$tmp/fail-catalog-delete" "$tmp/route-table" "$tmp/rule-priority"
 mkdir -p "$wal" "$ROUTEPOLICY_ROOT/etc/config" "$ROUTEPOLICY_ROOT/proc/sys/kernel/random"
 : >"$ROUTEPOLICY_ROOT/etc/config/routepolicy"; : >"$tmp/routes"; : >"$tmp/commands"
 printf 'wan2\n' >"$tmp/current-if"; printf '%s\n' "$2" >"$tmp/kill-at"
 printf 'normal\n' >"$tmp/scenario"
 printf 'applying\n' >"$wal/phase"; printf '%s\n' "$1" >"$wal/policy-active"; : >"$wal/policy-attempted"
 printf '0123456789abcdef0123456789abcdef\n' >"$wal/token"
 printf '11111111-1111-1111-1111-111111111111\n' >"$wal/boot-id"
 cp "$wal/boot-id" "$ROUTEPOLICY_ROOT/proc/sys/kernel/random/boot_id"
 printf 'set\troutepolicy.main.enabled\t1\nset\troutepolicy.main.policy_interface\twan2\n' >"$wal/candidate"
 if [ "$1" = 1 ]; then
  : >"$tmp/nft"; printf '12000: from all fwmark 0x100/0x100 lookup 200\n' >"$tmp/rule"
  printf 'default via 10.17.1.2 dev eth0 metric 10 \nblackhole default metric 32760 \n10.17.1.0/24 dev eth0 scope link src 10.17.1.15 metric 10 \n' >"$tmp/routes"
  cat >"$state/applied" <<'EOF'
schema=1
route_table=200
rule_priority=12000
mark=0x100
mark_mask=0x100
policy_interface=wanold
policy_device=eth0
policy_cidr=10.17.1.0/24
EOF
  printf 'boot_id=%s\n' "$(cat "$wal/boot-id")" >>"$state/applied"
  if [ "${TEST_MARK:-0x100}" != 0x100 ]; then
   sed -i "s/mark=0x100/mark=$TEST_MARK/;s/mark_mask=0x100/mark_mask=$TEST_MARK/" "$state/applied"
  fi
 fi
}
run_owner() {
 if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
  "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/bin/busybox" ash "$tmp/owner"
 else sh "$tmp/owner"; fi
}
recovery_wrote_nothing() {
 if grep -Eq '^ip -4 (rule (add|del)|route (add|del|replace|flush))|^nft (-f|delete)' "$tmp/commands"; then cat "$tmp/commands" >&2; exit 1; fi
}
exit_stopped_policy() (
 . "$ROUTEPOLICY_LIBEXEC/common"
 for scenario in stopped-present stopped-absent stopped-kill stopped-boot stopped-foreign-rule stopped-foreign-boot-rule stopped-foreign-90 stopped-foreign-receipt stopped-bad-marker stopped-missing-marker; do
  reset 0 never
  printf '1\n' >"$wal/policy-active"; printf 'rolling_back\n' >"$wal/phase"
  printf 'exit\n' >"$wal/kind"; printf '1\n' >"$wal/dns90-new-absent"
  printf 'wanold\n' >"$tmp/current-if"; printf '%s\n' "$scenario" >"$tmp/scenario"
  TEST_SMARTDNS_ENABLED=1
  if [ "$scenario" = stopped-absent ]; then
   TEST_SMARTDNS_ENABLED=0; : >"$wal/dns90-absent"
  else rp_smartdns90_content policy >"$wal/dns90-old"; fi
  export TEST_SMARTDNS_ENABLED
  case "$scenario" in
   stopped-kill) printf 'default\n' >"$tmp/kill-at" ;;
   stopped-boot) printf 'published\n' >"$tmp/kill-at" ;;
   stopped-foreign*rule)
    printf '11000: from all lookup 201\n' >"$tmp/rule"
    if [ "$scenario" = stopped-foreign-boot-rule ]; then
     printf '22222222-2222-2222-2222-222222222222\n' >"$RP_ROOT/proc/sys/kernel/random/boot_id"
    fi ;;
   stopped-foreign-90)
    mkdir -p "$(dirname "$RP_SMARTDNS_FILE")"
    printf 'external DNS content\n' >"$RP_SMARTDNS_FILE" ;;
   stopped-foreign-receipt) printf 'schema=1\ninit_generation=external\n' >"$state/applied" ;;
   stopped-bad-marker) printf 'exit\n' >"$wal/dns90-new-absent" ;;
   stopped-missing-marker) rm "$wal/dns90-new-absent" ;;
  esac
  case "$scenario" in stopped-foreign-*|stopped-*-marker)
   if run_owner >"$tmp/stopped-owner.log" 2>&1; then printf 'stopped exit adopted %s\n' "$scenario" >&2; exit 1; fi
   recovery_wrote_nothing
   [ ! -e "$wal/policy-runtime-intent" ]
   case "$scenario" in
    stopped-foreign*rule) grep -Fxq '11000: from all lookup 201' "$tmp/rule" ;;
    stopped-foreign-90) grep -Fxq 'external DNS content' "$RP_SMARTDNS_FILE" ;;
    stopped-foreign-receipt) grep -Fxq 'init_generation=external' "$state/applied" ;;
   esac
   continue ;;
  esac
  if ! run_owner >"$tmp/stopped-owner.log" 2>&1; then
   printf 'stopped exit restore failed: %s\n' "$scenario" >&2
   cat "$tmp/stopped-owner.log" "$tmp/result" >&2; exit 1
  fi
  [ ! -e "$wal/policy-runtime-intent" ] && [ -f "$tmp/nft" ] && [ -f "$tmp/rule" ] || exit 1
  grep -Fq 'default via 10.17.1.2 dev eth0' "$tmp/routes"
  [ "$(rp_state_get init_generation)" = "$(cat "$wal/token")" ]
  if [ "$scenario" = stopped-absent ]; then
   [ ! -e "$RP_SMARTDNS_FILE" ] && [ "$(rp_state_get smartdns90_present)" = 0 ] || exit 1
  else
   cmp "$RP_SMARTDNS_FILE" "$wal/dns90-old"
   rp_smartdns_receipt_content "$(cat "$RP_ROOT/proc/sys/kernel/random/boot_id")" >"$tmp/restored90"
   cmp "$RP_SMARTDNS_FILE" "$tmp/restored90"
  fi
  case "$scenario" in stopped-kill|stopped-boot)
   grep -Fxq "$(printf 'before-rule\t0')" "$tmp/exit-intent"
   grep -Fxq "$(printf 'before-nft\t0')" "$tmp/exit-intent" ;;
  esac
 done
 printf '%s\n' 'stopped exit policy: passed (original active1, exact 90/absence, foreign resources and bad marker refused, same/new-boot intent retry)'
)
if [ "${1:-}" = --exit-stopped ]; then exit_stopped_policy; exit 0; fi
if [ "${1:-}" = --bootstrap ]; then
	. "$ROUTEPOLICY_LIBEXEC/common"
	cat >"$tmp/owner" <<'SH'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter init
wal="$RP_STATE_DIR/init-transaction/current"
export ROUTEPOLICY_INIT_GENERATION="$(cat "$wal/token")"
printf '%s\n' "$ROUTEPOLICY_INIT_GENERATION" >"$wal/source-bootstrap"
ROUTEPOLICY_SOURCE_BOOTSTRAP=1 "$ROUTEPOLICY_LIBEXEC/apply" >"$TEST_INTERRUPTION_DIR/bootstrap-result" 2>&1
[ -f "$wal/policy-runtime-intent" ] && [ "$(rp_state_get source_bootstrap)" = 1 ]
cp "$wal/policy-runtime-intent" "$TEST_INTERRUPTION_DIR/bootstrap-intent"
scenario=$(cat "$TEST_INTERRUPTION_DIR/scenario")
if [ "$scenario" = source-published ]; then
	rp_managed_prepare "$wal"
	mkdir "$wal/managed-expected"; printf 'new.example\n' >"$wal/managed-expected/feed.domain-policy.list"
	printf 'previous.next.123\n' >"$wal/managed-swap-name"; rp_managed_phase "$wal" publishing
	mv "$RP_MANAGED_CURRENT" "$RP_ETC/managed.d/previous.next.123"
	cp -pR "$wal/managed-expected" "$RP_MANAGED_CURRENT"
	rm -rf "$RP_MANAGED_PREVIOUS"; mv "$RP_ETC/managed.d/previous.next.123" "$RP_MANAGED_PREVIOUS"
	rp_managed_phase "$wal" published
fi
if [ "$scenario" = final-failure ] || [ "$scenario" = success ]; then
	[ "$scenario" != final-failure ] || : >"$TEST_INTERRUPTION_DIR/fail-applied-publish"
	set +e
	ROUTEPOLICY_SOURCE_BOOTSTRAP=0 "$ROUTEPOLICY_LIBEXEC/apply" >"$TEST_INTERRUPTION_DIR/final-result" 2>&1
	result=$?
	set -e
	if [ "$scenario" = success ]; then
		[ "$result" = 0 ] && [ ! -e "$wal/policy-runtime-intent" ] && [ "$(rp_state_get source_bootstrap)" = 0 ]
		exit 0
	fi
	[ "$result" != 0 ] && cmp "$wal/policy-runtime-intent" "$TEST_INTERRUPTION_DIR/bootstrap-intent"
fi
kill -KILL "$$"
SH
	cat >"$tmp/bootstrap-recover" <<'SH'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter init
wal="$RP_STATE_DIR/init-transaction/current"
printf 'rolling_back\n' >"$wal/phase"
rp_managed_restore "$wal"
mode=teardown
if [ "$(cat "$wal/policy-active")" = 1 ]; then printf 'wanold\n' >"$TEST_INTERRUPTION_DIR/current-if"; mode=apply; fi
rm -f "$TEST_INTERRUPTION_DIR/fail-applied-publish"
ROUTEPOLICY_INIT_RESTORE=1 ROUTEPOLICY_INIT_GENERATION="$(cat "$wal/token")" "$ROUTEPOLICY_LIBEXEC/apply" "$mode" >"$TEST_INTERRUPTION_DIR/recover-result" 2>&1
SH
	# Authenticated bootstrap has no exemption from configuration validation.
	for active in 0 1; do
		reset "$active" never
		cp "$tmp/routes" "$tmp/invalid-routes.before"
		[ "$active" = 0 ] || cp "$state/applied" "$tmp/invalid-applied.before"
		printf '100.00 0.00\n' >"$ROUTEPOLICY_ROOT/proc/uptime"; printf '10000\n' >"$wal/uptime-start-cs"
		if TEST_STRICT=broken run_owner >"$tmp/invalid-bootstrap.log" 2>&1; then
			printf 'bootstrap ignored invalid strict_enforcement\n' >&2; exit 1
		fi
		grep -Fq 'strict_enforcement' "$tmp/bootstrap-result" || { printf 'bootstrap bypassed configuration validation\n' >&2; exit 1; }
		recovery_wrote_nothing
		[ ! -e "$wal/policy-runtime-intent" ]; cmp "$tmp/routes" "$tmp/invalid-routes.before"
		if [ "$active" = 0 ]; then [ ! -e "$state/applied" ]; else cmp "$state/applied" "$tmp/invalid-applied.before"; fi
	done
	for active in 0 1; do
		for boundary in bootstrap-published source-published final-failure success; do
			reset "$active" never
			printf '100.00 0.00\n' >"$ROUTEPOLICY_ROOT/proc/uptime"; printf '10000\n' >"$wal/uptime-start-cs"
			printf '%s\n' "$boundary" >"$tmp/scenario"
			mkdir -p "$RP_MANAGED_CURRENT" "$RP_MANAGED_PREVIOUS"
			printf 'old.example\n' >"$RP_MANAGED_CURRENT/feed.domain-policy.list"
			printf 'unknown\n' >"$RP_MANAGED_CURRENT/unknown.keep"
			if run_owner >"$tmp/bootstrap-owner.log" 2>&1; then rc=0; else rc=$?; fi
			if [ "$boundary" = success ]; then
				[ "$rc" = 0 ] || { cat "$tmp/bootstrap-owner.log" "$tmp/bootstrap-result" "$tmp/final-result"; exit 1; }
			else
				[ "$rc" = 137 ] || { cat "$tmp/bootstrap-owner.log" "$tmp/bootstrap-result" "$tmp/final-result" 2>/dev/null; exit 1; }
				sh "$tmp/bootstrap-recover" || { cat "$tmp/recover-result"; exit 1; }
				[ ! -e "$wal/policy-runtime-intent" ]
				grep -Fxq old.example "$RP_MANAGED_CURRENT/feed.domain-policy.list"
				grep -Fxq unknown "$RP_MANAGED_CURRENT/unknown.keep"
				if [ "$active" = 0 ]; then [ ! -s "$tmp/routes" ] && [ ! -e "$tmp/rule" ] && [ ! -e "$tmp/nft" ];
				else grep -Fq 'default via 10.17.1.2 dev eth0' "$tmp/routes"; [ -f "$tmp/rule" ] && [ -f "$tmp/nft" ]; fi
			fi
		done
	done
	printf '%s\n' 'bootstrap typed intent: passed (active0/1; post-bootstrap/source kill, final write failure, unchanged first intent, final retirement)'
	exit 0
fi
count=0
for active in 0 1; do
 for point in nft rule blackhole connected default catalog before-applied published; do
  [ "$active:$point" != 1:rule ] || continue
  reset "$active" "$point"
  printf 'interruption active=%s point=%s\n' "$active" "$point"
  if ! run_owner >"$tmp/owner.log" 2>&1; then printf 'interruption failed active=%s point=%s\n' "$active" "$point" >&2; cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
  [ "$(cat "$tmp/killed-at")" = "$point" ] && [ "$(cat "$tmp/recovery-rc")" = 0 ] || exit 1
  [ ! -e "$wal/policy-runtime-intent" ]
  if grep -Fq 'ip -4 route flush' "$tmp/commands"; then printf 'intent compensation flushed the routing table\n' >&2; exit 1; fi
  if [ "$active" = 0 ]; then
   if [ -e "$tmp/rule" ] || [ -s "$tmp/routes" ] || [ -e "$tmp/nft" ] || [ -e "$state/applied" ]; then
    printf 'interrupted inactive apply reported recovery with runtime leftovers\n' >&2; cat "$tmp/routes" >&2; exit 1
   fi
  else
   grep -Fxq 'policy_interface=wanold' "$state/applied"
   grep -Fq '10.17.1.0/24 dev eth0 scope link src 10.17.1.15 metric 10' "$tmp/routes"
   if grep -Fq '10.17.2.0/24' "$tmp/routes"; then printf 'candidate connected route survived enabled-policy recovery\n' >&2; exit 1; fi
  fi
  count=$((count+1))
 done
done
for active in 0 1; do
 for scenario in foreign-route foreign-rule changed-gateway unknown-field missing-intent bad-record bad-token bad-owner missing-marker wrong-phase symlink-intent unknown-catalog foreign-applied fail-rules fail-routes fail-nft newboot-foreign intent-leading-table intent-leading-priority newboot-leading-table newboot-leading-priority; do
  reset "$active" default; printf '%s\n' "$scenario" >"$tmp/scenario"
  if ! run_owner >"$tmp/owner.log" 2>&1; then printf 'rejection failed active=%s scenario=%s\n' "$active" "$scenario" >&2; cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
  recovery_wrote_nothing
  case "$scenario" in newboot-leading-*)
   grep -Fq '无前导零的十进制整数' "$tmp/result"
   [ -f "$wal/policy-runtime-intent" ]
   if [ "$active" = 1 ]; then grep -Fxq 'policy_interface=wanold' "$state/applied"; fi ;;
   intent-leading-*) grep -Fq '非规范十进制' "$tmp/result" ;;
  esac
 done
done
for scenario in compensate-again newboot-retry; do
 active=0; [ "$scenario" != newboot-retry ] || active=1
 reset "$active" default; printf '%s\n' "$scenario" >"$tmp/scenario"
 if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
 [ ! -e "$wal/policy-runtime-intent" ]
 if [ "$active" = 0 ]; then [ ! -s "$tmp/routes" ] && [ ! -e "$tmp/rule" ] || exit 1
 else grep -Fxq 'policy_interface=wanold' "$state/applied"; fi
done
for failure in fail-rules fail-routes fail-nft fail-intent-publish; do
 reset 0 never; printf 'prewrite\n' >"$tmp/scenario"; : >"$tmp/$failure"
 if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
 recovery_wrote_nothing
done
reset 1 never; printf 'prewrite\n' >"$tmp/scenario"; : >"$tmp/fail-first-nft"
if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
recovery_wrote_nothing
for active in 0 1; do
 reset "$active" never; printf 'failed-publication\n' >"$tmp/scenario"; : >"$tmp/fail-applied-publish"
 if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
 [ -s "$tmp/intent-after-initial" ] && [ ! -e "$wal/policy-runtime-intent" ] || exit 1
done
for scenario in finish-failure newboot-finish applied-delete catalog-delete; do
 point=default; [ "$scenario" != applied-delete ] || point=published
 [ "$scenario" != catalog-delete ] || point=catalog
 reset 0 "$point"; printf '%s\n' "$scenario" >"$tmp/scenario"
 if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
 [ ! -e "$wal/policy-runtime-intent" ]
done
TEST_MARK=0x0100; TEST_MARK_MASK=0x0100
export TEST_MARK TEST_MARK_MASK
reset 1 connected
if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
if grep -Fq 'ip -4 rule add' "$tmp/initial.commands" "$tmp/commands"; then printf 'native mark normalization duplicated the already-proven rule\n' >&2; exit 1; fi
unset TEST_MARK TEST_MARK_MASK
for phase in applying rolling_back pending confirming; do
 reset 0 never; printf 'missing-generation\n' >"$tmp/scenario"; printf '%s\n' "$phase" >"$wal/phase"
 if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
 grep -Fq '缺少 INIT_GENERATION' "$tmp/result"
 recovery_wrote_nothing
done
for phase in confirmed rolled_back expired prepared; do
 reset 0 never; printf 'plain-init\n' >"$tmp/scenario"; printf '%s\n' "$phase" >"$wal/phase"
 [ "$phase" != prepared ] || rm "$wal/policy-attempted"
 if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
 [ -f "$state/applied" ] && [ ! -e "$wal/policy-runtime-intent" ] || exit 1
done
reset 0 never; printf 'missing-generation\n' >"$tmp/scenario"; printf 'confirmed\n' >"$wal/phase"; printf 'invalid\n' >"$wal/token"
if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
recovery_wrote_nothing
reset 0 never; printf 'missing-generation\n' >"$tmp/scenario"; mv "$wal" "$tmp/wal-copy"; ln -s "$tmp/wal-copy" "$wal"
if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
recovery_wrote_nothing
for setting in table priority; do
 reset 0 never; printf 'prewrite\n' >"$tmp/scenario"
 if [ "$setting" = table ]; then TEST_ROUTE_TABLE=0200; export TEST_ROUTE_TABLE
 else TEST_RULE_PRIORITY=012000; export TEST_RULE_PRIORITY; fi
 if ! run_owner >"$tmp/owner.log" 2>&1; then cat "$tmp/owner.log" "$tmp/result" >&2; exit 1; fi
 grep -Fq '无前导零的十进制整数' "$tmp/result"
 recovery_wrote_nothing
 unset TEST_ROUTE_TABLE TEST_RULE_PRIORITY
done
# Official 419 capture: cache-before-core-rebuild.txt, POLICY_ROUTE. Color escapes
# belong to the terminal capture; subprocess route output is plain text.
(
 . "$tmp/lib/init-policy-runtime"
 cat >"$tmp/native-routes" <<'EOF'
default via 10.17.2.2 dev eth2 metric 10 
blackhole default metric 32760 
10.17.2.0/24 dev eth2 scope link src 10.17.2.15 metric 10 
EOF
 ipr_normalize_routes <"$tmp/native-routes" >"$tmp/canonical"
 [ "$(wc -l <"$tmp/canonical")" -eq 3 ]
 printf '10.17.2.15 dev eth2 scope link src 10.17.2.15 metric 10 linkdown\n' | ipr_normalize_routes >"$tmp/canonical"
 grep -Fxq "$(printf 'unicast\t10.17.2.15/32\teth2\t-\t10.17.2.15\t10\tlink\tboot')" "$tmp/canonical"
 if printf 'default via 10.17.2.2 dev eth2 metric 10 onlink\n' | ipr_normalize_routes >/dev/null; then printf 'unknown route flag was accepted\n' >&2; exit 1; fi
 if printf 'default via 10.17.2.2 dev eth2 proto static metric 10\n' | ipr_normalize_routes >/dev/null; then printf 'foreign route protocol was accepted\n' >&2; exit 1; fi
)
printf 'init apply interruption: passed (%s kernel/catalog/applied windows; original active0/1, real gate and drain)\n' "$count"
printf 'init intent boundaries: passed (foreign/invalid evidence, read and publish failure, compensation retry and new-boot restore killed twice)\n'
printf 'init intent retirement: passed (single error JSON on failed intent/applied/catalog removal, retry; numeric mark normalization)\n'
printf 'init intent admission: passed (unfinished no-token writer rejected, terminal/prepared ordinary path retained, bad token/path rejected)\n'
printf 'init routing IDs: passed (0200/012000 rejected before writes, intent load and cross-boot retirement; canonical IDs and padded hex mark retained)\n'
exit_stopped_policy
