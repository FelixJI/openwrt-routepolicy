'use strict';
'require view';
'require ui';
'require uci';
'require request';
'require routepolicy/api as api';
'require routepolicy/lifecycle as lifecycle';

/* Lifecycle wizard: first-time configuration, import/restore, exit and status
 * self-check. The page only reads state while loading; every mutating step is
 * an explicit user action behind a read-only preview and a danger
 * confirmation. All dynamic values are rendered as plain text nodes. */

var POLL_INTERVAL_MS = 2000;
var TRANSACTION_TOKEN_RE = /^[0-9a-f]{32}$/;
var RULE_LISTS = {
	'domain-policy': _('策略域名'),
	'domain-default': _('默认覆盖域名'),
	'ipv4-policy': _('策略 IPv4/CIDR'),
	'ipv4-default': _('默认覆盖 IPv4/CIDR')
};
var SOURCE_FORMATS = [ 'plain-domain', 'plain-ipv4', 'hosts-domain', 'adblock-domain', 'dnsmasq-domain', 'clash-domain', 'clash-ipv4' ];
var SOURCE_TARGETS = {
	'domain-policy': _('域名 → 策略出口'),
	'domain-default': _('域名 → 默认出口'),
	'ipv4-policy': _('IPv4/CIDR → 策略出口'),
	'ipv4-default': _('IPv4/CIDR → 默认出口')
};

function alertBox(tone, nodes) {
	return E('div', { 'class': 'alert-message ' + (tone === 'error' ? 'error' : 'notice') }, nodes);
}

function rowItem(label, value, description) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label),
		E('div', { 'class': 'cbi-value-field' }, [
			E('strong', {}, api.safeText(value)),
			description ? E('div', { 'class': 'cbi-value-description' }, api.safeText(description)) : ''
		])
	]);
}

function preBlock(text) {
	return E('pre', {
		'class': 'command',
		'style': 'white-space:pre-wrap;overflow-wrap:anywhere;user-select:text'
	}, api.safeText(text));
}

function inputText(value, placeholder) {
	return E('input', {
		'class': 'cbi-input-text',
		type: 'text',
		value: value == null ? '' : String(value),
		placeholder: placeholder || ''
	});
}

function selectControl(options, selected) {
	var children = options.map(function(option) {
		return E('option', {
			value: option.value,
			selected: option.value === selected ? '' : null
		}, option.label);
	});
	return E('select', { 'class': 'cbi-input-select' }, children);
}

function diffTable(candidateText, baselineText) {
	var rows = lifecycle.candidateRows(candidateText, baselineText);
	if (!rows.length)
		return E('p', { 'class': 'cbi-section-descr' }, _('后端未返回候选差异内容。'));
	var body = [ E('div', { 'class': 'tr table-titles' }, [
		E('div', { 'class': 'th' }, _('配置项')),
		E('div', { 'class': 'th' }, _('操作')),
		E('div', { 'class': 'th' }, _('原值（基线）')),
		E('div', { 'class': 'th' }, _('候选值'))
	]) ];
	var lastGroup = null;
	for (var i = 0; i < rows.length; i++) {
		var row = rows[i];
		if (row.group !== lastGroup) {
			lastGroup = row.group;
			body.push(E('div', { 'class': 'tr' },
				E('div', { 'class': 'td', colspan: '4' }, E('strong', {}, lifecycle.groupLabels[row.group] || row.group))));
		}
		body.push(E('div', { 'class': 'tr', 'data-key': row.key }, [
			E('div', { 'class': 'td' }, row.key),
			E('div', { 'class': 'td' }, row.action),
			E('div', { 'class': 'td' }, row.old == null ? _('（不存在或未提供）') : row.old),
			E('div', { 'class': 'td' }, row.action === 'delete' ? _('（删除）') : row.value)
		]));
	}
	return E('div', { 'class': 'table cbi-section-table', 'id': 'routepolicy-candidate-diff' }, body);
}

function stateLabel(kind, value) {
	if (value === '1')
		return kind === 'running' ? _('1（运行中）') : _('1（启用自启）');
	if (value === '0')
		return kind === 'running' ? _('0（已停止）') : _('0（禁用自启）');
	return api.safeText(value);
}

function servicesTable(servicesText) {
	var rows = lifecycle.parseServicesTsv(servicesText);
	if (!rows.length)
		return E('span', { style: 'display:none' });
	var body = [ E('div', { 'class': 'tr table-titles' }, [
		E('div', { 'class': 'th' }, _('服务')),
		E('div', { 'class': 'th' }, _('项目')),
		E('div', { 'class': 'th' }, _('当前')),
		E('div', { 'class': 'th' }, _('退出后恢复为'))
	]) ];
	for (var i = 0; i < rows.length; i++)
		body.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td' }, rows[i].service),
			E('div', { 'class': 'td' }, rows[i].kind === 'running' ? _('运行状态') : rows[i].kind === 'enabled' ? _('开机自启') : rows[i].kind),
			E('div', { 'class': 'td' }, stateLabel(rows[i].kind, rows[i].current)),
			E('div', { 'class': 'td' }, stateLabel(rows[i].kind, rows[i].restore))
		]));
	return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-exit-services' }, [
		E('h3', {}, _('退出将恢复的服务状态（真实归属差异）')),
		E('div', { 'class': 'table cbi-section-table' }, body)
	]);
}

function checklistNode(checks) {
	return E('ul', { 'style': 'padding-left:1.2rem' }, checks.map(function(check) {
		return E('li', {}, [
			E('strong', {}, (check.hits.length ? '✓ ' : '✗ ') + check.label),
			check.hits.length
				? E('div', { 'class': 'cbi-value-description' }, check.hits.slice(0, 4).join('；') + (check.hits.length > 4 ? ' …' : ''))
				: E('div', { 'class': 'cbi-value-description' }, _('本次候选中没有该类证据'))
		]);
	}));
}

var PREVIEW_WARNINGS = [
	_('所选接入接口将关闭 DHCPv4、RA、DHCPv6 与 NDP 服务。'),
	_('所选接口转为 IPv4-only：新建 IPv6 转发会被拒绝；外部路由器 RA 或终端直连链路 IPv6 仍可能绕行，不宣称 AAAA 过滤等于全流量受控。'),
	_('SmartDNS 将独占监听受管接入侧与回环的 IPv4 TCP/UDP 53，并设置开机自启；dnsmasq 将停止并禁用自启动，DNS 切换可能造成短暂解析中断。'),
	_('fw4 按候选建立出口失败策略与 NAT/分流规则；请以差异表中的实际 firewall 条目为准。'),
	_('应用开始后进入连接确认窗口：终端与主路由需把网关和 DNS 指向候选管理地址（见上方实际值），然后在新的管理地址重新登录本页面确认。'),
	_('共享维护约定：从本次预览到确认成功或回滚完成期间单人维护，请暂停其他页面、SSH 或脚本保存 network、dhcp、firewall、routepolicy、smartdns 配置；已保留冲突检测。')
];

