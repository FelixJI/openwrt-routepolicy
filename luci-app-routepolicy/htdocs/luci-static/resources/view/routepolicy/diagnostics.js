'use strict';
'require view';
'require ui';
'require routepolicy/api as api';

function plain(value) {
	if (typeof value === 'string') return value;
	try { return JSON.stringify(value, null, 2); }
	catch (e) { return String(value || ''); }
}

return view.extend({
	load: function() { return api.diagnose(); },

	render: function(initial) {
		let output = E('pre', { 'class': 'routepolicy-diagnostic-output', tabindex: '0' }, plain(initial));
		let self = this;
		let invoke = function(method, label, confirmText) {
			return E('button', { 'class': method === 'importLegacy' ? 'cbi-button cbi-button-negative' : 'cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(self, function() {
				if (confirmText && !window.confirm(confirmText)) return;
				return api[method]().then(function(reply) { output.textContent = plain(reply); api.notice(ui, reply, label); });
			}) }, label);
		};
		let download = E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() {
			let file = new Blob([output.textContent], { type: 'text/plain;charset=utf-8' });
			let link = document.createElement('a');
			link.href = URL.createObjectURL(file); link.download = 'routepolicy-diagnose.txt'; link.click(); URL.revokeObjectURL(link.href);
		} }, _('下载诊断文本'));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('诊断与迁移')),
			E('p', { 'class': 'cbi-section-descr' }, _('诊断覆盖 UCI、接口、main 默认路由、mark 冲突、策略表/blackhole、nftables、SmartDNS、DNS、IPv6、NAT/MSS、网段冲突和更新源。报告由核心命令脱敏 URL 查询参数及本机认证信息。')),
			E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5rem;flex-wrap:wrap;margin:.75rem 0' }, [
				invoke('diagnose', _('重新诊断')),
				invoke('importLegacy', _('导入 /etc/splitroute'), _('仅复制和转换 /etc/splitroute 中的旧数据，不会删除旧文件。继续吗？')),
				download
			]),
			E('p', { 'class': 'alert-message notice' }, _('迁移只允许固定的 /etc/splitroute 路径；界面不提供任意路径导入或命令执行。')),
			output
		]);
	}
});
