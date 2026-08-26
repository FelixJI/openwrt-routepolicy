'use strict';
'require view';
'require ui';
'require routepolicy/api as api';

const FIELDS = [
	[ 'enabled', '启用 SmartDNS 服务', 'tri' ], [ 'port', 'UDP 监听端口', 'number' ],
	[ 'tcp_server', 'TCP DNS', 'tri' ], [ 'ipv6_server', 'IPv6 监听', 'tri' ],
	[ 'auto_set_dnsmasq', 'dnsmasq 自动配置', 'tri' ],
	[ 'cache_size', '缓存条数（-1 自动，0 禁用）', 'number' ], [ 'cache_persist', '缓存持久化', 'tri' ],
	[ 'cache_file', '缓存文件', 'text' ], [ 'cache_checkpoint_time', '检查点间隔（秒）', 'number' ],
	[ 'prefetch_domain', '域名预取', 'tri' ], [ 'serve_expired', '过期缓存应答', 'tri' ],
	[ 'rr_ttl_min', '内部最小 TTL', 'number' ], [ 'rr_ttl_max', '内部最大 TTL', 'number' ],
	[ 'rr_ttl_reply_max', '客户端最大 TTL', 'number' ], [ 'serve_expired_reply_ttl', '过期应答 TTL', 'number' ],
	[ 'dualstack_ip_selection', 'IPv4/IPv6 双栈优选', 'tri' ], [ 'force_aaaa_soa', '屏蔽 AAAA', 'tri' ],
	[ 'force_https_soa', '屏蔽 HTTPS/SVCB', 'tri' ], [ 'local_domain', '本地域后缀', 'text' ],
	[ 'dashboard_enabled', '启用 smartdns-ui 仪表盘', 'tri' ], [ 'dashboard_port', '仪表盘端口（默认 6080）', 'number' ],
	[ 'dashboard_data_dir', '仪表盘数据目录', 'text' ], [ 'dashboard_log_retention', '日志保留天数', 'number' ]
];

const SERVER_FIELDS = [ 'name', 'enabled', 'type', 'ip', 'port', 'server_group',
	'exclude_default_group', 'host_name', 'http_host', 'fallback', 'proxy', 'interface', 'set_mark' ];

function triSelect(key, value) {
	return E('select', { 'data-key': key }, [
		E('option', { value: '', selected: value === '' ? '' : null }, _('继承')),
		E('option', { value: '1', selected: value === '1' ? '' : null }, _('开启')),
		E('option', { value: '0', selected: value === '0' ? '' : null }, _('关闭'))
	]);
}

function fieldRow(spec, settings) {
	let key = spec[0], value = settings[key] ? settings[key].explicit : '';
	let control = spec[2] === 'tri' ? triSelect(key, value) :
		E('input', { 'data-key': key, type: spec[2], value: value || '', min: spec[2] === 'number' ? '-1' : null });
	return E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title' }, _(spec[1])), E('div', { class: 'cbi-value-field' }, control) ]);
}

function serverInput(server, field) {
	let value = server[field] || '';
	if (field === 'enabled' || field === 'exclude_default_group' || field === 'fallback')
		return triSelect('server.' + server.id + '.' + field, value);
	if (field === 'type')
		return E('select', { 'data-key': 'server.' + server.id + '.type' },
			[ 'udp', 'tcp', 'tls', 'https', 'quic', 'h3' ].map(function(protocol) {
				return E('option', { value: protocol, selected: value === protocol ? '' : null }, protocol.toUpperCase());
			}));
	return E('input', { 'data-key': 'server.' + server.id + '.' + field, value: value, type: field === 'port' ? 'number' : 'text' });
}

function serverCard(server) {
	let card = E('div', { class: 'cbi-section', 'data-server': server.id }, [
		E('h4', {}, [ _('上游：'), ' ', server.id ]),
		E('div', { class: 'cbi-value' }, SERVER_FIELDS.map(function(field) {
			return E('label', { style: 'display:inline-block;margin:.35em' }, [ field, E('br'), serverInput(server, field) ]);
		})),
		E('button', { class: 'btn cbi-button-negative', click: function() {
			card.setAttribute('data-delete', '1'); card.style.display = 'none';
		} }, _('删除上游'))
	]);
	return card;
}

