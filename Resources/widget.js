// The widget as the design draws it. Widget Settings uses it for the preview;
// Widget/WidgetView.swift is the SwiftUI port that runs on the desktop.
const METRICS = [
  { k: 'cpu', label: 'CPU', color: '#0A84FF' },
  { k: 'mem', label: 'Memory', color: '#5E5CE6' },
  { k: 'net', label: 'Network', color: '#FF9F0A' },
  { k: 'disk', label: 'Disk', color: '#34C759' },
  { k: 'temp', label: 'Temperature', color: '#FF453A' },
];

const LOOKS = {
  glass: { bg: 'rgba(255,255,255,0.64)', border: 'rgba(255,255,255,0.8)', text: '#1D1D1F', sub: '#4A4A4F', tile: 'rgba(255,255,255,0.6)', track: 'rgba(120,120,128,0.2)', ok: '#1E7A34', shadow: 'none', btnBg: 'rgba(255,255,255,0.75)' },
  tinted: { bg: 'rgba(16,52,104,0.62)', border: 'rgba(255,255,255,0.28)', text: '#FFFFFF', sub: 'rgba(255,255,255,0.8)', tile: 'rgba(255,255,255,0.12)', track: 'rgba(255,255,255,0.22)', ok: '#8CF5AE', shadow: 'none', btnBg: 'rgba(255,255,255,0.16)' },
  clear: { bg: 'rgba(255,255,255,0.14)', border: 'rgba(255,255,255,0.55)', text: '#FFFFFF', sub: 'rgba(255,255,255,0.9)', tile: 'rgba(255,255,255,0.14)', track: 'rgba(255,255,255,0.3)', ok: '#A6FFC2', shadow: '0 1px 3px rgba(0,0,0,0.4)', btnBg: 'rgba(255,255,255,0.18)' },
};

const DIMS = { S: [172, 172, 26], M: [364, 172, 26], L: [364, 384, 28], XL: [748, 384, 30] };

function widgetPreview(w, servers) {
  const L = LOOKS[w.look] || LOOKS.glass, d = DIMS[w.size];
  const one = servers.find((s) => s.id === w.server);
  const list = one ? [one] : servers.filter((s) => s.widgets !== false).slice(0, MAX_SERVERS);
  const box = `box-sizing: border-box; width: ${d[0]}px; height: ${d[1]}px; padding: ${w.size === 'S' ? '14px' : '16px'}; display: flex; border-radius: ${d[2]}px; background: ${L.bg}; backdrop-filter: blur(36px) saturate(180%); -webkit-backdrop-filter: blur(36px) saturate(180%); border: 1px solid ${L.border}; box-shadow: 0 16px 40px rgba(8,28,60,0.25), inset 0 1px 0 rgba(255,255,255,0.6); transition: width 0.25s, height 0.25s`;
  if (!list.length) return `<section aria-label="Widget preview" style="${box}; align-items: center; justify-content: center; font-size: 13px; font-weight: 600; color: ${L.sub}">Add a server in Ice Servers</section>`;
  return one ? widget(w, L, list, box) : allServers(w, L, list, box);
}

