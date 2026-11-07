#!/bin/sh
# sysupgrade run_hooks ignores return codes, so an incomplete DNS backup is fatal.
# shellcheck disable=SC3043
routepolicy_backup_static_dns() {
	local list=$1 result helper=${ROUTEPOLICY_LIBEXEC:-/usr/libexec/routepolicy}/firmware-backup
	result=$(mktemp /tmp/routepolicy-backup.XXXXXX) || exit 1
	if ! "$helper" <"$list" >"$result"; then rm -f "$result"; exit 1; fi
	cat "$result" >"$list" || { rm -f "$result"; exit 1; }
	rm -f "$result"
}
[ -z "${sysupgrade_init_conffiles:-}" ] || append sysupgrade_init_conffiles routepolicy_backup_static_dns
