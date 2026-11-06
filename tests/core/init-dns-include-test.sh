#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-dns-include.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root" TEST_INCLUDE_DIR=$tmp
mkdir -p "$tmp/bin" "$tmp/root/etc/smartdns/conf.d"
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q export smartdns')
		printf 'package smartdns\n'
		[ ! -f "$TEST_INCLUDE_DIR/client" ] || printf "config client-rule 'guest'\n list conf_files 'client.conf'\n" ;;
	'-q show smartdns') [ ! -f "$TEST_INCLUDE_DIR/client" ] || printf 'smartdns.guest=client-rule\n' ;;
	'-q get smartdns.guest.enabled') printf 1 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/uci"
export PATH="$tmp/bin:$PATH"
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/common"
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/init-dns"
user="$tmp/root/etc/smartdns/user.conf"
child="$tmp/root/etc/smartdns/nested child.conf"
files='/etc/smartdns/user.conf|/etc/smartdns/conf.d/90-routepolicy.conf|/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf'
rp_smartdns_init_probes >"$tmp/root/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf"
printf 'nameserver /example.test/rp_init_policy\n' >"$tmp/root/etc/smartdns/conf.d/90-routepolicy.conf"
reject() {
	cp "$user" "$tmp/user.before"
	if init_dns_audit_user_files "$files" br-lan >"$tmp/rejected" 2>&1; then printf 'unsafe include accepted\n' >&2; exit 1; fi
	cmp "$tmp/user.before" "$user"
}
for option in '-group rp_init_policy' '-g "rp_init_default"' '--gr=rp_init_policy' '-grp_init_policy' '-egrp_init_default'; do
	printf 'server 203.0.113.53:53 %s -exclude-default-group\n' "$option" >"$user"
	reject
done
printf "conf-file 'nested child.conf' --group=user_group\n" >"$user"
printf 'server-tcp 203.0.113.53:53 --group rp_init_policy\n' >"$child"
cp "$child" "$tmp/child.before"; reject; cmp "$tmp/child.before" "$child"
printf 'server 203.0.113.53:53 -g user_group\n' >"$child"
init_dns_audit_user_files "$files" br-lan
printf 'server 203.0.113.53:53 --group=rp_init_policy_backup\n' >>"$user"
init_dns_audit_user_files "$files" br-lan
for line in "group-begin 'rp_init_default'" 'conf-file "nested child.conf" -g rp_init_policy' 'conf-file "*.conf"' 'server 203.0.113.53 -g rp_init_pol\icy'; do
	printf '%s\n' "$line" >"$user"; reject
done
printf 'ser\\\nver 203.0.113.53 -g rp_init_policy\n' >"$user"; reject
: >"$user"
printf 'server 203.0.113.53 -g rp_init_policy\n' >"$tmp/root/etc/smartdns/custom.conf"
reject; rm "$tmp/root/etc/smartdns/custom.conf"
if init_dns_audit_user_files "/etc/smartdns/quoted'path.conf" br-lan >"$tmp/rejected" 2>&1; then exit 1; fi
: >"$tmp/client"
printf 'server 203.0.113.53 -g rp_init_default\n' >"$tmp/root/etc/smartdns/conf.d/client.conf"
reject
printf '%s\n' 'SmartDNS include audit: passed (native group spellings, quoted relative nesting, client/fixed includes, ordinary groups and unchanged files)'
