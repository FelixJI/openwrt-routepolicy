'use strict';
'require view';
'require ui';
'require routepolicy/api as api';

const LISTS = {
	'domain-policy': { title: _('策略域名'), hint: _('每行一个域名，解析结果将写入策略动态集合。') },
	'domain-default': { title: _('默认覆盖域名'), hint: _('每行一个域名，优先于策略域名。') },
	'ipv4-policy': { title: _('策略 IPv4/CIDR'), hint: _('每行一个 IPv4 地址或 CIDR。') },
	'ipv4-default': { title: _('默认覆盖 IPv4/CIDR'), hint: _('每行一个 IPv4 地址或 CIDR，优先于策略 IPv4。') }
};

/* Keep this policy aligned with converter-lib reserved(). */
const RESERVED_IPV4_RANGES = [
	[ 0, 16777215 ], [ 167772160, 184549375 ],
	[ 1681915904, 1686110207 ], [ 2130706432, 2147483647 ],
	[ 2851995648, 2852061183 ], [ 2886729728, 2887778303 ],
	[ 3221225472, 3221225727 ], [ 3221225984, 3221226239 ],
	[ 3227017984, 3227018239 ], [ 3232235520, 3232301055 ],
	[ 3323068416, 3323199487 ], [ 3325256704, 3325256959 ],
	[ 3405803776, 3405804031 ], [ 3758096384, 4294967295 ]
];

function allowedIPv4Range(value) {
	let parts = value.split('/');
	let octets = parts[0].split('.');
	let address = 0;
	for (let i = 0; i < octets.length; i++)
		address = address * 256 + Number(octets[i]);

	let prefix = parts.length > 1 ? Number(parts[1]) : 32;
	let block = 1;
	for (let i = prefix; i < 32; i++)
		block *= 2;
	let first = address - (address % block);
	let last = first + block - 1;

	for (let i = 0; i < RESERVED_IPV4_RANGES.length; i++) {
		let reserved = RESERVED_IPV4_RANGES[i];
		if (first <= reserved[1] && reserved[0] <= last)
			return false;
	}
	return true;
}

function clientCheck(kind, content) {
	let domain = kind.indexOf('domain-') === 0;
	let rule = domain
		? /^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i
		: /^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9][0-9]?)(?:\/(?:[0-9]|[12][0-9]|3[0-2]))?$/;
	let invalid = [], seen = {}, valid = 0, duplicate = 0;
	content.split(/\r?\n/).forEach(function(raw) {
		let text = raw.trim();
		if (!text || text.charAt(0) === '#') return;
		if (!rule.test(text) || (!domain && !allowedIPv4Range(text))) invalid.push(text);
		else if (seen[text.toLowerCase()]) duplicate++;
		else { seen[text.toLowerCase()] = true; valid++; }
	});
	return { ok: invalid.length === 0, valid: valid, duplicate: duplicate, invalid: invalid };
}

function resultNode(check) {
	let valid = Array.isArray(check.valid) ? check.valid.length : (check.valid_count === undefined ? (check.valid || 0) : check.valid_count);
	let duplicate = check.duplicate_count === undefined ? (check.duplicate || 0) : check.duplicate_count;
	let list = check.invalid || [];
	let invalid = Array.isArray(list) ? list.length : (check.invalid_count || 0);
	let wording = _('有效 %d 条，重复 %d 条，非法 %d 条').format(valid, duplicate, invalid);
	return E('div', { 'class': check.ok ? 'alert-message notice' : 'alert-message error' }, [
		check.message || check.error ? E('p', {}, api.safeText(check.error || check.message)) : '',
		E('strong', {}, wording),
		list.length ? E('pre', {}, list.join('\n')) : ''
	]);
}

return view.extend({
	load: function() { return api.readUserList({ list: 'domain-policy' }); },

	render: function(initial) {
		let selected = 'domain-policy';
		let select = E('select', { 'class': 'cbi-input-select' }, Object.keys(LISTS).map(function(key) { return E('option', { value: key }, LISTS[key].title); }));
		let title = E('h3', {}, LISTS[selected].title);
		let hint = E('p', { 'class': 'cbi-section-descr' }, LISTS[selected].hint);
		let text = E('textarea', { 'class': 'cbi-input-textarea', rows: 20, spellcheck: 'false', wrap: 'off' }, initial && initial.content || '');
		let feedback = E('div');
		let loading = false;
		let loadList = function(kind) {
			if (loading) return;
			loading = true;
			api.readUserList({ list: kind }).then(function(reply) {
				selected = kind;
				title.textContent = LISTS[kind].title;
				hint.textContent = LISTS[kind].hint;
				text.value = reply.content || '';
				feedback.replaceChildren();
			}).catch(function(err) { ui.addNotification(null, E('p', {}, _('读取规则失败：') + err), 'error'); }).finally(function() { loading = false; });
		};
		select.addEventListener('change', function() { loadList(select.value); });
		let check = E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { feedback.replaceChildren(resultNode(clientCheck(selected, text.value))); } }, _('校验此列表'));
		let save = E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
			let local = clientCheck(selected, text.value);
			feedback.replaceChildren(resultNode(local));
			if (!local.ok) return Promise.resolve(local);
			return api.writeUserList({ list: selected, content: text.value }).then(function(reply) {
				feedback.replaceChildren(resultNode(reply));
				api.notice(ui, reply, _('人工规则保存失败'));
				return reply;
			}, function(error) {
				let reply = { ok: false, error: error && error.message || String(error), invalid: [] };
				feedback.replaceChildren(resultNode(reply));
				return reply;
			});
		}) }, _('校验并保存'));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('人工规则')),
			E('p', { 'class': 'cbi-section-descr' }, _('专用 RPC 只允许读取和写入四类固定清单，并在写入前逐行校验。')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('保存后如何生效')),
				E('p', { 'class': 'cbi-section-descr' }, _('“校验并保存”会原子写入人工规则文件，但不会立即改变运行态。')),
				E('ol', {}, [
					E('li', {}, _('保存成功后打开“运行状态”页面。')),
					E('li', {}, _('先点击“验证候选配置”，确认当前配置和人工规则均通过校验。')),
					E('li', {}, _('验证通过后点击“重新应用当前配置”，完成后新规则才会进入运行态；若 RoutePolicy 未启用，请改用“启用并应用”。'))
				])
			]),
			E('div', { 'class': 'cbi-section' }, [ E('label', {}, [_('规则类型 '), select]), title, hint, text, E('div', { 'style': 'margin-top: .75rem; display: flex; gap: .5rem' }, [check, save]), feedback ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
