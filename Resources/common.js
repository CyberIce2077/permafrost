// Shared by every page. Swift calls render(state); pages talk back through post().
const post = (m) => window.webkit?.messageHandlers?.ice?.postMessage(m);
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
// Only touch the DOM when a section's markup actually changed (keeps spinners and hovers alive).
const set = (el, html) => { if (el._html !== html) { el.innerHTML = html; el._html = html; } };

const LABELS = { connecting: 'Connecting…', online: 'Online', restarting: 'Restarting…', stopping: 'Shutting down…', starting: 'Starting…', off: 'Offline', updating: 'Updating…', checking: 'Checking…' };
const BUSY = ['connecting', 'restarting', 'stopping', 'starting', 'updating', 'checking'];
const LIVE = ['online', 'updating', 'checking'];
const COLORS = { online: ['#1E7A34', 'rgba(52,199,89,0.16)', '#30D158'], off: ['#56565B', 'rgba(120,120,128,0.16)', '#8E8E93'] };
const colorsFor = (phase) => COLORS[phase] || ['#B33000', 'rgba(255,159,10,0.18)', '#FF9F0A'];
const RING = 2 * Math.PI * 38;

const last = (a) => a[a.length - 1];
const pts = (arr, max) => arr.map((v, i) => (i * 240 / (arr.length - 1)).toFixed(1) + ',' + (54 - Math.min(Math.max(v, 0), max) / max * 50).toFixed(1)).join(' ');
const netMax = (s) => Math.max(1, ...s.down, ...s.up);
const size = (gb) => gb >= 1000 ? +(gb / 1000).toFixed(1) + ' TB' : Math.round(gb) + ' GB';
const rate = (v) => (v < 10 ? v.toFixed(1) : Math.round(v)) + ' MB/s';

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
