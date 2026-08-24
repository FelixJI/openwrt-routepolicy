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

function clientCheck(kind, content) {
	let domain = kind.indexOf('domain-') === 0;
	let rule = domain
		? /^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i
		: /^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9][0-9]?)(?:\/(?:[0-9]|[12][0-9]|3[0-2]))?$/;
	let invalid = [], seen = {}, valid = 0, duplicate = 0;
	content.split(/\r?\n/).forEach(function(raw) {
		let text = raw.trim();
		if (!text || text.charAt(0) === '#') return;
		if (!rule.test(text)) invalid.push(text);
		else if (seen[text.toLowerCase()]) duplicate++;
		else { seen[text.toLowerCase()] = true; valid++; }
	});
	return { ok: invalid.length === 0, valid: valid, duplicate: duplicate, invalid: invalid };
}

function resultNode(check) {
	let wording = _('有效 %d 条，重复 %d 条，非法 %d 条').format(check.valid || check.valid_count || 0, check.duplicate || check.duplicate_count || 0, (check.invalid || []).length || check.invalid_count || 0);
	let list = check.invalid || [];
	return E('div', { 'class': check.ok ? 'alert-message notice' : 'alert-message error' }, [ E('strong', {}, wording), list.length ? E('pre', {}, list.join('\n')) : '' ]);
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
		let save = E('button', { 'class': 'cbi-button cbi-button-apply', 'click': function() {
			let local = clientCheck(selected, text.value);
			feedback.replaceChildren(resultNode(local));
			if (!local.ok) return;
			api.writeUserList({ list: selected, content: text.value }).then(function(reply) { feedback.replaceChildren(resultNode(reply)); api.notice(ui, reply, _('人工规则已保存')); });
		} }, _('校验并保存'));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('人工规则')),
			E('p', { 'class': 'cbi-section-descr' }, _('专用 RPC 只允许读取和写入四类固定清单。任何内容都会以纯文本显示，不会解释为 HTML 或命令。')),
			E('div', { 'class': 'cbi-section' }, [ E('label', {}, [_('规则类型 '), select]), title, hint, text, E('div', { 'style': 'margin-top: .75rem; display: flex; gap: .5rem' }, [check, save]), feedback ])
		]);
	}
});
