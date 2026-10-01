// Shared by every page. Swift calls render(state); pages talk back through post().
const post = (m) => window.webkit?.messageHandlers?.ice?.postMessage(m);
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
// Only touch the DOM when a section's markup actually changed (keeps spinners and hovers alive).
const set = (el, html) => { if (el._html !== html) { el.innerHTML = html; el._html = html; } };

const LABELS = { connecting: 'Connecting…', online: 'Online', restarting: 'Restarting…', stopping: 'Shutting down…', starting: 'Starting…', off: 'Offline', updating: 'Updating…', checking: 'Checking…' };
const BUSY = ['connecting', 'restarting', 'stopping', 'starting', 'updating', 'checking'];
const LIVE = ['online', 'updating', 'checking'];
const COLORS = { online: ['#1E7A34', 'rgba(52,199,89,0.16)', '#30D158'], off: ['var(--sub2)', 'rgba(120,120,128,0.16)', '#8E8E93'] };
const colorsFor = (phase) => COLORS[phase] || ['#B33000', 'rgba(255,159,10,0.18)', '#FF9F0A'];
const RING = 2 * Math.PI * 38;

const last = (a) => a[a.length - 1];
const pts = (arr, max) => arr.map((v, i) => (i * 240 / (arr.length - 1)).toFixed(1) + ',' + (54 - Math.min(Math.max(v, 0), max) / max * 50).toFixed(1)).join(' ');
const netMax = (s) => Math.max(1, ...s.down, ...s.up);
const size = (gb) => gb >= 1000 ? +(gb / 1000).toFixed(1) + ' TB' : Math.round(gb) + ' GB';
// Settings › General units; pages set UNITS from the state Swift sends.
const UNITS = { unit: 'C', net: 'MBs' };
const deg = (c) => c == null ? '—' : UNITS.unit === 'F' ? Math.round(c * 9 / 5 + 32) + '°F' : Math.round(c) + '°C';
const netUnit = () => UNITS.net === 'Mbit' ? 'Mbit/s' : 'MB/s';
const speed = (mb, digits = 1) => (UNITS.net === 'Mbit' ? mb * 8 : mb).toFixed(digits) + ' ' + netUnit();
const rate = (v) => { const x = UNITS.net === 'Mbit' ? v * 8 : v; return (x < 10 ? x.toFixed(1) : Math.round(x)) + ' ' + netUnit(); };

// Settings › Appearance (design: Settings). Colors and formulas are the design's; at the defaults
// the main window keeps its own artboard's exact values.
const ACCENTS = { blue: ['#0066CC', '#0A84FF'], teal: ['#0A7C86', '#40C8E0'], purple: ['#6E4FD8', '#A48BFF'], pink: ['#C2185B', '#FF6B9A'], orange: ['#B85400', '#FF9F0A'], graphite: ['#56565B', '#AEAEB2'] };
const TINTS = { none: [[246, 248, 252], [30, 32, 38]], ice: [[226, 238, 252], [22, 36, 58]], graphite: [[232, 233, 236], [40, 41, 45]], warm: [[250, 240, 230], [50, 40, 33]] };
const SERVER_COLORS = { blue: 'linear-gradient(160deg, #5AC8FA, #0A64D6)', teal: 'linear-gradient(160deg, #6EE0D0, #0A7C86)', purple: 'linear-gradient(160deg, #B9A6FF, #5E5CE6)', orange: 'linear-gradient(160deg, #FFC46B, #E06A00)', pink: 'linear-gradient(160deg, #FF9EC0, #C2185B)', graphite: 'linear-gradient(160deg, #C7C7CC, #636366)' };
const isDark = (P) => P.theme === 'dark' || (P.theme === 'auto' && matchMedia('(prefers-color-scheme: dark)').matches);
const hexRgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16)).join(',');

function look(P) {
  const dark = isDark(P), rgb = TINTS[P.tint][dark ? 1 : 0];
  const alpha = P.reduce ? 0.98 : 0.22 + P.glass / 100 * 0.7;
  const isDefault = P.glass === 60 && P.blur === 40 && P.tint === 'ice' && !P.reduce;
  return { dark, rgb, alpha, acc: ACCENTS[P.accent][dark ? 1 : 0], bg: `rgba(${rgb.join(',')},${alpha.toFixed(2)})`, isDefault };
}

