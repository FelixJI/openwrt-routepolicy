'use strict';
'require rpc';
'require baseclass';

const METHODS = [
	'status', 'validate', 'apply', 'reload', 'update', 'rollback',
	'observe_interfaces', 'observe_sets', 'observe_query',
	'diagnose', 'import_legacy', 'read_user_list', 'write_user_list',
	'smartdns_status', 'smartdns_save', 'smartdns_validate', 'smartdns_apply',
	'smartdns_discard_candidate', 'read_local_hosts', 'write_local_hosts',
	'init_discover', 'init_preview', 'init_prepare', 'init_candidate',
	'init_status', 'init_apply', 'init_cancel', 'init_finish', 'init_recover',
	'config_export', 'config_import', 'restore_status', 'restore_prepare', 'restore_recover',
	'exit_preview', 'exit_prepare', 'exit_candidate', 'exit_apply'
];
const PARAMS = {
	read_user_list: { list: true },
	write_user_list: { list: true, content: true },
	observe_query: { dataset: true, query: true, cursor: true, limit: true, device: true, sort: true },
	init_preview: [ 'content' ],
	init_prepare: [ 'content' ],
	config_import: [ 'content' ],
	restore_prepare: [ 'content' ],
	init_apply: [ 'token' ],
	init_cancel: [ 'token' ],
	init_finish: [ 'token' ],
	exit_apply: [ 'token' ],
	smartdns_save: [ 'content' ],
	write_local_hosts: [ 'content' ]
};

const api = {};
const renameSource = rpc.declare({
	object: 'uci',
	method: 'rename',
	params: [ 'config', 'section', 'name' ],
	reject: true
});

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

api.newSourceName = function(uci, reserved) {
	const bytes = new Uint8Array(12);
	let name;
	do {
		window.crypto.getRandomValues(bytes);
		name = 'rp_src_' + Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
	} while (uci.get('routepolicy', name) || (reserved && reserved.has(name)));
	return name;
};

api.nameAnonymousSources = async function(uci) {
	const config = 'routepolicy';
	const anonymous = () => uci.sections(config, 'source').filter(section => section['.anonymous'] === true);
	const reload = async () => {
		uci.unload(config);
		try {
			await uci.load(config);
		}
		catch (error) {
			// LuCI caches the rejected load promise until explicitly unloaded.
			uci.unload(config);
			throw error;
		}
	};

	// Save has staged the edits. Only a fresh read can rule out remaining anonymous sources.
	await reload();
	const sections = anonymous();
	if (!sections.length)
		return false;
	const reserved = new Set();
	let renameError;
	try {
		for (const section of sections) {
			const name = api.newSourceName(uci, reserved);
			reserved.add(name);
			await renameSource(config, section['.name'], name);
		}
	}
	catch (error) {
		renameError = error;
	}
	// A later rename may fail after an earlier one was staged. Reload the actual IDs.
	await reload().catch(error => { throw renameError || error; });
	if (renameError)
		throw renameError;
	if (anonymous().length)
		throw new Error(_('仍有匿名来源未转换，请重新保存。'));
	return true;
};

return baseclass.extend(api);
