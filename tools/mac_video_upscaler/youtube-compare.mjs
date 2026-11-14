// Live YouTube comparison in the custom Chromium. Node 22+ required.
// Artifacts: out/Upscale/upscaler-tests/youtube-comparison/{mode}-{seconds}.png and results.json.
import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir, mkdtemp} from 'node:fs/promises';
import {resolve} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

const root = resolve(import.meta.dirname, '../..');
const out = resolve(root, 'out/Upscale/upscaler-tests/youtube-comparison');
const browser = resolve(root, 'out/Upscale/Chromium.app/Contents/MacOS/Chromium');
const url = 'https://www.youtube.com/watch?v=x22TJMv2RYo';
const timestamps = [30, 45];
const modes = (process.env.COMPARISON_MODES || 'off,videotoolbox,metalfx').split(',');
if(modes.some(m=>!['off','videotoolbox','metalfx'].includes(m))) throw new Error('Invalid comparison mode');
let results = [];
if(process.env.COMPARISON_MODES) {
  results = JSON.parse(await readFile(resolve(out,'results.json'),'utf8')).filter(r=>!modes.includes(r.mode));
  for(const r of results) r.captures = r.captures.filter(c=>timestamps.includes(c.seconds));
}
await mkdir(out, {recursive: true});
for (const mode of modes) {
  const profile = await mkdtemp(resolve(out, `${mode}-profile-`));
  const child = spawn(browser, ['--headless=new', '--remote-debugging-port=0',
    `--user-data-dir=${profile}`, `--mac-video-upscaler=${mode}`, '--no-first-run',
    '--no-default-browser-check', '--use-mock-keychain', '--autoplay-policy=no-user-gesture-required',
    '--window-size=1708,960', '--enable-logging=stderr', 'about:blank'], {stdio:['ignore','ignore','pipe']});
  let stderr = '', socket;
  const events = [];
  child.stderr.on('data', x => stderr += x);
  try {
    let port;
    for (let i=0; i<120; i++) {
      if (child.exitCode !== null) throw new Error(`Chromium exited: ${child.exitCode}`);
      try {port=(await readFile(resolve(profile,'DevToolsActivePort'),'utf8')).split('\n')[0]; break;} catch {}
      await delay(500);
    }
    if (!port) throw new Error('DevTools did not start');
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    socket = new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);
    await new Promise((r,j)=>{socket.onopen=r;socket.onerror=j;});
    let id=0; const pending=new Map();
    socket.onmessage=({data})=>{
      const m=JSON.parse(data);
      if (m.id) {const p=pending.get(m.id); if(p){pending.delete(m.id);m.error?p.reject(new Error(JSON.stringify(m.error))):p.resolve(m.result);}}
      else if (m.method?.startsWith('Media.')) events.push(m);
    };
    const call=(method,params={})=>new Promise((resolve,reject)=>{
      const key=++id;
      const timer=setTimeout(()=>{pending.delete(key);reject(new Error(`CDP timeout ${method}`));},25000);
      pending.set(key,{resolve:x=>{clearTimeout(timer);resolve(x);},reject:e=>{clearTimeout(timer);reject(e);}});
      socket.send(JSON.stringify({id:key,method,params}));
    });
    const evaluate=async expression=>{
      const r=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
      if(r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };
    await call('Media.enable');
    await call('Page.enable');
    await call('Emulation.setDeviceMetricsOverride',{width:1708,height:960,deviceScaleFactor:1,mobile:false});
    await call('Page.navigate',{url});
    let state;
    for(let i=0;i<90;i++) {
      await delay(1000);
      state=await evaluate(`(()=>{
        [...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Reject all' && b.getBoundingClientRect().height>0)?.click();
        const p=document.querySelector('#movie_player'), v=document.querySelector('video');
        if(!p || !v || !p.getAvailableQualityLevels?.().includes('large')) return {text:document.body?.innerText.slice(0,300)};
        if(p.getPlaybackQuality()!=='large') {p.setPlaybackQualityRange?.('large','large');p.setPlaybackQuality?.('large');}
        v.muted=true;if(v.paused)v.play().catch(()=>{});
        return {title:document.title,width:v.videoWidth,height:v.videoHeight,time:v.currentTime,quality:p.getPlaybackQuality(),format:p.getVideoStats?.().fmt,ad:p.classList.contains('ad-showing')};
      })()`);
      if(state.width===854 && state.height===480 && state.time>1 && state.quality==='large' && !state.ad) break;
      if(i%15===14) console.log(mode, 'waiting for 480p:', JSON.stringify(state));
    }
    if(state?.width!==854 || state?.height!==480 || state.quality!=='large' || state.ad) throw new Error(`480p stream unavailable: ${JSON.stringify(state)}`);
    console.log(mode, 'loaded:', JSON.stringify(state));
    await evaluate(`(()=>{
      const v=document.querySelector('video');
      window.frameProbe={count:0,sizes:{},last:null};
      function frame(now,m){const p=window.frameProbe;p.count++;const size=m.width+'x'+m.height;p.sizes[size]=(p.sizes[size]||0)+1;p.last={width:m.width,height:m.height,mediaTime:m.mediaTime,presentedFrames:m.presentedFrames};v.requestVideoFrameCallback(frame);}
      v.requestVideoFrameCallback(frame);
      const style=document.createElement('style');
      style.textContent='::-webkit-scrollbar{display:none!important}body{margin:0!important;background:black!important}body *{visibility:hidden!important}#movie_player{position:fixed!important;inset:0!important;width:1708px!important;height:960px!important;z-index:2147483647!important}.ytp-chrome-top,.ytp-chrome-bottom,.ytp-gradient-top,.ytp-gradient-bottom,.ytp-pause-overlay,.ytp-ce-element,.ytp-watermark{display:none!important}video{visibility:visible!important;position:fixed!important;top:0!important;left:0!important;width:1708px!important;height:960px!important;margin:0!important;object-fit:fill!important;z-index:2147483647!important;transform:none!important}';
      document.head.appendChild(style);
      for(let p=v.parentElement;p;p=p.parentElement){p.style.setProperty('visibility','visible','important');p.style.setProperty('transform','none','important');p.style.setProperty('contain','none','important');p.style.setProperty('overflow','visible','important');}
    })()`);
    const sample = ()=>evaluate(`(()=>{const v=document.querySelector('video'),q=v.getVideoPlaybackQuality(),p=document.querySelector('#movie_player');return {wall:performance.now(),time:v.currentTime,ready:v.readyState,error:document.querySelector('.ytp-error')?.innerText,width:v.videoWidth,height:v.videoHeight,total:q.totalVideoFrames,dropped:q.droppedVideoFrames,quality:p.getPlaybackQuality(),format:p.getVideoStats?.().fmt,probe:window.frameProbe}})()`);
    await delay(1000);
    const before=await sample();
    await delay(10000);
    const after=await sample();
    const expected = mode==='off' ? '854x480' : '1708x960';
    if((after.probe.sizes[expected]||0)<50 || Object.keys(after.probe.sizes).some(s=>s!==expected)) throw new Error(`Wrong compositor frames: ${JSON.stringify(after)}`);
    const record={mode,url,title:state.title,source:{width:854,height:480,format:state.format,quality:'large'},display:{width:1708,height:960},before,after,
      performance:{seconds:(after.wall-before.wall)/1000,mediaSeconds:after.time-before.time,totalFrames:after.total-before.total,droppedFrames:after.dropped-before.dropped,submittedFrames:after.probe.last.presentedFrames-before.probe.last.presentedFrames},captures:[]};
    for(const seconds of timestamps) {
      await evaluate(`(()=>{const p=document.querySelector('#movie_player');p.pauseVideo();p.seekTo(${seconds},true)})()`);
      let seek;
      for(let attempt=0;attempt<120;attempt++) {
        await delay(500);
        seek=await evaluate(`(()=>{const v=document.querySelector('video');return {time:v.currentTime,paused:v.paused,seeking:v.seeking,ready:v.readyState,error:document.querySelector('.ytp-error')?.innerText,frame:window.frameProbe.last}})()`);
        // Audio buffering may keep HTMLMediaElement.seeking true even after
        // the requested video frame has reached composition. Verify that frame.
        if(seek.error) throw new Error('YouTube player error: '+seek.error);
        if(seek.paused && seek.ready>=2 && Math.abs(seek.time-seconds)<0.05 && Math.abs(seek.frame?.mediaTime-seconds)<0.05) break;
        if(attempt%30===29) console.log(mode, 'waiting for seek', seconds, JSON.stringify(seek));
      }
      if(!seek.frame || Math.abs(seek.frame.mediaTime-seconds)>0.05) throw new Error(`Seek frame timed out: ${JSON.stringify(seek)}`);
      await delay(500);
      const captureState=await sample();
      if(captureState.error || captureState.ready<2 || captureState.width!==854 || captureState.height!==480 || captureState.format!==state.format || captureState.quality!=='large' || Math.abs(captureState.time-seconds)>0.05 || captureState.probe.last.width+'x'+captureState.probe.last.height!==expected || Math.abs(captureState.probe.last.mediaTime-seconds)>0.05) throw new Error(`Wrong seek frame ${seconds}: ${JSON.stringify(captureState)}`);
      const shot=await call('Page.captureScreenshot',{format:'png',clip:{x:0,y:0,width:1708,height:960,scale:1},captureBeyondViewport:false});
      const filename=`${mode}-${seconds}.png`;
      await writeFile(resolve(out,filename),Buffer.from(shot.data,'base64'));
      record.captures.push({seconds,filename,state:captureState});
    }
    const log=JSON.stringify(events);
    if(/FATAL:|GPU process exited unexpectedly/.test(stderr) || log.includes('video decoder fallback')) throw new Error('GPU crash or decoder fallback');
    if(mode!=='off' && !log.includes(`${mode} 2x active at 854x480`)) throw new Error('Backend success log missing');
    // Enforce identical encoded stream and presented timestamps across modes.
    if(results.length) {
      if(record.source.format!==results[0].source.format) throw new Error('Different YouTube format; comparison invalid');
      for(let i=0;i<timestamps.length;i++) if(Math.abs(record.captures[i].state.probe.last.mediaTime-results[0].captures[i].state.probe.last.mediaTime)>0.001) throw new Error('Capture frames differ across modes');
    }
    results.push(record);
    await writeFile(resolve(out,'results.json'),JSON.stringify(results,null,2));
    console.log(mode, 'verified:', JSON.stringify(record.performance), 'captures:',record.captures.map(c=>c.state.probe.last.mediaTime));
  } finally {
    await writeFile(resolve(out,`${mode}-media.json`),JSON.stringify(events,null,2));
    await writeFile(resolve(out,`${mode}-browser.log`),stderr);
    socket?.close();child.kill('SIGTERM');
  }
}
console.log('Live YouTube comparison passed for all modes. Artifacts:',out);
