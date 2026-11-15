#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Load helpers without entering the production CLI.
sed '/^case "\$operation:\$#" in$/,$d' "$LIBEXEC/smartdns-package" >"$tmp/readers"
export ROUTEPOLICY_LIBEXEC=$LIBEXEC
. "$tmp/readers"

# Official first install has boot links but UCI enabled=0 and no process.
(
	boot_enabled=1; running=0; config_enabled=0
	rp_smartdns_single_root() { printf 'main\n'; }
	rp_init_active_record() { return 1; }
	init_dns_enabled() { printf '%s\n' "$boot_enabled"; }
	init_dns_service_state() { printf '%s\n' "$running"; }
	uci() { printf '%s\n' "$config_enabled"; }
	preserve_config() { [ "$1:$2" = verify:manifest ]; }
	init_dns_call() { [ "$1:$2" = smartdns:enable ] && boot_enabled=1; }
	test "$(admit_services)" = inactive-enabled
	boot_enabled=0
	restore_service inactive-enabled manifest
	test "$boot_enabled:$running" = 1:0
	boot_enabled=0
	test "$(admit_services)" = inactive
	restore_service inactive
	running=1
	if admit_services || restore_service inactive-enabled manifest; then exit 1; fi
	running=0; config_enabled=1
	if admit_services; then exit 1; fi
)

# Early armed recovery must not re-enable boot links over external committed changes.
(
	JOURNAL="$tmp/armed-journal"; mkdir "$JOURNAL"
	printf 'armed\n' >"$JOURNAL/phase"
	printf 'inactive-enabled\n' >"$JOURNAL/role"
	printf 'old\n' >"$JOURNAL/old.id"; printf 'new\n' >"$JOURNAL/new.id"
	# shellcheck disable=SC2034
	operation=package-recover-early
	current=old; payload_matches=1; config_matches=1; config_enabled=0
	owned_regular() { [ -f "$1" ]; }
	quiesce() { boot_enabled=0; }
	rp_writer_enter() { :; }
	installed_id() { printf '%s\n' "$current"; }
	native_payload_matches() { [ "$payload_matches" = 1 ]; }
	no_pending_config() { :; }
	other_config_unchanged() { :; }
	preserve_config() { [ "$config_matches" = 1 ]; }
	rp_smartdns_single_root() { printf 'main\n'; }
	uci() { printf '%s\n' "$config_enabled"; }
	init_dns_enabled() { printf '%s\n' "$boot_enabled"; }
	init_dns_service_state() { printf '0\n'; }
	init_dns_call() { [ "$1:$2" = smartdns:enable ] && boot_enabled=1; }
	publish_phase() { printf '%s\n' "$1" >"$JOURNAL/phase"; }
	finish_transaction() { touch "$tmp/armed-finished"; }
	for scenario in enabled config payload identity; do
		case "$scenario" in
			enabled) config_enabled=1 ;;
			config) config_matches=0 ;;
			payload) payload_matches=0 ;;
			identity) current=new ;;
		esac
		if recover_transaction; then exit 1; fi
		test "$boot_enabled" = 0
		test "$(cat "$JOURNAL/phase")" = armed
		test ! -e "$tmp/armed-finished"
		current=old; payload_matches=1; config_matches=1; config_enabled=0
	done
	recover_transaction
	test "$boot_enabled" = 1 && test -f "$tmp/armed-finished"
)