function applyLook(P) {
  if (!P) return;
  const L = look(P), r = document.documentElement.style;
  r.setProperty('--win', !L.dark && L.isDefault ? 'rgba(244,247,251,0.66)' : L.bg);
  r.setProperty('--wk', L.dark ? '0.14' : P.reduce ? '1.3' : '1');
  r.setProperty('--hair', L.dark ? '255,255,255' : '60,60,67');
  r.setProperty('--sheet', L.dark ? '40,42,48' : '248,250,253');
  r.setProperty('--solid', L.dark ? 'rgba(255,255,255,0.22)' : '#FFFFFF');
  r.setProperty('--text', L.dark ? '#F5F5F7' : '#1D1D1F');
  ['--sub', '--sub2', '--sub3'].forEach((k, i) => r.setProperty(k, L.dark ? '#B4B4BA' : ['#5E5E63', '#56565B', '#6E6E73'][i]));
  r.setProperty('--accent', L.acc);
  r.setProperty('--accent-rgb', hexRgb(L.acc));
  document.documentElement.style.colorScheme = L.dark ? 'dark' : 'light';
}

function uptime(sec, short) {
  if (sec < 60) return short ? '<1m' : 'less than a minute';
  const [n, unit, u] = sec < 3600 ? [Math.floor(sec / 60), 'min', 'm'] : sec < 86400 ? [Math.floor(sec / 3600), 'hour', 'h'] : [Math.floor(sec / 86400), 'day', 'd'];
  if (short) return n + u;
  return n + ' ' + (unit === 'min' || n === 1 ? unit : unit + 's');
}

function ago(sec) {
  if (sec == null) return 'never';
  if (sec < 60) return 'just now';
  if (sec < 3600) return Math.floor(sec / 60) + ' min ago';
  if (sec < 86400) return Math.floor(sec / 3600) + ' hr ago';
  const d = Math.floor(sec / 86400);
  return d + (d === 1 ? ' day ago' : ' days ago');
}

const ICON = {
  server: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="7" rx="2"></rect><rect x="3" y="13" width="18" height="7" rx="2"></rect><path d="M7 7.5h.01M7 16.5h.01"></path></svg>',
  power: (px, stroke, w) => `<svg width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="${stroke}" stroke-width="${w}" stroke-linecap="round" aria-hidden="true"><path d="M12 3v8"></path><path d="M6.4 6.6a8 8 0 1 0 11.2 0"></path></svg>`,
  restart: (px, w) => `<svg width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7"></path><path d="M20 4v7h-7"></path></svg>`,
  download: (px, w, stroke = 'currentColor') => `<svg width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="${stroke}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"></path></svg>`,
  check: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12l5 5 9-10"></path></svg>',
  spin: '<svg class="icespin" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9"></path></svg>',
};

// The whole window drags from anywhere that isn't a control.
document.addEventListener('mousedown', (e) => {
  if (e.button === 0 && !e.target.closest('button, input, label, a')) post({ cmd: 'drag' });
});
document.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  const t = e.target.closest('[data-menu]');
  post({ cmd: 'menu', id: t ? t.dataset.menu : null });
});
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-cmd]');
  if (b && !b.disabled) act(b.dataset);
});
addEventListener('load', () => post({ cmd: 'ready' }));

