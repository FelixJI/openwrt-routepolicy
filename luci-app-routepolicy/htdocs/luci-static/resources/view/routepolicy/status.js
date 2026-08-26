'use strict';
'require view';
'require ui';
'require uci';
'require routepolicy/api as api';

function stateText(value, yes, no) {
	if (value === true) return yes || _('正常');
	if (value === false) return no || _('否');
	return api.safeText(value);
}

function statusRow(label, value, description) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label),
		E('div', { 'class': 'cbi-value-field' }, [
			E('strong', {}, api.safeText(value)),
			description ? E('div', { 'class': 'cbi-value-description' }, api.safeText(description)) : ''
		])
	]);
}

function resultNode(reply, fallback) {
	let ok = reply && reply.ok;
	let detail = reply && (reply.error || reply.message);
	return E('div', { 'class': 'alert-message ' + (ok ? 'notice' : 'error') }, [
		E('strong', {}, ok ? _('操作成功') : _('操作失败')),
		E('p', {}, api.safeText(detail, fallback))
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ api.status(), uci.load('routepolicy') ]);
	},

	render: function(data) {
		let status = Array.isArray(data) ? (data[0] || {}) : (data || {});
		let service = status.service || {};
		let routing = status.routing || {};
		let dns = status.smartdns || {};
		let sets = status.sets || {};
		let interfaces = status.interfaces || {};
		let feedback = E('div', { 'id': 'routepolicy-operation-result' });
		let self = this;

		let showPending = function(label) {
			feedback.replaceChildren(E('div', { 'class': 'alert-message notice' }, [
				E('strong', {}, label), E('p', {}, _('请稍候，操作完成前不要关闭页面。'))
			]));
		};

		let run = function(method, label, confirmation, buttonClass) {
			return E('button', {
				'class': 'cbi-button ' + (buttonClass || 'cbi-button-neutral'),
				'click': ui.createHandlerFn(self, function() {
					if (confirmation && !window.confirm(confirmation)) return Promise.resolve();
					showPending(label);
					return api[method]().then(function(reply) {
						feedback.replaceChildren(resultNode(reply, label));
						api.notice(ui, reply, label);
						return reply;
					}, function(error) {
						let reply = { ok: false, error: error && error.message || String(error) };
						feedback.replaceChildren(resultNode(reply, label));
						throw error;
					});
				})
			}, label);
		};

		let setEnabled = function(enabled) {
			let label = enabled ? _('启用并应用') : _('停用并清理');
			let confirmation = enabled
				? _('启用会应用 nftables、策略路由和 SmartDNS 片段。首次启用前，请确认可通过 VMM 控制台回退。继续吗？')
				: _('停用会删除 RoutePolicy 自有的 nftables 表、策略路由和 SmartDNS 片段。继续吗？');
			return E('button', {
				'class': 'cbi-button ' + (enabled ? 'cbi-button-positive important' : 'cbi-button-negative'),
				'disabled': service.enabled === enabled ? '' : null,
				'click': ui.createHandlerFn(self, function() {
					if (!window.confirm(confirmation)) return Promise.resolve();
					showPending(label);
					uci.set('routepolicy', 'main', 'enabled', enabled ? '1' : '0');
					return uci.save().then(function() {
						feedback.replaceChildren(E('div', { 'class': 'alert-message notice' }, [
							E('strong', {}, _('配置已保存')),
							E('p', {}, _('LuCI 正在应用变更；完成后页面会自动刷新并显示新的运行状态。'))
						]));
						return ui.changes.apply(true);
					}, function(error) {
						feedback.replaceChildren(resultNode({ ok: false, error: error && error.message || String(error) }, label));
						throw error;
					});
				})
			}, label);
		};

		let interfaceRows = [];
		for (let name in interfaces) {
			let iface = interfaces[name] || {};
			interfaceRows.push(E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td' }, name),
				E('div', { 'class': 'td' }, api.safeText(iface.device)),
				E('div', { 'class': 'td' }, api.safeText(iface.address)),
				E('div', { 'class': 'td' }, stateText(iface.online, _('在线'), _('离线'))),
				E('div', { 'class': 'td' }, api.safeText(iface.message))
			]));
		}
		let interfaceTableRows = [
			E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th' }, _('逻辑接口')),
				E('div', { 'class': 'th' }, _('实际设备')),
				E('div', { 'class': 'th' }, _('IPv4 地址')),
				E('div', { 'class': 'th' }, _('状态')),
				E('div', { 'class': 'th' }, _('说明'))
			])
		].concat(interfaceRows.length ? interfaceRows : [
			E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, _('状态接口未返回接口数据')))
		]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('运行状态')),
			E('div', { 'class': 'cbi-map-descr' }, _('查看保存配置与实际运行态，并通过 LuCI 标准应用流程执行启停。验证只检查候选，不会修改网络。')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('服务与配置')),
				statusRow(_('管理开关'), stateText(service.enabled, _('已启用'), _('已停用')), _('决定应用时启动策略，还是停用并清理自有状态。')),
				statusRow(_('守护进程'), stateText(service.running === undefined ? service.state : service.running, _('运行中'), _('未运行')), service.message),
				statusRow(_('配置应用状态'), stateText(service.applied, _('已应用'), _('未应用')), status.last_apply),
				statusRow(_('策略路由'), stateText(routing.real_default === undefined ? routing.state : routing.real_default, _('默认路由已就绪'), _('默认路由未就绪')), routing.blackhole ? _('Blackhole 后备已就绪') : _('未确认 Blackhole 后备')),
				statusRow(_('SmartDNS'), stateText(dns.running === undefined ? dns.state : dns.running, _('运行中'), _('未运行')), dns.fragment_loaded ? _('RoutePolicy 片段已加载') : _('RoutePolicy 片段未加载')),
				statusRow(_('动态策略集合'), sets.domain_policy4 === undefined ? '—' : sets.domain_policy4, _('当前 IPv4 元素数量')),
				statusRow(_('最近更新'), status.last_update, status.last_error || _('无最近错误'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('配置与运行操作')),
				E('p', { 'class': 'cbi-section-descr' }, _('“保存”只暂存 UCI；“启用并应用/停用并清理”会保存开关并通过 LuCI 的受控应用流程提交。重新应用不会改变启停开关。')),
				E('div', { 'class': 'cbi-page-actions' }, [
					setEnabled(true), ' ', setEnabled(false), ' ',
					run('validate', _('验证候选配置')), ' ',
					run('apply', _('重新应用当前配置'), _('这会按当前已提交的启停开关重新同步运行态。继续吗？'), 'cbi-button-action'), ' ',
					run('update', _('更新全部来源')), ' ',
					run('rollback', _('回滚上一份清单'), _('将恢复上一份已知可用清单。继续吗？'), 'cbi-button-negative'), ' ',
					E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { window.location.reload(); } }, _('刷新状态'))
				]),
				feedback
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('接口观测')),
				E('div', { 'class': 'table cbi-section-table' }, interfaceTableRows)
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
