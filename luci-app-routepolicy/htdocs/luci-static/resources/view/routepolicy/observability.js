'use strict';
'require view';
'require routepolicy/api as api';

const DATASETS = {
	domain_policy: { title: _('策略域名'), kind: 'domain' },
	domain_default: { title: _('默认域名'), kind: 'domain' },
	static_policy4: { title: _('静态策略 IP'), kind: 'static' },
	static_default4: { title: _('静态默认 IP'), kind: 'static' },
	dynamic_policy4: { title: _('动态策略 IP'), kind: 'dynamic' },
	dynamic_default4: { title: _('动态默认 IP'), kind: 'dynamic' }
};

const SOURCE_DATASETS = {
	source_ingress4: true,
	source_egress4: true
};

const HISTORY_LIMIT = 150;

function text(value, fallback) {
	return api.safeText(value, fallback);
}

function toBigInt(value) {
	if (value === null || value === undefined || value === '')
		return null;
	try {
		return BigInt(String(value));
	}
	catch (e) {
		return null;
	}
}

function formatInteger(value) {
	let number = toBigInt(value);
	if (number === null)
		return text(value);
	return number.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function formatBytes(value) {
	let number = toBigInt(value);
	if (number === null)
		return text(value);
	let units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB' ];
	let unit = 0;
	while (number >= 1024n && unit < units.length - 1) {
		number /= 1024n;
		unit++;
	}
	return number.toString() + ' ' + units[unit];
}

function formatRate(value) {
	return value === null || value === undefined ? '—' : formatBytes(value) + '/s';
}

function formatTTL(value, permanent) {
	if (permanent || value === null || value === undefined || value === '')
		return permanent ? _('永久') : '—';
	let seconds = Number(value);
	if (!isFinite(seconds) || seconds < 0)
		return '—';
	seconds = Math.floor(seconds);
	if (seconds < 60) return seconds + _(' 秒');
	if (seconds < 3600) return Math.floor(seconds / 60) + _(' 分钟');
	return Math.floor(seconds / 3600) + _(' 小时');
}

function counter(entry, name) {
	return entry && entry.counters && entry.counters[name] !== undefined ? entry.counters[name] : entry && entry[name];
}

function normalInterfaces(reply) {
	let entries = reply && (reply.interfaces || reply.devices || reply.items) || [];
	if (!Array.isArray(entries))
		entries = Object.keys(entries).map(function(key) { return entries[key]; });
	return entries.filter(function(entry) { return entry && entry.device; });
}

function setMap(reply) {
	let sets = reply && (reply.sets || reply.items) || {};
	if (Array.isArray(sets)) {
		let mapped = {};
		sets.forEach(function(entry) { if (entry && entry.dataset) mapped[entry.dataset] = entry; });
		return mapped;
	}
	return sets;
}

function ratePoint(previous, entry, now) {
	let rx = toBigInt(counter(entry, 'rx_bytes'));
	let tx = toBigInt(counter(entry, 'tx_bytes'));
	let result = { at: now, rx: null, tx: null };
	if (!previous || previous.rx === null || previous.tx === null || rx === null || tx === null || now <= previous.at || rx < previous.rx || tx < previous.tx)
		return { point: result, baseline: { at: now, rx: rx, tx: tx } };

	let elapsed = BigInt(Math.max(1, Math.round(now - previous.at)));
	result.rx = (rx - previous.rx) * 1000n / elapsed;
	result.tx = (tx - previous.tx) * 1000n / elapsed;
	return { point: result, baseline: { at: now, rx: rx, tx: tx } };
}

function pushPoint(history, point) {
	history.push(point);
	if (history.length > HISTORY_LIMIT)
		history.splice(0, history.length - HISTORY_LIMIT);
}

function sourceMode(reply, sets) {
	if (reply && (reply.source_accounting === false || reply.accounting_enabled === false))
		return 'disabled';
	let ingress = sets.source_ingress4 || {};
	let egress = sets.source_egress4 || {};
	if (ingress.enabled === false || egress.enabled === false)
		return 'disabled';
	if (ingress.available === false || egress.available === false)
		return 'unavailable';
	return 'enabled';
}

function setCount(set) {
	return set && (set.count === undefined ? set.elements : set.count);
}

function responseError(reply) {
	if (!reply || reply.ok !== false)
		return null;
	return text(reply.error || reply.message, _('观测请求失败。'));
}

function svgLine(points, key, maximum, color) {
	let width = 640, height = 180, segment = [], lines = [];
	let flush = function() {
		if (segment.length > 1)
			lines.push(E('polyline', { fill: 'none', stroke: color, 'stroke-width': '2', points: segment.join(' ') }));
		segment = [];
	};
	points.forEach(function(point, index) {
		let value = point[key];
		if (value === null || value === undefined) { flush(); return; }
		let x = points.length < 2 ? 0 : Math.round(index * width / (points.length - 1));
		let y = maximum > 0n ? height - Number(value * BigInt(height) / maximum) : height;
		segment.push(x + ',' + Math.max(0, Math.min(height, y)));
	});
	flush();
	return lines;
}

function chartNode(points) {
	let maximum = 0n;
	points.forEach(function(point) {
		[ point.rx, point.tx ].forEach(function(value) { if (value !== null && value > maximum) maximum = value; });
	});
	let lines = svgLine(points, 'rx', maximum, '#1a73a8').concat(svgLine(points, 'tx', maximum, '#d9822b'));
	return E('div', { 'class': 'routepolicy-observability-chart' }, [
		E('div', { 'class': 'cbi-value-description' }, maximum > 0n ? _('最近 5 分钟（蓝色 RX，橙色 TX；计数器重置与采样间断处断线）') : _('正在建立速率基线；计数器重置与采样间断处断线。')),
		E('svg', { viewBox: '0 0 640 180', width: '100%', height: '180', role: 'img', 'aria-label': _('接口实时流量折线图') }, [
			E('line', { x1: '0', y1: '180', x2: '640', y2: '180', stroke: '#999', 'stroke-width': '1' })
		].concat(lines))
	]);
}

function itemCells(dataset, item) {
	if (dataset.kind === 'domain')
		return [ text(item.domain || item.value), text(item.target) ];
	if (dataset.kind === 'dynamic')
		return [ text(item.address || item.value), formatTTL(item.expires, false) ];
	return [ text(item.address || item.value), formatTTL(null, true) ];
}

return view.extend({
	load: function() { return Promise.resolve(); },

	render: function() {
		let state = {
			interfaces: [], unavailableRoles: [], baselines: {}, history: {}, selectedDevice: '', sourceDataset: 'source_ingress4',
			sourceDevice: '', sourceMode: 'unknown', sourceQueryError: '', sourceItems: [], ruleDataset: 'domain_policy', ruleItems: [], ruleCursor: null,
			rulePrevious: [], ruleMeta: {}, setSummary: {}, stale: {}, pending: {}, failures: {}, timers: {}, visible: document.visibilityState !== 'hidden'
		};
		let self = this;
		let interfaceRows = E('div', { 'class': 'table cbi-section-table' });
		let interfaceStatus = E('p', { 'class': 'cbi-section-descr' });
		let chartSelect = E('select', { 'class': 'cbi-input-select' });
		let chart = E('div');
		let sourceSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: 'source_ingress4' }, _('入站 IPv4 源地址')),
			E('option', { value: 'source_egress4' }, _('出站 IPv4 源地址'))
		]);
		let sourceDevice = E('select', { 'class': 'cbi-input-select' });
		let sourceSort = E('select', { 'class': 'cbi-input-select' }, [ E('option', { value: 'bytes' }, _('按字节')), E('option', { value: 'packets' }, _('按数据包')) ]);
		let sourceQuery = E('input', { type: 'search', maxlength: '128', pattern: '[0-9./]*', 'class': 'cbi-input-text', placeholder: _('搜索 IPv4/CIDR 前缀') });
		let sourceStatus = E('p', { 'class': 'cbi-section-descr' });
		let sourceRows = E('div', { 'class': 'table cbi-section-table' });
		let datasetTabs = E('div', { 'class': 'cbi-tabmenu' });
		let ruleQuery = E('input', { type: 'search', maxlength: '128', 'class': 'cbi-input-text', placeholder: _('搜索当前生效规则') });
		let ruleRows = E('div', { 'class': 'table cbi-section-table' });
		let ruleStatus = E('p', { 'class': 'cbi-section-descr' });
		let previousButton = E('button', { 'class': 'cbi-button cbi-button-neutral', disabled: 'disabled' }, _('上一页'));
		let nextButton = E('button', { 'class': 'cbi-button cbi-button-neutral', disabled: 'disabled' }, _('下一页'));

		let clearTimer = function(name) {
			if (state.timers[name]) { window.clearTimeout(state.timers[name]); delete state.timers[name]; }
		};
		let schedule = function(name, delay, callback) {
			clearTimer(name);
			if (state.visible)
				state.timers[name] = window.setTimeout(callback, delay);
		};
		let retryDelay = function(name, interval) {
			return interval * Math.min(16, Math.pow(2, state.failures[name] || 0));
		};
		let clearBaselines = function() { state.baselines = {}; };
		let setStale = function(name, error) {
			if (name === 'interfaces') clearBaselines();
			state.stale[name] = error || true;
			refreshStatus();
		};
		let request = function(name, interval, method, success) {
			if (!state.visible || state.pending[name]) return;
			state.pending[name] = true;
			Promise.resolve().then(method).then(function(reply) {
				let error = responseError(reply);
				if (error) throw new Error(error);
				return reply || {};
			}).then(function(reply) {
				state.failures[name] = 0;
				delete state.stale[name];
				success(reply);
			}, function(error) {
				state.failures[name] = (state.failures[name] || 0) + 1;
				setStale(name, error && error.message || String(error));
			}).then(function() {
				state.pending[name] = false;
				if (interval > 0)
					schedule(name, retryDelay(name, interval), function() { request(name, interval, method, success); });
			});
		};
		let requestOnce = function(name, method, success) {
			if (!state.visible || state.pending[name]) return;
			state.pending[name] = true;
			Promise.resolve().then(method).then(function(reply) {
				let error = responseError(reply);
				if (error) throw new Error(error);
				return reply || {};
			}).then(function(reply) {
				state.failures[name] = 0;
				delete state.stale[name];
				success(reply);
			}, function(error) {
				state.failures[name] = (state.failures[name] || 0) + 1;
				setStale(name, error && error.message || String(error));
			}).then(function() { state.pending[name] = false; });
		};
		let resetBaselines = function() {
			clearBaselines();
			state.history = {};
		};
		let updateDeviceOptions = function() {
			let devices = state.interfaces.map(function(entry) { return entry.device; });
			if (devices.indexOf(state.selectedDevice) < 0) state.selectedDevice = devices[0] || '';
			if (devices.indexOf(state.sourceDevice) < 0) state.sourceDevice = '';
			chartSelect.replaceChildren.apply(chartSelect, devices.map(function(device) { return E('option', { value: device, selected: device === state.selectedDevice ? 'selected' : null }, device); }));
			sourceDevice.replaceChildren.apply(sourceDevice, [ E('option', { value: '', selected: state.sourceDevice === '' ? 'selected' : null }, _('全部受管设备')) ].concat(devices.map(function(device) { return E('option', { value: device, selected: device === state.sourceDevice ? 'selected' : null }, device); })));
		};
		let refreshInterfaces = function() {
			let rows = [ E('div', { 'class': 'tr table-titles' }, [
				E('div', { 'class': 'th' }, _('角色')), E('div', { 'class': 'th' }, _('实际设备')), E('div', { 'class': 'th' }, _('状态')),
				E('div', { 'class': 'th' }, _('RX / TX 速率')), E('div', { 'class': 'th' }, _('累计字节')), E('div', { 'class': 'th' }, _('累计包 / 错误 / 丢包'))
			]) ];
			state.interfaces.forEach(function(entry) {
				let point = (state.history[entry.device] || []).slice(-1)[0] || {};
				let roles = Array.isArray(entry.roles) ? entry.roles.map(function(role) { return role && (role.role || role.interface) || role; }).join('、') : text(entry.roles || entry.role, '—');
				rows.push(E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td' }, roles), E('div', { 'class': 'td' }, text(entry.device)), E('div', { 'class': 'td' }, entry.online === false ? _('离线') : _('在线')),
					E('div', { 'class': 'td' }, formatRate(point.rx) + ' / ' + formatRate(point.tx)),
					E('div', { 'class': 'td' }, formatBytes(counter(entry, 'rx_bytes')) + ' / ' + formatBytes(counter(entry, 'tx_bytes'))),
					E('div', { 'class': 'td' }, formatInteger(counter(entry, 'rx_packets')) + ' / ' + formatInteger(counter(entry, 'tx_packets')) + ' / ' + formatInteger(counter(entry, 'rx_errors')) + '+' + formatInteger(counter(entry, 'tx_errors')) + ' / ' + formatInteger(counter(entry, 'rx_dropped')) + '+' + formatInteger(counter(entry, 'tx_dropped')))
				]));
			});
			if (rows.length === 1) rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, _('暂无受管接口快照。'))));
			interfaceRows.replaceChildren.apply(interfaceRows, rows);
			let interfaceMessage = state.stale.interfaces ? _('接口数据已过期，正在退避重试。') : _('累计量来自受管实际设备；同一设备合并角色后只采集一次。');
			if (state.unavailableRoles.length)
				interfaceMessage += ' ' + _('缺失逻辑角色：') + state.unavailableRoles.join('、') + '。';
			interfaceStatus.textContent = interfaceMessage;
			chart.replaceChildren(chartNode(state.history[state.selectedDevice] || []));
		};
		let refreshSource = function() {
			let rows = [ E('div', { 'class': 'tr table-titles' }, [ E('div', { 'class': 'th' }, _('IPv4 地址')), E('div', { 'class': 'th' }, _('设备')), E('div', { 'class': 'th' }, _('数据包')), E('div', { 'class': 'th' }, _('字节')), E('div', { 'class': 'th' }, _('剩余活动时间')) ]) ];
			if (state.sourceMode === 'disabled') {
				sourceStatus.textContent = _('按源 IP 统计已关闭。请在“基础设置 → 高级设置”启用；该功能只统计 RoutePolicy 受管 IPv4 路径，offload 可能造成差异。');
			} else if (state.sourceMode === 'unavailable') {
				sourceStatus.textContent = _('归因数据不可用：按源 IP 统计已启用，但当前 source set 不可读取。等待服务应用或集合恢复后会自动重试。');
			} else {
				let summary = state.setSummary[state.sourceDataset] || {};
				sourceStatus.textContent = state.sourceQueryError || (state.stale.source ? _('归因数据已过期，正在退避重试。') : summary.saturated ? _('归因集合已饱和，转发不受影响，但可能遗漏新的归因 IP。') : _('入站/出站归因与接口总量口径不同，不能相减得出“未知流量”。'));
			state.sourceItems.forEach(function(item) { rows.push(E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td' }, text(item.address)), E('div', { 'class': 'td' }, text(item.device)), E('div', { 'class': 'td' }, formatInteger(item.packets)), E('div', { 'class': 'td' }, formatBytes(item.bytes)), E('div', { 'class': 'td' }, formatTTL(item.expires, false)) ])); });
			if (rows.length === 1) rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, _('当前筛选条件下没有归因 IP。'))));
			}
			sourceRows.replaceChildren.apply(sourceRows, rows);
		};
		let refreshRules = function() {
			let dataset = DATASETS[state.ruleDataset];
			let sets = state.setSummary;
			datasetTabs.replaceChildren.apply(datasetTabs, Object.keys(DATASETS).map(function(key) {
				let summary = sets[key] || {};
				return E('button', { 'class': 'cbi-tab' + (key === state.ruleDataset ? ' cbi-tab-active' : ''), 'click': function() { selectDataset(key); } }, DATASETS[key].title + ' (' + text(setCount(summary), '—') + ')');
			}));
			let headers = dataset.kind === 'domain' ? [ _('域名'), _('目标') ] : [ _('地址'), _('剩余时间') ];
			let rows = [ E('div', { 'class': 'tr table-titles' }, headers.map(function(header) { return E('div', { 'class': 'th' }, header); })) ];
			state.ruleItems.forEach(function(item) { rows.push(E('div', { 'class': 'tr' }, itemCells(dataset, item).map(function(cell) { return E('div', { 'class': 'td' }, cell); }))); });
			if (rows.length === 1) rows.push(E('div', { 'class': 'tr' }, E('div', { 'class': 'td' }, _('当前筛选条件下没有生效规则。'))));
			ruleRows.replaceChildren.apply(ruleRows, rows);
			let meta = state.ruleMeta;
			ruleStatus.textContent = state.stale.rules ? _('规则查询失败：') + text(state.stale.rules) + _('。请重新搜索以建立新的分页基线。') : _('仅展示最近一次成功应用后的生效数据。') + (meta.volatile ? _(' 动态集合在翻页期间可能变化。') : '') + (meta.truncated ? _(' 结果已截断。') : '');
			previousButton.disabled = state.rulePrevious.length ? null : 'disabled';
			nextButton.disabled = meta.next_cursor ? null : 'disabled';
		};
		let refreshStatus = function() {
			refreshInterfaces();
			refreshSource();
			refreshRules();
		};
		let loadSource = function() {
			if (state.sourceMode !== 'enabled') return;
			let query = (sourceQuery.value || '').trim();
			if (!/^[0-9./]*$/.test(query)) {
				state.sourceQueryError = _('IP 查询只能使用 IPv4、CIDR 或点号数字前缀。');
				refreshSource();
				return;
			}
			state.sourceQueryError = '';
			request('source', 5000, function() { return api.observeQuery({ dataset: state.sourceDataset, query: query, device: state.sourceDevice || undefined, sort: sourceSort.value, limit: 50 }); }, function(reply) {
				state.sourceItems = Array.isArray(reply.items) ? reply.items : [];
				if (reply.enabled === false) state.sourceMode = 'disabled';
				refreshSource();
			});
		};
		let loadRules = function(cursor, previous) {
			let selected = state.ruleDataset;
			requestOnce('rules', function() { return api.observeQuery({ dataset: selected, query: ruleQuery.value || '', cursor: cursor || undefined, limit: 50 }); }, function(reply) {
				if (selected !== state.ruleDataset) return;
				if (previous) state.rulePrevious.push(state.ruleCursor);
				state.ruleCursor = cursor || null;
				state.ruleItems = Array.isArray(reply.items) ? reply.items : [];
				state.ruleMeta = reply;
				refreshRules();
			});
		};
		let selectDataset = function(dataset) {
			state.ruleDataset = dataset;
			state.ruleCursor = null;
			state.rulePrevious = [];
			state.ruleItems = [];
			state.ruleMeta = {};
			loadRules(null, false);
			refreshRules();
		};
		let pollInterfaces = function() {
			request('interfaces', 2000, function() { return api.observeInterfaces(); }, function(reply) {
				let now = typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now();
				state.interfaces = normalInterfaces(reply);
				state.unavailableRoles = Array.isArray(reply.unavailable_roles) ? reply.unavailable_roles.filter(function(role) { return typeof role === 'string' && role; }) : [];
				let visibleDevices = {};
				state.interfaces.forEach(function(entry) { visibleDevices[entry.device] = true; });
				Object.keys(state.baselines).forEach(function(device) { if (!visibleDevices[device]) delete state.baselines[device]; });
				state.interfaces.forEach(function(entry) {
					let sample = ratePoint(state.baselines[entry.device], entry, now);
					state.baselines[entry.device] = sample.baseline;
					if (!state.history[entry.device]) state.history[entry.device] = [];
					pushPoint(state.history[entry.device], sample.point);
				});
				updateDeviceOptions();
				refreshInterfaces();
			});
		};
		let pollSets = function() {
			request('sets', 10000, function() { return api.observeSets(); }, function(reply) {
				state.setSummary = setMap(reply);
				state.sourceMode = sourceMode(reply, state.setSummary);
				refreshRules();
				refreshSource();
				if (state.sourceMode === 'enabled') loadSource();
			});
		};
		let start = function() {
			if (!state.visible) return;
			pollInterfaces();
			pollSets();
			loadRules(null, false);
		};
		let stop = function() { Object.keys(state.timers).forEach(clearTimer); };
		let visibility = function() {
			state.visible = document.visibilityState !== 'hidden';
			if (!state.visible) { clearBaselines(); stop(); return; }
			resetBaselines();
			start();
		};

		chartSelect.addEventListener('change', function() { state.selectedDevice = chartSelect.value; refreshInterfaces(); });
		sourceSelect.addEventListener('change', function() { state.sourceDataset = sourceSelect.value; loadSource(); });
		sourceDevice.addEventListener('change', function() { state.sourceDevice = sourceDevice.value; loadSource(); });
		sourceSort.addEventListener('change', loadSource);
		sourceQuery.addEventListener('keydown', function(event) { if (event.key === 'Enter') loadSource(); });
		ruleQuery.addEventListener('keydown', function(event) { if (event.key === 'Enter') { state.rulePrevious = []; loadRules(null, false); } });
		previousButton.addEventListener('click', function() { if (state.rulePrevious.length) loadRules(state.rulePrevious.pop(), false); });
		nextButton.addEventListener('click', function() { if (state.ruleMeta.next_cursor) loadRules(state.ruleMeta.next_cursor, true); });
		if (document.addEventListener) document.addEventListener('visibilitychange', visibility);
		if (window.addEventListener) window.addEventListener('pagehide', stop, { once: true });
		start();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('流量与集合')),
			E('div', { 'class': 'cbi-map-descr' }, _('仅在页面可见时轮询：接口快照 2 秒、归因 Top 列表 5 秒、集合摘要 10 秒。连续失败会退避并标记数据已过期。')),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('接口实时流量')), interfaceStatus, interfaceRows ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('流量折线图')), E('label', { 'class': 'cbi-value-title' }, _('设备')), chartSelect, chart ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('IP 归因')), sourceSelect, ' ', sourceDevice, ' ', sourceSort, ' ', sourceQuery, E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': loadSource }, _('搜索')), sourceStatus, sourceRows ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('生效规则与集合')), datasetTabs, ruleQuery, E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { state.rulePrevious = []; loadRules(null, false); } }, _('搜索')), ruleStatus, ruleRows, E('div', { 'class': 'cbi-page-actions' }, [ previousButton, ' ', nextButton ]) ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
