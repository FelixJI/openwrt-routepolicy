'use strict';
'require rpc';
'require baseclass';

const METHODS = [
	'status', 'validate', 'apply', 'reload', 'update', 'rollback',
	'diagnose', 'import_legacy', 'read_user_list', 'write_user_list',
	'smartdns_status', 'smartdns_save', 'smartdns_validate', 'smartdns_apply',
	'smartdns_discard_candidate', 'read_local_hosts', 'write_local_hosts'
];
const PARAMS = {
	read_user_list: { list: true },
	write_user_list: { list: true, content: true },
	smartdns_save: [ 'content' ],
	write_local_hosts: [ 'content' ]
};

const api = {};

for (let method of METHODS) {
	api[method.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); })] = rpc.declare({
		object: 'routepolicy',
		method: method,
		params: PARAMS[method] || [],
		expect: { }
	});
}

api.safeText = function(value, fallback) {
	if (value === null || value === undefined || value === '')
		return fallback || '—';
	return String(value);
};

api.notice = function(ui, payload, fallback) {
	let ok = payload && payload.ok;
	let detail = payload && (payload.error || payload.message);
	ui.addNotification(null, E('p', {}, api.safeText(detail, fallback)), ok ? 'info' : 'error');
	return payload;
};

return baseclass.extend(api);
