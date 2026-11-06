#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-lifecycle.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" ROUTEPOLICY_OUTPUT=json
mkdir -p "$tmp/bin" "$tmp/root/etc/config" "$tmp/root/etc/routepolicy/user.d" "$tmp/root/proc/sys/kernel/random"
printf '00000000-0000-4000-8000-000000000001\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
cat >"$tmp/bin/uci" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
config = pathlib.Path(os.environ['ROUTEPOLICY_ROOT'])/'etc/config'
while args and args[0].startswith('-'):
    flag = args.pop(0)
    if flag in ('-c', '-t'):
        value = args.pop(0)
        if flag == '-c': config = pathlib.Path(value)
op = args.pop(0)
key = args[0] if args else ''
package = key.split('.')[0].split('=')[0]
dbfile = config/(package+'.test-json')
db = json.loads(dbfile.read_text()) if dbfile.exists() else {}
if op == 'get':
    if key not in db: sys.exit(1)
    print(db[key])
elif op == 'set':
    key, value = key.split('=',1); db[key] = value
    config.mkdir(parents=True, exist_ok=True)
    dbfile.write_text(json.dumps(db, ensure_ascii=False))
    (config/package).write_text('# fixture UCI\n')
elif op == 'show':
    for field,value in db.items(): print(field+'='+value)
elif op in ('changes','commit'): pass
else: sys.exit(1)
PY
chmod +x "$tmp/bin/uci"
for command_name in ubus jsonfilter nft ip; do printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$command_name"; chmod +x "$tmp/bin/$command_name"; done
export PATH="$tmp/bin:$PATH"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, re, sys
root = pathlib.Path(os.environ['ROUTEPOLICY_ROOT'])
text = (pathlib.Path(sys.argv[1])/'routepolicy/files/etc/config/routepolicy').read_text()
values = {'routepolicy.main':'main'}
for key,value in re.findall(r"option\s+(\w+)\s+'([^']*)'",text): values['routepolicy.main.'+key]=value
values.update({'routepolicy.feed':'source','routepolicy.feed.enabled':'0','routepolicy.feed.name':'中文来源','routepolicy.feed.url':'https://example.invalid/list'})
(root/'etc/config/routepolicy.test-json').write_text(json.dumps(values,ensure_ascii=False))
(root/'etc/config/routepolicy').write_text('# original app configuration\n')
(root/'etc/config/smartdns.test-json').write_text(json.dumps({'smartdns.main':'smartdns','smartdns.main.unknown':'keep'}))
for package in ('network','dhcp','firewall','smartdns'): (root/'etc/config'/package).write_text('unchanged '+package+'\n')
PY
tool="$ROUTEPOLICY_LIBEXEC/lifecycle"
export ROUTEPOLICY_OUTPUT=text
sh "$tool" config-export >"$tmp/export"
grep -Fq '中文来源' "$tmp/export"
grep -Fq 'unportable	smartdns.main.unknown' "$tmp/export"
sh "$tool" config-import <"$tmp/export" >"$tmp/import-status"
grep -Fq '"candidate_pending":true' "$tmp/import-status"
[ "$(uci -c "$tmp/root/tmp/routepolicy/restore/config" get routepolicy.feed.name)" = 中文来源 ]
for package in network dhcp firewall smartdns; do [ "$(cat "$tmp/root/etc/config/$package")" = "unchanged $package" ]; done
reject() { if sh "$tool" config-import <"$1" >/dev/null 2>&1; then printf 'accepted malicious declaration: %s\n' "$1" >&2; exit 1; fi; }
printf 'routepolicy-config\t2\nsensitive\t1\n' >"$tmp/future"; reject "$tmp/future"
for payload in 'file	../../etc/config/network	anything' 'rule	../network	anything' 'journal	current	confirmed' 'main	enabled	1
main	enabled	0'; do
	{ printf 'routepolicy-config\t1\nsensitive\t1\n'; printf '%b\n' "$payload"; } >"$tmp/bad"; reject "$tmp/bad"