// "All servers": one compact row per server (design: WidgetOptions › allMode).
function allServers(w, L, list, box) {
  const picked = METRICS.filter((m) => w.metrics[m.k]).slice(0, { S: 1, M: 2, L: 3, XL: 4 }[w.size]);
  const tall = w.size === 'L' || w.size === 'XL';
  const cols = `minmax(0, 1.4fr) repeat(${picked.length}, minmax(0, 1fr))${w.size === 'XL' ? ' 44px' : ''}`;
  const online = list.filter((s) => LIVE.includes(s.phase)).length;
  const rows = list.map((s) => {
    const live = LIVE.includes(s.phase), off = !live;
    const t = s.temp.length ? last(s.temp) : null, nm = netMax(s);
    const v = { cpu: last(s.cpu), mem: last(s.mem), net: last(s.down) / nm * 100, disk: s.disk, temp: t || 0 };
    const text = { cpu: Math.round(last(s.cpu)) + '%', mem: s.memUsed.toFixed(1) + ' GB', net: rate(last(s.down)), disk: Math.round(s.disk) + '%', temp: deg(t) };
    const hist = { cpu: s.cpu, mem: s.mem, net: s.down.map((x) => x / nm * 100), disk: s.cpu.map(() => s.disk), temp: s.temp.length > 1 ? s.temp : s.cpu.map(() => t || 0) };
    const cells = picked.map((m) => {
      const val = off ? 0 : v[m.k], txt = off ? (m.k === 'disk' && s.diskTotal ? text.disk : '—') : text[m.k];
      const color = (m.k === 'disk' && val > 80) || (m.k === 'temp' && val >= 70) ? '#FF9F0A' : m.color;
      return `<div style="display: flex; flex-direction: column; gap: 3px; min-width: 0">
<span style="font-size: ${tall ? '12px' : '11px'}; font-weight: 700; white-space: nowrap; color: ${off ? L.sub : L.text}; text-shadow: ${L.shadow}">${tall && !off ? m.label.slice(0, 4) + ' ' + txt : txt}</span>
${!off && w.size !== 'S' && w.style !== 'graph' ? `<span style="display: block; height: 5px; border-radius: 3px; background: ${L.track}"><span style="display: block; height: 100%; border-radius: 3px; width: ${Math.min(val, 100)}%; background: ${color}"></span></span>` : ''}
${!off && w.size !== 'S' && w.style === 'graph' ? `<svg viewBox="0 0 240 56" preserveAspectRatio="none" style="width: 100%; height: 14px; display: block" aria-hidden="true"><polyline points="${pts(hist[m.k], 100)}" fill="none" stroke="${m.color}" stroke-width="2" vector-effect="non-scaling-stroke"></polyline></svg>` : ''}
</div>`;
    }).join('');
    return `<div style="display: grid; grid-template-columns: ${cols}; column-gap: 12px; align-items: center; box-sizing: border-box; min-height: ${{ XL: '58px', L: '64px', M: '24px', S: '20px' }[w.size]}; padding: ${tall ? '6px 12px' : '0'}; border-radius: 14px; background: ${tall ? L.tile : 'transparent'}">
<div style="display: flex; align-items: center; gap: 8px; min-width: 0"><span style="width: 7px; height: 7px; border-radius: 4px; flex-shrink: 0; background: ${live ? '#30D158' : '#8E8E93'}"></span><span style="font-size: ${tall ? '14px' : '12px'}; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: ${L.text}; text-shadow: ${L.shadow}">${esc(s.name)}</span></div>
${cells}
${w.size === 'XL' ? `<button data-cmd="power" data-id="${s.id}" aria-label="${off ? 'Turn on ' : 'Turn off '}${esc(s.name)}" style="width: 44px; height: 44px; border-radius: 22px; border: 0; display: flex; align-items: center; justify-content: center; cursor: pointer; background: ${off ? L.track : '#248A3D'}">${ICON.power(16, off ? L.text : '#FFFFFF', 2.2)}</button>` : ''}
</div>`;
  }).join('');
  return `<section aria-label="Widget preview" style="${box}; flex-direction: column; gap: 12px">
<div style="display: flex; flex-direction: column; width: 100%; min-width: 0; gap: ${w.size === 'S' || w.size === 'M' ? '5px' : '8px'}">
<div style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px"><span style="font-size: ${w.size === 'XL' ? '17px' : '14px'}; font-weight: 700; color: ${L.text}; text-shadow: ${L.shadow}">${w.size === 'S' ? 'Servers' : 'All servers'}</span><span style="font-size: 11px; font-weight: 600; white-space: nowrap; color: ${L.sub}; text-shadow: ${L.shadow}">${online} of ${list.length} online</span></div>
${rows}
</div>
</section>`;
}