// Toast and sudo password sheet, shared by the main window and Settings (design: SudoPrompt).
const LOCK = (px, stroke = '#FFFFFF') => `<svg width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="${stroke}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="10" width="16" height="11" rx="2"></rect><path d="M8 10V7a4 4 0 0 1 8 0v3"></path></svg>`;
const CHECK = (px, w) => `<svg width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12l5 5 9-10"></path></svg>`;
const OVERLAY = 'position: fixed; inset: 0; border-radius: 28px; display: flex; align-items: center; justify-content: center';
const DIALOG = 'box-sizing: border-box; border-radius: 30px; backdrop-filter: blur(50px) saturate(180%); -webkit-backdrop-filter: blur(50px) saturate(180%); border: 1px solid rgba(255,255,255,calc(0.95 * var(--wk))); box-shadow: 0 30px 80px rgba(8,28,60,0.4), inset 0 1px 0 rgba(255,255,255,calc(1 * var(--wk)))';
const GHOST = 'height: 44px; border-radius: 22px; border: 1px solid rgba(var(--hair),0.18); background: rgba(255,255,255,calc(0.85 * var(--wk))); font-size: 14px; font-weight: 600; color: var(--text); cursor: pointer';
const PRIMARY = (enabled) => 'height: 44px; border: 0; border-radius: 22px; background: var(--accent); color: #FFFFFF; font-size: 14px; font-weight: 600; cursor: pointer; box-shadow: 0 6px 16px rgba(var(--accent-rgb),0.3);' + (enabled ? '' : ' opacity: 0.4; cursor: default; box-shadow: none;');
const checkbox = (on) => `<span style="width: 22px; height: 22px; flex-shrink: 0; box-sizing: border-box; border-radius: 7px; display: flex; align-items: center; justify-content: center; background: ${on ? 'var(--accent)' : 'var(--solid)'}; border: 1.5px solid ${on ? 'var(--accent)' : 'rgba(var(--hair),0.35)'}">${CHECK(12, 3.4)}</span>`;
const toggle = (on, cmd, label) => `<button data-cmd="${cmd}" aria-label="${label}" aria-pressed="${on}" style="position: relative; width: 52px; height: 30px; flex-shrink: 0; padding: 0; border: 0; border-radius: 15px; cursor: pointer; transition: background 0.2s; background: ${on ? '#248A3D' : 'rgba(120,120,128,0.36)'}"><span style="position: absolute; top: 2px; left: ${on ? '24px' : '2px'}; width: 26px; height: 26px; border-radius: 13px; background: #FFFFFF; box-shadow: 0 2px 6px rgba(0,0,0,0.22); transition: left 0.2s"></span></button>`;

function layer(id) {
  let el = $(id);
  if (!el) { el = document.createElement('div'); el.id = id; document.body.appendChild(el); }
  return el;
}

let toastTimer = null;
function toast(o) {
  const el = layer('toast');
  // With Undo it's the design's Settings toast; otherwise the main window's.
  el.innerHTML = o.undo || window.SETTINGS_TOAST
    ? `<div role="status" style="position: fixed; left: 50%; top: 20px; transform: translateX(-50%); z-index: 20; height: 44px; padding: 0 18px; display: flex; align-items: center; gap: 14px; border-radius: 22px; background: rgba(255,255,255,calc(0.92 * var(--wk))); box-shadow: 0 12px 30px rgba(8,28,60,0.25); font-size: 14px; font-weight: 600; color: var(--text); white-space: nowrap">${esc(o.text)}${o.undo ? `<button data-cmd="undoRemove" style="height: 32px; padding: 0 14px; border-radius: 16px; border: 0; background: rgba(var(--accent-rgb),0.12); color: var(--accent); font-size: 13px; font-weight: 700; cursor: pointer">Undo</button>` : ''}</div>`
    : `<div role="status" style="position: fixed; left: 50%; top: 20px; transform: translateX(-50%); z-index: 20; display: flex; align-items: center; gap: 10px; height: 48px; padding: 0 20px 0 14px; border-radius: 24px; background: rgba(255,255,255,calc(0.86 * var(--wk))); backdrop-filter: blur(30px) saturate(180%); -webkit-backdrop-filter: blur(30px) saturate(180%); border: 1px solid rgba(255,255,255,calc(0.95 * var(--wk))); box-shadow: 0 12px 30px rgba(8,28,60,0.25); font-size: 14px; font-weight: 600; color: var(--text); white-space: nowrap"><span style="width: 26px; height: 26px; border-radius: 13px; background: #248A3D; display: flex; align-items: center; justify-content: center">${CHECK(14, 3)}</span>${esc(o.text)}</div>`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.innerHTML = ''; }, o.undo ? 5000 : 3000);
}

// Swift shows the sheet with askPassword() and closes it with hidePassword().
let pw = null;