# Reserve unpacked payload and recovery work, rather than a fixed disk threshold.
(
	RP_ROOT="$tmp/space-root"; STATE="$RP_ROOT/state"
	mkdir -p "$RP_ROOT/lib/apk/db" "$STATE/staged/config" "$tmp/space-media"
	printf 'db\n' >"$RP_ROOT/lib/apk/db/installed"
	printf 'saved\n' >"$STATE/staged/config/user"
	printf 'info:\n  installed-size: 392852\npaths: # 0 items\n' >"$tmp/space-media/old.adb"
	printf 'info:\n  installed-size: 8143511\npaths: # 0 items\n' >"$tmp/space-media/new.adb"
	available=65536
	df() {
		printf 'Filesystem Total Used Available Capacity Mounted\ntest 100000 0 %s 0%% /\n' "$available"
	}
	recovery_space_available "$tmp/space-media" "$STATE/staged"
	test ! -e "$STATE/staged/inode-check"
	(
		probe_inodes() { return 1; }
		if recovery_space_available "$tmp/space-media" "$STATE/staged"; then exit 1; fi
	)
	# A failed create must not be mistaken for a successful allocation probe.
	(
		mkdir() { command mkdir "$1" && command mkdir "$1/0"; }
		if probe_inodes "$STATE/staged/failed-probe" 2; then exit 1; fi
	)
	available=1024
	if recovery_space_available "$tmp/space-media" "$STATE/staged"; then exit 1; fi
	available=65536
	printf 'info:\n  installed-size: 73400320\n' >"$tmp/space-media/new.adb"
	if recovery_space_available "$tmp/space-media" "$STATE/staged"; then exit 1; fi
	printf 'info:\n  installed-size: 1025\n' >"$tmp/size.adb"
	test "$(apk_size_kib "$tmp/size.adb")" = 2
	printf '  installed-size: 1025\n' >>"$tmp/size.adb"
	if apk_size_kib "$tmp/size.adb"; then exit 1; fi
	printf 'info:\n  installed-size: unknown\n' >"$tmp/size.adb"
	if apk_size_kib "$tmp/size.adb"; then exit 1; fi
	printf 'info:\n  installed-size: 1025\n' >"$tmp/space-media/new.adb"
	df() { return 1; }
	if recovery_space_available "$tmp/space-media" "$STATE/staged"; then exit 1; fi
)

# Abandoned private staging is reclaimable; published state and symlinks are not.
(
	STATE="$tmp/stage-root"; JOURNAL="$STATE/current"
	mkdir -p "$STATE/.stage.ABC123" "$tmp/outside"
	printf 'partial WAL\n' >"$STATE/.stage.ABC123/media"
	printf 'keep\n' >"$tmp/outside/keep"
	# Ownership is tested natively as root; keep this host filesystem test runnable in unprivileged CI.
	owned_mode() { [ -d "$1" ] && [ ! -L "$1" ] && printf '0700\n'; }
	cleanup_staging
	test ! -e "$STATE/.stage.ABC123"
	ln -s "$tmp/outside" "$STATE/.stage.BAD123"
	if cleanup_staging; then exit 1; fi
	test "$(cat "$tmp/outside/keep")" = keep
	rm "$STATE/.stage.BAD123"
	mkdir "$JOURNAL" "$STATE/.stage.DEF456"
	if cleanup_staging; then exit 1; fi
	test -d "$STATE/.stage.DEF456"
)

# Host-only runs may lack a real ucode binary. The stand-in below emulates
# the exact fixed programs this suite invokes; it is not a ucode interpreter
# and proves nothing about real json() parsing, which must be exercised with a
# real OpenWrt ucode on the target runtime.
if ! command -v ucode >/dev/null 2>&1; then
	mkdir "$tmp/bin"
	cat >"$tmp/bin/ucode" <<'EOF'
#!/usr/bin/env python3
import base64
import json
import re
import sys

assert len(sys.argv) == 5 and sys.argv[1] == "-e" and sys.argv[3] == "--"
assert sys.argv[2].strip()
program, value = sys.argv[2], sys.argv[4]
if "json(ARGV[0])" in program:
    # Mirror dnsmasq_services_empty's fixed program: strict empty object, or a
    # single "dnsmasq" key holding an empty object; anything else mismatches.
    try:
        data = json.loads(value)
    except ValueError:
        sys.exit(1)
    if not isinstance(data, dict):
        sys.exit(1)
    if len(data) == 0:
        sys.exit(0)
    if len(data) == 1 and isinstance(data.get("dnsmasq"), dict) and len(data["dnsmasq"]) == 0:
        sys.exit(0)
    sys.exit(1)
if re.fullmatch(r"[0-9a-f]{64}", value):
    print(base64.b64encode(bytes.fromhex(value[:40])).decode("ascii"), end="")
else:
    assert re.fullmatch(r"[A-Za-z0-9+/]{27}=", value)
    print(base64.b64decode(value, validate=True)[:4].hex(), end="")
EOF
	chmod +x "$tmp/bin/ucode"
	export PATH="$tmp/bin:$PATH"
fi

