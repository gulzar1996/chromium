// Make an offline A/B viewer from the verified YouTube capture results.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
const out=resolve(import.meta.dirname,'../../out/Upscale/upscaler-tests/youtube-comparison');
const results=JSON.parse(await readFile(resolve(out,'results.json'),'utf8'));
if(results.length!==3) throw new Error('Run youtube-compare.mjs successfully first');
const labels={off:'Off',videotoolbox:'VideoToolbox',metalfx:'MetalFX'};
const rows=results.map(r=>`<tr><td>${labels[r.mode]}</td><td>${r.after.probe.last.width} × ${r.after.probe.last.height}</td><td>${(r.performance.submittedFrames/r.performance.seconds).toFixed(1)}</td><td>${r.performance.droppedFrames} / ${r.performance.totalFrames}</td></tr>`).join('');
const html=`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>YouTube upscaler comparison · x22TJMv2RYo</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#111318;color:#e9edf5;font:16px system-ui,sans-serif}main{max-width:1760px;margin:auto;padding:24px}h1{font-size:26px;margin:0 0 8px}p{color:#b9c1ce;line-height:1.5}a{color:#99caff}label{display:inline-flex;align-items:center;gap:8px;margin:8px 20px 12px 0}select{padding:8px;background:#202631;color:white;border:1px solid #657083;border-radius:6px}.image{position:relative;aspect-ratio:1708/960;overflow:hidden;background:black}.image img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain}.image #top{clip-path:inset(0 50% 0 0)}#line{position:absolute;left:50%;height:100%;border-left:2px solid white;filter:drop-shadow(0 0 2px black)}.badge{position:absolute;top:14px;padding:6px 10px;background:#000b;border-radius:5px}#leftBadge{left:14px}#rightBadge{right:14px}input[type=range]{width:100%;margin:16px 0}table{border-collapse:collapse;min-width:550px;max-width:100%;margin:16px 0}th,td{text-align:left;padding:10px 18px 10px 0;border-bottom:1px solid #39414e}.links{display:flex;gap:20px;flex-wrap:wrap}.details{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}.crop{height:260px;background-repeat:no-repeat;background-size:1708px 960px;border:1px solid #39414e}.detail h3{font-size:16px;font-weight:500;margin-bottom:8px}small{color:#b9c1ce}@media(max-width:700px){main{padding:12px}.details{grid-template-columns:1fr}table{min-width:0;font-size:13px}}
</style><main>
<h1>YouTube: Off / VideoToolbox / MetalFX</h1>
<p><a href="https://www.youtube.com/watch?v=x22TJMv2RYo">TEST VIDEO 480P</a> · same 854 × 480 H.264 stream (YouTube format 135), same frame timestamps, same 1708 × 960 browser display. Captured from the custom Chromium with its normal GPU sandbox enabled.</p>
<p><strong>Visual assessment:</strong> Off is softest. VideoToolbox gives the clearest pitch lines and player outlines in these samples, though some edges look over-emphasized. MetalFX also sharpens the image, with more visibly coarse texture around players and the crowd. My preference for this clip is VideoToolbox; neither restores convincing fine facial or crowd detail. This is a subjective assessment of two still frames, not a temporal-quality score.</p>
<label>Frame <select id="scene"><option value="30">00:30 · players close up</option><option value="45">00:45 · goal / pitch lines</option></select></label>
<label>Left <select id="left"><option value="off">Off</option><option value="videotoolbox" selected>VideoToolbox</option><option value="metalfx">MetalFX</option></select></label>
<label>Right <select id="right"><option value="off" selected>Off</option><option value="videotoolbox">VideoToolbox</option><option value="metalfx">MetalFX</option></select></label>
<div class="image" id="comparison"><img id="bottom" alt="Right comparison frame"><img id="top" alt="Left comparison frame"><div id="line"></div><span class="badge" id="leftBadge"></span><span class="badge" id="rightBadge"></span></div>
<input id="split" aria-label="Comparison divider" type="range" min="0" max="100" value="50">
<p>Move the divider to compare. Click a point in the image to inspect that region below at one screenshot pixel per CSS pixel. Open an original PNG for full resolution.</p>
<div class="links" id="links"></div><div class="details" id="details"></div>
<table><thead><tr><th>Mode</th><th>Compositor frame</th><th>Submitted frames/s</th><th>Dropped / total frames</th></tr></thead><tbody>${rows}</tbody></table>
<small>Frame-rate measurements cover a single approximately 10-second playback window per mode, excluding initial startup. These headless runs are not a sustained performance or physical-display scanout benchmark. No high-resolution reference is available, so the images support visual comparison, not a ground-truth reconstruction score.</small>
<p>Scope: matched frames at 00:30 and 00:45. Attempts to seek to 01:00 encountered a YouTube player error even with upscaling Off; this report does not validate full-length playback or arbitrary seeking. Every accepted screenshot was checked for the requested frame timestamp, source size and compositor size. YouTube's earlier cached 360p frames were rejected.</p>
<p><a href="results.json">Raw measurements</a> · Native dimensions stay 854 × 480 in the page; the compositor dimensions above verify the actual enhanced frame size.</p>
</main><script>
const labels=${JSON.stringify(labels)};
const scene=document.getElementById('scene'),left=document.getElementById('left'),right=document.getElementById('right');
const topImage=document.getElementById('top'),bottom=document.getElementById('bottom'),split=document.getElementById('split');
let point={x:854,y:480};
function update(){
 topImage.src=left.value+'-'+scene.value+'.png';bottom.src=right.value+'-'+scene.value+'.png';
 document.getElementById('leftBadge').textContent=labels[left.value];document.getElementById('rightBadge').textContent=labels[right.value];
 document.getElementById('links').innerHTML=Object.entries(labels).map(([mode,label])=>'<a href="'+mode+'-'+scene.value+'.png" target="_blank">'+label+' PNG</a>').join('');
 document.getElementById('details').innerHTML=Object.entries(labels).map(([mode,label])=>'<div class="detail"><h3>'+label+'</h3><div class="crop" data-mode="'+mode+'"></div></div>').join('');updateCrops();
}
function updateCrops(){document.querySelectorAll('.crop').forEach(el=>{const x=Math.max(0,Math.min(1708-el.clientWidth,point.x-el.clientWidth/2)),y=Math.max(0,Math.min(700,point.y-130));el.style.backgroundImage='url('+el.dataset.mode+'-'+scene.value+'.png)';el.style.backgroundPosition=-x+'px '+(-y)+'px';});}
function divide(){topImage.style.clipPath='inset(0 '+(100-split.value)+'% 0 0)';document.getElementById('line').style.left=split.value+'%';}
scene.onchange=left.onchange=right.onchange=update;split.oninput=divide;window.onresize=updateCrops;
document.getElementById('comparison').onclick=e=>{const r=e.currentTarget.getBoundingClientRect();point={x:(e.clientX-r.left)/r.width*1708,y:(e.clientY-r.top)/r.height*960};updateCrops();};
update();divide();
</script></html>`;
await writeFile(resolve(out,'comparison.html'),html);
console.log(resolve(out,'comparison.html'));