function askPassword(o) {
  const same = pw && pw.id === o.id;
  pw = { ...o, remember: same ? pw.remember : o.remember, busy: false };
  const body = o.action
    ? `${esc(o.action)} needs sudo as <strong style="color: var(--text)">${esc(o.user)}</strong>.${o.remember ? ' You only need to enter this once.' : ''}`
    : `Power, restart and updates need sudo as <strong style="color: var(--text)">${esc(o.user)}</strong>. You only need to enter this once.`;
  layer('pwSheet').innerHTML = `<div style="${OVERLAY}; z-index: 10; background: rgba(10,25,50,0.3)">
<form id="pwForm" role="dialog" aria-label="Sudo password" autocomplete="off" style="width: 440px; padding: 28px; display: flex; flex-direction: column; align-items: center; gap: 16px; background: rgba(var(--sheet),0.92); text-align: center; ${DIALOG}">
<span style="width: 56px; height: 56px; border-radius: 16px; background: linear-gradient(160deg, #8E8CF5, #5E5CE6); display: flex; align-items: center; justify-content: center; box-shadow: inset 0 1px 0 rgba(255,255,255,calc(0.45 * var(--wk)))">${LOCK(26)}</span>
<div style="display: flex; flex-direction: column; gap: 6px">
<h2 style="margin: 0; font-size: 19px; font-weight: 700">Admin password for ${esc(o.name)}</h2>
<p style="margin: 0; font-size: 13px; color: var(--sub2); line-height: 1.45">${body}</p>
</div>
<input class="icefield" name="pw" type="password" aria-label="Sudo password" placeholder="Sudo password" autocomplete="off">
${o.error ? `<div role="alert" style="margin-top: -6px; font-size: 12px; font-weight: 600; color: #C4000F">${esc(o.error)}</div>` : ''}
<button type="button" data-cmd="pwRemember" role="checkbox" aria-checked="${pw.remember}" style="align-self: stretch; display: flex; align-items: center; gap: 10px; min-height: 44px; padding: 0 4px; border: 0; background: transparent; cursor: pointer; text-align: left">
<span id="pwCheck">${checkbox(pw.remember)}</span>
<span style="display: flex; flex-direction: column; gap: 1px"><span style="font-size: 13px; font-weight: 600; color: var(--text)">Remember in Keychain</span><span style="font-size: 12px; color: var(--sub2)">Encrypted on this Mac, never synced.</span></span>
</button>
<div style="align-self: stretch; display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px">
<button type="button" data-cmd="pwCancel" style="${GHOST}">Cancel</button>
<button id="pwGo" type="submit" disabled style="${PRIMARY(false)}">Continue</button>
</div>
</form>
</div>`;
  const f = $('pwForm');
  f.pw.addEventListener('input', pwButton);
  f.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!f.pw.value || pw.busy) return;
    pw.busy = true;
    f.pw.disabled = true;
    pwButton();
    post({ cmd: 'password', id: pw.id, value: f.pw.value, remember: pw.remember });
  });
  if (o.error) f.classList.add('shake');
  f.pw.focus();
}

function pwButton() {
  const go = $('pwGo'), ok = !!$('pwForm').pw.value && !pw.busy;
  go.disabled = !ok;
  go.style.cssText = PRIMARY(ok);
  go.textContent = pw.busy ? 'Checking…' : 'Continue';
}

function hidePassword() {
  pw = null;
  layer('pwSheet').innerHTML = '';
}

// Handles the sheet's own buttons; pages call this first from their act().
function sheetAct(d) {
  if (d.cmd === 'undoRemove') { post({ cmd: 'undoRemove' }); layer('toast').innerHTML = ''; return true; }
  if (d.cmd === 'pwCancel') { post({ cmd: 'passwordCancel' }); return true; }
  if (d.cmd === 'pwRemember') {
    pw.remember = !pw.remember;
    $('pwCheck').innerHTML = checkbox(pw.remember);
    document.querySelector('[data-cmd="pwRemember"]').setAttribute('aria-checked', pw.remember);
    return true;
  }
  return false;
}

addEventListener('keydown', (e) => { if (e.key === 'Escape' && pw) post({ cmd: 'passwordCancel' }); });
