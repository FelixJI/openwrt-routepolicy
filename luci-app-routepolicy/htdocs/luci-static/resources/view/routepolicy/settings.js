'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require routepolicy/api as api';

return view.extend({
	load: function() { return uci.load('routepolicy'); },

	render: function() {
		let m = new form.Map('routepolicy', _('基础设置'), _('这里的“保存”只写入 UCI，不会改变当前网络。请先到运行状态页验证候选配置，再明确应用。'));
		let s = m.section(form.NamedSection, 'main', 'main', _('策略控制面'));
		s.addremove = false;

		let o = s.option(form.Flag, 'enabled', _('启用 RoutePolicy'));
		o.default = '0';
		o.description = _('首次启用前，请确保已有 VMM 控制台或等效的带外回退路径。应用动作会再次要求确认。');

		o = s.option(form.NetworkSelect, 'lan_interface', _('LAN 逻辑接口'));
		o.nocreate = true;
		o.rmempty = false;
		o.description = _('使用逻辑接口选择器；不会接受设备名或 shell 文本。');

		o = s.option(form.NetworkSelect, 'default_interface', _('默认出口逻辑接口'));
		o.nocreate = true;
		o.rmempty = false;

		o = s.option(form.NetworkSelect, 'policy_interface', _('策略出口逻辑接口'));
		o.nocreate = true;
		o.rmempty = false;

		o = s.option(form.Flag, 'strict_enforcement', _('严格阻断'));
		o.default = '1';
		o.description = _('策略接口离线时保留策略表的 blackhole 默认路由，避免流量回落到默认出口。');

		o = s.option(form.Flag, 'dns_redirect', _('重定向 LAN DNS'));
		o.default = '1';
		o.description = _('仅把 LAN 的 TCP/UDP 53 受控重定向到本机 DNS。');

		o = s.option(form.Flag, 'warm_restore', _('动态集合暖启动'));
		o.default = '1';
		o.description = _('重启后的短暂保底；随后由 SmartDNS 的 TTL 写入重新接管。');

		s.tab('advanced', _('高级设置'));
		let a = s.taboption('advanced', form.Value, 'route_table', _('策略路由表号'));
		a.tab = 'advanced';
		a.default = '200';
		a.datatype = 'range(1,252)';
		a.description = _('推荐值 200。应用前会检测现有路由表和 mark 冲突。');

		a = s.taboption('advanced', form.Value, 'rule_priority', _('ip rule 优先级'));
		a.tab = 'advanced';
		a.default = '12000';
		a.datatype = 'uinteger';

		a = s.taboption('advanced', form.Value, 'mark', _('策略 mark bit'));
		a.tab = 'advanced';
		a.default = '0x100';
		a.datatype = 'or(hexstring,range(1,2147483647))';
		a.description = _('仅使用指定 bit；RoutePolicy 不覆盖完整 fwmark。');

		a = s.taboption('advanced', form.Value, 'mark_mask', _('mark 掩码'));
		a.tab = 'advanced';
		a.default = '0x100';
		a.datatype = 'or(hexstring,range(1,2147483647))';

		a = s.taboption('advanced', form.Flag, 'smartdns_enabled', _('生成 SmartDNS 适配片段'));
		a.tab = 'advanced';
		a.default = '1';

		a = s.taboption('advanced', form.Value, 'smartdns_policy_group', _('已存在的 SmartDNS 解析组'));
		a.tab = 'advanced';
		a.datatype = 'uciname';
		a.default = 'policy';
		a.description = _('只引用已有解析组；本应用不会创建或删除上游 DNS 服务器。');

		a = s.taboption('advanced', form.Flag, 'auto_update', _('定时更新'));
		a.tab = 'advanced';
		a.default = '1';
		a = s.taboption('advanced', form.Value, 'update_hour', _('更新时间（小时）'));
		a.tab = 'advanced';
		a.default = '4';
		a.datatype = 'range(0,23)';
		a = s.taboption('advanced', form.Value, 'update_minute', _('更新时间（分钟）'));
		a.tab = 'advanced';
		a.default = '17';
		a.datatype = 'range(0,59)';
		a = s.taboption('advanced', form.Flag, 'update_via_policy_interface', _('更新经策略接口'));
		a.tab = 'advanced';
		a.default = '1';

		this.map = m;
		return m.render();
	},

	handleSave: function(ev) { return this.map.save(); },
	handleSaveApply: function(ev) {
		return this.map.save().then(function() {
			return api.reload();
		}).then(function(reply) {
			api.notice(ui, reply, _('服务配置已同步'));
			if (!reply || !reply.ok)
				throw new Error(reply && (reply.error || reply.message) || _('服务配置同步失败'));
			return reply;
		});
	},
	handleReset: function(ev) { return this.map.reset(); }
});