return view.extend({
	load: function() { return Promise.all([ api.smartdnsStatus(), api.readLocalHosts() ]); },

	render: function(data) {
		this.status = data[0] || {};
		let hosts = data[1] || {};
		let serverBox = E('div', { id: 'smartdns-servers' }, (this.status.servers || []).map(serverCard));
		this.serverBox = serverBox;
		this.hosts = E('textarea', { id: 'smartdns-local-hosts', rows: 10, style: 'width:100%' }, hosts.content || '');
		let statusText = this.status.ambiguous ? _('存在多个 SmartDNS 根段，写入已禁用。') :
			(this.status.initialized ? _('已识别唯一 SmartDNS 根配置段；空白或“继承”表示该选项未显式配置。') :
				_('未找到 SmartDNS 根配置段；首次验证并应用时会在明确确认后创建最小根段。'));
		return E('div', { class: 'cbi-map' }, [
			E('h2', {}, _('SmartDNS 管理')),
			E('p', {}, _('SmartDNS 候选与 RoutePolicy 路由应用完全独立。继承表示删除对应 option；页面不会在打开时物化默认值。')),
			E('div', { class: 'alert-message ' + (this.status.ambiguous ? 'error' : 'notice') }, statusText),
			E('h3', {}, _('服务、缓存与 TTL、全局 DNS 行为')),
			E('div', {}, FIELDS.map(function(spec) { return fieldRow(spec, this.status.settings || {}); }, this)),
			E('p', {}, _('dnsmasq 自动配置会在端口 53 时关闭其 DNS 监听，在非 53 端口时改为转发到 SmartDNS，并可能调整 noresolv、重绑定保护、domainneeded、DHCP option 6 和重启 dnsmasq。RoutePolicy 不会自行启动 DHCP。')),
			E('h3', {}, _('上游 DNS')),
			E('p', {}, _('支持 UDP/TCP/TLS/HTTPS/QUIC/H3。未知 option 在编辑时保留；删除需要应用前确认。建议总数约 10 个并分散运营者与协议。')),
			serverBox,
			E('button', { class: 'btn cbi-button-add', click: this.addServer.bind(this) }, _('新增上游')),
			E('h3', {}, _('本地主机')),
			E('p', {}, _('每行：IP 主名称 [别名…]。PTR 只扩展主名称；DHCP 租约仅被动读取，不修改 DHCP。')),
			this.hosts,
			E('h3', {}, _('仪表盘与状态')),
			E('p', {}, this.status.dashboard && this.status.dashboard.installed ?
				_('已检测到 smartdns-ui；启用前请修改默认凭据并自行配置防火墙。') : _('未检测到 smartdns-ui，仪表盘保持禁用。')),
			E('p', {}, _('90 实际加载：') + String(!!(this.status.fragments && this.status.fragments['90'] && this.status.fragments['90'].loaded)) +
				'；' + _('91 实际加载：') + String(!!(this.status.fragments && this.status.fragments['91'] && this.status.fragments['91'].loaded))),
			E('div', { class: 'cbi-page-actions' }, [
				E('button', { class: 'btn cbi-button-save', click: this.handleSave.bind(this) }, _('保存 SmartDNS')),
				' ', E('button', { class: 'btn cbi-button-apply important', click: this.applyCandidate.bind(this) }, _('验证并应用 SmartDNS')),
				' ', E('button', { class: 'btn cbi-button-reset', click: this.handleDiscard.bind(this) }, _('丢弃候选'))
			])
		]);
	},

	addServer: function() {
		let id = window.prompt(_('请输入稳定的 UCI 段标识（仅限字母、数字和下划线）'));
		if (!id) return;
		if (!/^[A-Za-z0-9_]{1,64}$/.test(id)) {
			ui.addNotification(null, E('p', {}, _('上游段标识非法')), 'error'); return;
		}
		this.serverBox.appendChild(serverCard({ id: id, enabled: '1', type: 'udp' }));
	},

	manifest: function() {
		let lines = [ 'version\t' + (this.status.version || ''), 'initialize\t' + (this.status.initialized ? '0' : '1') ];
		document.querySelectorAll('[data-key]').forEach(function(node) { lines.push(node.getAttribute('data-key') + '\t' + String(node.value || '')); });
		document.querySelectorAll('[data-server]').forEach(function(node) {
			if (node.getAttribute('data-delete') === '1') lines.push('server.' + node.getAttribute('data-server') + '.delete\t1');
		});
		lines.push('confirm_danger\t1');
		return lines.join('\n') + '\n';
	},

	handleSave: function() {
		if (!window.confirm(_('保存只写候选和本地主机文件，不重载服务。继续？'))) return Promise.resolve();
		return Promise.all([ api.smartdnsSave(this.manifest()), api.writeLocalHosts(this.hosts.value) ]).then(function(replies) {
			api.notice(ui, replies[0], _('SmartDNS 候选保存完成')); api.notice(ui, replies[1], _('本地主机保存完成'));
			if (!replies[0].ok || !replies[1].ok) throw new Error(_('候选保存失败'));
			return replies;
		});
	},

	applyCandidate: function() {
		if (!window.confirm(_('将精确修改 SmartDNS UCI、90/91 登记并重载或启停 SmartDNS；dnsmasq、缓存删除、上游删除和 DNS 屏蔽可能产生高影响。确认继续？'))) return Promise.resolve();
		return Promise.all([ api.smartdnsSave(this.manifest()), api.writeLocalHosts(this.hosts.value) ])
			.then(function(replies) { if (!replies[0].ok || !replies[1].ok) throw new Error(_('保存失败')); return api.smartdnsValidate(); })
			.then(function(reply) {
				if (!reply.ok) throw new Error(reply.error || reply.message);
				let preview = reply.preview || {};
				let summary = _('变更字段数：') + String(preview.changes || 0) + '\n' +
					_('服务动作：') + String(preview.service_action || '—') + '\n' +
					_('dnsmasq 自动配置：') + String(preview.dnsmasq_auto || _('继承')) + '\n' +
					_('将删除的缓存文件：') + String(preview.cache_delete || _('无'));
				if (!window.confirm(summary + '\n\n' + _('确认按此预览应用？'))) throw new Error(_('用户取消应用'));
				return api.smartdnsApply();
			})
			.then(function(reply) { api.notice(ui, reply, _('SmartDNS 应用完成')); if (!reply.ok) throw new Error(reply.error || reply.message); return reply; });
	},

	handleDiscard: function() {
		return api.smartdnsDiscardCandidate().then(function(reply) { api.notice(ui, reply, _('候选已丢弃')); return reply; });
	},

	handleSaveApply: null,
	handleReset: null
});
