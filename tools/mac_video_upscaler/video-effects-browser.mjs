// Live WebUI, decoder and sandbox integration. Node 22+, FFmpeg, built Chromium.
import {spawn, execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {access, mkdir, mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {resolve} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import assert from 'node:assert/strict';
const root = resolve(import.meta.dirname, '../..');
const work = resolve(root, `chromium-work/video-effects-validation${process.argv.includes('--headed') ? '-headed' : ''}`);
const binary = process.env.CHROMIUM_BINARY || resolve(root, 'chromium-work/browser/src/out/Upscale/Chromium.app/Contents/MacOS/Chromium');
const headed = process.argv.includes('--headed');
await access(binary); await mkdir(work, {recursive:true});
const fixture = resolve(work, 'av-timing.mp4');
// A 100ms flash and tone every second, plus moving detail. B-frames exercise
// presentation reordering; the audio track provides the playback master clock.
execFileSync('ffmpeg', ['-hide_banner','-loglevel','error','-f','lavfi','-i',
  'testsrc2=size=640x360:rate=30:duration=20', '-f','lavfi','-i',
  'aevalsrc=if(lt(mod(t\\,1)\\,0.1)\\,0.5*sin(2*PI*1000*t)\\,0):s=48000:d=20',
  '-vf', "drawbox=x=0:y=0:w=64:h=64:color=white:t=fill:enable='lt(mod(t,1),0.1)'",
  '-c:v','libx264','-bf','3','-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart','-y',fixture]);
const bytes = await readFile(fixture);
const server = createServer((req,res)=>{
  if (req.url === '/video.mp4') {
    const range = req.headers.range?.match(/bytes=(\d+)-(\d*)/);
    const start = range ? Number(range[1]) : 0;
    const end = range?.[2] ? Number(range[2]) : bytes.length-1;
    res.writeHead(range ? 206 : 200, {'Content-Type':'video/mp4','Accept-Ranges':'bytes',
      'Content-Length':end-start+1,...(range ? {'Content-Range':`bytes ${start}-${end}/${bytes.length}`} : {})});
    res.end(bytes.subarray(start,end+1));
  } else {
    res.writeHead(200, {'Content-Type':'text/html'});
    res.end(`<!doctype html><title>Video effects AV timing fixture</title>
      <style>body{margin:0;background:#111;color:white;font:16px system-ui}video{width:100%;max-height:90vh}</style>
      <video id="v" autoplay muted controls loop src="/video.mp4"></video>
      <script>window.loadId=crypto.randomUUID();window.samples=[];
      const v=document.querySelector('video');window.playbackEvents=[];
      for(const event of ['play','pause','ended','waiting','playing','error','seeking','seeked'])v.addEventListener(event,()=>playbackEvents.push({event,time:v.currentTime,now:performance.now(),visibility:document.visibilityState}));
      function sample(now,m){samples.push({now,mediaTime:m.mediaTime,clock:v.currentTime,width:m.width,height:m.height,presentedFrames:m.presentedFrames,expectedDisplayTime:m.expectedDisplayTime});if(samples.length>3000)samples.shift();v.requestVideoFrameCallback(sample)}
      v.requestVideoFrameCallback(sample);</script>`);
  }
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url=`http://127.0.0.1:${server.address().port}/`;
class CDP {
  constructor(socket) {
    this.socket=socket;this.pending=new Map();this.id=0;this.events=[];
    socket.addEventListener('message',({data})=>{
      const m=JSON.parse(data);
      if(!m.id){this.events.push(m);return;}
      const p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);
      clearTimeout(p.timer);m.error?p.reject(new Error(JSON.stringify(m.error))):p.resolve(m.result);
    });
  }
  static async open(url) {const ws=new WebSocket(url);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true});});return new CDP(ws);}
  call(method,params={}) {return new Promise((resolve,reject)=>{
    const id=++this.id;const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error(`Timeout ${method}`));},20000);
    this.pending.set(id,{resolve,reject,timer});this.socket.send(JSON.stringify({id,method,params}));
  });}
  async eval(expression) {const r=await this.call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,userGesture:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
  close(){this.socket.close();}
}
async function until(fn,label,timeout=30000) {
  const start=Date.now();let value;
  while(Date.now()-start<timeout){value=await fn();if(value)return value;await delay(200);}
  throw new Error(`Timed out: ${label}; last=${JSON.stringify(value)}`);
}
const profiles=[];let proc, browser, currentUi, connections=[], stderr='', expectedGpuCrash=false;
async function start(profile,mode='settings') {
  stderr='';
  await rm(resolve(profile,'DevToolsActivePort'),{force:true});
  proc=spawn(binary,[...(mode==='settings'?[]:[`--mac-video-upscaler=${mode}`]),...(headed?[]:['--headless=new']),
    `--user-data-dir=${profile}`,'--remote-debugging-port=0','--no-first-run','--no-default-browser-check',
    '--use-mock-keychain','--enable-logging=stderr','--disable-component-update','--disable-background-networking','--autoplay-policy=no-user-gesture-required','--disable-backgrounding-occluded-windows',
    '--disable-renderer-backgrounding','--disable-background-media-suspend','--window-size=1100,850','--enable-sandbox-logging','about:blank'],{stdio:['ignore','ignore','pipe']});
  proc.stderr.on('data',x=>{stderr+=x;});
  const endpoint=await until(async()=>{
    if(proc.exitCode!==null||proc.signalCode!==null)throw new Error(`Browser exited: ${stderr.slice(-3000)}`);
    try {return (await readFile(resolve(profile,'DevToolsActivePort'),'utf8')).split('\n');}catch{return false;}
  },'DevTools port');
  browser=await CDP.open(`ws://127.0.0.1:${endpoint[0]}${endpoint[1]}`);connections.push(browser);
  return endpoint[0];
}
async function page(port,pageUrl) {
  const {targetId}=await browser.call('Target.createTarget',{url:pageUrl,newWindow:true});
  const targets=await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const c=await CDP.open(targets.find(t=>t.id===targetId).webSocketDebuggerUrl);
  connections.push(c);c.targetId=targetId;
  await browser.call('Target.activateTarget',{targetId});
  await c.call('Media.enable');await c.call('Runtime.enable');
  return c;
}
async function stop(name) {
  if(proc && proc.exitCode===null){try{await browser.call('Browser.close');}catch{}await until(()=>proc.exitCode!==null||proc.signalCode!==null,'browser exit',15000);}
  for(const c of connections)c.close();connections=[];
  await writeFile(resolve(work,`${name}.log`),stderr);
  if(!expectedGpuCrash)assert(!/GPU process exited unexpectedly|GpuProcessHost: The GPU process crashed/.test(stderr),'Unexpected GPU crash');
  else assert.equal((stderr.match(/GPU process exited unexpectedly/g)||[]).length,1,'Only the intentional GPU crash is allowed');
  assert(!/FATAL:/.test(stderr),'Browser or GPU DCHECK failure');
}
const snapshot=async ui=>ui.eval(`(async()=>{const m=await import('./video_effects.mojom-webui.js');return JSON.parse(JSON.stringify((await (window.effectsTestRemote ??= m.PageHandler.getRemote()).getSnapshot()).snapshot,(_,v)=>typeof v==='bigint'?String(v):v));})()`);
async function control(ui,id,value,type='change') {
  const before = await snapshot(ui);
  await ui.eval(`(()=>{const e=document.getElementById(${JSON.stringify(id)});if(e.type==='checkbox')e.checked=${JSON.stringify(value)};else e.value=${JSON.stringify(String(value))};e.dispatchEvent(new Event(${JSON.stringify(type)},{bubbles:true}));})()`);
  await until(async()=>{const s=await snapshot(ui);return BigInt(s.settings.version)>BigInt(before.settings.version)&&s.settings[id]===(id==='strength'?value/100:value);},`control ${id}=${value}`);
}
async function probe(player,label,seconds=2,activate=true) {
  if(activate) await browser.call('Target.activateTarget',{targetId:player.targetId});
  await delay(300);
  await player.eval('v.play()');
  await player.eval('samples=[]');await delay(seconds*1000);
  const result=await player.eval(`({loadId,paused:v.paused,time:v.currentTime,intrinsic:[v.videoWidth,v.videoHeight],error:v.error?.message,playbackEvents,samples,quality:{dropped:v.getVideoPlaybackQuality().droppedVideoFrames,total:v.getVideoPlaybackQuality().totalVideoFrames}})`);
  await writeFile(resolve(work,`${label}-frames.json`),JSON.stringify(result,null,2));
  assert(!result.error && !result.paused,`${label}: playback paused or failed; ${JSON.stringify(result.playbackEvents.slice(-8))}`);assert.deepEqual(result.intrinsic,[640,360]);
  assert(result.samples.length>4,`${label}: no compositor callbacks`);
  const frames=result.samples;
  for(let i=1;i<frames.length;i++)if(frames[i].mediaTime>=frames[i-1].mediaTime)assert(frames[i].mediaTime>frames[i-1].mediaTime,'duplicate presentation timestamp');
  const drifts=frames.map(s=>Math.abs(s.clock-s.mediaTime));
  assert(Math.max(...drifts)<.25,`${label}: AV master-clock drift ${Math.max(...drifts)}`);
  await writeFile(resolve(work,`${label}-frames.json`),JSON.stringify(result,null,2));
  return result;
}
try {
  const profile=await mkdtemp(resolve(work,'profile-'));profiles.push(profile);
  let port=await start(profile);
  let ui=await page(port,'chrome://video-effects/');currentUi=ui;
  await until(()=>ui.eval('document.getElementById("ack")?.textContent.includes("acknowledged")'),'control page');
  assert.deepEqual(await ui.eval(`Object.fromEntries(['enabled','upscaling','motion','cadence','noise','strength','retry'].map(id=>[id,document.getElementById(id).checkVisibility()]))`),
    {enabled:true,upscaling:true,motion:false,cadence:false,noise:false,strength:false,retry:true});
  await writeFile(resolve(work,'controls.png'),Buffer.from((await ui.call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  let s=await snapshot(ui);assert.equal(s.settings.enabled,false);assert.equal(s.settings.upscaling,0);
  const first=await page(port,url),second=await page(port,url);
  await until(async()=>{const x=await snapshot(ui);return x.players.length===2&&x.players.every(p=>p.inputWidth===640);},'two hardware players');
  const loadIds=await Promise.all([first.eval('loadId'),second.eval('loadId')]);
  const observations=[];
  await control(ui,'enabled',true);
  for(const [id,value,type] of [['upscaling',1],['upscaling',2],['noise',true],['strength',75,'input'],['motion',1],['motion',2],['cadence',1],['cadence',2],['motion',0],['noise',false],['upscaling',0]]) {
    await control(ui,id,value,type);
    await delay(type==='input'?200:50);
    s=await until(async()=>{const x=await snapshot(ui);return x.acknowledgedVersion===x.settings.version&&x.players.length===2&&x.players.every(p=>p.appliedVersion===x.settings.version&&p.state!=='Warming up')?x:false;},`${id}=${value}`,60000);
    observations.push({control:id,value,snapshot:s});
    await writeFile(resolve(work,'live-controls.json'),JSON.stringify(observations,null,2));
    assert(s.players.every(p=>p.queueDepth<=3));
    assert.deepEqual(await Promise.all([first.eval('loadId'),second.eval('loadId')]),loadIds);
    await probe(first,`${id}-${value}`,1);
  }
  // Verify real temporal activation separately from permitted per-stage fallback
  // in the control matrix, then record several seconds of submitted frames.
  for (const [motion,cadence,label,active] of [
    [1,0,'low-latency-steady','Low-latency interpolation'],
    [2,1,'quality-60-steady','Quality conversion'],
    [2,2,'quality-120-steady','Quality conversion'],
  ]) {
    await control(ui,'motion',motion);
    if (motion===2) await control(ui,'cadence',cadence);
    await until(async()=>{const x=await snapshot(ui);return x.players.length===2&&x.players.every(p=>p.active.includes(active));},`${label} native activation`,60000);
    const samples=[];
    await Promise.all([probe(first,label,6),(async()=>{for(let i=0;i<12;i++){samples.push(await snapshot(ui));await delay(500);}})()]);
    await writeFile(resolve(work,`${label}-processing.json`),JSON.stringify(samples,null,2));
  }
  await control(ui,'noise',true);
  await control(ui,'upscaling',2);
  const combined=[];
  await Promise.all([probe(first,'quality-120-combined',6),(async()=>{for(let i=0;i<12;i++){combined.push(await snapshot(ui));await delay(500);}})()]);
  await writeFile(resolve(work,'quality-120-combined-processing.json'),JSON.stringify(combined,null,2));
  await control(ui,'motion',0);
  await control(ui,'noise',false);
  await until(async()=>{const x=await snapshot(ui);return x.players.every(p=>p.outputWidth===1280);},'2x output');
  await control(ui,'enabled',false);
  await until(async()=>{const x=await snapshot(ui);return x.settings.upscaling===2&&x.players.every(p=>p.state==='Bypassed'&&p.outputWidth===640);},'master bypass preserving choices');
  await control(ui,'enabled',true);
  await until(async()=>{const x=await snapshot(ui);return x.players.every(p=>p.outputWidth===1280);},'master restore');
  await ui.eval('document.getElementById("retry").click()');
  await first.eval('v.currentTime=3');
  const seek=await probe(first,'seek',3);assert(seek.samples.some(f=>f.width===1280));
  // EOS includes all outstanding generated output and must not deadlock.
  await first.eval('v.loop=false;v.currentTime=19');
  await until(()=>first.eval('v.ended'),'EOS',15000);
  await first.eval('v.loop=true;v.currentTime=0;v.play()');
  if(headed) {
    await browser.call('Target.activateTarget',{targetId:first.targetId});
    await first.eval('v.requestFullscreen()');
    await until(()=>first.eval('document.fullscreenElement===v'),'fullscreen entered');
    await probe(first,'fullscreen',2,false);
    assert(await first.eval('document.fullscreenElement===v'));
    await writeFile(resolve(work,'fullscreen.png'),Buffer.from((await first.call('Page.captureScreenshot',{format:'png'})).data,'base64'));
    await first.eval('document.exitFullscreen()');
    await delay(1000);
    await first.eval('v.requestPictureInPicture()');
    await until(()=>first.eval('document.pictureInPictureElement===v'),'PiP entered');
    await probe(first,'picture-in-picture',2,false);
    assert(await first.eval('document.pictureInPictureElement===v'));
    await first.eval('document.exitPictureInPicture()');
  }
  s=await snapshot(ui);
  await writeFile(resolve(work,'live-controls.json'),JSON.stringify(observations,null,2));
  await writeFile(resolve(work,'before-reconnect.json'),JSON.stringify(s,null,2));
  assert(!/FATAL:|GPU process exited unexpectedly/.test(stderr),'Unexpected failure before the intentional GPU crash');
  expectedGpuCrash=true;
  await browser.call('Browser.crashGpuProcess');
  await delay(1500);
  await until(async()=>{const x=await snapshot(ui);return x.gpuConnected&&x.acknowledgedVersion===s.settings.version;},'GPU settings reconnection',30000);
  const third=await page(port,url);
  await until(async()=>{const x=await snapshot(ui);return x.players.some(p=>p.outputWidth===1280);},'new player after GPU reconnect',45000);
  await probe(third,'gpu-reconnect',2);
  await stop('live');
  expectedGpuCrash=false;
  // Restart only in this separate persistence test; the control matrix above
  // ran in a single browser process without reloading either playing document.
  port=await start(profile);ui=await page(port,'chrome://video-effects/');
  await until(()=>ui.eval('document.getElementById("ack")?.textContent.includes("acknowledged")'),'restored control page');
  s=await snapshot(ui);assert.equal(s.settings.enabled,true);assert.equal(s.settings.upscaling,2);assert.equal(s.settings.strength,.75);
  await stop('persistence');
  for(const mode of [1,2]) {
    const migration=await mkdtemp(resolve(work,`migration-${mode}-`));
    await writeFile(resolve(migration,'Local State'),JSON.stringify({browser:{enabled_labs_experiments:[`mac-video-upscaler@${mode}`]}}));
    port=await start(migration);ui=await page(port,'chrome://video-effects/');
    await until(()=>ui.eval('document.getElementById("ack")?.textContent.includes("acknowledged")'),'migration page');
    s=await snapshot(ui);assert.equal(s.settings.upscaling,mode);assert.equal(s.settings.enabled,true);
    await stop(`migration-${mode}`);
  }
  console.log(`PASS live controls in one browser process, two tabs, seek/EOS, persistence, migration, GPU reconnect${headed?', fullscreen and PiP':''}. GPU sandbox enabled. Artifacts: ${work}`);
} finally {
  if(proc?.exitCode===null && currentUi) {
    try {
      await writeFile(resolve(work,'failure-ui.html'),await currentUi.eval('document.documentElement.outerHTML'));
      await writeFile(resolve(work,'failure-events.json'),JSON.stringify(currentUi.events,null,2));
    } catch {}
  }
  if(proc?.exitCode===null)proc.kill('SIGTERM');
  for(const c of connections)c.close();
  server.close();
  await writeFile(resolve(work,'last-session.log'),stderr);
}
