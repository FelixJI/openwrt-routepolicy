#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-dns-listener.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export TEST_LISTENER_DIR=$tmp
mkdir "$tmp/bin" "$tmp/wal"
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get dhcp.@dnsmasq[0].port') cat "$TEST_LISTENER_DIR/port" ;;
	'-q show smartdns') printf 'smartdns.main=smartdns\n' ;;
	'-q get smartdns.main.port') printf '6053\n' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/netstat" <<'EOF'
#!/bin/sh
cat "$TEST_LISTENER_DIR/sockets"
EOF
cat >"$tmp/bin/dig" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_LISTENER_DIR/queries"
case " $* " in *' -p 53 '*|*' -p 6053 '*) ;; *) exit 9 ;; esac
case " $* " in *' @::1 '*) [ "$1" = -6 ] || exit 9 ;; *' @127.0.0.1 '*) [ "$1" = -4 ] || exit 9 ;; *) exit 9 ;; esac
printf ';; ->>HEADER<<- status: NOERROR, id: 1\n'
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/common"
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/init-dns"
WAL="$tmp/wal"
printf 53 >"$tmp/port"
# BusyBox uses tcp/udp for IPv6 too; UDP has no LISTEN column.
cat >"$tmp/sockets" <<'EOF'
tcp 0 0 0.0.0.0:53 0.0.0.0:* LISTEN 910/dnsmasq
udp 0 0 0.0.0.0:53 0.0.0.0:* 910/dnsmasq
tcp 0 0 :::53 :::* LISTEN 910/dnsmasq
udp 0 0 :::53 :::* 910/dnsmasq
udp 0 0 192.0.2.1:41793 0.0.0.0:* 910/dnsmasq
udp 0 0 0.0.0.0:67 0.0.0.0:* 910/dnsmasq
EOF
init_dns_original_probe dnsmasq save
if grep -Eq -- '-p (41793|67) ' "$tmp/queries"; then printf 'queried an upstream source or DHCP socket\n' >&2; exit 1; fi
[ "$(wc -l <"$WAL/dnsmasq-listeners")" = 4 ]
grep -Fxq 'tcp ::1 53 1' "$WAL/dnsmasq-listeners"
grep -Fxq 'udp ::1 53 1' "$WAL/dnsmasq-listeners"
# Restart changes the random upstream socket, while DNS keeps its real port.
sed -i 's/41793/49217/' "$tmp/sockets"
init_dns_original_probe dnsmasq verify
printf 0 >"$tmp/port"; : >"$tmp/queries"
init_dns_original_probe dnsmasq save
[ ! -s "$WAL/dnsmasq-listeners" ] && [ ! -s "$tmp/queries" ]
printf 'udp 0 0 0.0.0.0:6053 0.0.0.0:* 920/smartdns\n' >"$tmp/sockets"
init_dns_original_probe smartdns save
grep -Fxq 'udp 127.0.0.1 6053 1' "$WAL/smartdns-listeners"
printf '%s\n' 'original DNS listener contract: passed (BusyBox IPv6, ephemeral UDP, DHCP, port zero and SmartDNS port)'