# Only the two empty dnsmasq snapshots may differ in a restored WAL.
(
	wal="$tmp/dnsmasq-wal"
	snapshot='{"dnsmasq":{"instances":{"dnsmasq1":{"running":false}}}}'
	save_dnsmasq() { printf '%s\n%s\n' "$enabled" "$snapshot"; }
	matches() { printf '%s\n%s\n' "$1" "$2" >"$wal"; dnsmasq_state_matches "$wal"; }

	enabled=0
	matches 0 "$snapshot"
	enabled=1
	matches 1 "$snapshot"
	# The empty pair is interchangeable in both directions and for both flags.
	for form in '{}' '{"dnsmasq":{}}'; do
		enabled=0; snapshot='{}'
		matches 0 "$form"
		enabled=1
		matches 1 "$form"
		snapshot="$form"
		matches 1 '{}'
		enabled=0
		matches 0 '{}'
	done
	# Real ubus output is pretty-printed, including when it has no instances.
	snapshot=$(printf '{\n\t"dnsmasq": {\n\t\t\n\t}\n}')
	matches 0 "$(printf '{\n\t\n}')"
	snapshot=$(printf '{\n\t\n}')
	matches 0 "$(printf '{\n\t"dnsmasq": {\n\t\t\n\t}\n}')"
	enabled=invalid
	if matches invalid '{}'; then exit 1; fi
	enabled=0
	# An enabled flag change is never tolerated.
	snapshot='{}'
	if matches 1 '{}'; then exit 1; fi
	# Instances (running=false included), unknown keys, arrays, null, non-object
	# or broken JSON stay hard mismatches in either direction.
	for variant in \
		'{"dnsmasq":{"instances":{}}}' \
		'{"dnsmasq":{"instances":{"dnsmasq1":{"running":false}}}}' \
		'{"dnsmasq":[]}' \
		'{"dnsmasq":null}' \
		'{"dnsmasq":{},"unknown":{}}' \
		'{"other":{}}' \
		'{"dnsmasq":' \
		'0'
	do
		snapshot='{}'
		if matches 0 "$variant"; then exit 1; fi
		snapshot="$variant"
		if matches 0 '{}'; then exit 1; fi
	done
	# Malformed WALs never match, not even against an empty current state.
	snapshot='{}'
	printf '0\n' >"$wal"
	if dnsmasq_state_matches "$wal"; then exit 1; fi
	printf '0\n{}\nextra\n' >"$wal"
	if dnsmasq_state_matches "$wal"; then exit 1; fi
	# A failed collection is a hard failure, never a quiet pass.
	printf '0\n{}\n' >"$wal"
	save_dnsmasq() { printf '0\n{}\n'; return 1; }
	if dnsmasq_state_matches "$wal"; then exit 1; fi
	# Without the declared ucode dependency comparisons fail closed.
	save_dnsmasq() { printf '0\n%s\n' "$snapshot"; }
	rp_have() { [ "$1" != ucode ]; }
	if matches 0 '{}'; then exit 1; fi
	if matches 0 '{"dnsmasq":{}}'; then exit 1; fi
)

cat >"$tmp/package" <<'EOF'
info:
  name: smartdns
  version: 46.1-r1
  arch: x86_64
paths: # 2 items
  - name: etc/init.d
    acl:
      mode: 0755
      user: root
      group: root
    files: # 1 items
      - name: smartdns
        acl:
          mode: 0755
          user: root
          group: root
        hash: 2154e5670096b6f0190acbc8da3b95963b2a90bdc56b3c5fbf00e52ce652793b
  - name: usr/sbin
    acl:
      mode: 0755
      user: root
      group: root
    files: # 1 items
      - name: smartdns
        acl:
          mode: 0755
          user: root
          group: root
        hash: 1bb747991cd24c9b8ff7bee3ef8df817d16b95eea35b1217e056639eeee00b0f
scripts:
  post-install: |
    #!/bin/sh
