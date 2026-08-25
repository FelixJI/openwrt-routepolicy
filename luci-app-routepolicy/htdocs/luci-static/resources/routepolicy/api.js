'use strict';
'require rpc';

const METHODS = [
	'status', 'validate', 'apply', 'reload', 'update', 'rollback',
	'diagnose', 'import_legacy', 'read_user_list', 'write_user_list',
	'smartdns_status', 'smartdns_save', 'smartdns_validate', 'smartdns_apply',
	'smartdns_discard_candidate', 'read_local_hosts', 'write_local_hosts'
];

const api = {};

for (let method of METHODS) {
	let params = (method === 'smartdns_save' || method === 'write_local_hosts') ? [ 'content' ] : [];
	api[method.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); })] = rpc.declare({
		object: 'routepolicy',
		method: method,
		params: params,
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
	ui.addNotification(null, E('p', {}, api.safeText(payload && payload.message, fallback)), ok ? 'info' : 'error');
	return payload;
};

return api;
