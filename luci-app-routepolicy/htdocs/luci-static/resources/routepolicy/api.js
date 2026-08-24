'use strict';
'require rpc';

const METHODS = [
	'status', 'validate', 'apply', 'reload', 'update', 'rollback',
	'diagnose', 'import_legacy', 'read_user_list', 'write_user_list'
];

const api = {};

for (let method of METHODS)
	api[method.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); })] = rpc.declare({
		object: 'routepolicy',
		method: method,
		expect: { }
	});

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
