import {PageHandler, Motion, Cadence, Upscaling} from './video_effects.mojom-webui.js';
import type {Settings, Snapshot} from './video_effects.mojom-webui.js';
const handler = PageHandler.getRemote();
const input = (id: string) => document.getElementById(id) as HTMLInputElement;
const select = (id: string) => document.getElementById(id) as HTMLSelectElement;
const text = (id: string, value: string) => { document.getElementById(id)!.textContent = value; };
let settings: Settings;
let pending = false;
let dirty = false;
let debounce: number|undefined;
let requestedVersion = 0n;
function syncControls(s: Settings) {
  input('enabled').checked = s.enabled;
  select('upscaling').value = String(s.upscaling);
  select('motion').value = String(s.motion);
  select('cadence').value = String(s.cadence);
  select('cadence').disabled = s.motion !== Motion.kQuality;
  input('noise').checked = s.noise;
  input('strength').value = String(Math.round(s.strength * 100));
  text('strength-value', `${input('strength').value}%`);
}
function readControls(): Settings {
  return {...settings, enabled: input('enabled').checked,
    upscaling: Number(select('upscaling').value) as Upscaling,
    motion: Number(select('motion').value) as Motion,
    cadence: Number(select('cadence').value) as Cadence,
    noise: input('noise').checked, strength: Number(input('strength').value) / 100};
}
async function save() {
  if (pending) { dirty = true; return; }
  pending = true; dirty = false;
  try {
    const next = readControls();
    if (next.motion !== Motion.kQuality) next.cadence = Cadence.kDouble;
    requestedVersion = (await handler.setSettings(next)).version;
    settings = next;
  } catch { text('ack', 'Connection interrupted. Reload this control page to reconnect.'); }
  finally { pending = false; if (dirty) void save(); }
}
function render(snapshot: Snapshot) {
  const s = snapshot.settings;
  if (!pending && !dirty && debounce === undefined && s.version >= requestedVersion) {
    settings = s; syncControls(s);
  }
  text('ack', snapshot.gpuConnected ? `Settings version ${s.version}; GPU acknowledged ${snapshot.acknowledgedVersion}. Each player shows its applied version.` : 'GPU reconnecting; saved settings will be restored.');
  text('requested', `Requested: ${s.enabled ? 'enabled' : 'master bypass'} · ${['upscaling off', 'VideoToolbox 2×', 'MetalFX 2×'][s.upscaling]} · ${['motion off', 'low-latency 2×', `quality ${['2× source', '60 FPS', '120 FPS'][s.cadence]}`][s.motion]} · noise ${s.noise ? `${Math.round(s.strength * 100)}%` : 'off'}`);
  const container = document.getElementById('players')!;
  container.replaceChildren();
  if (!snapshot.players.length) { container.textContent = 'No VideoToolbox players registered. Start a supported video; software-decoded players do not appear here.'; return; }
  for (const p of snapshot.players) {
    const article = document.createElement('article');
    article.dataset['playerId'] = String(p.id);
    const title = document.createElement('h3');
    title.textContent = `Player ${p.id} — ${p.state}`;
    article.append(title);
    for (const line of [p.reason, `Active: ${p.active || 'none'} · applied version ${p.appliedVersion}`,
      `${p.inputWidth}×${p.inputHeight} → ${p.outputWidth}×${p.outputHeight}`,
      `Source ${p.sourceFps.toFixed(1)} FPS · processed ${p.processedFps.toFixed(1)} FPS · processing ${p.processingMs.toFixed(1)} ms · queue ${p.queueDepth}`]) {
      const paragraph = document.createElement('p'); paragraph.textContent = line; article.append(paragraph);
    }
    container.append(article);
  }
}
async function refresh() { try { render((await handler.getSnapshot()).snapshot); } catch { text('ack', 'Control page disconnected. Reload to reconnect.'); } }
async function initialize() {
  const snapshot = (await handler.getSnapshot()).snapshot;
  settings = snapshot.settings; render(snapshot);
  for (const id of ['enabled', 'upscaling', 'motion', 'cadence', 'noise']) {
    document.getElementById(id)!.addEventListener('change', () => {
      if (id === 'motion') {
        select('cadence').disabled = Number(select('motion').value) !== Motion.kQuality;
        if (select('cadence').disabled) select('cadence').value = '0';
      }
      dirty = true; void save();
    });
  }
  input('strength').addEventListener('input', () => {
    text('strength-value', `${input('strength').value}%`);
    dirty = true; clearTimeout(debounce);
    debounce = setTimeout(() => { debounce = undefined; void save(); }, 100);
  });
  document.getElementById('retry')!.addEventListener('click', async () => {
    requestedVersion = (await handler.retry()).version; await refresh();
  });
  setInterval(() => void refresh(), 500);
}
void initialize();
