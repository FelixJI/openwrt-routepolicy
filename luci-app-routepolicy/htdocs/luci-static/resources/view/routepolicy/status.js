'use strict';
'require view';
'require ui';
'require routepolicy/api as api';

function style() {
	return E('style', {}, `
 .rp-console{--rp-ink:#17212b;--rp-line:#ccd6df;--rp-ok:#0f766e;--rp-warn:#b45309;--rp-bad:#b42318;--rp-panel:#f7fafb;color:var(--rp-ink)}
 .rp-console .rp-hero{display:flex;align-items:flex-end;justify-content:space-between;gap:1rem;border-left:5px solid #0b6477;padding:.85rem 1.1rem;background:linear-gradient(105deg,#e5f3f5,#f8fbfc)}
 .rp-console .rp-hero h2{margin:0;font:600 1.55rem/1.2 Georgia,serif;letter-spacing:.02em}.rp-console .rp-eyebrow{margin:0 0 .3rem;text-transform:uppercase;font-size:.72rem;letter-spacing:.12em;color:#47616d}
 .rp-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:.75rem;margin:1rem 0}.rp-card{border:1px solid var(--rp-line);border-top:3px solid #78909c;background:var(--rp-panel);padding:.8rem 1rem}.rp-card.ok{border-top-color:var(--rp-ok)}.rp-card.warn{border-top-color:var(--rp-warn)}.rp-card.bad{border-top-color:var(--rp-bad)}
 .rp-card dt{font-size:.76rem;text-transform:uppercase;letter-spacing:.08em;color:#536471}.rp-card dd{margin:.4rem 0 0;font-weight:600;overflow-wrap:anywhere}.rp-actions{display:flex;gap:.6rem;flex-wrap:wrap;margin:.9rem 0}.rp-actions button{border-radius:0;border:1px solid #38616a;background:#fff;color:#193d45;padding:.45rem .72rem}.rp-actions button.cbi-button-apply{background:#0b6477;color:#fff}.rp-table{width:100%;border-collapse:collapse}.rp-table th,.rp-table td{padding:.55rem;border-bottom:1px solid var(--rp-line);text-align:left;vertical-align:top}.rp-table th{font-size:.75rem;text-transform:uppercase;letter-spacing:.08em;color:#536471}
 @media (prefers-color-scheme:dark){.rp-console{--rp-ink:#e6edf2;--rp-line:#47545d;--rp-panel:#202a30}.rp-console .rp-hero{background:#19343a}.rp-actions button{background:#253139;color:#e6edf2}}
 `);
}

function state(value) {
	if (value === true || value === 'running' || value === 'online' || value === 'loaded') return 'ok';
	if (value === false || value === 'stopped' || value === 'offline' || value === 'error') return 'bad';
	return 'warn';
}

function card(label, value, detail) {
	return E('dl', { 'class': 'rp-card ' + state(value) }, [ E('dt', {}, label), E('dd', {}, api.safeText(value)), detail ? E('small', {}, api.safeText(detail)) : '' ]);
}

return view.extend({
	load: function() { return api.status(); },

	render: function(status) {
		status = status || {};
		let service = status.service || {};
		let routing = status.routing || {};
		let dns = status.smartdns || {};
		let sets = status.sets || {};
		let interfaces = status.interfaces || {};
		let self = this;
		let action = function(method, label, confirmation) {
			return E('button', {
				'class': method == 'apply' ? 'cbi-button cbi-button-apply' : 'cbi-button cbi-button-neutral',
				'click': ui.createHandlerFn(self, function() {
					if (confirmation && !window.confirm(confirmation)) return;
					return api[method]().then(function(reply) { api.notice(ui, reply, label); window.location.reload(); });
				})
			}, label);
		};

		let interfaceRows = [];
		for (let name in interfaces) {
			let iface = interfaces[name] || {};
			interfaceRows.push(E('tr', {}, [ E('td', {}, name), E('td', {}, api.safeText(iface.device)), E('td', {}, api.safeText(iface.address)), E('td', {}, api.safeText(iface.online)), E('td', {}, api.safeText(iface.message)) ]));
		}

		return E('div', { 'class': 'rp-console' }, [
			style(),
			E('div', { 'class': 'rp-hero' }, [ E('div', {}, [ E('p', { 'class': 'rp-eyebrow' }, _('RoutePolicy / operation desk')), E('h2', {}, _('运行状态与受控操作')) ]), E('small', {}, _('数据来自固定 RPC 状态接口')) ]),
			E('div', { 'class': 'rp-grid' }, [
				card(_('服务'), service.running === undefined ? service.state : service.running, service.message),
				card(_('配置已应用'), service.applied, service.enabled ? _('已启用') : _('未启用')),
				card(_('策略路由'), routing.real_default === undefined ? routing.state : routing.real_default, routing.blackhole ? _('Blackhole 后备存在') : _('未确认 Blackhole')),
				card(_('SmartDNS'), dns.running === undefined ? dns.state : dns.running, dns.fragment_loaded ? _('适配片段已加载') : _('适配片段未加载')),
				card(_('动态策略集合'), sets.domain_policy4 === undefined ? '—' : sets.domain_policy4, _('元素数量')),
				card(_('最近更新'), status.last_update, status.last_error || _('无最近错误'))
			]),
			E('div', { 'class': 'rp-actions' }, [
				action('validate', _('验证候选配置')),
				action('apply', _('应用已保存配置'), _('这会修改 RoutePolicy 自己的 nftables 表、策略路由和 SmartDNS 片段。首次启用前，请确认可通过 VMM 控制台回退。继续吗？')),
				action('reload', _('受控重载')),
				action('update', _('更新全部来源')),
				action('rollback', _('回滚上一份清单'), _('将恢复上一份已知可用清单。继续吗？'))
			]),
			E('h3', {}, _('接口观测')), E('table', { 'class': 'rp-table' }, [ E('thead', {}, E('tr', {}, [ E('th', {}, _('逻辑接口')), E('th', {}, _('实际设备')), E('th', {}, _('IPv4 地址')), E('th', {}, _('在线')), E('th', {}, _('说明')) ])), E('tbody', {}, interfaceRows.length ? interfaceRows : E('tr', {}, E('td', { colspan: 5 }, _('状态接口未返回接口数据')))) ]),
			E('p', { 'class': 'alert-message notice' }, _('保存 UCI、验证候选配置和应用运行配置是三项独立操作。'))
		]);
	}
});
