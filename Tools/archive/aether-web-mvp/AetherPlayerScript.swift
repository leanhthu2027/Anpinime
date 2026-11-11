import Foundation

/// A player-only bridge. No catalog scraping, stream URL interception, native
/// handoff, DRM changes or private Aether/React-store APIs.
enum AetherPlayerScript {
    static let javascript = #"""
    (function(){
      if(window.__anpinimeAetherNativePlayer)return;window.__anpinimeAetherNativePlayer=true;
      var activeVideo=null,automaticPiP=false,originalControls=false;
      var bound=new WeakSet(),savedControls=new WeakMap(),videoSessions=new WeakMap(),surface=null;
      var desiredRate=1,desiredVolume=1,fill=false,lastEnded=false;
      function send(name,value){try{window.webkit.messageHandlers[name].postMessage(value);}catch(e){}}
      function isAdvertisement(v){return !!v.closest('.advertisement,.video-ad,[data-ad="true"]');}
      \#(WebPictureInPictureScript.core)
      // Keep the shared session protocol, but retain an Aether request until the
      // platform has actually settled it. In particular a cancel cannot turn a
      // pending Promise into a fictitious stopped acknowledgement.
      var sharedSyncPiP=syncPiP,sharedStopPiP=stopPiP;
      syncPiP=function(v,c){
        if(c.aetherOutstanding&&!pipActive(v)&&!c.active)return;
        sharedSyncPiP(v,c);
        if(pipActive(v)){
          c.aetherOutstanding=false;
          if(c.aetherCancel){c.aetherCancel=false;sharedStopPiP(v);}
        }
      };
      requestPiP=function(v,input){
        if(!v)return;var c=pipContext(v);input=input||{};syncPiP(v,c);
        if(input.sessionID&&input.sessionID!==c.sessionID)return;
        if(pipActive(v)||c.pendingAt!==null||c.aetherOutstanding)return;
        c.requestID=input.requestID||('legacy-'+(++pipSequence));c.error='';
        var reason=v.paused?'paused':isAdvertisement(v)?'advertisement':!supportsPiP(v)?'unsupported':'';
        if(reason){c.error=reason;pipNotice(c,'error',reason);return;}
        var id=c.requestID;c.pendingAt=Date.now();c.aetherOutstanding=true;c.aetherCancel=false;pipNotice(c,'pending','');
        function current(){return pipContexts.get(v)===c&&c.requestID===id;}
        function settled(rejected){
          if(!current())return;c.aetherOutstanding=false;
          if(c.aetherCancel&&!pipActive(v)){
            c.aetherCancel=false;c.pendingAt=null;c.error='';pipNotice(c,'stopped','');
          }else if(rejected&&!pipActive(v)){
            c.pendingAt=null;c.error='rejected';pipNotice(c,'error',c.error);
          }else syncPiP(v,c);
          state();
        }
        try{
          if(v.webkitSetPresentationMode&&(!v.webkitSupportsPresentationMode||v.webkitSupportsPresentationMode('picture-in-picture'))){
            v.webkitSetPresentationMode('picture-in-picture');syncPiP(v,c);
          }else{
            var p=v.requestPictureInPicture();
            if(p&&p.then)p.then(function(){settled(false);},function(){settled(true);});
            else settled(false);
          }
        }catch(e){settled(true);}
      };
      stopPiP=function(v){
        if(!v)return;var c=pipContext(v);
        if(c.aetherOutstanding&&!pipActive(v)){
          c.aetherCancel=true;return;
        }
        sharedStopPiP(v);
      };
      var style=document.createElement('style');style.id='anpinime-aether-native-controls';
      // Streambert's Aether rule supplies the navigation selectors. Buttons and
      // sliders are reversibly hidden only while Anpinime owns the controls;
      // caption nodes, loaders, verification and original event handlers remain.
      style.textContent='html[data-anpinime-aether-native="true"],html[data-anpinime-aether-native="true"] body{margin:0!important;overflow:hidden!important;background:#000!important;}'+
        'html[data-anpinime-aether-native="true"] [data-anpinime-aether-surface="true"]{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;margin:0!important;}'+
        'html[data-anpinime-aether-native="true"] [data-anpinime-aether-surface="true"] video{width:100%!important;height:100%!important;max-height:none!important;object-fit:contain;}'+
        'html[data-anpinime-aether-native="true"] .top-content,'+
        'html[data-anpinime-aether-native="true"] a.tabbable[class*="cancelHover"],'+
        'html[data-anpinime-aether-native="true"] button,'+
        'html[data-anpinime-aether-native="true"] [role="button"],'+
        'html[data-anpinime-aether-native="true"] input[type="range"],'+
        'html[data-anpinime-aether-native="true"] [role="slider"]{visibility:hidden!important;pointer-events:none!important;}';
      (document.head||document.documentElement).appendChild(style);
      if(!document.querySelector('meta[name="viewport"]')){var viewport=document.createElement('meta');viewport.name='viewport';viewport.content='width=device-width,initial-scale=1';(document.head||document.documentElement).appendChild(viewport);}
      function controls(visible){
        originalControls=visible;
        document.documentElement.setAttribute('data-anpinime-aether-native',visible||!activeVideo||activeVideo.readyState<1?'false':'true');
        // Resize the existing player wrapper; never move the video or remove
        // sibling caption/translation renderers. Original mode is reversible.
        if(!activeVideo||(!pipActive(activeVideo)&&!pipPending(activeVideo))){
          var next=activeVideo&&(activeVideo.closest('[data-player],.video-player,.player-container,#player')||activeVideo.parentElement);
          if(surface&&surface!==next)surface.removeAttribute('data-anpinime-aether-surface');
          surface=next;if(surface)surface.setAttribute('data-anpinime-aether-surface','true');
        }
        document.querySelectorAll('video').forEach(function(v){
          if(!savedControls.has(v))savedControls.set(v,v.controls);
          if(!pipActive(v)&&!pipPending(v))v.controls=visible?savedControls.get(v):false;
        });
      }
      function list(xs){try{return Array.from(xs||[]);}catch(e){return [];}}
      function trackState(v,c){
        var audio=list(v.audioTracks),subtitles=list(v.textTracks).filter(function(t){return t.kind==='subtitles'||t.kind==='captions';});
        function label(t,index,prefix){return t.label||t.language||(prefix+' '+(index+1));}
        return {audio:audio.map(function(t,i){return {id:c.sessionID+':audio:'+i,title:label(t,i,'Âm thanh')};}),
          audioID:audio.reduce(function(id,t,i){return t.enabled?c.sessionID+':audio:'+i:id;},''),
          subtitles:subtitles.length?[{id:'off',title:'Tắt'}].concat(subtitles.map(function(t,i){return {id:c.sessionID+':sub:'+i,title:label(t,i,'Phụ đề')};})):[],
          subtitleID:subtitles.reduce(function(id,t,i){return t.mode==='showing'?c.sessionID+':sub:'+i:id;},'off')};
      }
      function state(){
        var v=activeVideo;if(!v)return;var c=pipContext(v);syncPiP(v,c);
        var previousSession=videoSessions.get(v);
        if(previousSession&&previousSession!==c.sessionID)c.replacesSession=previousSession;
        videoSessions.set(v,c.sessionID);
        var rect=v.getBoundingClientRect();
        var ended=!!v.ended;
        send('mediaState',{pipSessionID:c.sessionID,pipRequestID:c.requestID,pipSupported:supportsPiP(v),pipActive:pipActive(v),pipPending:pipPending(v),pipError:c.error,
          time:isFinite(v.currentTime)?v.currentTime:0,duration:isFinite(v.duration)?v.duration:0,
          paused:v.paused,ready:v.readyState>=2,buffering:!v.paused&&v.readyState<3,ended:ended,rate:v.playbackRate,volume:v.volume,
          videoWidth:v.videoWidth||0,videoHeight:v.videoHeight||0,tracks:trackState(v,c),
          area:Math.max(0,rect.width*rect.height),originalControls:originalControls,replacesSession:c.replacesSession||''});
        lastEnded=ended;
      }
      function bind(v){
        if(bound.has(v))return;bound.add(v);if(!savedControls.has(v))savedControls.set(v,v.controls);
        if(!originalControls)v.controls=false;
        v.playbackRate=desiredRate;v.volume=desiredVolume;
        ['playing','pause','loadedmetadata','loadeddata','waiting','ended','durationchange','timeupdate','ratechange','volumechange','enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged'].forEach(function(name){
          v.addEventListener(name,function(){if(pipActive(v)||!activeVideo||(!pipActive(activeVideo)&&!pipPending(activeVideo)&&!v.paused))activeVideo=v;state();});
        });
        ['audioTracks','textTracks'].forEach(function(name){var xs=v[name];if(xs&&xs.addEventListener)xs.addEventListener('change',state);});
      }
      function observe(){
        if(!window.document)return;
        var previous=activeVideo;
        var videos=list(document.querySelectorAll('video')).filter(function(v){return !isAdvertisement(v);});
        if(previous&&!videos.includes(previous)&&!pipActive(previous)&&!pipPending(previous)){
          var old=pipContext(previous);send('mediaState',{pipSessionID:videoSessions.get(previous)||old.sessionID,pipRequestID:old.requestID,pipSupported:false,pipActive:false,pipPending:false,paused:true,ready:false,removed:true});
        }
        videos.forEach(bind);
        if(!activeVideo||(!pipActive(activeVideo)&&!pipPending(activeVideo))){
          var candidates=videos.filter(function(v){return !v.paused&&v.readyState>=2;});
          if(!candidates.length)candidates=videos;
          candidates.sort(function(a,b){var x=a.getBoundingClientRect(),y=b.getBoundingClientRect();return y.width*y.height-x.width*x.height;});
          activeVideo=candidates[0]||null;
        }
        controls(originalControls);
        if(activeVideo&&!activeVideo.__anpinimePreferredSubtitle){
          var subs=list(activeVideo.textTracks).filter(function(t){return t.kind==='subtitles'||t.kind==='captions';});
          var preferred=subs.find(function(t){return /^(vi|vie)(-|$)/i.test(t.language||'');})||subs.find(function(t){return /^(en|eng)(-|$)/i.test(t.language||'');});
          if(preferred){activeVideo.__anpinimePreferredSubtitle=true;subs.forEach(function(t){t.mode=t===preferred?'showing':'disabled';});}
        }
        state();
      }
      function choose(v,c,input){
        var tracks=trackState(v,c);
        if(input.kind==='audio'){
          var option=tracks.audio.findIndex(function(t){return t.id===input.id;});
          if(option<0)return;list(v.audioTracks).forEach(function(t,i){t.enabled=i===option;});
        }else if(input.kind==='subtitles'){
          var option=input.id==='off'?-1:tracks.subtitles.filter(function(t){return t.id!=='off';}).findIndex(function(t){return t.id===input.id;});
          if(input.id!=='off'&&option<0)return;
          list(v.textTracks).filter(function(t){return t.kind==='subtitles'||t.kind==='captions';}).forEach(function(t,i){t.mode=i===option?'showing':'disabled';});
        }
      }
      window.addEventListener('message',function(event){
        var input=event.data;if(!input||input.type!=='AnPinimeCommand')return;
        if(input.name==='websiteControls'){controls(input.value===1);state();}
        if(input.name==='automaticPiP')automaticPiP=input.value===1;
        if(input.name==='endSession')document.querySelectorAll('video').forEach(function(v){stopPiP(v);v.pause();});
        var v=activeVideo,c=v?pipContext(v):null;
        if(v&&input.sessionID&&input.sessionID===c.sessionID){
          try{
            switch(input.name){
              case 'play':var promise=v.play();if(promise&&promise.catch)promise.catch(function(){send('bridgeError',{sessionID:c.sessionID,reason:'play-rejected'});});break;
              case 'pause':v.pause();break;
              case 'seek':if(isFinite(input.value)){var end=isFinite(v.duration)&&v.duration>0?v.duration:Number.MAX_VALUE;v.currentTime=Math.max(0,Math.min(end,input.value));}break;
              case 'rate':if(isFinite(input.value)&&input.value>=0.25&&input.value<=3){desiredRate=input.value;v.playbackRate=desiredRate;}break;
              case 'volume':if(isFinite(input.value)){desiredVolume=Math.max(0,Math.min(1,input.value));v.volume=desiredVolume;}break;
              case 'fit':if(!pipActive(v)&&!pipPending(v)){fill=input.value===1;v.style.objectFit=fill?'cover':'contain';}break;
              case 'track':choose(v,c,input);break;
              case 'pip':requestPiP(v,input);break;
              case 'pipStop':stopPiP(v);break;
              case 'owner':document.querySelectorAll('video').forEach(function(other){if(other!==v&&!pipActive(other)&&!pipPending(other))other.pause();});break;
            }
            state();
          }catch(error){send('bridgeError',{sessionID:c.sessionID,reason:'command-failed'});}
        }else if(input.name==='owner'&&v&&!pipActive(v)&&!pipPending(v)){v.pause();}
        // Each document accepts commands only for its negotiated video identity.
        document.querySelectorAll('iframe').forEach(function(frame){try{frame.contentWindow.postMessage(input,'*');}catch(e){}});
      });
      controls(false);
      new MutationObserver(observe).observe(document.documentElement,{childList:true,subtree:true});
      setInterval(observe,500);observe();
    })();
    """#
}
