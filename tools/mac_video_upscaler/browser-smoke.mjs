// Run after building: node tools/mac_video_upscaler/browser-smoke.mjs
// Uses only Node's built-in APIs and Chromium's DevTools Protocol.
import {spawn, execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {readFile, writeFile, mkdir, mkdtemp, access} from 'node:fs/promises';
import {resolve} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

const root = resolve(import.meta.dirname, '../..');
const work = resolve(root, 'out/Upscale/upscaler-tests');
const browser = resolve(root, 'out/Upscale/Chromium.app/Contents/MacOS/Chromium');
await access(browser);
await mkdir(resolve(work, 'validation'), {recursive: true});
const fixture = resolve(work, 'validation/pattern.mp4');
execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
  'testsrc2=size=640x360:rate=30:duration=8', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
  '-movflags', '+faststart', '-y', fixture]);
const video = await readFile(fixture);
const server = createServer((req, res) => {
  if (req.url === '/pattern.mp4') {
    res.writeHead(200, {'Content-Type':'video/mp4', 'Content-Length':video.length});
    res.end(video);
  } else {
    res.writeHead(200, {'Content-Type':'text/html'});
    res.end('<!doctype html><style>body{margin:0;background:black}video{width:1280px;height:720px}</style><video id="v" autoplay muted loop controls src="/pattern.mp4"></video>');
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/`;

try {
  for (const mode of ['off', 'videotoolbox', 'metalfx']) {
    const profile = await mkdtemp(resolve(work, `validation/${mode}-`));
    const child = spawn(browser, ['--headless=new', '--remote-debugging-port=0',
      `--user-data-dir=${profile}`, `--mac-video-upscaler=${mode}`, '--no-first-run',
      '--no-default-browser-check', '--use-mock-keychain', '--autoplay-policy=no-user-gesture-required',
      '--window-size=1280,800', '--enable-logging=stderr', 'about:blank'], {stdio:['ignore','ignore','pipe']});
    let stderr = '';
    child.stderr.on('data', x => {stderr += x;});
    let socket;
    try {
      let port;
      for (let i=0;i<120;i++) {
        if (child.exitCode !== null) throw new Error(`Browser exited: ${child.exitCode}`);
        try {port = (await readFile(resolve(profile,'DevToolsActivePort'),'utf8')).split('\n')[0]; break;} catch {}
        await delay(500);
      }
      if (!port) throw new Error('DevTools did not start');
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      socket = new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);
      await new Promise((res,rej)=>{socket.addEventListener('open',res,{once:true});socket.addEventListener('error',rej,{once:true});});
      const pending = new Map();
      const events = [];
      let id=0;
      socket.addEventListener('message', ({data})=>{
        const message = JSON.parse(data);
        if (message.id) {
          const callback = pending.get(message.id);
          if (callback) {pending.delete(message.id); message.error ? callback.reject(new Error(JSON.stringify(message.error))) : callback.resolve(message.result);}
        } else if (message.method?.startsWith('Media.')) events.push(message);
      });
      const call = (method,params={})=>new Promise((resolve,reject)=>{
        const key=++id;
        const timer=setTimeout(()=>{pending.delete(key);reject(new Error(`CDP timeout: ${method}`));},15000);
        pending.set(key,{resolve:x=>{clearTimeout(timer);resolve(x);},reject:x=>{clearTimeout(timer);reject(x);}});
        socket.send(JSON.stringify({id:key,method,params}));
      });
      await call('Media.enable');
      await call('Page.enable');
      await call('Page.addScriptToEvaluateOnNewDocument', {source: `
        document.addEventListener('DOMContentLoaded', () => {
          const v = document.querySelector('video');
          if (!v) return;
          window.frameProbe = {callbacks: 0, sizes: {}, last: null};
          function frame(now, m) {
            const p = window.frameProbe;
            p.callbacks++;
            const size = m.width + 'x' + m.height;
            p.sizes[size] = (p.sizes[size] || 0) + 1;
            p.last = {width: m.width, height: m.height,
              presentedFrames: m.presentedFrames, mediaTime: m.mediaTime};
            v.requestVideoFrameCallback(frame);
          }
          v.requestVideoFrameCallback(frame);
        });
      `});
      if (mode === 'off') {
        await call('Page.navigate', {url: 'chrome://flags/#mac-video-upscaler'});
        let options;
        for (let i=0; i<50; i++) {
          await delay(200);
          const ui = await call('Runtime.evaluate', {
            expression: '(()=>{const e=document.querySelector("flags-app")?.shadowRoot?.querySelector("#mac-video-upscaler"); const s=e?.shadowRoot?.querySelector("select.experiment-select"); return s ? [...s.options].map(o=>o.textContent.trim()) : null})()',
            returnByValue: true,
          });
          options = ui.result.value;
          if (options?.length === 3) break;
        }
        if (!options || options[0] !== 'Off' || !options[1].includes('VideoToolbox') || !options[2].includes('MetalFX')) throw new Error(`Missing upscaler selector: ${JSON.stringify(options)}`);
        await writeFile(resolve(work,'validation/flag-options.json'), JSON.stringify(options,null,2));
        console.log('chrome://flags: all three upscaler choices present');
      }
      await call('Page.navigate',{url});
      let state;
      for (let i=0;i<40;i++) {
        await delay(500);
        const result=await call('Runtime.evaluate',{expression:'(()=>{let v=document.querySelector("video");return v?{time:v.currentTime,width:v.videoWidth,height:v.videoHeight,frames:v.getVideoPlaybackQuality().totalVideoFrames,error:v.error?.message}:null})()',returnByValue:true});
        state=result.result.value;
        const logged=JSON.stringify(events);
        if (state?.time>2 && (mode==='off' || logged.includes(`${mode} 2x active`))) break;
      }
      await writeFile(resolve(work,`validation/${mode}-media.json`),JSON.stringify({state,events},null,2));
      if (!state || state.error || state.width!==640 || state.height!==360 || state.frames<20 || state.time<=1) throw new Error(`Playback or intrinsic dimensions failed: ${JSON.stringify(state)}`);
      if (mode!=='off' && !JSON.stringify(events).includes(`${mode} 2x active`)) throw new Error(`No ${mode} active status from the decoder. Check media log and GPU sandbox.`);
      const expectedSize = mode === 'off' ? '640x360' : '1280x720';
      const checkFrames = async () => {
        const result = await call('Runtime.evaluate', {expression: 'window.frameProbe', returnByValue: true});
        const probe = result.result.value;
        await writeFile(resolve(work,`validation/${mode}-frames.json`), JSON.stringify(probe,null,2));
        if (!probe || (probe.sizes[expectedSize] || 0) < 20 || Object.keys(probe.sizes).some(size => size !== expectedSize)) {
          throw new Error(`Expected compositor frames ${expectedSize}: ${JSON.stringify(probe)}`);
        }
        if (/FATAL:|GPU process exited unexpectedly/.test(stderr) ||
            JSON.stringify(events).includes('video decoder fallback')) {
          throw new Error('GPU crash or decoder fallback; playback alone is not proof of upscaling.');
        }
        return probe;
      };
      const beforeSeek = await checkFrames();
      // Seek and verify playback resumes with the same intrinsic dimensions.
      await call('Runtime.evaluate',{expression:'document.querySelector("video").currentTime=0.2'});
      await delay(1000);
      const seekResult = await call('Runtime.evaluate', {expression:'(()=>{let v=document.querySelector("video");return {time:v.currentTime,error:v.error?.message,width:v.videoWidth,height:v.videoHeight}})()',returnByValue:true});
      const afterSeek = seekResult.result.value;
      if (afterSeek.error || afterSeek.time <= 0.2 || afterSeek.width !== 640 || afterSeek.height !== 360) throw new Error(`Seek failed: ${JSON.stringify(afterSeek)}`);
      const afterSeekFrames = await checkFrames();
      if (afterSeekFrames.callbacks <= beforeSeek.callbacks + 5) throw new Error('Compositor frames stopped after seek');
      await writeFile(resolve(work,`validation/${mode}-media.json`),JSON.stringify({state,afterSeek,frames:afterSeekFrames,events},null,2));
      const screenshot=await call('Page.captureScreenshot',{format:'png'});
      await writeFile(resolve(work,`validation/${mode}.png`),Buffer.from(screenshot.data,'base64'));
      console.log(`${mode}: passed, ${afterSeekFrames.callbacks} compositor callbacks at ${expectedSize}, intrinsic ${state.width}x${state.height}, seek passed, no decoder fallback`);
    } finally {
      socket?.close();
      child.kill('SIGTERM');
      await writeFile(resolve(work,`validation/${mode}-browser.log`),stderr);
    }
  }
} finally {
  server.close();
}