function widget(w, L, list, box) {
  const many = list.length > 1;
  const shown = METRICS.filter((m) => w.metrics[m.k]).slice(0, { S: many ? 1 : 2, M: many ? 2 : 4, L: many ? 2 : 4, XL: 4 }[w.size]);
  const row = many && (w.size === 'M' || w.size === 'XL');
  let cols;
  if (w.size === 'S') cols = w.style === 'bars' ? 1 : Math.min(2, shown.length);
  else if (w.size === 'M') cols = many ? (w.style === 'bars' ? 1 : Math.min(2, shown.length)) : Math.min(w.style === 'bars' ? 2 : 4, shown.length);
  else cols = Math.min(2, shown.length);
  const showActions = w.size === 'XL' || (w.size === 'L' && !many);
  const showPower = w.size === 'L' || w.size === 'XL';

  const columns = list.map((s, idx) => {
    const live = LIVE.includes(s.phase);
    const nm = netMax(s);
    const t = s.temp.length ? last(s.temp) : null;
    const v = { cpu: last(s.cpu), mem: last(s.mem), net: last(s.down) / nm * 100, disk: s.disk, temp: t || 0 };
    const text = { cpu: Math.round(last(s.cpu)) + '%', mem: s.memUsed.toFixed(1) + ' GB', net: rate(last(s.down)), disk: Math.round(s.disk) + '%', temp: deg(t) };
    const hist = { cpu: s.cpu, mem: s.mem, net: s.down.map((x) => x / nm * 100), disk: s.cpu.map(() => s.disk), temp: s.temp.length > 1 ? s.temp : s.cpu.map(() => t || 0) };
    const c = colorsFor(s.phase);
    const on = s.phase !== 'off' && s.phase !== 'stopping';
    const status = s.phase === 'online' ? 'Online · up ' + uptime(s.uptime, true) : LABELS[s.phase];
    const cant = s.phase !== 'online' ? 'disabled' : '';
    const updLabel = s.phase === 'updating' ? `Updating ${s.progress}%` : s.phase === 'checking' ? 'Checking…' : s.updates > 0 ? `${s.updates} Update${s.updates === 1 ? '' : 's'}` : 'Check';

    const tiles = shown.map((m) => {
      const val = live ? v[m.k] : 0, txt = live ? text[m.k] : '—';
      const labelStyle = `font-size: 11px; font-weight: 600; color: ${L.sub}; text-shadow: ${L.shadow}; white-space: nowrap`;
      const valueStyle = `font-size: ${w.style === 'rings' || w.size === 'S' ? '13px' : '16px'}; font-weight: 700; color: ${L.text}; text-shadow: ${L.shadow}; white-space: nowrap`;
      let inner;
      if (w.style === 'rings') {
        inner = `<div style="display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; height: 100%">
<svg width="46" height="46" viewBox="0 0 100 100" aria-hidden="true" style="transform: rotate(-90deg); flex-shrink: 0"><circle cx="50" cy="50" r="38" fill="none" stroke="${L.track}" stroke-width="13"></circle><circle cx="50" cy="50" r="38" fill="none" stroke="${m.color}" stroke-width="13" stroke-linecap="round" stroke-dasharray="${(val / 100 * RING).toFixed(1)} ${RING.toFixed(1)}"></circle></svg>
<span style="${valueStyle}">${txt}</span>
<span style="${labelStyle}">${m.label}</span>
</div>`;
      } else if (w.style === 'graph') {
        inner = `<div style="display: flex; flex-direction: column; gap: 4px; height: 100%">
<div style="display: flex; justify-content: space-between; align-items: baseline; gap: 6px"><span style="${labelStyle}">${m.label}</span><span style="${valueStyle}">${txt}</span></div>
<svg viewBox="0 0 240 56" preserveAspectRatio="none" style="width: 100%; flex-grow: 1; min-height: 20px; display: block" aria-hidden="true"><polyline points="${pts(live ? hist[m.k] : hist[m.k].map(() => 0), 100)}" fill="none" stroke="${m.color}" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round"></polyline></svg>
</div>`;
      } else {
        inner = `<div style="display: flex; flex-direction: column; justify-content: center; gap: 6px; height: 100%">
<div style="display: flex; justify-content: space-between; align-items: baseline; gap: 6px"><span style="${labelStyle}">${m.label}</span><span style="${valueStyle}">${txt}</span></div>
<div style="height: 6px; border-radius: 3px; background: ${L.track}"><div style="height: 100%; border-radius: 3px; background: ${(m.k === 'disk' && val > 80) || (m.k === 'temp' && val >= 70) ? '#FF9F0A' : m.color}; width: ${Math.min(val, 100)}%"></div></div>
</div>`;
      }
      return `<div style="box-sizing: border-box; min-width: 0; min-height: 0; padding: ${w.size === 'S' ? '6px 8px' : '8px 10px'}; border-radius: 14px; background: ${L.tile}">${inner}</div>`;
    }).join('');

    const divider = row && idx > 0 ? `padding-left: 16px; border-left: 1px solid ${w.look === 'glass' ? 'rgba(60,60,67,0.14)' : 'rgba(255,255,255,0.25)'};` : '';
    return `<div style="flex: 1 1 0; min-width: 0; min-height: 0; display: flex; flex-direction: column; gap: ${w.size === 'S' ? '8px' : '10px'}; ${divider}">
<div style="display: flex; align-items: center; justify-content: space-between; gap: 8px">
<div style="display: flex; flex-direction: column; gap: 2px; min-width: 0">
<span style="font-size: ${w.size === 'S' ? '14px' : '15px'}; font-weight: 700; color: ${L.text}; text-shadow: ${L.shadow}; overflow: hidden; text-overflow: ellipsis; white-space: nowrap">${esc(s.name)}</span>
<span style="display: flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 600; white-space: nowrap; color: ${s.phase === 'online' ? L.ok : w.look === 'glass' ? c[0] : L.sub}; text-shadow: ${L.shadow}"><span style="width: 6px; height: 6px; border-radius: 3px; background: ${c[2]}; flex-shrink: 0"></span>${status}</span>
</div>
${showPower ? `<button data-cmd="power" data-id="${s.id}" aria-label="Turn ${esc(s.name)} ${on ? 'off' : 'on'}" ${BUSY.includes(s.phase) ? 'disabled' : ''} style="width: 44px; height: 44px; flex-shrink: 0; border-radius: 22px; border: 0; display: flex; align-items: center; justify-content: center; background: ${on ? '#248A3D' : 'rgba(120,120,128,0.5)'}; cursor: pointer; box-shadow: ${on ? '0 4px 12px rgba(36,138,61,0.35), ' : ''}inset 0 1px 0 rgba(255,255,255,0.35)">${ICON.power(18, '#FFFFFF', 2.2)}</button>` : ''}
</div>
<div style="flex-grow: 1; min-height: 0; display: grid; grid-template-columns: repeat(${Math.max(1, cols)}, minmax(0, 1fr)); grid-auto-rows: minmax(0, 1fr); gap: 8px">${tiles}</div>
${showActions ? `<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px">
<button data-cmd="restart" data-id="${s.id}" ${cant} style="height: 44px; border: 1px solid ${L.border}; border-radius: 22px; background: ${L.btnBg}; display: flex; align-items: center; justify-content: center; gap: 7px; font-size: 13px; font-weight: 600; color: ${L.text}; cursor: pointer">${ICON.restart(15, 2.2)}Restart</button>
<button data-cmd="${s.updates > 0 ? 'install' : 'check'}" data-id="${s.id}" ${cant} style="height: 44px; border: 0; border-radius: 22px; background: #0066CC; display: flex; align-items: center; justify-content: center; gap: 7px; font-size: 13px; font-weight: 600; color: #FFFFFF; cursor: pointer; box-shadow: 0 4px 12px rgba(0,102,204,0.3), inset 0 1px 0 rgba(255,255,255,0.35)">${ICON.download(15, 2.2)}${updLabel}</button>
</div>` : ''}
</div>`;
  }).join('');

  return `<section aria-label="Widget preview" style="${box}; flex-direction: ${row ? 'row' : 'column'}; gap: ${row ? '16px' : '12px'}">${columns}</section>`;
}