return view.extend({
	load: function() {
		/* Read-only RPCs only; failures degrade the panel instead of failing
		 * the whole page, so read-only accounts can still see the status. */
		var empty = function() { return {}; };
		return Promise.all([
			api.initStatus().catch(empty),
			api.restoreStatus().catch(empty),
			uci.load('routepolicy').catch(function() { return null; })
		]);
	},

	render: function(data) {
		this.status = (data && data[0]) || {};
		this.restore = (data && data[1]) || {};
		this.offline = this.status.ok !== true || this.restore.ok !== true;
		this.applyIntent = null;
		this.prepareCheck = null;
		this.confirmCheck = null;
		this.setScreen('overview');
		this.busy = {};
		this.discover = null;
		this.canWrite = null; /* null = unknown; false = LuCI reports no write permission */
		this.feedback = E('div', { 'id': 'routepolicy-wizard-feedback' });
		this.confirmation = E('div', { 'id': 'routepolicy-wizard-confirmation' });
		this.body = E('div', { 'id': 'routepolicy-wizard-body' });
		this.root = E('div', { 'class': 'cbi-map', 'id': 'routepolicy-wizard' }, [
			E('h2', {}, _('初始化与恢复向导')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('首次配置、导入恢复、退出与状态自检都在本页完成。页面加载时只读取状态，不做任何修改；每个危险步骤都先只读预览、再明确确认。'),
				E('br'),
				_('首次安装时，默认启用开关为 0。即使不运行向导，也可以继续使用原有功能。')
			]),
			this.feedback,
			this.confirmation,
			this.body
		]);
		this.determineWritePermission();
		this.paintOverview();
		return this.root;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	/* Verified against luci-base in the target SDK: hasViewPermission() takes
	 * no arguments and returns synchronously - `true` when a required ACL
	 * group is granted with write permissions, `false` for read-only access
	 * and `null` when the view resources cannot be loaded at all. With 'write'
	 * denied, mutating buttons are disabled; the backend ACL always remains
	 * the enforcement point and no write-ACL method is called during load. */
	determineWritePermission: function() {
		try {
			if (typeof L.hasViewPermission === 'function')
				this.canWrite = L.hasViewPermission() === true;
		}
		catch (e) { /* fall through to unknown */ }
	},

	readOnlyNotice: function() {
		return this.canWrite === false
			? alertBox('error', [
				E('strong', {}, _('当前账户没有本页面的写权限')),
				E('p', {}, _('只能查看状态与自检结果；初始化预览（含 ARP 冲突探测）、准备、应用、导入、导出与退出等操作按钮已禁用。'))
			])
			: null;
	},

	fail: function(message) {
		this.feedback.replaceChildren(alertBox('error', [
			E('strong', {}, _('操作失败')),
			E('p', {}, api.safeText(message))
		]));
	},

	ok: function(message) {
		this.feedback.replaceChildren(alertBox('notice', [
			E('strong', {}, _('操作已受理')),
			E('p', {}, api.safeText(message))
		]));
	},

	confirmAction: function(message) {
		let self = this;
		if (this.pendingConfirmation)
			return Promise.resolve(false);
		var screen = this.screen;
		var status = this.status, restore = this.restore;
		this.body.inert = true;
		return new Promise(function(resolve) {
			var finish = function(accepted) {
				if (self.pendingConfirmation !== finish)
					return;
				self.pendingConfirmation = null;
				self.body.inert = false;
				self.confirmation.replaceChildren();
				if (accepted && self.current === 'overview' && (self.offline ||
						self.status.phase !== status.phase || self.status.token !== status.token ||
						self.restore.declaration_phase !== restore.declaration_phase || self.restore.init_token !== restore.init_token)) {
					self.fail(_('设备状态已变化。请查看当前状态后再操作。'));
					accepted = false;
				}
				resolve(accepted && self.screen === screen);
			};
			self.pendingConfirmation = finish;
			var cancel = E('button', { type: 'button', 'class': 'cbi-button cbi-button-neutral', 'data-action': 'confirmation-cancel',
				click: function() { finish(false); } }, _('取消'));
			self.confirmation.replaceChildren(E('div', { 'class': 'alert-message notice', role: 'group', 'aria-label': _('操作确认') }, [
				E('strong', {}, _('操作确认')),
				E('p', {}, message),
				cancel, ' ', E('button', { type: 'button', 'class': 'cbi-button cbi-button-negative important', 'data-action': 'confirmation-accept',
					click: function() { finish(true); } }, _('确认继续'))
			]));
			if (typeof cancel.focus === 'function')
				cancel.focus();
		});
	},

	button: function(label, name, className, handler, needsWrite) {
		let self = this;
		var node = E('button', {
			'class': 'cbi-button ' + (className || 'cbi-button-neutral'),
			'data-action': name,
			'click': ui.createHandlerFn(this, function() {
				if (self.pendingConfirmation || self.busy[name])
					return Promise.resolve();
				if (needsWrite !== false && self.canWrite === false)
					return Promise.resolve();
				self.busy[name] = true;
				node.disabled = true;
				return Promise.resolve(handler.call(self)).catch(function(error) {
					self.fail(error && error.message || String(error));
				}).then(function() {
					self.busy[name] = false;
					/* Re-enable unless the account is known read-only. */
					if (needsWrite === false || self.canWrite !== false)
						node.disabled = false;
				});
			})
		}, label);
		if (needsWrite !== false && this.canWrite === false)
			node.disabled = true;
		return node;
	},

	clearPollTimer: function() {
		if (this.pollTimer != null) {
			window.clearTimeout(this.pollTimer);
			this.pollTimer = null;
		}
	},

	setScreen: function(name) {
		if (this.pendingConfirmation)
			this.pendingConfirmation(false);
		this.clearPollTimer();
		this.statusRequest = null;
		this.current = name;
		this.screen = {};
	},

	declarationCommitUnsettled: function() {
		// An empty binding can belong to a new import interrupted before network preparation.
		return this.status.phase === 'confirmed' && this.restore.declaration_phase === 'installed' &&
			this.restore.init_token !== '';
	},

	awaitingApplyStatus: function() {
		var st = this.status;
		var job = lifecycle.jobInfo(st);
		if (lifecycle.pollPhases[st.phase] === true)
			return false;
		// The status command reads phase before reading the worker record.
		return !!(this.applyIntent || (job && (
			(st.phase === 'prepared' && job.kind === 'init') ||
			(job.kind === 'exit' && st.phase !== 'exited' && (job.state === 'done' ||
				(st.exit_candidate_available === true && job.state === 'running')))
		)));
	},

	statusInProgress: function() {
		var job = lifecycle.jobInfo(this.status);
		return this.offline || !!this.prepareCheck || lifecycle.pollPhases[this.status.phase] === true || this.awaitingApplyStatus() ||
			this.declarationCommitUnsettled() || !!(job && job.state === 'running');
	},

	needsPoll: function() {
		return this.statusInProgress() || this.status.phase === 'prepared' || this.status.exit_candidate_available === true;
	},

	settleApplyIntent: function(exitCandidate) {
		var intent = this.applyIntent;
		if (!intent)
			return;
		var st = this.status;
		var job = lifecycle.jobInfo(st);
		var sameJob = job && job.kind === intent.kind && job.token === intent.token;
		if (st.token === intent.token) {
			var terminal = intent.kind === 'exit' ? [ 'exited', 'rolled_back', 'conflict' ] :
				[ 'expired', 'confirmed', 'rolled_back', 'conflict' ];
			if (terminal.indexOf(st.phase) >= 0 && !(sameJob && job.state === 'running'))
				this.applyIntent = null;
		}
		else if (intent.kind === 'init') {
			if (st.token && !sameJob)
				this.applyIntent = null;
		}
		else if (sameJob ? job.state === 'failed' : st.exit_candidate_available !== true ||
			(exitCandidate && exitCandidate.ok === true && exitCandidate.token && exitCandidate.token !== intent.token)) {
			this.applyIntent = null;
		}
	},

	settlePrepareCheck: function(candidate) {
		var check = this.prepareCheck;
		if (!check || !candidate || candidate.ok !== true || !TRANSACTION_TOKEN_RE.test(candidate.token) || candidate.token === check.previousToken)
			return;
		if (check.kind === 'exit' ? this.status.exit_candidate_available !== true :
				this.status.phase !== 'prepared' || this.status.token !== candidate.token)
			return;
		this.prepareCheck = null;
		if (this.feedback.contains(check.notice))
			this.feedback.replaceChildren(alertBox('notice', [
				E('strong', {}, _('设备报告了当前候选')),
				E('p', {}, _('请打开当前候选并重新审阅差异，再决定是否应用。'))
			]));
	},

	settleConfirmCheck: function() {
		var check = this.confirmCheck;
		if (!check)
			return;
		if (!this.feedback.contains(check.notice)) {
			this.confirmCheck = null;
			return;
		}
		if (!this.offline && this.status.token === check.token && this.status.phase === 'confirmed' && !this.status.confirmation_error) {
			this.confirmCheck = null;
			this.feedback.replaceChildren(alertBox('notice', [ E('p', {}, _('设备已确认本次网络变更。请查看状态自检。')) ]));
		}
	},

	readStatuses: function() {
		return Promise.all([ api.initStatus(), api.restoreStatus() ]);
	},

	/* The reads are independent. After a write, discard any read started before its reply. */
	refreshStatus: function(afterWrite) {
		let self = this;
		if (this.current !== 'overview')
			return Promise.resolve();
		if (this.statusRequest && !afterWrite)
			return this.statusRequest;
		this.clearPollTimer();
		var update = function(replies, candidate) {
			if (self.statusRequest !== read)
				return;
			self.statusRequest = null;
			self.offline = !replies || !replies.every(function(reply) { return reply && reply.ok === true; });
			if (!self.offline) {
				self.status = replies[0];
				self.restore = replies[1];
				self.settleApplyIntent(candidate);
				self.settlePrepareCheck(candidate);
				self.settleConfirmCheck();
			}
			self.paintOverview();
		};
		var read = this.readStatuses().then(function(replies) {
			if (self.statusRequest !== read)
				return;
			var intent = self.applyIntent;
			var prepare = self.prepareCheck;
			var st = replies[0];
			var job = lifecycle.jobInfo(st);
			var readCandidate;
			// Exit status only reports candidate presence. Read its identity to detect a replacement.
			if (st && st.exit_candidate_available === true && (prepare && prepare.kind === 'exit' ||
					intent && intent.kind === 'exit' && st.token !== intent.token && (!job || job.token !== intent.token)))
				readCandidate = api.exitCandidate;
			else if (st && prepare && prepare.kind !== 'exit' && st.phase === 'prepared' && st.token && st.token !== prepare.previousToken)
				readCandidate = api.initCandidate;
			if (readCandidate)
				return readCandidate().then(function(candidate) { update(replies, candidate); }, function() { update(replies); });
			update(replies);
		}, function() { update(null); });
		this.statusRequest = read;
		return read;
	},

	syncPolling: function() {
		let self = this;
		if (this.current !== 'overview' || !this.needsPoll()) {
			this.clearPollTimer();
			return;
		}
		if (!this.statusRequest && this.pollTimer == null)
			this.pollTimer = window.setTimeout(function() {
				self.pollTimer = null;
				self.refreshStatus();
			}, POLL_INTERVAL_MS);
	},

	/* ---------- overview / status self check ---------- */

	showOverview: function(afterWrite) {
		if (this.current !== 'overview') {
			this.setScreen('overview');
			this.body.replaceChildren(E('p', {}, _('正在读取状态…')), this.applyReconnectHint() || '',
				this.prepareCheck ? this.reloadStatusControl() : '');
		}
		return this.refreshStatus(afterWrite);
	},

	paintOverview: function() {
		this.body.replaceChildren(this.statusPanel(), this.phaseActions() || '', this.entryPanel(), this.readOnlyNotice() || '');
		this.syncPolling();
	},

	statusAction: function(call, errorText, successText) {
		let self = this;
		return call.then(function(reply) {
			if (reply && reply.ok === true)
				self.ok(successText || reply.message || _('操作已完成；结果见状态自检。'));
			else
				self.fail(reply && (reply.error || reply.message) || errorText);
		}, function(error) {
			self.fail(error && error.message || errorText);
		}).then(function() { return self.refreshStatus(true); });
	},

	reloadStatusControl: function() {
		return E('p', {}, [
			_('设备可能仍在处理。若状态长时间没有更新，可以重新加载页面并核对当前状态。'),
			' ', this.button(_('重新加载页面'), 'reload-page', 'cbi-button-neutral', function() {
				window.location.reload();
			}, false)
		]);
	},

	statusPanel: function() {
		var st = this.status || {};
		var info = lifecycle.phaseInfo(st.phase);
		var awaitingApply = this.awaitingApplyStatus();
		var nodes = [];
		if (this.offline)
			nodes.push(alertBox('error', [
				E('strong', {}, _('状态未知')),
				E('p', {}, _('暂时无法读取完整状态。页面会自动重试；网络恢复后也可点击“重新检测状态”。'))
			]));
		else if (awaitingApply)
			nodes.push(alertBox('notice', [
				E('strong', {}, _('等待设备报告提交状态')),
				E('p', {}, _('设备尚未报告明确进度。页面会继续检测，请勿重复提交。'))
			]));
		else
			nodes.push(E('div', { 'class': 'alert-message ' + info.tone, 'id': 'routepolicy-phase' }, [
				E('strong', {}, _('当前状态：') + info.label),
				E('p', {}, info.text)
			]));
		if (this.prepareCheck)
			nodes.push(alertBox('notice', [ E('p', {}, _('准备请求结果待核实。页面会检测当前候选，请勿重复准备。')) ]));
		if (awaitingApply || this.prepareCheck)
			nodes.push(this.reloadStatusControl());
		var extras = [];
		var reconnectHint = this.offline && this.applyReconnectHint();
		if (reconnectHint)
			nodes.push(reconnectHint);
		if (st.management_address && !reconnectHint)
			extras.push(rowItem(_('候选管理地址'), st.management_address, _('确认前请先在该地址重新登录。')));
		if (!this.offline && typeof st.remaining_seconds === 'number' && (st.phase === 'pending' || st.phase === 'applying')) {
			if (st.remaining_seconds > 0)
				extras.push(rowItem(_('剩余确认时间（秒）'), String(st.remaining_seconds), _('倒计时以后端为准；窗口结束后后端自动回滚。')));
			else
				extras.push(rowItem(_('确认窗口'), _('已结束'), _('等待后端按合同自动回滚；请勿重复应用。')));
		}
		if (!this.offline && st.phase === 'pending') {
			extras.push(rowItem(_('HTTP 连接确认'), st.http_confirmation_ready === true ? _('后端已就绪，可立即确认') : _('尚未就绪：请先在新管理地址重新登录，再等待按钮可用')));
			if (st.confirmation_transport)
				extras.push(rowItem(_('确认通道'), st.confirmation_transport === 'trusted-luci-or-ssh'
					? _('trusted-luci-or-ssh：本页面仅经 HTTP 确认入口提交，需真实连接候选管理地址并具备写权限与 CSRF 会话')
					: st.confirmation_transport, _('即使按钮可用，地址不符或无写权限时后端仍会拒绝并保持待确认。')));
		}
		if (st.stage)
			extras.push(rowItem(_('当前阶段'), st.stage));
		if (st.failed_stage)
			extras.push(rowItem(_('失败阶段'), st.failed_stage));
		if (st.prepared_expired_reason)
			extras.push(rowItem(_('候选过期原因'), st.prepared_expired_reason));
		if (st.verification_error)
			extras.push(rowItem(_('验证错误'), st.verification_error));
		if (st.link_error)
			extras.push(rowItem(_('链路错误'), st.link_error));
		if (st.policy_error)
			extras.push(rowItem(_('策略错误'), st.policy_error));
		if (st.deferred_services)
			extras.push(rowItem(_('延迟处理的服务'), st.deferred_services));
		if (st.source_bootstrap === true)
			extras.push(rowItem(_('清单来源'), _('启动引导进行中'), _('首次应用会先准备来源再激活策略。')));
		if (st.confirmation_error) {
			var advice = '';
			if (!this.offline && st.phase === 'confirmed' && st.token)
				advice = _('请使用下方“完成确认收尾”入口处理。');
			else if (!this.offline && st.phase === 'pending' && st.remaining_seconds > 0)
				advice = _('可以在确认窗口内按提示重新确认；超时后会自动回滚。');
			else if (!this.offline && st.phase === 'rolled_back')
				advice = _('本次配置已回滚。请检查失败原因，再决定是否重新准备。');
			extras.push(rowItem(_('确认错误（持久）'), st.confirmation_error, advice));
		}
		if (st.conflicts)
			extras.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('冲突记录')),
				E('div', { 'class': 'cbi-value-field' }, preBlock(st.conflicts))
			]));
		var job = lifecycle.jobInfo(st);
		if (job)
			extras.push(rowItem(_('后台任务'), (job.kind || '—') + ' / ' + (job.state || '—'), job.error || _('无错误信息')));
		if (extras.length)
			nodes.push(E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('状态自检详情')) ].concat(extras)));
		return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-status-panel' }, nodes);
	},

	/* Build the re-login URL from the backend-supplied legal IPv4 and the
	 * CURRENT page scheme/port: never force https onto an http deployment and
	 * never drop a custom port. Only http/https schemes are produced. */
	reconnectUrl: function(address) {
		if (!lifecycle.isIPv4(String(address)))
			return null;
		var location = window.location || {};
		var scheme = location.protocol === 'http:' ? 'http' : 'https';
		var port = String(location.port || '');
		if ((scheme === 'http' && port === '80') || (scheme === 'https' && port === '443'))
			port = '';
		return scheme + '://' + address + (port ? ':' + port : '') + L.url('admin/services/routepolicy/wizard');
	},

	applyReconnectHint: function() {
		var address = this.applyIntent && this.applyIntent.address;
		var url = this.reconnectUrl(address);
		return url ? alertBox('notice', [
			E('strong', {}, _('刚审阅的候选管理地址')),
			E('p', {}, E('a', { href: url, target: '_blank', rel: 'noopener' }, address)),
			E('p', {}, _('若原地址无法访问，可以尝试在此地址重新登录。是否已生效以设备报告的状态为准。'))
		]) : null;
	},

	phaseActions: function() {
		let self = this;
		var st = this.status || {};
		var nodes = [];
		if (this.offline)
			return null;
		var awaitingApply = this.awaitingApplyStatus();

		if (st.phase === 'pending') {
			var address = st.management_address || _('见状态详情');
			var reconnectUrl = this.reconnectUrl(address);
			var reconnectLink = reconnectUrl
				? E('p', {}, E('a', { href: reconnectUrl, target: '_blank', rel: 'noopener' },
					_('在新管理地址打开本页面（重新登录后继续确认）')))
				: null;
			nodes.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('连接确认')),
				E('p', { 'class': 'cbi-section-descr' }, _('应用已把路由器切换到候选配置。请先在新的管理地址重新登录本页面，再执行确认；确认只在本页面完成，不需要 SSH。')),
				rowItem(_('新管理地址'), address, _('终端与主路由的网关和 DNS 应指向该地址（按候选实际值）；地址不符时确认会被拒绝并保持待确认。地址断线后仍在本页展示。')),
				reconnectLink,
				st.http_confirmation_ready === true
					? this.button(_('我已重新连接，确认生效'), 'http-confirm', 'cbi-button-apply important', function() {
						return self.confirmConnected(st.token);
					})
					: E('p', { 'class': 'alert-message notice' }, _('后端尚未允许 HTTP 确认。请稍候或先在新地址重新登录；本页面不会通过其他通道伪造确认。'))
			]));
		}
		else if (this.prepareCheck) {
			return null;
		}
		else if (st.phase === 'prepared') {
			var job = lifecycle.jobInfo(st);
			var cancelToken = st.token && (!this.applyIntent || this.applyIntent.token === st.token) &&
				(!job || job.kind !== 'init' || job.token === st.token) ? st.token : null;
			nodes.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, awaitingApply ? _('候选提交状态待核实') : _('已准备的候选')),
				E('p', { 'class': 'cbi-section-descr' }, awaitingApply
					? (cancelToken ? _('若想放弃，可以请求取消。设备仅在候选仍未应用时允许取消。') : _('请等待设备核实当前候选。'))
					: _('请先查看差异再决定是否应用。若刚提交过，请等待状态更新。')),
				!awaitingApply ? this.button(_('查看候选并准备应用'), 'view-candidate', 'cbi-button-action', function() {
					return self.openPreparedView();
				}) : '',
				' ',
				cancelToken ? this.button(_('取消已准备的候选'), 'cancel-candidate', 'cbi-button-negative', async function() {
					if (!await self.confirmAction(_('只取消这份尚未应用的候选。若它已经开始应用或被替换，取消将被拒绝。继续吗？')))
						return;
					return self.statusAction(api.initCancel(cancelToken), _('后端拒绝取消候选'), _('已取消这份候选。'));
				}) : E('p', {}, _('无法识别这份候选，请重新检测状态后再取消。'))
			]));
		}
		else if (awaitingApply) {
			return null;
		}
		else if (st.phase === 'expired') {
			nodes.push(E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-section-descr' }, _('候选已过期，需要重新生成预览并准备。')),
				this.button(_('重新进入首次配置向导'), 'restart-init', 'cbi-button-neutral', function() {
					self.initFormScreen();
				})
			]));
		}
		else if (st.phase === 'confirmed') {
			var declarationPending = st.token && this.declarationCommitUnsettled() && this.restore.init_token === st.token;
			if (st.confirmation_error || declarationPending) {
				nodes.push(E('div', { 'class': 'cbi-section', 'id': 'routepolicy-confirm-finish' }, [
					E('h3', {}, _('确认收尾未完成')),
					E('p', { 'class': 'cbi-section-descr' }, st.confirmation_error
						? _('网络已经确认，不会自动回滚。收尾步骤失败，可以重试。')
						: _('网络已经确认，正在等候导入声明的最终状态。若长时间没有更新，可以重试收尾。')),
					st.token ? this.button(_('完成确认收尾'), 'confirm-finish', 'cbi-button-negative important', async function() {
						if (!await self.confirmAction(_('只完成这次已确认操作的收尾，不会重新应用或回滚网络。继续吗？')))
							return;
						return self.statusAction(api.initFinish(st.token), _('后端拒绝收尾恢复'), _('确认收尾已完成。'));
					}) : E('p', {}, _('无法识别本次确认，请重新检测状态后再试。'))
				]));
			}
			nodes.push(this.healthPanel(st));
		}
		else if (st.phase === 'conflict') {
			var conflictNodes = [
				E('h3', {}, _('冲突处理')),
				E('p', { 'class': 'cbi-section-descr' }, _('网络事务处于冲突状态：请先恢复网络事务让其收敛；存在导入声明时，收敛完成后按页面提示再处理声明。恢复不会覆盖外部修改，会逐字段保留并报告。')),
				this.button(_('恢复当前事务'), 'init-recover', 'cbi-button-negative', async function() {
					if (!await self.confirmAction(_('将让后端尝试收敛当前事务（恢复或回滚）。继续吗？')))
						return;
					return self.statusAction(api.initRecover(), _('恢复被后端拒绝'));
				})
			];
			nodes.push(E('div', { 'class': 'cbi-section' }, conflictNodes));
		}

		if (st.exit_candidate_available === true && !this.statusInProgress())
			nodes.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('已准备的退出候选')),
				E('p', { 'class': 'cbi-section-descr' }, _('后端已准备好退出候选。点击后重新取回（含服务恢复差异），经危险确认后才会执行退出。')),
				this.button(_('查看退出候选并准备执行'), 'view-exit-candidate', 'cbi-button-action', function() {
					var screen = self.screen;
					return api.exitCandidate().then(function(payload) {
						if (self.screen !== screen || self.pendingConfirmation || self.statusInProgress())
							return;
						if (!payload || payload.ok !== true)
							throw new Error(payload && (payload.error || payload.message) || _('读取退出候选失败'));
						self.renderPrepared(payload, 'exit');
					});
				})
			]));

		var declarationPanel = this.declarationPanel(st);
		if (declarationPanel)
			nodes.push(declarationPanel);

		return nodes.length ? E('div', { 'id': 'routepolicy-phase-actions' }, nodes) : E('span', { style: 'display:none' });
	},

	declarationPanel: function(st) {
		let self = this;
		var decl = this.restore && this.restore.declaration_phase;
		if (!decl || decl === 'absent' || decl === 'rolled_back' || decl === 'committed')
			return null;
		if (st.phase === 'prepared')
			return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-declaration-panel' }, [
				E('h3', {}, _('导入的恢复声明')),
				E('p', { 'class': 'alert-message notice' }, [
					E('strong', {}, _('请先取消已准备的网络候选')),
					E('p', {}, _('请先使用上方“取消已准备的候选”，再撤销导入的声明。'))
				])
			]);
		var networkBusy = lifecycle.pollPhases[st.phase] === true || st.phase === 'conflict';
		if (networkBusy)
			return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-declaration-panel' }, [
				E('h3', {}, _('导入的恢复声明')),
				E('p', { 'class': 'alert-message notice' }, [
					E('strong', {}, _('声明等待网络收敛（' + decl + '）')),
					E('p', {}, _('网络事务进行中，现在处理声明会被后端拒绝。请先让网络收敛（必要时先恢复网络事务），之后此处会出现明确的处理入口。'))
				])
			]);
		if (this.declarationCommitUnsettled())
			return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-declaration-panel' }, [
				E('h3', {}, _('导入的恢复声明')),
				E('p', { 'class': 'alert-message notice' }, _('网络已确认，但声明还没有报告完成。页面会继续检测状态。'))
			]);
		var preparing = decl === 'preparing';
		return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-declaration-panel' }, [
			E('h3', {}, preparing ? _('导入声明有未完成的准备') : _('导入的恢复声明待处理')),
			E('p', { 'class': 'cbi-section-descr' }, preparing
				? _('上次准备中断后残留（' + decl + '）：该阶段尚未修改任何声明文件，可安全取消残留候选；若后端正好在忙，会由后端加锁拒绝并如实提示，不会自行猜测“正在运行”。')
				: _('当前存在已导入但未撤销的声明（' + decl + '）；后端在完成或撤销前会拒绝新的准备/退出/恢复。撤销将逐文件恢复声明原值，不覆盖外部修改。')),
			this.button(preparing ? _('取消残留的导入声明') : _('撤销已导入的声明'), 'restore-recover', 'cbi-button-negative important', async function() {
				if (!await self.confirmAction(preparing
						? _('将让后端取消残留的导入候选（该阶段未修改声明文件）。继续吗？')
						: _('将让后端逐文件撤销导入的声明，不覆盖外部修改。继续吗？')))
					return;
				return self.statusAction(api.restoreRecover(), _('撤销被后端拒绝'));
			})
		]);
	},

	healthPanel: function(st) {
		var health = st && st.health;
		if (!health || typeof health !== 'object')
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('生效与健康检查')),
				alertBox('notice', [
					E('strong', {}, _('后端尚未返回本次确认的健康检查数据')),
					E('p', {}, _('健康项属于事务验收检查：缺失字段或快照不视为端到端全部通过，本页面不会显示全绿。'))
				])
			]);
		var rows = [];
		var topology = health.topology && typeof health.topology === 'object' ? health.topology : null;
		if (topology) {
			if (topology.management_address)
				rows.push(rowItem(_('实际管理地址'), topology.management_address));
			var interfaces = topology.interfaces || {};
			[ 'access', 'default', 'policy' ].forEach(function(role) {
				if (interfaces[role] != null)
					rows.push(rowItem(_('接口（' + role + '）'), typeof interfaces[role] === 'object' ? JSON.stringify(interfaces[role]) : interfaces[role]));
			});
			if (topology.default_egress != null)
				rows.push(rowItem(_('默认出口验证'), topology.default_egress));
		}
		if (health.policy_egress != null)
			rows.push(rowItem(_('策略出口验证'), health.policy_egress));
		if (health.rules_loaded != null)
			rows.push(rowItem(_('分流规则装载（classify 链）'), health.rules_loaded === true ? _('已装载') : String(health.rules_loaded)));
		if (health.sets_loaded != null)
			rows.push(rowItem(_('nft 域名/静态集合装载'), health.sets_loaded === true ? _('已装载') : String(health.sets_loaded)));
		var queryNodes = [];
		var queries = Array.isArray(health.dns_queries) ? health.dns_queries : [];
		var failedQueries = 0;
		for (var i = 0; i < queries.length; i++) {
			var query = queries[i] || {};
			var rcode = String(query.rcode == null ? '' : query.rcode);
			/* Probes use reserved .test domains: NXDOMAIN still proves the
			 * managed DNS path answers; only missing/other rcodes fail. */
			var answered = rcode === 'NOERROR' || rcode === 'NXDOMAIN';
			if (!answered)
				failedQueries++;
			var verdictText = rcode === 'NOERROR' ? 'NOERROR（收到响应）'
				: rcode === 'NXDOMAIN' ? 'NXDOMAIN（无 A 结果，保留 .test 探针域）'
				: rcode;
			queryNodes.push(E('div', { 'class': 'tr', 'data-check': answered ? 'pass' : 'fail' }, [
				E('div', { 'class': 'td' }, api.safeText(query.group)),
				E('div', { 'class': 'td' }, api.safeText(query.transport)),
				E('div', { 'class': 'td' }, (answered ? '✓ ' : '✗ ') + verdictText)
			]));
		}
		if (queryNodes.length)
			rows.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('DNS 查询证据（TCP/UDP）')),
				E('div', { 'class': 'cbi-value-field' }, E('div', { 'class': 'table cbi-section-table' }, [
					E('div', { 'class': 'tr table-titles' }, [
						E('div', { 'class': 'th' }, _('解析组')),
						E('div', { 'class': 'th' }, _('传输')),
						E('div', { 'class': 'th' }, _('结果'))
					])
				].concat(queryNodes)))
			]));
		var incomplete = !topology || health.policy_egress !== 'verified' ||
			failedQueries > 0 || !queries.length || health.rules_loaded !== true || health.sets_loaded !== true ||
			(topology.default_egress != null && topology.default_egress !== 'verified');
		var verdict = incomplete
			? alertBox('error', [ E('strong', {}, _('部分检查未通过或未提供')), E('p', {}, _('以上为后端事务验收检查的真实证据；存在未验证项时不显示全绿。')) ])
			: alertBox('notice', [ E('strong', {}, _('后端事务验收检查全部通过')), E('p', {}, _('仅代表本次事务验收检查通过，不额外宣称未检查的能力。')) ]);
		return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-health' }, [
			E('h3', {}, _('生效与健康检查')),
			E('p', { 'class': 'cbi-section-descr' }, _('以下数据仅来自后端在当前启动内的真实检查（拓扑、DNS TCP/UDP、规则出口证据）；缺失即按未通过显示。'))
		].concat(rows).concat([ verdict ]));
	},

	entryPanel: function() {
		let self = this;
		var busyPhase = this.statusInProgress();
		var retainedRestore = this.restore && this.restore.candidate_pending === true;
		var nodes = [
			E('h3', {}, _('操作入口')),
			E('p', { 'class': 'cbi-section-descr' }, busyPhase
				? _('请等待状态更新后再开始新的向导流程。')
				: _('选择一个入口。所有入口都会先读取后端状态，再进入只读预览。'))
		];
		var refresh = this.button(_('重新检测状态'), 'refresh-status', 'cbi-button-neutral', function() {
			return self.refreshStatus();
		}, false);
		var initButton = this.button(_('首次配置向导'), 'open-init', 'cbi-button-apply', function() {
			self.initFormScreen();
		});
		var restoreButton = this.button(_('导入恢复'), 'open-restore', 'cbi-button-apply', function() {
			self.openRestore();
		});
		var exitButton = this.button(_('退出'), 'open-exit', 'cbi-button-negative', function() {
			self.openExit();
		});
		if (busyPhase) {
			initButton.disabled = true;
			restoreButton.disabled = true;
			exitButton.disabled = true;
		}
		nodes.push(refresh, ' ', initButton, ' ', restoreButton, ' ', exitButton);
		if (retainedRestore)
			nodes.push(E('p', { 'class': 'alert-message notice' }, _('设备保留了一份导入声明，可在“导入恢复”中查看。')));
		return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-entry-panel' }, nodes);
	},

	confirmConnected: function(token) {
		let self = this;
		if (!token) {
			self.fail(_('无法识别本次网络变更，请重新检测状态后再确认。'));
			return Promise.resolve();
		}
		var screen = this.screen;
		var feedback = this.feedback.firstChild;
		var canReport = function() {
			return self.screen === screen && self.status.token === token && self.feedback.firstChild === feedback;
		};
		/* The controller reads http.formvalue: the confirmation must be sent as a
	 * real form body (multipart FormData), never JSON and never in the URL. */
		var form = new FormData();
		form.append('token', L.env.token);
		form.append('transaction_token', token);
		return request.post(L.url('admin/services/routepolicy/confirm'), form, { timeout: 30000 }).then(function(response) {
			var body = response && typeof response.json === 'function'
				? response.json()
				: Promise.resolve(response);
			return Promise.resolve(body).then(function(reply) {
				if (!reply || (reply.ok !== true && reply.ok !== false))
					throw new Error(_('设备未返回明确的连接确认结果。'));
				if (!canReport())
					return;
				if (reply.ok === true)
					self.ok(_('后端已受理连接确认；正在完成确认与健康检查，结果以状态自检为准。'));
				else
					self.fail(_('连接确认被后端拒绝：') + (reply.error || reply.message || _('未返回原因')));
			});
		}).catch(function(error) {
			if (!canReport())
				return;
			var notice = alertBox('notice', [
				E('strong', {}, _('连接确认结果待核实')),
				E('p', {}, _('未收到明确回复。请以设备报告的状态为准。')),
				E('p', {}, api.safeText(error && error.message))
			]);
			self.confirmCheck = { token: token, notice: notice };
			self.feedback.replaceChildren(notice);
			self.settleConfirmCheck();
		}).then(function() { return self.refreshStatus(true); });
	},

	openPreparedView: function() {
		let self = this;
		var screen = this.screen;
		return api.initCandidate().then(function(payload) {
			if (self.screen !== screen || self.pendingConfirmation || self.statusInProgress() || self.status.phase !== 'prepared')
				return;
			if (!payload || payload.ok !== true)
				throw new Error(payload && (payload.error || payload.message) || _('读取已准备候选失败'));
			/* Derive the kind from authoritative state, not browser memory: a
			 * prepared candidate bound to a pending declaration is a restore
			 * candidate (its apply is still the same init transaction). */
			var decl = self.restore && self.restore.declaration_phase;
			var kind = (self.status && self.status.phase === 'prepared' && decl &&
				[ 'preparing', 'installing', 'installed', 'recovering', 'prepared' ].indexOf(decl) >= 0) ? 'restore' : 'init';
			self.renderPrepared(payload, kind);
		});
	},

	/* ---------- first-time configuration ---------- */

	initFormScreen: function() {
		let self = this;
		this.setScreen('init-form');
		this.discover = null;
		this.form = null;
		var discoverSection = E('div', { 'class': 'cbi-section', 'id': 'routepolicy-discover' }, [
			E('h3', {}, _('设备与接口自检')),
			E('p', { 'class': 'cbi-section-descr' }, _('正在读取设备与接口自检数据（只读）…'))
		]);
		var formSection = E('div', {});
		var previewButton = this.button(_('生成只读预览'), 'make-preview', 'cbi-button-apply important', function() {
			return self.makeInitPreview();
		});
		var backButton = this.button(_('返回状态总览'), 'back-overview-init', 'cbi-button-neutral', function() {
			if (!self.busy['save-rules'] && !self.busy['save-sources'])
				return self.showOverview();
		}, false);
		this.body.replaceChildren(
			discoverSection,
			formSection,
			this.rulesAndSourcesSection(function(saving) {
				previewButton.disabled = saving || self.canWrite === false;
				backButton.disabled = saving;
			}),
			E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5rem;margin:.75rem 0' }, [
				previewButton,
				backButton
			])
		);
		this.runDiscover(discoverSection, formSection);
	},

	runDiscover: function(section, formSection, mappingBox) {
		let self = this;
		var screen = this.screen;
		var isCurrent = function() { return self.screen === screen && (!mappingBox || mappingBox.contains(formSection)); };
		return api.initDiscover().then(function(discover) {
			if (!isCurrent())
				return;
			self.discover = discover || {};
			self.renderDiscover(section);
			formSection.replaceChildren(self.topologyForm());
		}, function(error) {
			if (!isCurrent())
				return;
			section.replaceChildren(
				E('h3', {}, _('设备与接口自检')),
				alertBox('error', [
					E('strong', {}, _('自检数据读取失败')),
					E('p', {}, api.safeText(error && error.message || String(error)))
				])
			);
		});
	},

	renderDiscover: function(section) {
		var d = this.discover || {};
		var nodes = [ E('h3', {}, _('设备与接口自检')) ];
		var missing = Array.isArray(d.missing_dependencies) ? d.missing_dependencies : [];
		if (missing.length)
			nodes.push(alertBox('error', [
				E('strong', {}, _('缺少依赖：') + missing.join('、')),
				E('p', {}, _('缺少上述命令时后端会拒绝初始化；请先安装依赖再继续。'))
			]));
		if (d.ok !== true)
			nodes.push(alertBox('error', [ E('p', {}, _('后端自检未全部通过（ok=false），以下信息仅供排查；预览仍由后端做权威校验。')) ]));
		var observations = d.observations || {};
		var obs = [];
		if (observations.fw4)
			obs.push(rowItem(_('fw4 配置检查'), observations.fw4));
		if (observations.mark_table_preflight)
			obs.push(rowItem(_('mark/路由表预检'), observations.mark_table_preflight));
		if (observations.dns_listeners)
			obs.push(rowItem(_('53 端口监听'), observations.dns_listeners));
		if (obs.length)
			nodes.push(E('div', {}, obs));
		if (observations.warning)
			nodes.push(alertBox('notice', [ E('p', {}, observations.warning) ]));
		var interfaces = lifecycle.netifdInterfaces(d);
		var rows = [ E('div', { 'class': 'tr table-titles' }, [
			E('div', { 'class': 'th' }, _('逻辑接口')),
			E('div', { 'class': 'th' }, _('实际设备')),
			E('div', { 'class': 'th' }, _('协议')),
			E('div', { 'class': 'th' }, _('IPv4')),
			E('div', { 'class': 'th' }, _('状态'))
		]) ];
		for (var i = 0; i < interfaces.length; i++) {
			var itf = interfaces[i];
			rows.push(E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td' }, itf.name),
				E('div', { 'class': 'td' }, itf.device || '—'),
				E('div', { 'class': 'td' }, itf.proto || '—'),
				E('div', { 'class': 'td' }, itf.address || '—'),
				E('div', { 'class': 'td' }, itf.up ? _('在线') : _('离线'))
			]));
		}
		nodes.push(E('div', { 'class': 'table cbi-section-table', 'id': 'routepolicy-discover-interfaces' }, rows));
		var freeDevices = lifecycle.unclaimedDevices(d);
		var deviceList = _('无法枚举，请核对 RoutePolicy 核心组件版本。');
		if (freeDevices)
			deviceList = freeDevices.length ? freeDevices.map(function(item) {
				return item.name + (item.up ? '' : _('（未启用）'));
			}).join('、') : _('没有可确认的独立网卡');
		nodes.push(rowItem(_('已识别未配置的独立网卡'), deviceList,
			_('设备会核对网卡是否独立且未被配置，生成预览时会再次检查。')));
		section.replaceChildren.apply(section, nodes);
	},

	topologyForm: function() {
		var interfaces = lifecycle.netifdInterfaces(this.discover).filter(function(itf) {
			return itf.up && itf.device && itf.device !== 'lo' && itf.address;
		});
		var freeDevices = lifecycle.unclaimedDevices(this.discover) || [];
		var interfaceOption = function(itf) {
			return {
				value: itf.name,
				label: itf.name + '（' + api.safeText(itf.proto, _('未知协议')) + ' / ' + itf.device + ' / ' + itf.address + '）'
			};
		};
		var accessOptions = interfaces.filter(function(itf) { return itf.proto === 'static'; }).map(interfaceOption);
		var egressOptions = interfaces.map(interfaceOption);
		if (freeDevices.length)
			egressOptions.push({ value: '---create---', label: _('＋ 新建出口（使用未配置网卡）') });
		var accessSelect = selectControl([ { value: '-', label: accessOptions.length ? _('请选择接入接口') : _('未发现在线的静态 IPv4 接口') } ].concat(accessOptions),
			accessOptions.length === 1 ? accessOptions[0].value : '-');
		var defaultSelect = selectControl([ { value: '-', label: _('请选择默认出口') } ].concat(egressOptions), '-');
		var policySelect = selectControl([ { value: '-', label: _('请选择策略出口') } ].concat(egressOptions), '-');
		var deviceOptions = freeDevices.length
			? freeDevices.map(function(item) { return { value: item.name, label: item.name + (item.up ? '' : _('（未启用）')) }; })
			: [ { value: '-', label: _('（未发现未配置网卡）') } ];
		var deviceSelect = selectControl(deviceOptions, deviceOptions[0].value);
		var protoSelect = selectControl([
			{ value: 'dhcp', label: _('DHCP 客户端') },
			{ value: 'static', label: _('静态 IPv4') }
		], 'dhcp');
		var newIp = inputText('', '例如 203.0.113.2');
		var newPrefix = inputText('', '例如 24');
		var newGateway = inputText('', '例如 203.0.113.1');
		var mgmtUse = selectControl([
			{ value: 'keep', label: _('保持当前管理地址') },
			{ value: 'change', label: _('改为新的管理地址') }
		], 'keep');
		var mgmtIp = inputText('', '例如 192.0.2.9');
		var mgmtPrefix = inputText('', '例如 24');
		var dnsDefault = inputText('', _('留空表示继承该逻辑接口的 IPv4 DNS'));
		var dnsPolicy = inputText('', _('留空表示继承；新建 DHCP 出口必须显式填写'));

		var staticBox = E('div', { 'style': 'display:none;margin-top:.35rem', 'id': 'routepolicy-new-static' }, [
			E('label', {}, [ _('IPv4 地址 '), newIp ]),
			E('label', { 'style': 'margin-left:.5rem' }, [ _('前缀 '), newPrefix ]),
			E('label', { 'style': 'margin-left:.5rem' }, [ _('网关 '), newGateway ])
		]);
		var createBox = E('div', { 'style': 'display:none;margin-left:1rem' }, [
			E('p', { 'class': 'cbi-value-description' }, _('将创建保留逻辑名 rp_init_default / rp_init_policy（取决于在哪一侧新建）。')),
			E('label', {}, [ _('网卡 '), deviceSelect ]),
			E('label', { 'style': 'margin-left:.75rem' }, [ _('协议 '), protoSelect ]),
			staticBox
		]);
		var syncCreate = function() {
			var creating = defaultSelect.value === '---create---' || policySelect.value === '---create---';
			createBox.style.display = creating ? '' : 'none';
			staticBox.style.display = creating && protoSelect.value === 'static' ? '' : 'none';
		};
		defaultSelect.addEventListener('change', syncCreate);
		policySelect.addEventListener('change', syncCreate);
		protoSelect.addEventListener('change', syncCreate);

		var mgmtBox = E('div', { 'style': 'display:none;margin-left:1rem' }, [
			E('label', {}, [ _('管理 IPv4 '), mgmtIp ]),
			E('label', { 'style': 'margin-left:.5rem' }, [ _('前缀 '), mgmtPrefix ]),
			E('p', { 'class': 'cbi-value-description' }, _('新管理地址将在应用后生效；确认阶段需要在新的地址重新登录。'))
		]);
		mgmtUse.addEventListener('change', function() {
			mgmtBox.style.display = mgmtUse.value === 'change' ? '' : 'none';
		});

		this.form = {
			accessSelect: accessSelect,
			defaultSelect: defaultSelect,
			policySelect: policySelect,
			deviceSelect: deviceSelect,
			protoSelect: protoSelect,
			newIp: newIp,
			newPrefix: newPrefix,
			newGateway: newGateway,
			mgmtUse: mgmtUse,
			mgmtIp: mgmtIp,
			mgmtPrefix: mgmtPrefix,
			dnsDefault: dnsDefault,
			dnsPolicy: dnsPolicy
		};

		return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-topology-form' }, [
			E('h3', {}, _('选择拓扑与必要输入')),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('接入（管理）逻辑接口')), E('div', { 'class': 'cbi-value-field' }, [ accessSelect, E('div', { 'class': 'cbi-value-description' }, _('后端要求：已有静态 IPv4、独立管理防火墙区域且入站 ACCEPT；支持与默认出口共享设备。')) ]) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('默认出口')), E('div', { 'class': 'cbi-value-field' }, [ defaultSelect ]) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('策略出口')), E('div', { 'class': 'cbi-value-field' }, [ policySelect ]) ]),
			createBox,
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('管理地址')), E('div', { 'class': 'cbi-value-field' }, [ mgmtUse, mgmtBox ]) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('默认出口 DNS')), E('div', { 'class': 'cbi-value-field' }, [ dnsDefault, E('div', { 'class': 'cbi-value-description' }, _('逗号分隔，最多 4 个 IPv4，可写 IP#端口（默认 53）；留空表示继承接口 DNS。')) ]) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('策略出口 DNS')), E('div', { 'class': 'cbi-value-field' }, [ dnsPolicy, E('div', { 'class': 'cbi-value-description' }, _('同一格式；初始化会自动创建 SmartDNS 解析组，无需手工建组。')) ]) ])
		]);
	},

	readForm: function() {
		var f = this.form;
		if (!f)
			return { ok: false, errors: [ _('表单尚未就绪') ] };
		var creating = f.defaultSelect.value === '---create---' || f.policySelect.value === '---create---';
		return lifecycle.buildInitContent({
			access: f.accessSelect.value,
			defaultMode: f.defaultSelect.value === '---create---' ? 'create' : 'existing',
			defaultIf: f.defaultSelect.value === '---create---' ? '' : f.defaultSelect.value,
			policyMode: f.policySelect.value === '---create---' ? 'create' : 'existing',
			policyIf: f.policySelect.value === '---create---' ? '' : f.policySelect.value,
			device: creating ? f.deviceSelect.value : '',
			proto: creating ? f.protoSelect.value : '',
			newIp: creating && f.protoSelect.value === 'static' ? f.newIp.value : '',
			newPrefix: creating && f.protoSelect.value === 'static' ? f.newPrefix.value : '',
			newGateway: creating && f.protoSelect.value === 'static' ? f.newGateway.value : '',
			mgmtIp: f.mgmtUse.value === 'change' ? f.mgmtIp.value : '',
			mgmtPrefix: f.mgmtUse.value === 'change' ? f.mgmtPrefix.value : '',
			dnsDefault: f.dnsDefault.value,
			dnsPolicy: f.dnsPolicy.value
		});
	},

	rulesAndSourcesSection: function(setNavigationBusy) {
		let self = this;
		var screen = this.screen;
		var listSelect = selectControl(Object.keys(RULE_LISTS).map(function(key) {
			return { value: key, label: RULE_LISTS[key] };
		}), 'domain-policy');
		var text = E('textarea', { 'class': 'cbi-input-textarea', rows: 8, spellcheck: 'false', wrap: 'off', 'id': 'routepolicy-wizard-rules' }, '');
		var ruleFeedback = E('div');
		var saveRules = E('button', { type: 'button', 'class': 'cbi-button cbi-button-save', 'data-action': 'save-rules' }, _('校验并保存人工规则'));
		var loadedKind = null, savedContent = '', readGeneration = 0, saving = false;
		var sourceSaving = false;
		var updateRuleEditor = function() {
			var unavailable = saving || loadedKind !== listSelect.value;
			listSelect.disabled = saving;
			text.disabled = unavailable;
			saveRules.disabled = unavailable || self.canWrite === false;
		};
		var readFailed = function(detail) {
			ruleFeedback.replaceChildren(alertBox('error', [
				E('p', {}, _('读取规则失败：') + api.safeText(detail, _('未收到规则内容'))),
				self.button(_('重新读取规则'), 'retry-rules', 'cbi-button-neutral', function() {
					return loadList(listSelect.value);
				}, false)
			]));
		};
		var loadList = function(kind) {
			if (self.screen !== screen || saving)
				return;
			var generation = ++readGeneration;
			var isCurrent = function() { return self.screen === screen && readGeneration === generation; };
			loadedKind = null;
			text.value = '';
			updateRuleEditor();
			ruleFeedback.replaceChildren(E('p', {}, _('正在读取所选规则…')));
			return api.readUserList({ list: kind }).then(function(reply) {
				if (!isCurrent())
					return;
				if (!reply || reply.ok !== true || typeof reply.content !== 'string') {
					readFailed(reply && (reply.error || reply.message));
					return;
				}
				loadedKind = kind;
				text.value = reply.content;
				savedContent = text.value;
				updateRuleEditor();
				ruleFeedback.replaceChildren();
			}, function(error) {
				if (isCurrent())
					readFailed(error && error.message || String(error));
			});
		};
		listSelect.addEventListener('change', async function() {
			if (self.screen !== screen || listSelect.value === loadedKind)
				return;
			var next = listSelect.value;
			if (saving || self.pendingConfirmation) {
				listSelect.value = loadedKind;
				return;
			}
			if (loadedKind && text.value !== savedContent) {
				listSelect.value = loadedKind;
				if (!await self.confirmAction(_('切换规则类型会丢弃当前未保存的修改。继续吗？')))
					return;
				listSelect.value = next;
			}
			return loadList(next);
		});
		var saveFailed = function(detail) {
			ruleFeedback.replaceChildren(alertBox('error', [
				E('strong', {}, _('人工规则保存失败')),
				E('p', {}, api.safeText(detail))
			]));
		};
		saveRules.addEventListener('click', ui.createHandlerFn(this, function() {
			if (self.screen !== screen || self.pendingConfirmation || saving || self.canWrite === false || loadedKind !== listSelect.value)
				return;
			if (self.busy['save-rules']) {
				saveFailed(_('上一次规则保存还未完成，请稍候。'));
				return;
			}
			if (self.busy['make-preview']) {
				saveFailed(_('正在生成预览。请等待预览结果，再保存规则。'));
				return;
			}
			var content = text.value;
			saving = true;
			self.busy['save-rules'] = true;
			updateRuleEditor();
			setNavigationBusy(true);
			ruleFeedback.replaceChildren(E('p', {}, _('正在保存规则，请等待保存结果。')));
			return api.writeUserList({ list: loadedKind, content: content }).then(function(reply) {
				if (self.screen !== screen)
					return;
				if (reply && reply.ok === true) {
					savedContent = content;
					ruleFeedback.replaceChildren(alertBox('notice', [
						E('strong', {}, _('人工规则已保存（后端逐行校验通过）')),
						E('p', {}, api.safeText(reply.message, _('规则文件已原子写入，将在初始化应用时进入运行态。')))
					]));
				}
				else
					saveFailed(reply && (reply.error || reply.message));
			}, function(error) {
				if (self.screen === screen)
					saveFailed(error && error.message || String(error));
			}).finally(function() {
				saving = false;
				self.busy['save-rules'] = false;
				if (self.screen === screen) {
					updateRuleEditor();
					setNavigationBusy(sourceSaving);
				}
			});
		}));
		loadList(listSelect.value);

		var sourceRows = E('div');
		var renderSources = function() {
			var sections = uci.sections('routepolicy', 'source');
			var rows = [ E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th' }, _('名称')),
				E('div', { 'class': 'th' }, _('HTTPS URL')),
				E('div', { 'class': 'th' }, _('格式')),
				E('div', { 'class': 'th' }, _('目标集合')),
				E('div', { 'class': 'th' }, _('启用')),
				E('div', { 'class': 'th' }, _('操作'))
			]) ];
			for (var i = 0; i < sections.length; i++) {
				var section = sections[i];
				let sid = section['.name'];
				var remove = E('button', { 'class': 'cbi-button cbi-button-remove', 'click': function() {
					if (!sourceSaving && self.canWrite !== false) {
						uci.remove('routepolicy', sid);
						renderSources();
					}
				} }, _('移除'));
				remove.disabled = sourceSaving || self.canWrite === false;
				rows.push(E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td' }, api.safeText(section.name)),
					E('div', { 'class': 'td' }, api.safeText(section.url)),
					E('div', { 'class': 'td' }, api.safeText(section.format)),
					E('div', { 'class': 'td' }, api.safeText(SOURCE_TARGETS[section.target] || section.target)),
					E('div', { 'class': 'td' }, section.enabled === '1' ? _('是') : _('否')),
					E('div', { 'class': 'td' }, remove)
				]));
			}
			if (!sections.length)
				rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td', colspan: '6' }, _('暂无清单来源；也可稍后在“清单来源”页配置。'))));
			sourceRows.replaceChildren(E('div', { 'class': 'table cbi-section-table', 'id': 'routepolicy-wizard-sources' }, rows));
		};
		renderSources();
		var addName = inputText('', _('名称'));
		var addUrl = inputText('', 'https://…');
		var addFormat = selectControl(SOURCE_FORMATS.map(function(v) { return { value: v, label: v }; }), 'plain-domain');
		var addTarget = selectControl(Object.keys(SOURCE_TARGETS).map(function(v) { return { value: v, label: SOURCE_TARGETS[v] }; }), 'domain-policy');
		var sourceFeedback = E('div');
		var saveSources = this.button(_('保存并提交来源'), 'save-sources', 'cbi-button-save', async function() {
			if (self.busy['make-preview'])
				return;
			sourceSaving = true;
			addSource.disabled = true;
			setNavigationBusy(true);
			renderSources();
			try {
				await uci.save();
				await api.nameAnonymousSources(uci);
				await uci.apply();
				/* Target SDK uci.unload() is synchronous and returns nothing;
			 * never treat it as a Promise. */
				uci.unload('routepolicy');
				await uci.load('routepolicy');
				sourceFeedback.replaceChildren(alertBox('notice', [ E('p', {}, _('清单来源已提交。必须在“准备候选”之前完成保存；存在未提交修改时后端会拒绝准备。')) ]));
			}
			catch (error) {
				sourceFeedback.replaceChildren(alertBox('error', [ E('p', {}, _('来源提交失败：') + api.safeText(error && error.message || String(error))) ]));
			}
			finally {
				sourceSaving = false;
				addSource.disabled = self.canWrite === false;
				setNavigationBusy(saving);
				renderSources();
			}
		});
		var addSource = this.button(_('添加来源（暂存）'), 'add-source', 'cbi-button-add', function() {
			if (sourceSaving)
				return;
			var sid = uci.add('routepolicy', 'source', api.newSourceName(uci));
			uci.set('routepolicy', sid, 'name', addName.value);
			uci.set('routepolicy', sid, 'url', addUrl.value);
			uci.set('routepolicy', sid, 'format', addFormat.value);
			uci.set('routepolicy', sid, 'target', addTarget.value);
			uci.set('routepolicy', sid, 'enabled', '1');
			renderSources();
		});

		return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-rules-sources' }, [
			E('h3', {}, _('人工规则与清单来源（复用现有能力）')),
			E('p', { 'class': 'cbi-section-descr' }, _('在本流程内即可配置真实人工规则与清单来源；SmartDNS 解析组由初始化自动创建，无需另页手工创建。所有保存必须在“准备候选”之前完成：prepared 之后会阻塞写入，基线也会拒绝未提交的暂存。')),
			E('label', {}, [ _('规则类型 '), listSelect ]),
			text,
			E('div', { 'style': 'margin-top:.5rem' }, [ saveRules ]),
			ruleFeedback,
			sourceRows,
			E('div', { 'style': 'display:flex;gap:.5rem;flex-wrap:wrap;margin-top:.5rem' }, [ addName, addUrl, addFormat, addTarget, addSource, saveSources ]),
			sourceFeedback
		]);
	},

	makeInitPreview: function() {
		let self = this;
		if (this.busy['save-rules'] || this.busy['save-sources'])
			return Promise.resolve();
		var screen = this.screen;
		var built = this.readForm();
		if (!built.ok) {
			this.fail(built.errors.join('\n'));
			return Promise.resolve();
		}
		return api.initPreview(built.content).then(function(payload) {
			if (self.screen !== screen || self.pendingConfirmation)
				return;
			if (!payload || payload.ok !== true)
				throw new Error(payload && (payload.error || payload.message) || _('后端拒绝生成预览'));
			self.renderPreviewScreen(payload, built.content);
		});
	},

	renderPreviewScreen: function(payload, content) {
		let self = this;
		this.setScreen('init-preview');
		var screen = this.screen;
		var acknowledge = E('input', { type: 'checkbox', 'id': 'routepolicy-preview-ack' });
		var backButton = this.button(_('返回修改'), 'back-form', 'cbi-button-neutral', function() {
			if (self.screen === screen && !self.busy['do-prepare'])
				self.initFormScreen();
		}, false);
		var prepareButton = this.button(_('准备候选（写入待应用事务）'), 'do-prepare', 'cbi-button-apply important', async function() {
			if (self.screen !== screen)
				return;
			if (!acknowledge.checked) {
				self.fail(_('请先勾选“我已阅读差异与风险”再准备候选。'));
				return Promise.resolve();
			}
			if (!await self.confirmAction(_('准备会把候选与逐字段基线写入后端事务（尚不修改网络）。确认继续？')))
				return Promise.resolve();
			return self.prepareCandidate('init', [ backButton, acknowledge ], function() {
				return api.initPrepare(content);
			}, _('后端拒绝准备候选'));
		});
		this.body.replaceChildren(
			E('h3', {}, _('只读预览（尚未写入配置）')),
			E('p', { 'class': 'cbi-section-descr' }, _('生成预览会对选定接口做受限 ARP 冲突探测，但不修改任何配置；差异与风险确认后才写入候选。')),
			this.previewSummary(payload),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('候选与基线的真实差异')), diffTable(payload.candidate, payload.baseline) ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('候选关键项（来自真实候选内容）')), checklistNode(lifecycle.candidateChecks(payload.candidate)) ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('必须了解的影响与风险')) ].concat(PREVIEW_WARNINGS.map(function(text) {
				return E('p', { 'class': 'cbi-section-descr' }, '· ' + text);
			}))),
			E('div', { 'class': 'cbi-section' }, [
				E('label', {}, [ acknowledge, ' ', _('我已阅读以上差异与风险，并确认预览到确认期间保持单人维护。') ]),
				E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5rem;margin-top:.75rem' }, [
					prepareButton,
					backButton
				])
			])
		);
	},

	previewSummary: function(payload) {
		var rows = [
			rowItem(_('确认超时窗口（秒）'), payload.confirmation_timeout, _('后端固定 180 秒并保留 20 秒余量，界面不改动。')),
			rowItem(_('候选管理地址'), payload.management_address, _('应用后请在该地址重新登录并确认。'))
		];
		if (payload.egress_failure_policy !== undefined)
			rows.push(rowItem(_('出口失败策略'), lifecycle.egressPolicyLabel(payload.egress_failure_policy), _('以后端返回的实际值为准。')));
		if (payload.link_preparation)
			rows.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('新出口链路准备')),
				E('div', { 'class': 'cbi-value-field' }, preBlock(payload.link_preparation))
			]));
		return E('div', { 'class': 'cbi-section', 'id': 'routepolicy-preview-summary' }, rows);
	},

	prepareBaseline: function(kind) {
		return api.initStatus().then(function(status) {
			if (!status || status.ok !== true || !status.phase)
				throw new Error(status && (status.error || status.message) || _('设备未返回可用状态。'));
			if (kind === 'exit') {
				if (status.exit_candidate_available !== true)
					return null;
				return api.exitCandidate().then(function(candidate) {
					if (!candidate || candidate.ok !== true || !TRANSACTION_TOKEN_RE.test(candidate.token))
						throw new Error(candidate && (candidate.error || candidate.message) || _('无法识别当前退出候选。'));
					return candidate.token;
				});
			}
			if (TRANSACTION_TOKEN_RE.test(status.token))
				return status.token;
			if (status.phase === 'absent')
				return null;
			throw new Error(_('无法识别当前网络事务。'));
		}).catch(function(error) {
			throw new Error(_('无法读取准备前的设备状态，尚未发送准备请求。') + ' ' + api.safeText(error && error.message));
		});
	},

	prepareCandidate: function(kind, controls, submit, rejection) {
		let self = this;
		var screen = this.screen;
		var disabled = controls.map(function(control) { return control.disabled; });
		controls.forEach(function(control) { control.disabled = true; });
		var progress = alertBox('notice', [ E('p', {}, _('正在准备候选，请等待设备回复。')) ]);
		this.feedback.replaceChildren(progress);
		return this.prepareBaseline(kind).then(function(previousToken) {
			if (self.screen !== screen)
				return;
			var uncertain = function(error) {
				if (self.screen !== screen)
					return;
				var notice = alertBox('notice', [
					E('strong', {}, _('未收到明确的准备结果')),
					error && error.message ? E('p', {}, api.safeText(error.message)) : ''
				]);
				self.prepareCheck = { kind: kind, previousToken: previousToken, notice: notice };
				if (self.feedback.contains(progress))
					self.feedback.replaceChildren(notice);
				return self.showOverview(true);
			};
			return Promise.resolve().then(submit).then(function(payload) {
				if (self.screen !== screen)
					return;
				if (payload && payload.ok === false)
					throw new Error(payload.error || payload.message || rejection);
				if (!payload || payload.ok !== true || !TRANSACTION_TOKEN_RE.test(payload.token))
					return uncertain();
				if (self.feedback.contains(progress))
					self.feedback.replaceChildren();
				self.renderPrepared(payload, kind);
			}, uncertain);
		}).finally(function() {
			controls.forEach(function(control, index) { control.disabled = disabled[index]; });
		});
	},

	renderPrepared: function(payload, kind) {
		let self = this;
		this.setScreen('prepared');
		var screen = this.screen;
		var token = payload && payload.token || '';
		var isExit = kind === 'exit';
		var title = E('h3', {}, isExit ? _('退出候选已准备') : _('候选已准备（等待应用确认）'));
		var introduction = E('p', {}, isExit
			? _('执行退出前，请核对下方的配置差异和服务恢复状态。')
			: _('候选与逐字段基线已保存。提交应用会开始处理网络变更。若刚提交过，请先返回状态总览核对。'));
		var acknowledge = E('input', { type: 'checkbox', 'id': 'routepolicy-apply-ack' });
		var applyButton = this.button(isExit ? _('执行退出（危险确认）') : _('开始应用（危险确认）'), 'do-apply', 'cbi-button-negative important', async function() {
			if (self.screen !== screen)
				return;
			if (self.applyIntent) {
				self.fail(_('上一次请求的状态尚未核实。请返回状态总览查看。'));
				return;
			}
			if (!acknowledge.checked) {
				self.fail(_('请先勾选确认框，再执行危险操作。'));
				return Promise.resolve();
			}
			var question = isExit
				? _('即将退出接管：恢复最初接入地址与 DHCP/DNS 服务状态，分流停止，管理地址可能变化且需要重新连接。确认执行？')
				: _('即将应用候选：接口、DHCP、DNS（SmartDNS 独占 53、dnsmasq 停止并禁自启）与 fw4 将被修改；请确认已保留带外回退路径。应用后需在新管理地址重新登录确认。确认执行？');
			if (!await self.confirmAction(question))
				return Promise.resolve();
			self.applyIntent = {
				kind: isExit ? 'exit' : 'init', token: token,
				address: !isExit && lifecycle.isIPv4(payload.management_address) ? payload.management_address : null
			};
			title.replaceChildren(isExit ? _('已发送退出请求') : _('已发送应用请求'));
			introduction.replaceChildren(_('正在等待设备回复。请勿重复提交。'));
			self.feedback.replaceChildren(alertBox('notice', [
				E('p', {}, _('请求已发送，实际进度以状态总览为准。'))
			]));
			var showingStatus = function() { return self.screen === screen || self.current === 'overview'; };
			var reportIssue = function(title, guidance, detail) {
				if (showingStatus())
					self.feedback.replaceChildren(alertBox('error', [
						E('strong', {}, title),
						E('p', {}, guidance),
						detail ? E('p', {}, api.safeText(detail)) : ''
					]));
			};
			var unknown = function(error) {
				reportIssue(_('请求结果未知'), _('未收到明确回复，设备可能已开始处理。请查看状态总览。'), error && error.message);
			};
			return Promise.resolve().then(function() {
				return isExit ? api.exitApply(token) : api.initApply(token);
			}).then(function(reply) {
				if (!showingStatus())
					return;
				if (reply && reply.ok === true)
					self.ok(_('设备已接收请求，请在状态总览查看进度。'));
				else if (reply && reply.ok === false)
					reportIssue(_('设备返回请求错误'), _('实际进度以状态总览为准。'), reply.error || reply.message);
				else
					unknown();
			}, unknown).then(function() {
				if (showingStatus())
					return self.showOverview(true);
				// A different form owns the screen. Returning to the overview will read again.
				return self.readStatuses().catch(function() {});
			});
		});
		var changes = E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('候选与基线的真实差异')), diffTable(payload.candidate, payload.baseline) ]);
		var details = isExit ? [ changes, servicesTable(payload.services) ] : [
			this.previewSummary(payload),
			changes,
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('候选关键项')), checklistNode(lifecycle.candidateChecks(payload.candidate)) ])
		];
		this.body.replaceChildren(
			title,
			alertBox('notice', [ introduction ]),
			...details,
			E('div', { 'class': 'cbi-section' }, [
				E('label', {}, [ acknowledge, ' ', isExit ? _('我确认退出影响并接受管理地址可能变化。') : _('我已备好带外回退路径，确认立即应用以上候选。') ]),
				E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5rem;margin-top:.75rem' }, [
					applyButton,
					this.button(_('返回状态总览'), 'back-overview-prepared', 'cbi-button-neutral', function() {
						self.showOverview();
					}, false)
				])
			])
		);
	},

	/* ---------- import / restore ---------- */

	openRestore: function() {
		let self = this;
		this.setScreen('restore-form');
		var screen = this.screen;
		this.discover = null;
		this.form = null;
		var importText = E('textarea', {
			'class': 'cbi-input-textarea', rows: 10, spellcheck: 'false', wrap: 'off',
			'id': 'routepolicy-restore-import'
		}, '');
		var mappingBox = E('div', { 'id': 'routepolicy-restore-mapping' });
		var readingMapping = false;
		var backButton = this.button(_('返回状态总览'), 'back-overview-restore', 'cbi-button-neutral', function() {
			if (self.screen === screen && !self.busy['restore-prepare'])
				return self.showOverview();
		}, false);
		var readMapping = function() {
			readingMapping = true;
			importButton.disabled = true;
			return api.restoreStatus().then(function(reply) {
				if (self.screen === screen && !self.busy['restore-prepare'])
					self.renderRestoreMapping(mappingBox, reply || {}, [ backButton, importButton, importText, exportButton ]);
			}).finally(function() {
				readingMapping = false;
				if (!self.busy['config-import'])
					importButton.disabled = self.canWrite === false;
			});
		};
		var importButton = this.button(_('校验并导入声明'), 'config-import', 'cbi-button-apply', async function() {
			if (self.screen !== screen || readingMapping || self.busy['restore-prepare'])
				return;
			var content = importText.value;
			if (!lifecycle.exportSizeOk(content)) {
				self.fail(_('导入内容为空或超过 2 MiB 上限。'));
				return Promise.resolve();
			}
			if (!await self.confirmAction(_('导入文本包含来源 URL、地址与本地主机等敏感明文；页面不会把它写入日志。确认导入为受限候选？')))
				return Promise.resolve();
			return api.configImport(content).then(function(reply) {
				if (!reply || reply.ok !== true)
					throw new Error(reply && (reply.error || reply.message) || _('后端拒绝导入'));
				return readMapping();
			});
		});
		var exportButton = this.button(_('导出声明备份'), 'config-export', 'cbi-button-neutral', async function() {
			if (self.screen !== screen || self.busy['restore-prepare'])
				return;
			if (!await self.confirmAction(_('备份包含来源 URL、地址和本地主机等敏感明文，仅授予管理员导出；请妥善保存，不要提交到仓库或日志。现在导出？')))
				return Promise.resolve();
			return api.configExport().then(function(reply) {
				if (!reply || reply.ok !== true || typeof reply.content !== 'string')
					throw new Error(reply && (reply.error || reply.message) || _('导出失败'));
				var blob = new Blob([ reply.content ], { type: 'text/plain;charset=utf-8' });
				var url = URL.createObjectURL(blob);
				var link = E('a', { href: url, download: 'routepolicy-config-export.tsv' });
				link.click();
				URL.revokeObjectURL(url);
			});
		});
		this.body.replaceChildren(
			E('h3', {}, _('导入恢复（沿用 #19 校验与重映射）')),
			E('p', { 'class': 'cbi-section-descr' }, _('导入只创建受限声明候选（schema/类型/大小由后端校验）；旧设备绑定必须重新映射并预检，不直接沿用旧参数。导出/导入均为敏感明文。')),
			E('div', { 'class': 'cbi-section' }, [ exportButton ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('粘贴声明备份文本')), importText, importButton ]),
			mappingBox,
			backButton
		);
		readMapping().catch(function() {
			if (self.screen === screen)
				mappingBox.replaceChildren(alertBox('error', [ E('p', {}, _('无法读取导入声明的状态，请重新打开导入恢复。')) ]));
		});
	},

	renderRestoreMapping: function(container, restore, controls) {
		let self = this;
		var screen = this.screen;
		this.form = null;
		if (restore.declaration_phase === 'installed' && this.status.phase === 'rolled_back') {
			container.replaceChildren(alertBox('notice', [
				E('p', {}, _('网络已回滚，但上次导入的声明仍在设备上。请先返回状态总览，撤销已导入的声明，再准备恢复候选。'))
			]));
			return;
		}
		if (restore.candidate_pending !== true) {
			container.replaceChildren(E('p', { 'class': 'cbi-section-descr' }, _('当前没有待映射的导入声明。可先粘贴备份文本并导入。')));
			return;
		}
		var unportable = String(restore.unportable_fields || '').split(/\s+/).filter(Boolean);
		var discoverSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('目标设备自检（只读）')), E('p', { 'class': 'cbi-section-descr' }, _('读取目标设备接口以完成重新映射。'))
		]);
		var formSection = E('div', {});
		var danger = E('input', { type: 'checkbox', 'id': 'routepolicy-restore-danger-ack' });
		var unportableAck = E('input', { type: 'checkbox', 'id': 'routepolicy-restore-unportable-ack' });
		var prepare = this.button(_('准备恢复候选（危险确认）'), 'restore-prepare', 'cbi-button-negative important', function() {
			if (self.screen !== screen || !container.contains(formSection) || self.busy['config-import'] || self.busy['config-export'])
				return;
			var built = self.readForm();
			if (!built.ok) {
				self.fail(built.errors.join('\n'));
				return Promise.resolve();
			}
			var result = lifecycle.appendRestoreConfirmations(built.content, danger.checked, unportableAck.checked, unportable.length > 0);
			if (!result.ok) {
				self.fail(result.errors.join('\n'));
				return Promise.resolve();
			}
			return self.prepareCandidate('restore', controls.concat(Object.values(self.form), [ danger, unportableAck ]), function() {
				return api.restorePrepare(result.content);
			}, _('后端拒绝准备恢复候选'));
		});
		container.replaceChildren.apply(container, [
			E('div', { 'class': 'alert-message notice' }, [
				E('strong', {}, _('设备保留的导入声明')),
				E('p', {}, _('声明状态：') + api.safeText(restore.declaration_phase)),
				E('p', {}, _('如需使用这份声明准备恢复，请重新映射接口并确认风险。'))
			]),
			unportable.length ? E('div', { 'class': 'alert-message error' }, [
				E('strong', {}, _('不可移植 SmartDNS 字段（仅列名，不执行原配置）')),
				preBlock(restore.unportable_fields)
			]) : E('span', { style: 'display:none' }),
			discoverSection,
			formSection,
			E('div', { 'class': 'cbi-section' }, [
				E('label', {}, [ danger, ' ', _('我确认导入的声明将按以下映射在目标设备重新安装（危险确认）。') ]),
				E('br'),
				E('label', {}, [ unportableAck, ' ', unportable.length ? _('我已逐项核对上述不可移植字段并确认。') : _('（本次导入没有不可移植字段）') ]),
				E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5rem;margin-top:.75rem' }, [ prepare ])
			])
		]);
		if (!this.discover)
			this.runDiscover(discoverSection, formSection, container);
		else
			formSection.replaceChildren(this.topologyForm());
	},

	/* ---------- exit ---------- */

	openExit: function() {
		let self = this;
		this.setScreen('exit-form');
		var screen = this.screen;
		var box = E('div', { 'id': 'routepolicy-exit-box' }, [
			E('p', { 'class': 'cbi-section-descr' }, _('退出（恢复最初接入地址与 DHCP/DNS 服务状态）与“停用并清理”（运行状态页，停用分流但保留接管配置）以及卸载（包管理/诊断页删除程序）不同。'))
		]);
		var backButton = this.button(_('返回状态总览'), 'back-overview-exit', 'cbi-button-neutral', function() {
			if (self.screen === screen && !self.busy['exit-prepare'])
				return self.showOverview();
		}, false);
		var previewButton = this.button(_('查看退出影响预览'), 'exit-preview', 'cbi-button-action', function() {
			if (self.screen !== screen || self.busy['exit-prepare'])
				return;
			return api.exitPreview().then(function(reply) {
				if (self.screen === screen)
					self.renderExitPreview(box, reply, [ backButton, previewButton ]);
			});
		});
		this.body.replaceChildren(
			E('h3', {}, _('退出接管')),
			box,
			E('div', { 'style': 'display:flex;gap:.5rem' }, [
				previewButton,
				backButton
			])
		);
	},

	renderExitPreview: function(box, reply, controls) {
		let self = this;
		var screen = this.screen;
		if (!reply || reply.ok !== true) {
			box.replaceChildren(alertBox('error', [
				E('strong', {}, _('退出预览被后端拒绝')),
				E('p', {}, api.safeText(reply && (reply.error || reply.message) || _('可能尚无可验证的已确认接管')))
			]));
			return;
		}
		var rows = [
			rowItem(_('退出状态'), reply.state === 'ready' ? _('就绪（可继续）') : api.safeText(reply.state, _('未知'))),
			rowItem(_('分流将停止'), reply.routing_will_stop === true ? _('是') : api.safeText(reply.routing_will_stop)),
			rowItem(_('管理地址可能变化'), reply.management_may_change === true ? _('是') : api.safeText(reply.management_may_change)),
			rowItem(_('需要明确确认'), reply.confirmation_required === true ? _('是') : api.safeText(reply.confirmation_required))
		];
		if (reply.conflicts)
			rows.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('冲突/归属问题')),
				E('div', { 'class': 'cbi-value-field' }, preBlock(reply.conflicts))
			]));
		if (reply.warning)
			rows.push(E('p', { 'class': 'cbi-section-descr' }, reply.warning));
		var nodes = [ E('div', { 'class': 'cbi-section' }, rows) ];
		if (reply.state === 'ready') {
			nodes.push(this.button(_('准备退出候选'), 'exit-prepare', 'cbi-button-apply important', function() {
				if (self.screen !== screen || self.busy['exit-preview'])
					return;
				return self.prepareCandidate('exit', controls, function() {
					return api.exitPrepare();
				}, _('后端拒绝准备退出'));
			}));
		}
		else {
			nodes.push(E('p', { 'class': 'alert-message error' }, _('当前状态不允许退出（例如存在外部修改或归属证据缺失）；请先按状态自检处理冲突。')));
		}
		box.replaceChildren.apply(box, [
			E('div', { 'class': 'alert-message notice' }, E('p', {}, _('退出预览展示实际归属差异；确认后才会执行。')))
		].concat(nodes));
	}
});
