// The widget as the design draws it (Settings › Widgets: gallery thumbnails and the editor preview).
// Widget/WidgetView.swift is the SwiftUI port that runs on the desktop.
const W_DEFS = { cpu: ['CPU', 'CPU', '#0A84FF'], mem: ['Memory', 'RAM', '#5E5CE6'], net: ['Network', 'Net', '#FF9F0A'], disk: ['Disk', 'Disk', '#34C759'], temp: ['Temperature', 'Temp', '#FF453A'] };
const W_ORDER = ['cpu', 'mem', 'net', 'disk', 'temp'];
const W_DIMS = { S: [172, 172, 26, 'Small'], M: [364, 172, 26, 'Medium'], L: [364, 384, 28, 'Large'], XL: [748, 384, 30, 'Extra Large'] };
const W_LOOKS = {
  glass: { bg: 'rgba(255,255,255,0.64)', border: 'rgba(255,255,255,0.8)', text: '#1D1D1F', sub: '#4A4A4F', tile: 'rgba(255,255,255,0.6)', track: 'rgba(120,120,128,0.2)', ok: '#1E7A34', shadow: 'none', btnBg: 'rgba(255,255,255,0.8)' },
  tinted: { bg: 'rgba(16,52,104,0.66)', border: 'rgba(255,255,255,0.28)', text: '#FFFFFF', sub: 'rgba(255,255,255,0.82)', tile: 'rgba(255,255,255,0.12)', track: 'rgba(255,255,255,0.22)', ok: '#8CF5AE', shadow: 'none', btnBg: 'rgba(255,255,255,0.16)' },
  clear: { bg: 'rgba(255,255,255,0.14)', border: 'rgba(255,255,255,0.55)', text: '#FFFFFF', sub: 'rgba(255,255,255,0.92)', tile: 'rgba(255,255,255,0.14)', track: 'rgba(255,255,255,0.3)', ok: '#A6FFC2', shadow: '0 1px 3px rgba(0,0,0,0.45)', btnBg: 'rgba(255,255,255,0.18)' },
};
const C1 = 2 * Math.PI * 38, C2 = 2 * Math.PI * 36;
const POWER_SVG = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round"><path d="M12 3v8"></path><path d="M6.4 6.6a8 8 0 1 0 11.2 0"></path></svg>';

// The servers widgets may show: not the ones turned off with "Show in widgets".
const widgetServers = (servers) => servers.filter((s) => s.widgets !== false);

// The servers a design shows (Shared/Store.swift has the same rule).
const designServers = (d, servers) => d.all ? widgetServers(servers) : d.servers.map((id) => servers.find((s) => s.id === id)).filter(Boolean);

function designCaps(d, multi) {
  const ctl = !!d.controls && (d.size === 'L' || d.size === 'XL');
  if (multi) return { rows: { S: 4, M: 4, L: 5, XL: 5 }[d.size], stats: { S: 1, M: 2, L: ctl ? 2 : 3, XL: 5 }[d.size] };
  return { rows: 1, stats: { S: 2, M: 4, L: 6, XL: 6 }[d.size] };
}

// One stat of one server: [0–100 value, text, history].
function wReading(k, s) {
  if (!LIVE.includes(s.phase)) return k === 'disk' && s.diskTotal ? [s.disk, Math.round(s.disk) + '%', []] : [0, '—', []];
  const nm = netMax(s), t = s.temp.length ? last(s.temp) : null;
  switch (k) {
    case 'cpu': return [last(s.cpu), Math.round(last(s.cpu)) + '%', s.cpu];
    case 'mem': return [last(s.mem), Math.round(last(s.mem)) + '%', s.mem];
    case 'net': return [last(s.down) / nm * 100, rate(last(s.down)), s.down.map((x) => x / nm * 100)];
    case 'temp': return [t || 0, deg(t), s.temp.length > 1 ? s.temp : s.cpu.map(() => t || 0)];
    default: return [s.disk, Math.round(s.disk) + '%', s.cpu.map(() => s.disk)];
  }
}
const wWarn = (k, v) => (k === 'disk' && v > 80) || (k === 'temp' && v >= 70);

