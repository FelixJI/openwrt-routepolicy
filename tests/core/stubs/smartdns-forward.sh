#!/bin/sh
#
# Copyright (C) 2018-2024 Ruilin Peng (Nick) <pymumu@gmail.com>.
#
# smartdns is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# smartdns is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Source: https://github.com/pymumu/smartdns/blob/Release46.1/package/openwrt/files/etc/init.d/smartdns
# License copy: COPYING.smartdns in this directory.
# Official SmartDNS Release46.1 native callbacks; only the init service path is relocated.
# shellcheck disable=SC2034,SC2154,SC3043
stop_forward_dnsmasq()
{
	local OLD_PORT="$1"
	local norestart="$2"
	addr="127.0.0.1#$OLD_PORT"
	OLD_SERVER="$(uci -q get dhcp.@dnsmasq[0].server) "
	if ! echo "$OLD_SERVER" | grep "^$addr " >/dev/null 2>&1; then
		return
	fi
	
	uci -q delete dhcp.@dnsmasq[0].server
	uci -q delete dhcp.@dnsmasq[0].noresolv
	uci -q set dhcp.@dnsmasq[0].rebind_protection=1
	uci -q set dhcp.@dnsmasq[0].domainneeded=1
	uci commit dhcp
	[ "$norestart" != "1" ] && "$ROUTEPOLICY_ROOT/etc/init.d/dnsmasq" reload
}

set_forward_dnsmasq()
{
	local PORT="$1"
	addr="127.0.0.1#$PORT"
	# space in suffix is important
	OLD_SERVER="$(uci -q get dhcp.@dnsmasq[0].server) "
	if echo "$OLD_SERVER" | grep "^$addr " >/dev/null 2>&1; then
		return
	fi

	uci -q delete dhcp.@dnsmasq[0].server
	uci -q add_list dhcp.@dnsmasq[0].server="$addr"
	uci -q set dhcp.@dnsmasq[0].noresolv=1
	uci -q set dhcp.@dnsmasq[0].rebind_protection=0
	uci -q set dhcp.@dnsmasq[0].domainneeded=0
	uci commit dhcp
	"$ROUTEPOLICY_ROOT/etc/init.d/dnsmasq" reload
}

unload_service()
{
	local section="$1"

	[ "$DO_RELOAD" = "1" ] && return 0

	config_get_bool enabled "$section" "enabled" '0'
	dnsmasq_port="$(uci -q get dhcp.@dnsmasq[0].port)"
	config_get port "$section" "port" "53"
	config_get auto_set_dnsmasq "$section" "auto_set_dnsmasq" "0"
	config_get old_enabled "$section" "old_enabled" "0"
	config_get old_port "$section" "old_port" "0"
	config_get old_auto_set_dnsmasq "$section" "old_auto_set_dnsmasq" "0"
	[ -z "${dnsmasq_port}" ] && dnsmasq_port="53"

	[ "$enabled" = "1" ] && {
		[ "$old_enabled" = "0" ] && return 1
		[ "$old_port" = "53" ] && stop_main_dns "0"
		[ "$old_port" != "53" ] && [ "$old_auto_set_dnsmasq" = "1" ] && stop_forward_dnsmasq "$old_port" "0"
	}
}
