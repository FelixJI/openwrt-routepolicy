#!/bin/sh
# Real native stop/start callbacks, with only process/config-generation boundaries isolated.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
if [ -z "${TEST_UCI_SDK_ROOT:-}" ] || [ -z "${TEST_SMARTDNS_INIT:-}" ]; then
	printf 'native DNS shutdown: skipped (provide official TEST_UCI_SDK_ROOT and TEST_SMARTDNS_INIT)\n'
	exit 0
fi
export TEST_SHUTDOWN_REPO=$ROOT
python3 - <<'PY'
import fcntl, json, os, pathlib, shutil, subprocess, tempfile, time

repo = pathlib.Path(os.environ['TEST_SHUTDOWN_REPO'])
off = pathlib.Path(os.environ['TEST_UCI_SDK_ROOT'])
tmp = pathlib.Path(tempfile.mkdtemp(prefix='routepolicy-dns-shutdown-', dir=os.environ.get('TMPDIR')))
root, bindir, lib = tmp/'root', tmp/'bin', tmp/'lib'
env = os.environ.copy()
env.update(F22_DIR=str(tmp), F22_ROOT=str(root), F22_OFF=str(off), IPKG_INSTROOT=str(root),
           ROUTEPOLICY_ROOT=str(root), ROUTEPOLICY_LIBEXEC=str(lib),
           ROUTEPOLICY_INIT_TRANSACTION=str(lib/'init-transaction'), ROUTEPOLICY_APPLY=str(bindir/'apply'),
           PATH=str(bindir)+':'+env['PATH'])
