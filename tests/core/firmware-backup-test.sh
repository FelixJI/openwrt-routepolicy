#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-firmware-backup.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib"
export TEST_BACKUP_FIXTURE=$tmp
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin" "$tmp/lib" "$ROUTEPOLICY_ROOT/etc/smartdns/conf.d" \
	"$ROUTEPOLICY_ROOT/etc/smartdns/download" "$ROUTEPOLICY_ROOT/etc/user-dns"
lib="$ROOT/routepolicy/files/usr/libexec/routepolicy"
cp "$lib/common" "$lib/init-dns" "$lib/firmware-backup" "$tmp/lib/"
chmod +x "$tmp/lib/firmware-backup"
cat >"$tmp/bin/uci" <<'SH'
#!/bin/sh
[ "$1" != -q ] || shift
case "$1:$2" in
	show:smartdns) cat "$TEST_BACKUP_FIXTURE/shown" ;;
	export:smartdns) cat "$TEST_BACKUP_FIXTURE/uci" ;;
	changes:smartdns|changes:dhcp) printf '%s' "${TEST_BACKUP_PENDING:-}" ;;
	get:smartdns.@smartdns\[0\].conf_files) printf '%s\n' '77-user.conf /etc/smartdns/conf.d/90-routepolicy.conf' ;;
	get:smartdns.@smartdns\[0\].hosts_files) printf '%s\n' 'selected.hosts' ;;
	*) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/uci"
cat >"$tmp/shown" <<'UCI'
smartdns.@smartdns[0]=smartdns
smartdns.@smartdns[0].conf_files='77-user.conf' '/etc/smartdns/conf.d/90-routepolicy.conf'
smartdns.@smartdns[0].hosts_files='selected.hosts'
UCI
cat >"$tmp/uci" <<'UCI'
package smartdns
config smartdns
	list conf_files '77-user.conf'
	list conf_files '/etc/smartdns/conf.d/90-routepolicy.conf'
	list hosts_files 'selected.hosts'
UCI
cat >"$tmp/platform" <<'PATHS'
/etc/config/smartdns
/etc/init.d/smartdns
/etc/routepolicy/state/init-transaction/active
/etc/routepolicy/state/init-transaction/source
/etc/routepolicy/state/init-transaction/confirmed/token/origin/fields/1/old
/usr/bin/native-platform-item
PATHS
dns="$ROUTEPOLICY_ROOT/etc/smartdns"
printf '# fixed\n' >"$dns/custom.conf"
printf '# retained user declaration\n' >"$dns/conf.d/91-routepolicy-smartdns-extra.conf"
printf 'conf-file "child.conf" -group user\n' >"$dns/conf.d/77-user.conf"
# SmartDNS supports a quoted value as a whole token, with a separate -file.
printf 'domain-set -name user -file "domains with spaces.list"\n' >"$dns/conf.d/child.conf"
printf 'ip-set -n clients --file=client.list\n' >>"$dns/conf.d/child.conf"
for name in 'domains with spaces.list' client.list; do printf 'fixture\n' >"$dns/conf.d/$name"; done
for name in selected.hosts unused.hosts; do printf '192.0.2.1 example.test\n' >"$dns/download/$name"; done
printf 'generated\n' >"$dns/conf.d/90-routepolicy.conf"
printf 'generated\n' >"$dns/smartdns.cache"
helper="$tmp/lib/firmware-backup"
"$helper" <"$tmp/platform" >"$tmp/list"
cat "$tmp/platform" >"$tmp/expected"
cat >>"$tmp/expected" <<'PATHS'
/etc/smartdns/conf.d/77-user.conf
/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf
/etc/smartdns/conf.d/child.conf
/etc/smartdns/conf.d/client.list
/etc/smartdns/conf.d/domains with spaces.list
/etc/smartdns/custom.conf
/etc/smartdns/download/selected.hosts
PATHS
LC_ALL=C sort "$tmp/expected" >"$tmp/expected.sorted"
cmp "$tmp/expected.sorted" "$tmp/list"