EOF
apk_file_list "$tmp/package" >"$tmp/files"
test "$(cut -f 1 "$tmp/files")" = "$(printf 'etc/init.d/smartdns\nusr/sbin/smartdns')"
sed 's/user: root/user: runner/' "$tmp/package" >"$tmp/runner"
if apk_file_list "$tmp/runner"; then exit 1; fi
sed 's/mode: 0755/mode: 0775/' "$tmp/package" >"$tmp/writable"
if apk_file_list "$tmp/writable"; then exit 1; fi
sed 's@etc/init.d@etc/../etc/init.d@' "$tmp/package" >"$tmp/escape"
if apk_file_list "$tmp/escape"; then exit 1; fi

cat >"$tmp/index" <<'EOF'
packages: # 2 items
  - name: other
    version: 46.1-r1
    arch: x86_64
    hashes: 49a98cbc788ea160d22e3dbf42d83eb739565254
  - name: smartdns
    version: 46.1-r1
    arch: x86_64
    hashes: 314bf7c735dc0595ee2f454670bca3f0030a1b9f4b1ad25c5afbba79ab1115fa
EOF
test "$(index_identity "$tmp/index" 46.1-r1 x86_64)" = Q1MUv3xzXcBZXuL0VGcLyj8AMKG58=
if index_identity "$tmp/index" 46.1-r0 x86_64; then exit 1; fi

cat >"$tmp/writer-admit" <<'EOF'
set -eu
. "$1/common"
RP_ETC="$2/etc/routepolicy"
RP_STATE_DIR="$RP_ETC/state"
RP_RUN_DIR="$2/run"
RP_SMARTDNS_PACKAGE_STATE="$RP_STATE_DIR/smartdns-package"
mkdir -p "$RP_SMARTDNS_PACKAGE_STATE/current"
rp_config_admit() { return 1; }
operation='package-switch'
if rp_writer_enter smartdns-package quarantine; then exit 1; fi
operation='package-recover-early'
rp_writer_enter smartdns-package quarantine
rp_writer_owned
if rp_writer_enter smartdns-package; then exit 1; fi
EOF
sh "$tmp/writer-admit" "$LIBEXEC" "$tmp/gate"

cat >"$tmp/synchronous-recover" <<'EOF'
set -eu
export ROUTEPOLICY_ROOT="$2" ROUTEPOLICY_LIBEXEC="$1"
expected_action=$4
recovery_boot=${5:-same}
. "$3"
# Simulate native service and package actions. Use the real FD9 gate.
uci() {
	[ "$*" = '-q get routepolicy.main.config_schema' ] || return 1
	printf '%s\n' "$schema"
}
owned_regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
quiesce() { :; }
installed_id() { printf '46.1-r1\tx86_64\told\n'; }
no_pending_config() { :; }
other_config_unchanged() { :; }
reconcile_package() { rp_writer_owned && [ "$1" = old ] && touch "$package_restored"; }
same_boot() { [ "$recovery_boot" = same ]; }
init_dns_enabled() { [ "$1" = dnsmasq ] && printf '0\n'; }
restore_service() { [ "$1" = managed ] && touch "$dns_restored"; }
preserve_config() { :; }
save_dnsmasq() { printf '0\n%s\n' "$services_snapshot"; }

schema=1
operation=$expected_action
rp_writer_enter smartdns-package
mkdir -p "$JOURNAL" "$RP_STATE_DIR/init-transaction/declarations"
printf 'apk-attempted\n' >"$JOURNAL/phase"
printf 'managed\n' >"$JOURNAL/role"
# The saved WAL holds the bare "{}" form; the reload leaves an empty container.
printf '0\n{}\n' >"$JOURNAL/dnsmasq"
services_snapshot='{"dnsmasq":{}}'
installed_id >"$JOURNAL/old.id"
printf 'candidate\n' >"$JOURNAL/new.id"
package_restored="$RP_ROOT/package-restored"
dns_restored="$RP_ROOT/dns-restored"

schema=2
if recover_transaction; then exit 1; fi
[ -f "$JOURNAL/phase" ] && [ ! -e "$package_restored" ] && [ ! -e "$dns_restored" ]
schema=1
printf 'installing\n' >"$RP_STATE_DIR/init-transaction/declarations/phase"
if recover_transaction; then exit 1; fi
[ -f "$JOURNAL/phase" ] && [ ! -e "$package_restored" ] && [ ! -e "$dns_restored" ]
printf 'committed\n' >"$RP_STATE_DIR/init-transaction/declarations/phase"
if [ "$expected_action" = package-recover ]; then rp_writer_enter smartdns-package
elif rp_writer_enter smartdns-package; then exit 1; fi

