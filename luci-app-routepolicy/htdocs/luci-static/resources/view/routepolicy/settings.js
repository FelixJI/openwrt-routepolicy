'use strict';
'require view';
'require form';
'require tools.widgets as widgets';
'require uci';
'require ui';

function validateMarkBit(sectionId, value) {
	if (typeof value !== 'string' || !/^0x[0-9A-Fa-f]{1,8}$/.test(value))
		return _('请输入以 0x 开头、不超过 8 位十六进制数字的单一 mark bit，例如 0x100。');

	let number = parseInt(value, 16);
	if (number < 1 || number > 0x80000000 || (number & (number - 1)) !== 0)
		return _('mark 必须只包含一个非零 bit，例如 0x100。');

	let peerName = this.option === 'mark' ? 'mark_mask' : 'mark';
	let peer = this.map.lookupOption(peerName, sectionId);
	let peerValue = peer ? peer[0].formvalue(peer[1]) : null;
	if (peerValue && peerValue !== value)
		return _('策略 mark bit 与 mark 掩码必须填写完全相同的值。');

	return true;
}

return view.extend({
	load: function() { return uci.load('routepolicy'); },

	render: function() {
		let m = new form.Map('routepolicy', _('基础设置'), _('“保存”只把修改加入 LuCI 变更队列，不会改变当前网络；“保存并应用”会提交 UCI，并由服务触发器同步运行态。'));
		let s = m.section(form.NamedSection, 'main', 'main', _('策略控制面'));
		s.addremove = false;

		let o = s.option(form.Flag, 'enabled', _('启用 RoutePolicy'));
		o.default = '0';
		o.description = _('首次启用前，请确保已有 VMM 控制台或等效的带外回退路径。应用动作会再次要求确认。');

		o = s.option(widgets.NetworkSelect, 'lan_interface', _('LAN 逻辑接口'));
		o.nocreate = true;
		o.rmempty = false;
		o.description = _('使用逻辑接口选择器；不会接受设备名或 shell 文本。');

		o = s.option(widgets.NetworkSelect, 'default_interface', _('默认出口逻辑接口'));
		o.nocreate = true;
		o.rmempty = false;

		o = s.option(widgets.NetworkSelect, 'policy_interface', _('策略出口逻辑接口'));
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

		o = s.option(form.Flag, 'route_local_traffic', _('路由器本机 IPv4 分流'));
		o.default = '0';
		o.description = _('默认关闭。开启后，路由器上的下载器、插件和守护进程产生的 IPv4 流量也会按 RoutePolicy 分类。');

		o = s.option(form.Flag, 'source_accounting', _('按源 IP 统计'));
		o.default = '0';
		o.description = _('默认关闭。启用后会消耗额外内存和 CPU；只覆盖受管 IPv4 路径，硬件或 flow offload 可能造成与接口总量的正常差异。');

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
		a.rmempty = false;
		a.validate = validateMarkBit;
		a.description = _('使用 0x 前缀的单一 32 位 mark bit；RoutePolicy 不覆盖完整 fwmark。');

		a = s.taboption('advanced', form.Value, 'mark_mask', _('mark 掩码'));
		a.tab = 'advanced';
		a.default = '0x100';
		a.rmempty = false;
		a.validate = validateMarkBit;
		a.description = _('必须与策略 mark bit 完全相同。');

		a = s.taboption('advanced', form.Flag, 'smartdns_enabled', _('生成 SmartDNS 适配片段'));
		a.tab = 'advanced';
		a.default = '1';
		a.description = _('该开关只控制 RoutePolicy 的 90 规则片段；SmartDNS 服务和上游请在“服务 → 路由策略 → SmartDNS”独立管理。');

		a = s.taboption('advanced', form.Value, 'smartdns_policy_group', _('已存在的 SmartDNS 解析组'));
		a.tab = 'advanced';
		a.datatype = 'uciname';
		a.default = 'policy';
		a.description = _('RoutePolicy 域名规则引用的解析组；新的 SmartDNS 页面可在用户明确操作后管理上游，外部修改冲突时会拒绝覆盖。');

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

		a = s.taboption('advanced', form.Value, 'source_idle_timeout', _('归因闲置超时（秒）'));
		a.tab = 'advanced';
		a.default = '600';
		a.datatype = 'range(60,86400)';
		a.description = _('归因 IP 在无新流量后的保留时间。该值只影响有界的源 IP 统计，不影响业务分流集合。');

		a = s.taboption('advanced', form.Value, 'source_max_entries', _('每方向最大 IP 数'));
		a.tab = 'advanced';
		a.default = '4096';
		a.datatype = 'range(256,16384)';
		a.description = _('达到上限时转发不受影响，但新的归因 IP 可能遗漏；观测页会显示“已饱和”。');

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