results = []
def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)
def run(args, expected=0, extra=None):
    actual_env = env.copy(); actual_env.update(extra or {})
    result = subprocess.run([str(x) for x in args], env=actual_env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    results.append({'argv': [str(x) for x in args], 'rc': result.returncode})
    if expected is not None and result.returncode != expected:
        raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return result
try:
    shutil.copytree(pathlib.Path(os.environ.get('TEST_INIT_LIBEXEC', str(repo/'routepolicy/files/usr/libexec/routepolicy'))), lib)
    for path in [root/'etc/config', root/'etc/rc.d', root/'var/lock', root/'usr/share/libubox', tmp/'delta']:
        path.mkdir(parents=True)
    shutil.copy(off/'lib/functions/procd.sh', root/'lib-procd')
    write(root/'lib/functions/procd.sh', (root/'lib-procd').read_text())
    shutil.copy(off/'usr/share/libubox/jshn.sh', root/'usr/share/libubox/jshn.sh')
    write(root/'lib/functions/service.sh', '')
    write(root/'lib/functions.sh', '''list_contains() { eval "case \\" \\$$1 \\" in *\\" $2 \\"*) return 0 ;; *) return 1 ;; esac"; }
config_load() { :; }
config_get() { local target=$1 section=$2 option=$3 fallback=${4-} value; value=$(uci -q get "smartdns.$section.$option") || value=$fallback; export "$target=$value"; }
config_get_bool() { config_get "$@"; }
config_foreach() { local callback=$1 type=$2; [ "$type" != smartdns ] || "$callback" '@smartdns[0]'; return 0; }
config_list_foreach() { :; }
''')
    target = 'exec "$F22_OFF/lib/ld-musl-x86_64.so.1" --library-path "$F22_OFF/lib:$F22_OFF/usr/lib" '
    write(bindir/'target-ash', '#!/bin/sh\n'+target+'"$F22_OFF/bin/busybox" ash "$@"\n')
    write(bindir/'target-rc', '#!/bin/sh\nexec target-ash "$F22_OFF/etc/rc.common" "$@"\n')
    for command in ['jshn', 'jsonfilter']:
        write(bindir/command, '#!/bin/sh\n'+target+'"$F22_OFF/usr/bin/'+command+'" "$@"\n')
    write(bindir/'uci', '''#!/bin/sh
[ "${1:-}" != -q ] || shift
case "${1:-}" in -c|-t) exec "$F22_OFF/lib/ld-musl-x86_64.so.1" --library-path "$F22_OFF/lib:$F22_OFF/usr/lib" "$F22_OFF/sbin/uci" -q "$@" ;; esac
operation=$1; shift; key=${1-}; package=${key%%.*}
case "$package" in dhcp|network|smartdns|routepolicy|firewall) key="f22_$package${key#"$package"}" ;; *) exit 91 ;; esac
[ "$#" = 0 ] || shift
printf '%s %s\n' "$operation" "$key" >>"$F22_DIR/uci-commands"
case "$operation" in show|changes)
 output=$("$F22_OFF/lib/ld-musl-x86_64.so.1" --library-path "$F22_OFF/lib:$F22_OFF/usr/lib" "$F22_OFF/sbin/uci" -q -c "$F22_ROOT/etc/config" -t "$F22_DIR/delta" "$operation" "$key" "$@") || exit $?
 [ -z "$output" ] || printf '%s\n' "$output" | sed "s/^f22_$package/$package/"
 exit 0 ;;
esac
exec "$F22_OFF/lib/ld-musl-x86_64.so.1" --library-path "$F22_OFF/lib:$F22_OFF/usr/lib" "$F22_OFF/sbin/uci" -q -c "$F22_ROOT/etc/config" -t "$F22_DIR/delta" "$operation" "$key" "$@"
''')
    write(bindir/'ubus', '#!/bin/sh\nprintf "{}\\n"\n')
    write(bindir/'apply', '#!/bin/sh\nprintf "%s\\n" "$*" >>"$F22_DIR/apply-calls"\n')
    write(lib/'apply', (bindir/'apply').read_text())
    write(bindir/'dnsmasq-native', '#!/bin/sh\nprintf "%s\\n" "$*" >>"$F22_DIR/dnsmasq-calls"\n')
    write(root/'etc/init.d/dnsmasq', '#!/bin/sh\n[ "$1" != enabled ]\n')
    native = pathlib.Path(os.environ['TEST_SMARTDNS_INIT']).read_text()
    native = native.replace('/etc/init.d/dnsmasq', str(bindir/'dnsmasq-native'))
    native += '''
SMARTDNS_VAR_CONF_DIR="$F22_ROOT/var/etc/smartdns"
SMARTDNS_CONF="$SMARTDNS_VAR_CONF_DIR/smartdns.conf"
SMARTDNS_CONF_TMP="$SMARTDNS_CONF.tmp"
SMARTDNS_CONF_DIR="$F22_ROOT/etc/smartdns"
ADDRESS_CONF="$SMARTDNS_CONF_DIR/address.conf"
BLACKLIST_IP_CONF="$SMARTDNS_CONF_DIR/blacklist-ip.conf"
CUSTOM_CONF="$SMARTDNS_CONF_DIR/custom.conf"
enable_auto_update() { :; }
disable_auto_update() { :; }
get_tz() { SET_TZ=; }
conf_append_bind() { :; }
load_second_server() { :; }
'''
    write(root/'source/smartdns', native)
    write(root/'etc/init.d/smartdns', '''#!/bin/sh
[ ! -f "$F22_DIR/disable-fail" ] || [ "$1" != disable ] || exit 42
exec target-rc "$F22_ROOT/source/smartdns" "$@"
''')
    init = pathlib.Path(os.environ.get('TEST_SHUTDOWN_INIT', str(repo/'routepolicy/files/etc/init.d/routepolicy')))
    smart = root/'etc/init.d/smartdns'
    dhcp = "config dnsmasq\n option port '0'\n option disabled '1'\n list server '/corp.example/10.20.0.53'\nconfig dhcp 'lan'\n list dhcp_option '6,192.168.1.1/24'\n list dhcp_option '42,192.0.2.8'\n"
    configs = {'dhcp': dhcp, 'network': "config interface 'lan'\n option ipaddr '192.168.1.1/24'\n",
               'smartdns': "config smartdns\n option enabled '1'\n option old_enabled '1'\n option port '53'\n option old_port '53'\n option auto_set_dnsmasq '0'\n option old_auto_set_dnsmasq '0'\n option cache_persist '1'\n option cache_file '/tmp/routepolicy/smartdns.cache'\n option server_flags '-group rp_init_default'\n",
               'routepolicy': "config main 'main'\n option enabled '1'\n option smartdns_enabled '1'\n", 'firewall': ''}
    for package, data in configs.items():
        write(root/'etc/config'/package, data)
        (root/'etc/config'/('f22_'+package)).symlink_to(package)
    boot = root/'proc/sys/kernel/random/boot_id'; write(boot, '00000000-0000-4000-8000-000000000001\n')
    tx = root/'etc/routepolicy/state/init-transaction'; current = tx/'current'; active = tx/('confirmed-'+'a'*32)
    for path in [current, active]: path.mkdir(parents=True)
    for name, value in {'phase':'prepared', 'token':'b'*32, 'prepared-boot-id':boot.read_text(), 'candidate':''}.items(): write(current/name, value)
    for name, value in {'phase':'confirmed', 'token':'a'*32, 'boot-id':boot.read_text(), 'policy-active':'0', 'parameters':'lan\twan\twan2\t-\t-\t-\t-\t-\t-\t-\t-\t192.0.2.53\t198.51.100.53\n'}.items(): write(active/name, value)
    write(tx/'active', 'a'*32)
    values = [('smartdns.@smartdns[0].enabled','1'), ('smartdns.@smartdns[0].old_enabled','1'),
              ('smartdns.@smartdns[0].port','53'), ('smartdns.@smartdns[0].old_port','53'),
              ('smartdns.@smartdns[0].auto_set_dnsmasq','0'), ('smartdns.@smartdns[0].old_auto_set_dnsmasq','0'),
              ('smartdns.@smartdns[0].cache_persist','1'),
              ('smartdns.@smartdns[0].cache_file','/tmp/routepolicy/smartdns.cache'),
              ('smartdns.@smartdns[0].server_flags','-group rp_init_default'),
              ('dhcp.@dnsmasq[0].port','0'), ('dhcp.@dnsmasq[0].disabled','1')]
    write(active/'candidate', ''.join('set\t'+key+'\t'+value+'\n' for key,value in values))
    for row,(key,value) in enumerate(values,1):
        for name,data in {'key':key,'expected':value,'expected-type':'scalar','attempted':''}.items(): write(active/'fields'/str(row)/name,data)
    transaction = lib/'init-transaction'
    write(bindir/'transaction', '''#!/bin/sh
if [ "$1" = shutdown-dns ]; then
 [ ! -e "/proc/$$/fd/1000" ] || exit 73
 printf 'shutdown before procd FD1000\n' >>"$F22_DIR/lock-order"
fi
exec "$ROUTEPOLICY_LIBEXEC/init-transaction" "$@"
''')
    env['ROUTEPOLICY_INIT_TRANSACTION']=str(bindir/'transaction')
    # Red control uses the unchanged official callbacks, including same-value user option deletion.
    run([smart,'shutdown']); assert run([bindir/'uci','get','dhcp.@dnsmasq[0].port'],None).returncode != 0
    run([smart,'start']); assert run([bindir/'uci','get','dhcp.lan.dhcp_option']).stdout.split() == ['42,192.0.2.8','6,192.168.1.1/24']
    print('native red control: reproduced native stop/start DHCP option edit')
    write(root/'etc/config/dhcp', dhcp)
    for path in (tmp/'delta').iterdir(): path.unlink()
    run([smart,'enable']); queued = root/'etc/rc.d/K82smartdns'; assert queued.is_symlink()
    run([bindir/'target-rc',init,'shutdown'])
    assert 'shutdown before procd FD1000' in (tmp/'lock-order').read_text()
    assert not queued.exists(); before=(tmp/'uci-commands').read_text()
    assert run([bindir/'target-rc',queued,'shutdown'],None).returncode != 0
    assert (tmp/'uci-commands').read_text() == before
    assert (root/'etc/config/dhcp').read_text() == dhcp
    # Native start at the S94 boundary sees preserved port0 and preserves all options.
    run([smart,'start']); assert (root/'etc/config/dhcp').read_text() == dhcp
    # Normal manual stop does not acquire shutdown semantics or remove K82.
    run([smart,'enable']); run([bindir/'target-rc',init,'stop']); assert queued.exists()
    # A real competing writer makes K10 fail promptly, without mutating DHCP.
    with (tx/'lock').open('w') as held:
        fcntl.flock(held,fcntl.LOCK_EX)
        started=time.monotonic()
        assert run([bindir/'target-rc',init,'shutdown'],None).returncode != 0
        assert time.monotonic()-started < 12 and queued.exists()
    for key, value in [('dhcp.@dnsmasq[0].port','53'), ('dhcp.@dnsmasq[0].disabled','0'),
                       ('smartdns.@smartdns[0].enabled','0'), ('smartdns.@smartdns[0].old_port','6053'),
                       ('dhcp.@dnsmasq[0].dns_redirect','1')]:
        package=key.split('.')[0]; original=(root/'etc/config'/package).read_bytes()
        run([bindir/'uci','set',key+'='+value]);run([bindir/'uci','commit',package])
        before=(root/'etc/config'/package).read_bytes()
        assert run(['sh',transaction,'shutdown-dns'],None).returncode != 0
        assert (root/'etc/config'/package).read_bytes() == before and queued.exists()
        (root/'etc/config'/package).write_bytes(original)
    run([bindir/'uci','set','dhcp.@dnsmasq[0].port=53'])
    assert run(['sh',transaction,'shutdown-dns'],None).returncode != 0
    run([bindir/'uci','revert','dhcp'])
    run([bindir/'uci','delete','dhcp.@dnsmasq[0].port']);run([bindir/'uci','add_list','dhcp.@dnsmasq[0].port=0']);run([bindir/'uci','commit','dhcp'])
    assert run(['sh',transaction,'shutdown-dns'],None).returncode != 0
    write(root/'etc/config/dhcp',dhcp)
    # A preview without actual writes and without an old active contract owns nothing.
    (tx/'active').unlink(); before=(tmp/'uci-commands').read_text()
    run(['sh',transaction,'shutdown-dns']); assert queued.exists()
    write(tx/'active','a'*32)
    # Disable failure is visible; its later native callback must not be repaired by boot start.
    run([smart,'enable']); write(tmp/'disable-fail','1')
    assert run([bindir/'target-rc',init,'shutdown'],None).returncode != 0
    (tmp/'disable-fail').unlink(); run([smart,'shutdown'])
    write(boot, '00000000-0000-4000-8000-000000000002\n')
    run(['sh',transaction,'recover-early'])
    before=(root/'etc/config/dhcp').read_bytes()
    assert run(['sh',transaction,'boot-dns'],None).returncode != 0
    assert (active/'failed-stage').read_text().strip() == 'boot-dns-admission'
    assert (active/'dns-boot-pending').exists() and not (active/'dns-boot-ready').exists()
    assert (root/'etc/config/dhcp').read_bytes() == before
    # Restoring the committed scalar does not authorize an unapplied/forged record.
    run([bindir/'uci','set','dhcp.@dnsmasq[0].port=0']);run([bindir/'uci','commit','dhcp'])
    port_row=next(row for row,(key,_) in enumerate(values,1) if key=='dhcp.@dnsmasq[0].port')
    (active/'fields'/str(port_row)/'attempted').unlink()
    assert run(['sh',transaction,'shutdown-dns'],None).returncode != 0
    write(active/'fields'/str(port_row)/'attempted','')
    assert run(['sh',transaction,'shutdown-dns'],None,{'ROUTEPOLICY_WRITER_OWNER':'1:1','ROUTEPOLICY_WRITER_KIND':'init'}).returncode != 0
    print('native DNS shutdown: passed (K10, queued K82, old active + prepared, native callbacks, options, disable failure, boot refusal, provenance)')
finally:
    if os.environ.get('TEST_KEEP_SHUTDOWN'):
        (tmp/'results.json').write_text(json.dumps(results,indent=2)); print('native shutdown evidence:',tmp)
    else:
        shutil.rmtree(tmp)
PY