recover_transaction
[ "$operation" = "$expected_action" ] && [ ! -e "$JOURNAL" ] && [ -f "$package_restored" ]
if [ "$recovery_boot" = same ]; then [ -f "$dns_restored" ]
else [ ! -e "$dns_restored" ] && ! rp_dns_boot_pending; fi
EOF
for action in package-switch package-rollback; do
	sh "$tmp/synchronous-recover" "$LIBEXEC" "$tmp/$action" "$tmp/readers" "$action"
done
sh "$tmp/synchronous-recover" "$LIBEXEC" "$tmp/cold-recover" "$tmp/readers" package-recover cold
printf '%s\n' 'package recovery gate: same-boot DNS restore and cold managed deferral without pending passed'

(
	# Model apk's rejection of commit-only switches on read applets.
	APK_CONFIG="$tmp/untrusted-apk-config"
	export APK_CONFIG
	apk() {
		[ "$APK_CONFIG:$1:$2:$3" = '/dev/null:--progress=no:--network=no:--repositories-file' ] || return 94
		repo=$4; applet=$5; shift 5
		case "$applet" in
			adbdump|verify) [ "$repo:$*" = /dev/null:sample.apk ] ;;
			fetch) [ "$repo:$*" = local-repos:'--stdout smartdns' ] ;;
			add) [ "$#" = 4 ] && [ "$repo:$*" = /dev/null:'--scripts=no --commit-hooks=no --simulate smartdns' ] ;;
			fix) [ "$#" = 4 ] && [ "$repo:$*" = local-repos:'--scripts=no --commit-hooks=no --simulate smartdns' ] ;;
			*) return 1 ;;
		esac
	}
	apk_local adbdump sample.apk
	apk_local verify sample.apk
	apk_indexed local-repos fetch --stdout smartdns
	apk_local add --simulate smartdns
	apk_indexed local-repos fix --simulate smartdns
	[ "$APK_CONFIG" = "$tmp/untrusted-apk-config" ]
)

printf 'data\n' >"$tmp/input"
chmod 640 "$tmp/input"
details=$(path_details "$tmp/input")
[ "${details#- 0640 }" != "$details" ] && [ "${details##* }" = 5 ]
safe_input "$tmp/input"

(
	RP_ROOT="$tmp/quarantine-root"
	mkdir -p "$RP_ROOT/etc/rc.d"
	ln -s ../init.d/smartdns "$RP_ROOT/etc/rc.d/S19smartdns"
	ln -s /etc/init.d/smartdns "$RP_ROOT/etc/rc.d/K82smartdns"
	ln -s ../init.d/other "$RP_ROOT/etc/rc.d/S50other"
	owned_mode() { [ "$2" = l ] && [ -L "$1" ]; }
	owned_parents() { [ "$1" = "$RP_ROOT/etc/rc.d/smartdns" ]; }
	init_dns_stop() { touch "$tmp/stopped"; }
	quiesce
	boot_links_absent
	[ -L "$RP_ROOT/etc/rc.d/S50other" ] && [ -f "$tmp/stopped" ]
	ln -s ../init.d/other "$RP_ROOT/etc/rc.d/S19smartdns"
	rm "$tmp/stopped"
	if quiesce; then exit 1; fi
	[ -L "$RP_ROOT/etc/rc.d/S19smartdns" ] && [ ! -e "$tmp/stopped" ]
)

