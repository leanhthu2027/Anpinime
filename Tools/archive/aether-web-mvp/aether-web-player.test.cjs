const {readFileSync} = require('node:fs');
const assert = require('node:assert/strict');
const {JSDOM, VirtualConsole} = require('jsdom');
const core=readFileSync('AnyAnime/WebPictureInPictureScript.swift','utf8').match(/static let core = """([\s\S]*?)"""/)[1].replace(/\\\\/g,'\\');
const script=readFileSync('AnyAnime/Aether/AetherPlayerScript.swift','utf8').match(/static let javascript = #"""([\s\S]*?)"""#/)[1].replace('\\#(WebPictureInPictureScript.core)',core);
function fixture({noVideo=false, ready=4, rejectPlay=false, languages=['en','vi'], deferredPiP=false}={}) {
  const vc=new VirtualConsole().on('jsdomError',error=>{throw error;});
  const dom=new JSDOM('<header class="top-content">Aether</header><main id="player">'+(noVideo?'':'<video controls playsinline src="blob:https://aether.st/sealed"></video>')+'<button id="translate">Translate Vietnamese</button><div id="captions">Translated caption</div><button id="server">Server</button></main>',{url:'https://aether.st/media/tmdb-movie-1',runScripts:'outside-only',virtualConsole:vc});
  const w=dom.window,v=w.document.querySelector('video'),messages=[],timers=[];
  w.webkit={messageHandlers:new Proxy({}, {get:(_,name)=>({postMessage:value=>messages.push({name,value})})})};
  w.setInterval=fn=>{timers.push(fn);return timers.length;};w.setTimeout=fn=>{timers.push(fn);return timers.length;};
  let paused=true,plays=0,pauses=0,translated=0,completePiP;
  const tracks=languages.map(language=>({kind:'subtitles',language,label:language,mode:'disabled'}));
  const audio=[{language:'en',enabled:true},{language:'vi',enabled:false}];
  if(v){
    Object.defineProperties(v,{paused:{get:()=>paused},readyState:{get:()=>ready},duration:{get:()=>180},videoWidth:{get:()=>1280},videoHeight:{get:()=>720},textTracks:{value:tracks},audioTracks:{value:audio}});
    v.getBoundingClientRect=()=>({width:640,height:360});
    v.play=()=>{plays++;if(rejectPlay)return Promise.reject(Error('gesture'));paused=false;v.dispatchEvent(new w.Event('playing'));return Promise.resolve();};
    v.pause=()=>{pauses++;paused=true;v.dispatchEvent(new w.Event('pause'));};
    v.webkitPresentationMode='inline';v.webkitSupportsPresentationMode=()=>true;
    v.webkitSetPresentationMode=mode=>{v.webkitPresentationMode=mode;v.dispatchEvent(new w.Event('webkitpresentationmodechanged'));};
    if(deferredPiP){
      v.webkitSetPresentationMode=undefined;
      let element=null;
      Object.defineProperties(w.document,{pictureInPictureEnabled:{value:true},pictureInPictureElement:{get:()=>element}});
      v.requestPictureInPicture=()=>new Promise((resolve,reject)=>{completePiP=failed=>{
        if(failed){reject(Error('denied'));return;}
        element=v;v.dispatchEvent(new w.Event('enterpictureinpicture'));resolve({});
      };});
      w.document.exitPictureInPicture=()=>{element=null;v.dispatchEvent(new w.Event('leavepictureinpicture'));return Promise.resolve();};
    }
  }
  w.document.querySelector('#translate').onclick=()=>{translated++;w.document.querySelector('#captions').textContent='Vietnamese translation';};
  w.eval(script);
  const session=()=>messages.filter(m=>m.name==='mediaState').at(-1)?.value.pipSessionID;
  const command=(fields,target=session())=>w.dispatchEvent(new w.MessageEvent('message',{data:{type:'AnPinimeCommand',sessionID:target,...fields}}));
  return {dom,w,v,messages,timers,tracks,audio,session,command,completePiP:failed=>completePiP(failed),get plays(){return plays;},get pauses(){return pauses;},get translated(){return translated;}};
}
const f=fixture();
assert.equal(f.plays,0,'observer never autoplays or creates another decoder');
assert.equal(f.v.controls,false,'native Anpinime mode owns the controls');
assert.equal(f.w.document.documentElement.getAttribute('data-anpinime-aether-native'),'true');
assert.equal(f.w.document.querySelector('#player').getAttribute('data-anpinime-aether-surface'),'true','existing wrapper fills native viewport without moving video or captions');
assert.equal(f.w.document.querySelector('#captions').parentNode,f.v.parentNode);
assert.match(f.w.document.querySelector('#anpinime-aether-native-controls').textContent,/data-anpinime-aether-surface.*position:fixed/s);
assert.equal(f.tracks[1].mode,'showing','Vietnamese is preferred when HTML5 exposes it');
f.command({name:'play'},'another-frame');assert.equal(f.plays,0,'foreign identity cannot play another video');
f.command({name:'play'});assert.equal(f.plays,1);assert.equal(f.v.paused,false);
f.command({name:'pause'});assert.equal(f.v.paused,true);
f.command({name:'seek',value:999});assert.equal(f.v.currentTime,180);
f.command({name:'seek',value:-10});assert.equal(f.v.currentTime,0);
f.command({name:'seek',value:77});assert.equal(f.v.currentTime,77);
f.command({name:'rate',value:1.75});assert.equal(f.v.playbackRate,1.75);
f.command({name:'volume',value:0.3});assert.equal(f.v.volume,0.3);
const snapshot=f.messages.filter(m=>m.name==='mediaState').at(-1).value;
assert.equal(snapshot.rate,1.75);assert.equal(snapshot.volume,0.3);
f.command({name:'rate',value:99});assert.equal(f.v.playbackRate,1.75);
f.command({name:'track',kind:'audio',id:f.session()+':audio:1'});assert.deepEqual(f.audio.map(a=>a.enabled),[false,true]);
f.command({name:'track',kind:'subtitles',id:'off'});assert(f.tracks.every(t=>t.mode==='disabled'));
f.command({name:'track',kind:'subtitles',id:'old-session:sub:0'});assert(f.tracks.every(t=>t.mode==='disabled'),'stale track IDs cannot select another episode');
f.command({name:'track',kind:'subtitles',id:f.session()+':sub:0'});assert.equal(f.tracks[0].mode,'showing');
f.command({name:'websiteControls',value:1});assert.equal(f.v.controls,true);
assert.equal(f.w.document.documentElement.getAttribute('data-anpinime-aether-native'),'false');
f.w.document.querySelector('#translate').click();assert.equal(f.translated,1);
assert.equal(f.w.document.querySelector('#captions').textContent,'Vietnamese translation');
f.command({name:'websiteControls',value:0});assert.equal(f.v.controls,false);
assert.equal(f.w.document.querySelector('#captions').textContent,'Vietnamese translation','native controls never delete or replace the website caption renderer');
assert(!f.messages.some(m=>['videoFound','iframeFound'].includes(m.name)),'no stream URL capture or MPV handoff');
f.command({name:'play'});f.command({name:'pip',requestID:'manual'});
assert.equal(f.v.webkitPresentationMode,'picture-in-picture');
assert(f.messages.some(m=>m.name==='pipState'&&m.value.status==='active'));
const before=f.v.style.objectFit;f.command({name:'fit',value:1});assert.equal(f.v.style.objectFit,before,'PiP ownership freezes inline layout');
f.command({name:'pipStop'});assert.equal(f.v.webkitPresentationMode,'inline');
assert(f.messages.some(m=>m.name==='pipState'&&m.value.status==='stopped'&&m.value.requestID==='manual'),'stop is acknowledged by actual presentation mode');
f.command({name:'pause'});
const oldSession=f.session();f.v.setAttribute('src','blob:https://aether.st/server-two');f.v.dispatchEvent(new f.w.Event('loadedmetadata'));
const replacement=f.messages.filter(m=>m.name==='mediaState').at(-1).value;
assert.notEqual(replacement.pipSessionID,oldSession);
assert.equal(replacement.replacesSession,oldSession,'same video source replacement proves succession even when the new source is paused');
assert.equal(replacement.paused,true);
f.command({name:'play'});assert.equal(f.v.paused,false,'native commands can target replacement source');
f.command({name:'endSession'});assert.equal(f.v.paused,true);
f.v.remove();f.timers[0]();
assert(f.messages.some(m=>m.name==='mediaState'&&m.value.removed&&m.value.pipSessionID===replacement.pipSessionID),'DOM removal explicitly retires the old owner');
f.dom.window.close();
const empty=fixture({noVideo:true});
assert.equal(empty.w.document.documentElement.getAttribute('data-anpinime-aether-native'),'false','verification and source selection buttons remain accessible before a video exists');
empty.command({name:'websiteControls',value:1},'');empty.w.document.querySelector('#translate').click();assert.equal(empty.translated,1);empty.dom.window.close();
const english=fixture({languages:['fr','en']});assert.equal(english.tracks[1].mode,'showing','English is the fallback; translation remains a website action');english.dom.window.close();
const blocked=fixture({rejectPlay:true});blocked.command({name:'play'});
async function checkAsync(){
  await Promise.resolve();
  assert(blocked.messages.some(m=>m.name==='bridgeError'&&m.value.reason==='play-rejected'),'blocked autoplay asks native to reveal original controls');
  blocked.dom.window.close();
  for(const rejected of [false,true]){
    const pending=fixture({deferredPiP:true});pending.command({name:'play'});pending.command({name:'pip',requestID:'slow'});
    pending.command({name:'pipStop'});
    const later=pending.w.Date.now()+5000;pending.w.Date.now=()=>later;pending.timers[0]();
    assert(!pending.messages.some(m=>m.name==='pipState'&&m.value.status==='stopped'),'cancel cannot release an unresolved platform PiP request');
    assert.equal(pending.messages.filter(m=>m.name==='mediaState').at(-1).value.pipPending,true,'a polling timeout cannot discard pending ownership');
    pending.completePiP(rejected);await Promise.resolve();
    assert.equal(pending.w.document.pictureInPictureElement,null,'late-start PiP is closed before releasing the decoder');
    assert(pending.messages.some(m=>m.name==='pipState'&&m.value.status==='stopped'&&m.value.requestID==='slow'),'settled rejection or actual leave event acknowledges cancellation');
    assert.equal(pending.messages.filter(m=>m.name==='mediaState').at(-1).value.pipPending,false);
    pending.dom.window.close();
  }
  console.log('PASS: Aether native commands/state, source replacement/removal, scoped viewport, HTML5 tracks, Vietnamese/English preference, original translation controls, real PiP stop/cancel acknowledgement, no-video verification and blocked play');
}
checkAsync().catch(error=>{console.error(error);process.exitCode=1;});