reject() {
	if "$helper" <"$tmp/platform" >"$tmp/list" 2>"$tmp/error"; then
		printf 'accepted incomplete backup: %s\n' "$1" >&2; exit 1
	fi
	[ ! -s "$tmp/list" ]
	grep -Fq "$1" "$tmp/error"
}
printf 'hosts-file ./relative.hosts\n' >"$ROUTEPOLICY_ROOT/etc/user-dns/target.conf"
printf '192.0.2.2 example.test\n' >"$dns/conf.d/relative.hosts"
ln -s ../../user-dns/target.conf "$dns/conf.d/link.conf"
printf 'conf-file link.conf\n' >>"$dns/conf.d/77-user.conf"
reject '链接目标未在原官方清单 /etc/smartdns/conf.d/link.conf -> /etc/user-dns/target.conf'
grep -Fq /etc/sysupgrade.conf "$tmp/error"
printf '/etc/user-dns/target.conf\n' >>"$tmp/platform"
"$helper" <"$tmp/platform" >"$tmp/list"
grep -Fxq '/etc/smartdns/conf.d/link.conf' "$tmp/list"
grep -Fxq '/etc/smartdns/conf.d/relative.hosts' "$tmp/list"
printf 'hosts-file /etc/user-dns/outside.hosts\n' >>"$dns/conf.d/77-user.conf"
: >"$ROUTEPOLICY_ROOT/etc/user-dns/outside.hosts"
reject '外部依赖未在原官方清单 /etc/user-dns/outside.hosts'
printf '/etc/user-dns/outside.hosts\n' >>"$tmp/platform"
"$helper" <"$tmp/platform" >"$tmp/list"
grep -Fxq /etc/user-dns/outside.hosts "$tmp/list"

cp "$tmp/platform" "$tmp/clean-platform"
printf '/etc/routepolicy/state/init-transaction/current/token\n' >>"$tmp/platform"
reject '备份清单包含受管运行态'
cp "$tmp/clean-platform" "$tmp/platform"
printf '/etc/smartdns/smartdns.cache\n' >>"$tmp/platform"
reject 'SmartDNS 输出'
cp "$tmp/clean-platform" "$tmp/platform"
TEST_BACKUP_PENDING=1 reject 'UCI 暂存变更'

cp "$dns/conf.d/77-user.conf" "$tmp/valid"
for directive in 'conf-file missing.conf' 'conf-file *.conf' 'domain-set -name user --fi data.list' 'plugin /usr/lib/example.so' 'ca-path /etc/ssl/certs'; do
	cp "$tmp/valid" "$dns/conf.d/77-user.conf"
	printf '%s\n' "$directive" >>"$dns/conf.d/77-user.conf"
	case "$directive" in
		*missing*) reject '静态输入或链接目标缺失' ;;
		*'*.conf') reject '通配符' ;;
		*) reject '语法无法可靠盘点' ;;
	esac
done
printf 'conf-file missing.conf\n' >>"$dns/conf.d/77-user.conf"

# Like the official runner, this caller disregards hook return codes.
if sh -c '
	append() { sysupgrade_init_conffiles="$sysupgrade_init_conffiles $2"; }
	platform_hook() { :; }
	sysupgrade_init_conffiles=platform_hook
	. "$1"
	for hook in $sysupgrade_init_conffiles; do "$hook" "$2"; done
	printf "archive would proceed\n"
' firmware-hook "$ROOT/routepolicy/files/lib/upgrade/routepolicy.sh" "$tmp/platform" >"$tmp/hook" 2>"$tmp/error"; then
	printf 'failed hook allowed the archive to proceed\n' >&2; exit 1
fi
[ ! -s "$tmp/hook" ]
cmp "$tmp/clean-platform" "$tmp/platform"
printf '%s\n' 'firmware backup: passed (native declarations, transitive inputs, exact external coverage, fail-closed hook)'
