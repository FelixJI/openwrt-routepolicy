'use strict';
'require view';
'require form';
'require uci';
'require ui';

function validURL(section_id, value) {
	if (!value || value.length > 2048)
		return _('请输入不超过 2048 个字符的 HTTPS URL。');
	try {
		let url = new URL(value);
		return url.protocol === 'https:' && !url.username && !url.password ? true : _('只允许不含认证信息的 HTTPS URL。');
	}
	catch (e) {
		return _('URL 格式无效。');
	}
}

return view.extend({
	load: function() { return uci.load('routepolicy'); },

	render: function() {
		let m = new form.Map('routepolicy', _('清单来源'), _('“保存”只加入 LuCI 变更队列；“保存并应用”会提交来源定义。下载与替换清单仍需在运行状态页执行“更新全部来源”。'));
		let s = m.section(form.GridSection, 'source', _('远程来源'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;

		let o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '1';
		o = s.option(form.Value, 'name', _('名称'));
		o.rmempty = false;
		o.datatype = 'maxlength(80)';
		o = s.option(form.Value, 'url', _('HTTPS URL'));
		o.rmempty = false;
		o.validate = validURL;
		o = s.option(form.ListValue, 'format', _('输入格式'));
		[ 'plain-domain', 'plain-ipv4', 'hosts-domain', 'adblock-domain', 'dnsmasq-domain', 'clash-domain', 'clash-ipv4' ].forEach(function(v) { o.value(v, v); });
		o.default = 'plain-domain';
		o = s.option(form.ListValue, 'target', _('目标集合'));
		o.value('domain-policy', _('域名 → 策略出口'));
		o.value('domain-default', _('域名 → 默认出口'));
		o.value('ipv4-policy', _('IPv4/CIDR → 策略出口'));
		o.value('ipv4-default', _('IPv4/CIDR → 默认出口'));
		o.default = 'domain-policy';
		o = s.option(form.Value, 'min_entries', _('最低有效条目数'));
		o.datatype = 'uinteger';
		o.default = '100';
		o = s.option(form.Value, 'max_shrink_percent', _('允许最大缩减比例（%）'));
		o.datatype = 'range(0,100)';
		o.default = '50';
		o.description = _('新版本相较于当前版本骤降超过此阈值时拒绝替换。');
		o = s.option(form.Flag, 'update_via_policy_interface', _('经策略接口更新'));
		o.default = '1';

		this.map = m;
		return m.render();
	},
	handleSave: function(ev) { return this.map.save(); },
	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return ui.changes.apply(mode == '0');
		});
	},
	handleReset: function(ev) { return this.map.reset(); }
});