(
	# Keep fixture behavior in this subshell, with no production test switch.
	RP_ROOT="$tmp/guest"
	JOURNAL="$RP_ROOT/current"
	mkdir -p "$JOURNAL" "$RP_ROOT/lib/apk/db" "$tmp/media" "$tmp/work"
	owned_regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
	cat >"$RP_ROOT/lib/apk/db/installed" <<'EOF'
C:Q1MUv3xzXcBZXuL0VGcLyj8AMKG58=
P:smartdns
V:46.1-r1
A:x86_64
EOF
	cp "$tmp/index" "$tmp/media/packages.adb"
	cp "$tmp/package" "$tmp/media/smartdns-46.1-r1.apk"
	apk_local() {
		case "$1" in verify) return 0 ;; adbdump) cat "$2" ;; *) exit 91 ;; esac
	}
	apk_indexed() {
		[ "$2:$3:$4" = fetch:--stdout:smartdns ] || exit 92
		[ "${CORRUPT:-0}" = 0 ] || return 1
		cat "$(dirname "$(cat "$1")")/smartdns-46.1-r1.apk"
	}
	expected=$(installed_id)
	prepare_indexed_media "$tmp/media" "$tmp/work" old "$expected"
	CORRUPT=1
	if prepare_indexed_media "$tmp/media" "$tmp/work" bad "$expected"; then exit 1; fi
	CORRUPT=0
	if prepare_indexed_media "$tmp/media" "$tmp/work" mismatch "$(printf '46.1-r1\tx86_64\tQ1SamMvHiOoWDSLj2/Qtg+tzlWUlQ=')"; then exit 1; fi
	source_pin fork
	# pin_digest is set by source_pin from the dynamically sourced helper.
	# shellcheck disable=SC2154
	asset_digest() { printf '%s\n' "$pin_digest"; }
	# source_pin also assigns the native version and identity in the sourced helper.
	# shellcheck disable=SC2154
	sed -e "s/version: 46.1-r1/version: $pin_version/" "$tmp/runner" >"$tmp/unsafe.apk"
	if read_apk "$tmp/unsafe.apk" "$tmp/work/unsafe" fork; then exit 1; fi

	# A prepared journal must reenter cleanup without calling a service or APK.
	RP_SMARTDNS_PACKAGE_STATE="$RP_ROOT/package-state"
	STATE=$RP_SMARTDNS_PACKAGE_STATE
	JOURNAL="$STATE/current"
	mkdir -p "$JOURNAL" "$RP_ROOT/etc/config"
	printf 'external\n' >"$RP_ROOT/etc/config/smartdns"
	printf 'prepared\n' >"$JOURNAL/phase"
	quiesce() { exit 93; }
	rp_smartdns_package_pending
	recover_transaction
	if rp_smartdns_package_pending; then exit 1; fi
	test "$(cat "$RP_ROOT/etc/config/smartdns")" = external

	# ELF checks exercise the actual byte reader on a positive and a foreign header.
	mkdir -p "$RP_ROOT/usr/sbin"
	printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\076\000' >"$RP_ROOT/usr/sbin/smartdns"
	native_elf_x86_64
	printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\267\000' >"$RP_ROOT/usr/sbin/smartdns"
	if native_elf_x86_64; then exit 1; fi

	# Distinguish a missing package in an intact DB, an unknown installed image and a broken DB.
	database="$RP_ROOT/lib/apk/db/installed"
	cat >"$database" <<'EOF'
C:Q1MUv3xzXcBZXuL0VGcLyj8AMKG58=
P:some-package
V:1-r0
A:x86_64
EOF
	status=0
	installed_id || status=$?
	test "$status" = 2
	cat "$database" >"$tmp/db-without-smartdns"
	mkdir -p "$JOURNAL"
	printf 'apk-attempted\n' >"$JOURNAL/phase"
	printf 'inactive\n' >"$JOURNAL/role"
	printf 'feed\n' >"$JOURNAL/old.source"
	printf '%s\n' "$expected" >"$JOURNAL/old.id"
	# shellcheck disable=SC2154
	printf '%s\tx86_64\t%s\n' "$pin_version" "$pin_id" >"$JOURNAL/new.id"
	no_pending_config() { return 0; }
	other_config_unchanged() { return 0; }
	quiesce() { touch "$tmp/quiesced"; }
	reconcile_package() { [ "$1:$2" = old: ] && touch "$tmp/old-restored"; }
	rp_writer_enter() { [ "${configuration_schema:-supported}" = supported ]; }
	# recover_transaction reads the operation from the dynamically sourced helper.
	# shellcheck disable=SC2034
	operation='package-recover-early'
	configuration_schema=unsupported
	if recover_transaction; then exit 1; fi
	test -f "$tmp/quiesced"
	test ! -e "$tmp/old-restored"
	test -d "$JOURNAL"
	configuration_schema=supported
	rm "$tmp/quiesced"
	printf '\nP:truncated\n' >>"$database"
	if recover_transaction; then exit 1; fi
	test -f "$tmp/quiesced"
	test ! -e "$tmp/old-restored"
	sed 's/some-package/smartdns/' "$tmp/db-without-smartdns" >"$database"
	if recover_transaction; then exit 1; fi
	test ! -e "$tmp/old-restored"
	cp "$tmp/db-without-smartdns" "$database"
	printf 'fork\n' >"$JOURNAL/old.source"
	recover_transaction
	test -f "$tmp/old-restored"
	test "$(cat "$RP_ROOT/etc/config/smartdns")" = external

	# A missing DB entry may only trigger an exact, single-package signed-index plan.
	plan='(1/1) Installing smartdns (46.1-r1)'
	apk_indexed() { printf '%s\n' "$plan"; }
	indexed_add_plan "$tmp/repos" smartdns=46.1-r1 46.1-r1 "$tmp/plan" install
	plan='(1/2) Installing smartdns (46.1-r1)
