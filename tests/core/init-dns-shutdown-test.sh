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
    tx = root/'etc/routepolicy/state/init-transaction'; current = tx/'current'; active = tx/'confirmed'/('a'*32)
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
    def fields_and_pending():
        return ({p.name:p.read_bytes() for p in (root/'etc/config').iterdir() if p.is_file() and not p.is_symlink()},
                {p.name:p.read_bytes() for p in (tmp/'delta').iterdir() if p.is_file()})
    def cancel_callbacks(case):
        run([smart,'enable']); before=fields_and_pending()
        run([bindir/'target-rc',init,'shutdown'])
        assert not queued.exists() and fields_and_pending()==before
        calls_before=(tmp/'uci-commands').read_bytes()
        assert run([bindir/'target-rc',queued,'shutdown'],None).returncode!=0
        assert (tmp/'uci-commands').read_bytes()==calls_before
        results.append({'cancel_case':case,'K10_rc':0,'queued_K82_absent':True,'field_and_pending_bytes_unchanged':True})
    def startup_still_refused():
        write(active/'dns-boot-pending',boot.read_text())
        before=fields_and_pending(); applied=(tmp/'apply-calls').read_bytes()
        assert run(['sh',transaction,'boot-dns'],None).returncode!=0
        assert fields_and_pending()==before and (tmp/'apply-calls').read_bytes()==applied
        assert not (active/'dns-boot-ready').exists()
        (active/'dns-boot-pending').unlink()
    # Cancelling a destructive callback is permitted even when startup is unsafe.
    for key, value in [('dhcp.@dnsmasq[0].port','53'), ('dhcp.@dnsmasq[0].disabled','0'),
                       ('smartdns.@smartdns[0].enabled','0'), ('smartdns.@smartdns[0].old_port','6053'),
                       ('dhcp.@dnsmasq[0].dns_redirect','1')]:
        package=key.split('.')[0]; original=(root/'etc/config'/package).read_bytes()
        run([bindir/'uci','set',key+'='+value]);run([bindir/'uci','commit',package])
        cancel_callbacks('committed:'+key);startup_still_refused()
        (root/'etc/config'/package).write_bytes(original)
    write(root/'etc/config/firewall',"config rule 'f25'\n option value 'original'\n")
    # The zero-write prepared candidate falls back to active; expired does too.
    write(current/'phase','expired')
    for key,value in [('firewall.f25.value','pending'),('dhcp.@dnsmasq[0].port','53'),
                      ('smartdns.@smartdns[0].port','6053'),('network.lan.ipaddr','192.0.2.8/24'),
                      ('routepolicy.main.enabled','0')]:
        package=key.split('.')[0]
        run([bindir/'uci','set',key+'='+value])
        cancel_callbacks('pending:'+key);startup_still_refused()
        run([bindir/'uci','revert',package])
        if package=='firewall':
            # Reboot discards volatile UCI deltas, not the committed DHCP port.
            run([smart,'start']);assert (root/'etc/config/dhcp').read_text()==dhcp
    run([bindir/'uci','delete','dhcp.@dnsmasq[0].port']);run([bindir/'uci','add_list','dhcp.@dnsmasq[0].port=0']);run([bindir/'uci','commit','dhcp'])
    cancel_callbacks('committed:port-list-type');startup_still_refused()
    write(root/'etc/config/dhcp',dhcp)
    run([smart,'enable']);write(current/'phase','prepared')
    # A preview without actual writes and without an old active contract owns nothing.
    (tx/'active').unlink(); before=(tmp/'uci-commands').read_text()
    run(['sh',transaction,'shutdown-dns']); assert queued.exists()
    # A quiesce marker without the existing applied DNS identity adds no authority.
    write(current/'phase','applying');write(current/'dns-service-attempted','')
    write(current/'candidate','set\tsmartdns.@smartdns[0].port\t53\n')
    before=fields_and_pending()
    assert run(['sh',transaction,'shutdown-dns'],None).returncode!=0 and queued.exists()
    assert fields_and_pending()==before
    (current/'dns-service-attempted').unlink();write(current/'phase','prepared');write(current/'candidate','')
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
    # Startup requires DHCP field proof; cancellation requires the existing DNS identity.
    run([bindir/'uci','set','dhcp.@dnsmasq[0].port=0']);run([bindir/'uci','commit','dhcp'])
    port_row=next(row for row,(key,_) in enumerate(values,1) if key=='dhcp.@dnsmasq[0].port')
    (active/'fields'/str(port_row)/'attempted').unlink()
    cancel_callbacks('DNS-owned-without-DHCP-startup-proof');startup_still_refused()
    write(active/'fields'/str(port_row)/'attempted','')
    identity_row=next(row for row,(key,_) in enumerate(values,1) if key=='smartdns.@smartdns[0].cache_file')
    identity_entry=active/'fields'/str(identity_row)
    run([smart,'enable'])
    for bad_proof in ['unattempted','bad-type','symlink','bad-token']:
        if bad_proof=='unattempted':(identity_entry/'attempted').unlink()
        if bad_proof=='bad-type':write(identity_entry/'expected-type','list')
        if bad_proof=='symlink':
            (identity_entry/'attempted').unlink();(identity_entry/'attempted').symlink_to(identity_entry/'expected')
        if bad_proof=='bad-token':write(active/'token','invalid')
        assert run(['sh',transaction,'shutdown-dns'],None).returncode!=0 and queued.exists()
        if bad_proof in ['unattempted','symlink']:
            (identity_entry/'attempted').unlink(missing_ok=True);write(identity_entry/'attempted','')
        if bad_proof=='bad-type':write(identity_entry/'expected-type','scalar')
        if bad_proof=='bad-token':write(active/'token','a'*32)
    assert run(['sh',transaction,'shutdown-dns'],None,{'ROUTEPOLICY_WRITER_OWNER':'1:1','ROUTEPOLICY_WRITER_KIND':'init'}).returncode != 0
    # Both UI switches retain DNS ownership; real core stop does not restore DHCP.
    write(bindir/'nft', '#!/bin/sh\n[ "$1:$2" = list:tables ]\n')
    write(bindir/'ip', '#!/bin/sh\nexit 0\n')
    write(current/'phase','expired')
    (active/'dns-boot-pending').unlink(missing_ok=True)
    write(root/'etc/config/dhcp',dhcp)
    actual_apply=repo/'routepolicy/files/usr/libexec/routepolicy/apply'
    for policy,adapter in [('0','1'),('0','0'),('1','0'),('1','1')]:
        write(root/'etc/config/routepolicy', "config main 'main'\n option enabled '"+policy+"'\n option smartdns_enabled '"+adapter+"'\n")
        if policy=='0':
            run(['sh',actual_apply,'teardown'])
            assert (root/'etc/config/dhcp').read_text()==dhcp
        run([smart,'enable']);run([bindir/'target-rc',init,'shutdown'])
        assert not queued.exists() and (root/'etc/config/dhcp').read_text()==dhcp
    write(root/'etc/config/routepolicy',configs['routepolicy'])
    # Restore uses old typed values, not the managed-forward guard.
    write(bindir/'ubus', '''#!/bin/sh
case "$2:$3" in
 service:delete) rm -f "$F22_DIR/smart-running"; printf '{}\\n' ;;
 service:set) touch "$F22_DIR/smart-running"; printf '{}\\n' ;;
 service:list)
  case "${4:-}" in *smartdns*) name=smartdns; file=smart-running ;; *) name=dnsmasq; file=dns-running ;; esac
  if [ "$name" = smartdns ] && [ ! -f "$F22_DIR/$file" ]; then printf '{}\\n'; exit 0; fi
  running=false; [ ! -f "$F22_DIR/$file" ] || running=true
  printf '{"%s":{"instances":{"main":{"running":%s}}}}\\n' "$name" "$running" ;;
 *) printf '{}\\n' ;;
esac
''')
    write(root/'etc/init.d/dnsmasq', '''#!/bin/sh
printf 'dnsmasq %s\\n' "$1" >>"$F22_DIR/restore-services"
case "$1" in
 enabled) [ -f "$F22_DIR/dns-enabled" ] ;;
 enable) touch "$F22_DIR/dns-enabled" ;;
 disable) rm -f "$F22_DIR/dns-enabled" ;;
 start|restart) touch "$F22_DIR/dns-running" ;;
 stop) rm -f "$F22_DIR/dns-running" ;;
esac
''')
    write(bindir/'netstat', '''#!/bin/sh
for service in smartdns dnsmasq; do
 case "$service" in smartdns) file=smart-running; port=$(uci -q get 'smartdns.@smartdns[0].port') ;; *) file=dns-running; port=$(uci -q get 'dhcp.@dnsmasq[0].port') ;; esac
 [ -f "$F22_DIR/$file" ] && [ "$port" != 0 ] || continue
 printf 'tcp 0 0 127.0.0.1:%s 0.0.0.0:* LISTEN 123/%s\\nudp 0 0 127.0.0.1:%s 0.0.0.0:* 123/%s\\n' "$port" "$service" "$port" "$service"
done
''')
    write(bindir/'dig', "#!/bin/sh\nprintf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\\n'\n")
    write(root/'etc/init.d/routepolicy', '#!/bin/sh\n[ "$1" != enabled ]\n')
    for service in ['network','firewall']:write(root/'etc/init.d'/service,'#!/bin/sh\nexit 0\n')
    (tx/'active').unlink();(tx/'source').unlink(missing_ok=True)
    def restore_case(kind, original_port='53', original_auto='0'):
        shutil.rmtree(current);current.mkdir();(current/'delta').mkdir()
        for delta in (tmp/'delta').iterdir():delta.unlink()
        write(root/'etc/config/smartdns',configs['smartdns'])
        write(root/'etc/config/routepolicy',configs['routepolicy'])
        original_dns_port='0' if original_port=='53' else '53'
        write(root/'etc/config/dhcp', dhcp+"\n")
        run([bindir/'uci','delete','dhcp.@dnsmasq[0].server']);run([bindir/'uci','add_list','dhcp.@dnsmasq[0].server=127.0.0.1#'+original_port]);run([bindir/'uci','add_list','dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53']);run([bindir/'uci','commit','dhcp'])
        rows=values+[('routepolicy.main.enabled','1')]
        if kind in ['firewall','firewall-pending']:rows=rows+[('firewall.test.value','1')]
        write(root/'etc/config/firewall',"config rule 'test'\n option value '1'\n")
        for name,value in {'phase':'pending','token':'b'*32,'count':str(len(rows)),'policy-active':'0','dns-attempted':'','dns-service-attempted':'','dns-file-absent':'','dns-file-new':'','smartdns-enabled':'1','smartdns-running':'1','dnsmasq-enabled':'1','dnsmasq-running':'1','routepolicy-enabled':'0','boot-id':boot.read_text()}.items():write(current/name,value)
        write(current/'candidate',''.join('set\t'+key+'\t'+value+'\n' for key,value in rows))
        for row,(key,value) in enumerate(rows,1):
            old=value
            if key in ['smartdns.@smartdns[0].port','smartdns.@smartdns[0].old_port']:old=original_port
            if key in ['smartdns.@smartdns[0].auto_set_dnsmasq','smartdns.@smartdns[0].old_auto_set_dnsmasq']:old=original_auto
            if key=='dhcp.@dnsmasq[0].port':old=original_dns_port
            if key in ['dhcp.@dnsmasq[0].disabled','routepolicy.main.enabled','firewall.test.value']:old='0'
            for name,data in {'key':key,'expected':value,'expected-type':'scalar','old':old,'type':'scalar','existed':'1','attempted':''}.items():write(current/'fields'/str(row)/name,data)
        (root/'etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf').unlink(missing_ok=True)
        write(current/'smartdns-listeners','tcp 127.0.0.1 '+original_port+' 1\nudp 127.0.0.1 '+original_port+' 1\n')
        write(current/'dnsmasq-listeners','' if original_dns_port=='0' else 'tcp 127.0.0.1 53 1\nudp 127.0.0.1 53 1\n')
        (tmp/'dns-running').unlink(missing_ok=True);(tmp/'dns-enabled').unlink(missing_ok=True)
        write(tmp/'smart-running','1');run([smart,'enable'])
        if kind in ['port','port-logdir']:run([bindir/'uci','set','dhcp.@dnsmasq[0].port=53']);run([bindir/'uci','commit','dhcp'])
        if kind=='port-logdir':(current/'deferred-services').mkdir()
        if kind=='type':run([bindir/'uci','delete','dhcp.@dnsmasq[0].port']);run([bindir/'uci','add_list','dhcp.@dnsmasq[0].port=0']);run([bindir/'uci','commit','dhcp'])
        if kind=='pending':run([bindir/'uci','set','dhcp.@dnsmasq[0].port=53'])
        if kind=='smart':run([bindir/'uci','set','smartdns.@smartdns[0].port=6053']);run([bindir/'uci','commit','smartdns'])
        if kind.startswith('firewall'):
            run([bindir/'uci','set','firewall.test.value=2'])
            if kind=='firewall':run([bindir/'uci','commit','firewall'])
        result=run(['sh',transaction,'recover'],None)
        if kind in ['port','port-logdir','type','pending','smart']:
            assert result.returncode!=0 and not (tmp/'smart-running').exists() and not queued.exists()
            if kind=='port':
                assert run([bindir/'uci','get','dhcp.@dnsmasq[0].port']).stdout.strip()=='53'
                run([bindir/'uci','set','dhcp.@dnsmasq[0].port=0']);run([bindir/'uci','commit','dhcp'])
                run(['sh',transaction,'recover'])
                assert (tmp/'smart-running').exists() and queued.exists() and (tmp/'dns-running').exists()
            if kind=='type':assert "list port '0'" in (root/'etc/config/dhcp').read_text()
            if kind=='smart':assert (tmp/'dns-running').exists() and (tmp/'dns-enabled').exists()
        else:
            assert (tmp/'smart-running').exists() and (tmp/'dns-running').exists()
            assert result.returncode==(0 if kind=='safe' else 1)
            assert run([bindir/'uci','get','dhcp.@dnsmasq[0].server']).stdout.strip().endswith('127.0.0.1#'+original_port+' /corp.example/10.20.0.53')
        assert run([bindir/'uci','get','dhcp.lan.dhcp_option']).stdout.split()==['6,192.168.1.1/24','42,192.0.2.8']
    for kind in ['port','port-logdir','type','pending','smart','firewall','firewall-pending']:restore_case(kind)
    restore_case('safe','6053','1')
    print('native recovery admission: passed (port/type/pending preservation, independent dnsmasq, unrelated firewall conflict/pending, legal6053 conditional forwarding)')
    print('native DNS shutdown: passed (K10, queued K82, old active + prepared, native callbacks, options, disable failure, boot refusal, provenance)')
finally:
    if os.environ.get('TEST_KEEP_SHUTDOWN'):
        (tmp/'results.json').write_text(json.dumps(results,indent=2)); print('native shutdown evidence:',tmp)
    else:
        shutil.rmtree(tmp)
PY