// Draws design `d` at its size, scaled down to fit maxW × maxH. Returns { html, scale, hidRows, cap, multi, ids }.
function renderWidget(d, servers, maxW, maxH) {
  const dm = W_DIMS[d.size], w = dm[0], h = dm[1];
  const sc = Math.min(1, maxW / w, maxH / h);
  const Lk = W_LOOKS[d.look] || W_LOOKS.glass;
  const ids = designServers(d, servers);
  const stats = d.stats.filter((k) => W_DEFS[k]);
  const empty = ids.length === 0 || stats.length === 0;
  const single = !empty && ids.length === 1, multi = !empty && ids.length > 1;
  // Medium gets buttons too, as icons, but only for one server.
  const big = d.size === 'L' || d.size === 'XL', ctl = !!d.controls && (big || (d.size === 'M' && single)), small = d.size === 'S';
  const cap = designCaps(d, multi);
  const titleStyle = `font-size: ${d.size === 'XL' ? '17px' : small ? '13px' : '15px'}; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: ${Lk.text}; text-shadow: ${Lk.shadow}`;
  const subPlain = `font-size: 11px; font-weight: 600; white-space: nowrap; color: ${Lk.sub}; text-shadow: ${Lk.shadow}`;
  let body = '', hidRows = 0;

  if (empty) body = `<div style="margin: auto; max-width: 80%; font-size: 13px; font-weight: 600; text-align: center; color: ${Lk.sub}">Pick at least one server and one stat</div>`;

  if (single) {
    const s = ids[0], off = !LIVE.includes(s.phase);
    const shown = stats.slice(0, cap.stats), n = shown.length;
    const cols = small ? (d.style === 'bars' ? 1 : Math.min(2, n)) : d.size === 'M' ? (d.style === 'rings' || d.style === 'numbers' ? Math.min(4, n) : Math.min(2, n)) : d.size === 'L' ? Math.min(2, n) : Math.min(3, n);
    const tiles = shown.map((k, mi) => {
      const df = W_DEFS[k], [v, txt, hist] = wReading(k, s);
      const label = `<span style="font-size: 11px; font-weight: 600; white-space: nowrap; color: ${Lk.sub}; text-shadow: ${Lk.shadow}">${small ? df[1] : df[0]}</span>`;
      const value = `<span style="font-size: ${d.style === 'rings' || small ? '13px' : '16px'}; font-weight: 700; white-space: nowrap; color: ${Lk.text}; text-shadow: ${Lk.shadow}">${txt}</span>`;
      let inner;
      if (d.style === 'rings') inner = `<div style="display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; height: 100%">
<svg width="44" height="44" viewBox="0 0 100 100" style="transform: rotate(-90deg); flex-shrink: 0"><circle cx="50" cy="50" r="38" fill="none" stroke="${Lk.track}" stroke-width="13"></circle><circle cx="50" cy="50" r="38" fill="none" stroke="${df[2]}" stroke-width="13" stroke-linecap="round" stroke-dasharray="${(Math.min(v, 100) / 100 * C1).toFixed(1)} ${C1.toFixed(1)}"></circle></svg>
${value}${label}</div>`;
      else if (d.style === 'graph') inner = `<div style="display: flex; flex-direction: column; gap: 4px; height: 100%">
<div style="display: flex; justify-content: space-between; align-items: baseline; gap: 6px">${label}${value}</div>
<svg viewBox="0 0 240 56" preserveAspectRatio="none" style="width: 100%; flex-grow: 1; min-height: 18px; display: block"><polyline points="${hist.length > 1 ? pts(hist, 100) : ''}" fill="none" stroke="${df[2]}" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round"></polyline></svg></div>`;
      else if (d.style === 'numbers') inner = `<div style="display: flex; flex-direction: column; justify-content: center; gap: 2px; height: 100%">
${label}<span style="font-size: ${small ? '22px' : '28px'}; font-weight: 700; letter-spacing: -0.02em; white-space: nowrap; color: ${wWarn(k, v) && !off ? '#FF9F0A' : Lk.text}; text-shadow: ${Lk.shadow}">${txt}</span></div>`;
      else inner = `<div style="display: flex; flex-direction: column; justify-content: center; gap: 6px; height: 100%">
<div style="display: flex; justify-content: space-between; align-items: baseline; gap: 6px">${label}${value}</div>
<div style="height: 6px; border-radius: 3px; background: ${Lk.track}"><div style="height: 100%; border-radius: 3px; width: ${Math.min(v, 100)}%; background: ${wWarn(k, v) ? '#FF9F0A' : df[2]}"></div></div></div>`;
      return `<div style="box-sizing: border-box; min-width: 0; min-height: 0; padding: ${small ? '5px 8px' : '8px 10px'}; border-radius: 14px; background: ${Lk.tile}">${inner}</div>`;
    }).join('');
    const btn = `height: 40px; border-radius: 20px; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 600`;
    // Medium shows the server's icon from the app, as on the desktop.
    const icon = d.size === 'M' ? `<span style="width: 32px; height: 32px; flex-shrink: 0; border-radius: 10px; display: flex; align-items: center; justify-content: center; background: ${SERVER_COLORS[s.color] || SERVER_COLORS.blue}; box-shadow: inset 0 1px 0 rgba(255,255,255,0.5)">${ICON.server.replace('width="20" height="20"', 'width="18" height="18"')}</span>` : '';
    body = `<div style="display: flex; align-items: center; justify-content: space-between; gap: 8px">
<div style="display: flex; align-items: center; gap: 10px; min-width: 0">${icon}
<div style="display: flex; flex-direction: column; gap: 2px; min-width: 0">
<span style="${titleStyle}">${esc(s.name)}</span>
<span style="display: flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 600; white-space: nowrap; color: ${off ? Lk.sub : Lk.ok}; text-shadow: ${Lk.shadow}"><span style="width: 6px; height: 6px; border-radius: 3px; flex-shrink: 0; background: ${off ? '#8E8E93' : '#30D158'}"></span>${off ? 'Offline' : small ? 'Online' : 'Online · up ' + uptime(s.uptime, true)}</span>
</div>
</div>
<div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0">
${ctl && d.size === 'M' ? `<span style="box-sizing: content-box; width: 34px; height: 34px; border-radius: 17px; display: flex; align-items: center; justify-content: center; color: ${Lk.text}; background: ${Lk.btnBg}; border: 1px solid ${Lk.border}"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7"></path><path d="M20 4v7h-7"></path></svg></span><span style="position: relative; width: 34px; height: 34px; border-radius: 17px; display: flex; align-items: center; justify-content: center; background: #0066CC"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"></path></svg>${!off && s.updates > 0 ? '<span style="position: absolute; top: 0; right: 0; box-sizing: content-box; width: 9px; height: 9px; border-radius: 5px; background: #FF3B30; border: 1.5px solid #FFFFFF"></span>' : ''}</span>` : ''}
${ctl ? `<span style="width: ${d.size === 'M' ? 34 : 40}px; height: ${d.size === 'M' ? 34 : 40}px; flex-shrink: 0; border-radius: 20px; display: flex; align-items: center; justify-content: center; background: ${off ? 'rgba(120,120,128,0.45)' : '#248A3D'}">${POWER_SVG}</span>` : ''}
</div>
</div>
<div style="flex-grow: 1; min-height: 0; display: grid; grid-template-columns: repeat(${Math.max(1, cols)}, minmax(0, 1fr)); grid-auto-rows: minmax(0, 1fr); gap: 8px">${tiles}</div>
${ctl && big ? `<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px">
<span style="${btn}; box-sizing: content-box; color: ${Lk.text}; background: ${Lk.btnBg}; border: 1px solid ${Lk.border}">Restart</span>
<span style="${btn}; color: #FFFFFF; background: #0066CC">${s.updates ? s.updates + ' Updates' : 'Check Updates'}</span>
</div>` : ''}`;
  }

  if (multi) {
    const rowsIds = ids.slice(0, cap.rows), sh = stats.slice(0, cap.stats);
    const online = ids.filter((s) => LIVE.includes(s.phase)).length;
    hidRows = Math.max(0, ids.length - cap.rows);
    const cols2 = `minmax(0, 1.3fr) repeat(${sh.length}, minmax(0, 1fr))${ctl ? ' 40px' : ''}`;
    const rows = rowsIds.map((s) => {
      const off = !LIVE.includes(s.phase);
      const cells = sh.map((k) => {
        const df = W_DEFS[k], [v, txt, hist] = wReading(k, s), live = !off || k === 'disk';
        const ring = d.style === 'rings' && !small && live;
        return `<span style="display: flex; flex-direction: ${ring ? 'row; align-items: center; gap: 5px' : 'column; gap: 3px'}; min-width: 0">
${ring ? `<svg width="18" height="18" viewBox="0 0 100 100" style="transform: rotate(-90deg); flex-shrink: 0"><circle cx="50" cy="50" r="36" fill="none" stroke="${Lk.track}" stroke-width="18"></circle><circle cx="50" cy="50" r="36" fill="none" stroke="${df[2]}" stroke-width="18" stroke-dasharray="${(Math.min(v, 100) / 100 * C2).toFixed(1)} ${C2.toFixed(1)}"></circle></svg>` : ''}
<span style="font-size: ${big ? '12px' : '11px'}; font-weight: 700; white-space: nowrap; color: ${live ? (wWarn(k, v) && d.style === 'numbers' ? '#FF9F0A' : Lk.text) : Lk.sub}; text-shadow: ${Lk.shadow}">${txt}</span>
${d.style === 'bars' && !small && live ? `<span style="display: block; height: 5px; border-radius: 3px; background: ${Lk.track}"><span style="display: block; height: 100%; border-radius: 3px; width: ${Math.min(v, 100)}%; background: ${wWarn(k, v) ? '#FF9F0A' : df[2]}"></span></span>` : ''}
${d.style === 'graph' && !small && live && !off ? `<svg viewBox="0 0 240 56" preserveAspectRatio="none" style="width: 100%; height: 14px; display: block"><polyline points="${hist.length > 1 ? pts(hist, 100) : ''}" fill="none" stroke="${df[2]}" stroke-width="2" vector-effect="non-scaling-stroke"></polyline></svg>` : ''}
</span>`;
      }).join('');
      return `<div style="display: grid; grid-template-columns: ${cols2}; column-gap: 10px; align-items: center; box-sizing: border-box; min-height: ${d.size === 'XL' ? '52px' : big ? '50px' : '22px'}; padding: ${big ? '5px 12px' : '0'}; border-radius: 14px; background: ${big ? Lk.tile + '; flex: 1 1 0; max-height: 66px' : 'transparent'}">
<span style="display: flex; align-items: center; gap: 7px; min-width: 0"><span style="width: 7px; height: 7px; border-radius: 4px; flex-shrink: 0; background: ${off ? '#8E8E93' : '#30D158'}"></span><span style="font-size: ${big ? '13px' : '12px'}; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: ${Lk.text}; text-shadow: ${Lk.shadow}">${esc(s.name)}</span></span>
${cells}
${ctl ? `<span style="width: 36px; height: 36px; border-radius: 18px; display: flex; align-items: center; justify-content: center; background: ${off ? 'rgba(120,120,128,0.45)' : '#248A3D'}">${POWER_SVG}</span>` : ''}
</div>`;
    }).join('');
    body = `<div style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px">
<span style="${titleStyle}">${esc(d.name || 'Servers')}</span>
<span style="${subPlain}">${small ? online + '/' + ids.length + ' online' : online + ' of ' + ids.length + ' online'}</span>
</div>
<div style="display: flex; flex-direction: column; gap: ${big ? '6px' : '4px'}; min-height: 0${big ? '; flex-grow: 1' : ''}">${rows}</div>
${hidRows ? `<span style="${subPlain}">+${hidRows} more</span>` : ''}`;
  }

  const html = `<div style="position: relative; flex-shrink: 0; width: ${(w * sc).toFixed(1)}px; height: ${(h * sc).toFixed(1)}px">
<div aria-hidden="true" style="position: absolute; left: 0; top: 0; width: ${w}px; height: ${h}px; transform: scale(${sc.toFixed(3)}); transform-origin: 0 0; box-sizing: border-box; padding: ${small ? '14px' : '16px'}; display: flex; flex-direction: column; gap: ${small ? '8px' : '10px'}; overflow: hidden; border-radius: ${dm[2]}px; color: ${Lk.text}; background: ${Lk.bg}; backdrop-filter: blur(30px) saturate(180%); -webkit-backdrop-filter: blur(30px) saturate(180%); border: 1px solid ${Lk.border}; box-shadow: 0 14px 34px rgba(8,28,60,0.28), inset 0 1px 0 rgba(255,255,255,0.5)">
${body}
</div>
</div>`;
  return { html, scale: sc, hidRows, cap, multi, ids };
}