(2/2) Installing unexpected (1-r0)'
	if indexed_add_plan "$tmp/repos" smartdns=46.1-r1 46.1-r1 "$tmp/plan" install; then exit 1; fi
	plan='OK: no package changes'
	if indexed_add_plan "$tmp/repos" smartdns=46.1-r1 46.1-r1 "$tmp/plan" install; then exit 1; fi
	plan='( 1/10) Purging other (1-r0)
(1/1) Replacing smartdns (46.1-r1)'
	if indexed_add_plan "$tmp/repos" smartdns=46.1-r1 46.1-r1 "$tmp/plan"; then exit 1; fi
	apk_local() { printf '%s\n' "$plan"; }
	if package_plan "$tmp/plan" "$tmp/old.apk" 46.1-r1; then exit 1; fi
	plan='(1/1) Replacing smartdns (46.1-r1)'
	package_plan "$tmp/plan" "$tmp/old.apk" 46.1-r1
	plan='(1/1) Installing smartdns (46.1-r1)'
	package_plan "$tmp/plan" "$tmp/old.apk" 46.1-r1 install
)

(
	# The same native identity maps to an exact cache filename. A simulated
	# dependency change must leave the command's real reinstall branch untouched.
	JOURNAL="$tmp/cache-journal"
	mkdir -m 700 "$JOURNAL"
	printf '%s\n' 'exact archive' >"$tmp/exact.apk"
	owned_mode() { [ "$1:$2" = "$JOURNAL:d" ] && printf '0700\n'; }
	original_selectors() { printf '%s\n' 'smartdns><Q1MUv3xzXcBZXuL0VGcLyj8AMKG58='; }
	apk_local() {
		[ "$1:$2" = fix:--cache-dir ] && cmp -s "$tmp/exact.apk" "$3/smartdns-46.1-r1.314bf7c7.apk" || return 1
		case "$4:$5:$6" in
			--simulate:--reinstall:--allow-untrusted)
				[ "$7" = smartdns ] && printf '%s\n' "$plan" ;;
			--reinstall:--allow-untrusted:smartdns) printf '%s\n' "$result"; touch "$tmp/fixed" ;;
			*) return 1 ;;
		esac
	}
	plan='(1/2) Reinstalling smartdns (46.1-r1)
(2/2) Purging other (1-r0)'
	if reinstall_fixed_apk "$tmp/exact.apk" 46.1-r1 Q1MUv3xzXcBZXuL0VGcLyj8AMKG58=; then exit 1; fi
	[ ! -e "$tmp/fixed" ]
	plan='(1/1) Reinstalling smartdns (46.1-r1)'
	result='(1/1) [APK unavailable, skipped] Reinstalling smartdns (46.1-r1)'
	if reinstall_fixed_apk "$tmp/exact.apk" 46.1-r1 Q1MUv3xzXcBZXuL0VGcLyj8AMKG58=; then exit 1; fi
	[ -f "$tmp/fixed" ]
	rm "$tmp/fixed"
	result=$plan
	reinstall_fixed_apk "$tmp/exact.apk" 46.1-r1 Q1MUv3xzXcBZXuL0VGcLyj8AMKG58=
	[ -f "$tmp/fixed" ] && [ -z "$(ls -A "$JOURNAL")" ]
)

printf '%s\n' 'SmartDNS package ownership and signed-media checks passed'
