'use strict';

function confirm() {
	const group = ctx.authacl?.['access-group']?.['luci-app-routepolicy'];
	let reply;
	if (!ctx.authsession || !group || !('write' in group)) {
		http.status(403, 'Forbidden');
		reply = { ok: false, error: '确认需要已登录且具有 RoutePolicy 写权限的会话' };
	}
	else {
		const token = http.formvalue('transaction_token');
		/* uhttpd derives this value from getsockname() on the accepted socket. */
		const address = http.getenv('SERVER_ADDR');
		if (type(token) != 'string' || !match(token, /^[0-9a-f]{32}$/) ||
		    http.getenv('SERVER_SOFTWARE') != 'uhttpd' || type(address) != 'string' ||
		    !match(address, /^([0-9]{1,3}\.){3}[0-9]{1,3}$/)) {
			http.status(400, 'Bad Request');
			reply = { ok: false, error: '请从候选管理 IPv4 地址直接打开 LuCI 后确认' };
		}
		else {
			reply = require('routepolicy.lifecycle').call_core(
				'/usr/sbin/routepolicyctl web-init-confirm --json', `${token}\t${address}`);
		}
	}
	http.header('Cache-Control', 'no-store');
	http.prepare_content('application/json');
	http.write_json(reply);
}

return { confirm };