done
{ cat "$tmp/export"; printf 'main\tname\tbad\001value\n'; } >"$tmp/control"; reject "$tmp/control"
{ cat "$tmp/export"; printf 'source\tfeed.name\t\300\257\n'; } >"$tmp/utf8"; reject "$tmp/utf8"
dd if=/dev/zero of="$tmp/huge" bs=1024 count=2050 2>/dev/null; reject "$tmp/huge"
mkdir -p "$tmp/lib/converters"
cp "$ROUTEPOLICY_LIBEXEC/common" "$ROUTEPOLICY_LIBEXEC/lifecycle" "$tmp/lib/"
cp "$ROUTEPOLICY_LIBEXEC/converter-lib" "$tmp/lib/"
cp "$ROUTEPOLICY_LIBEXEC/converters/"* "$tmp/lib/converters/"
printf '#!/bin/sh\nexit 0\n' >"$tmp/lib/init-topology"
cat >"$tmp/lib/init-transaction" <<'SH'
#!/bin/sh
printf '{"ok":true,"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
SH
chmod +x "$tmp/lib/init-topology" "$tmp/lib/init-transaction"
export ROUTEPOLICY_LIBEXEC="$tmp/lib"
tool="$tmp/lib/lifecycle"
cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
/usr/bin/mv "$@" || exit $?
target=
for arg do target=$arg; done
if [ -n "${TEST_DECL_KILL_TO:-}" ] && [ "$target" = "$TEST_DECL_KILL_TO" ]; then kill -KILL "$PPID"; fi
SH
chmod +x "$tmp/bin/mv"
mapping=$(printf 'lan\twan\tusbwan\t-\t-\t-\t-\t-\t-\t-\t-\t192.0.2.53\t198.51.100.53\t1\t1\n')
if printf '%s\n\n' "$mapping" | sh "$tool" restore-prepare >/dev/null 2>&1; then printf 'multi-line mapping accepted\n' >&2; exit 1; fi
if printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\n' | sh "$tool" init-apply-request >/dev/null 2>&1; then printf 'multi-line token accepted\n' >&2; exit 1; fi
journal="$tmp/root/etc/routepolicy/state/init-transaction/declarations"
for name in domain-policy domain-default ipv4-policy ipv4-default local-hosts; do printf '# original %s\n' "$name" >"$tmp/root/etc/routepolicy/user.d/$name.list"; done
cp "$tmp/root/etc/config/routepolicy" "$tmp/app.before"
for key in routepolicy domain-policy domain-default ipv4-policy ipv4-default local-hosts; do
	case "$key" in routepolicy) target="$tmp/root/etc/config/routepolicy" ;; *) target="$tmp/root/etc/routepolicy/user.d/$key.list" ;; esac
	if printf '%s\n' "$mapping" | TEST_DECL_KILL_TO="$target" sh "$tool" restore-prepare >/dev/null 2>&1; then printf 'declaration kill point was not reached: %s\n' "$key" >&2; exit 1; fi
	[ "$(cat "$journal/phase")" = installing ]
	if sh "$tool" migrate >/dev/null 2>&1; then printf 'other writer bypassed incomplete declarations\n' >&2; exit 1; fi
	sh "$tool" restore-recover >/dev/null
	cmp "$tmp/app.before" "$tmp/root/etc/config/routepolicy"
	for name in domain-policy domain-default ipv4-policy ipv4-default local-hosts; do [ "$(cat "$tmp/root/etc/routepolicy/user.d/$name.list")" = "# original $name" ]; done
done
target="$tmp/root/etc/routepolicy/user.d/domain-policy.list"
if printf '%s\n' "$mapping" | TEST_DECL_KILL_TO="$target" sh "$tool" restore-prepare >/dev/null 2>&1; then exit 1; fi
printf 'external edit\n' >"$target"
cp "$tmp/root/etc/config/routepolicy" "$tmp/partial-app"
if sh "$tool" restore-recover >/dev/null 2>&1; then printf 'external declaration edit overwritten\n' >&2; exit 1; fi
[ "$(cat "$target")" = 'external edit' ]; cmp "$tmp/partial-app" "$tmp/root/etc/config/routepolicy"
cp "$journal/expected/domain-policy" "$target"
if TEST_DECL_KILL_TO="$tmp/root/etc/config/routepolicy" sh "$tool" restore-recover >/dev/null 2>&1; then exit 1; fi
sh "$tool" restore-recover >/dev/null
cmp "$tmp/app.before" "$tmp/root/etc/config/routepolicy"
uci set routepolicy.main.config_schema=2
if sh "$tool" config-export >/dev/null 2>&1; then printf 'future schema executed\n' >&2; exit 1; fi
printf '%s\n' 'lifecycle declaration tests: passed (UTF-8, unknown DNS, staging, strict schema, paths, journal, duplicates, controls, size)'
printf '%s\n' 'declaration interruption tests: passed (six install boundaries, writer exclusion, external conflict, interrupted recovery)'
