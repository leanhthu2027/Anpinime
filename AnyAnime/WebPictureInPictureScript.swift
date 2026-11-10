import Foundation

/// Shared, session/request-scoped protocol, extracted from the 2.9.4 player.
/// Callers provide send/state, activeVideo, automaticPiP and isAdvertisement.
enum WebPictureInPictureScript {
    static let core = """
          function supportsPiP(v){
            if(!v||v.disablePictureInPicture)return false;
            try{return !!((v.webkitSetPresentationMode&&(!v.webkitSupportsPresentationMode||v.webkitSupportsPresentationMode('picture-in-picture')))||(v.requestPictureInPicture&&document.pictureInPictureEnabled&&!v.disablePictureInPicture));}catch(e){return false;}
          }
          var pipContexts=new WeakMap(),pipSequence=0;
          var pipDocumentID=Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);
          function pipActive(v){return !!v&&(v.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===v);}
          function pipContext(v){
            var source=v.currentSrc||v.getAttribute('src')||'',c=pipContexts.get(v);
            if(!c||(c.source!==source&&!pipActive(v)&&c.pendingAt===null&&!c.active)){
              c={sessionID:pipDocumentID+'-'+(++pipSequence),source:source,requestID:'',pendingAt:null,active:false,error:''};pipContexts.set(v,c);
            }
            return c;
          }
          function pipNotice(c,status,error){send('pipState',{sessionID:c.sessionID,requestID:c.requestID,status:status,error:error||''});}
          function syncPiP(v,c){
            if(pipContexts.get(v)!==c)return;
            if(pipActive(v)){
              if(!c.active||c.pendingAt!==null){c.active=true;c.pendingAt=null;c.error='';pipNotice(c,'active','');}
            }else if(c.active){c.active=false;c.pendingAt=null;c.error='';pipNotice(c,'stopped','');}
            else if(c.pendingAt!==null&&Date.now()-c.pendingAt>=1500){c.pendingAt=null;c.error='timeout';pipNotice(c,'error',c.error);}
          }
          function pipPending(v){if(!v)return false;var c=pipContext(v);syncPiP(v,c);return c.pendingAt!==null&&!pipActive(v);}
          function requestPiP(v,command){
            if(!v)return;
            var c=pipContext(v),input=command||{};syncPiP(v,c);
            // Native commands are broadcast to child frames. A different
            // document must never acknowledge another session's request.
            if(input.sessionID&&input.sessionID!==c.sessionID)return;
            // Coalesce repeated bridge/manual requests without replacing the
            // identity that owns the asynchronous presentation.
            if(pipActive(v)||c.pendingAt!==null)return;
            c.requestID=input.requestID||('legacy-'+(++pipSequence));c.error='';
            var reason=v.paused?'paused':isAdvertisement(v)?'advertisement':input.name==='pipAutomatically'&&!automaticPiP?'automatic-disabled':!supportsPiP(v)?'unsupported':'';
            if(reason){c.error=reason;pipNotice(c,'error',reason);return;}
            var id=c.requestID;c.pendingAt=Date.now();pipNotice(c,'pending','');
            function current(){return pipContexts.get(v)===c&&c.requestID===id&&activeVideo===v;}
            function failed(){if(!current()||c.pendingAt===null)return;c.pendingAt=null;c.error='rejected';pipNotice(c,'error',c.error);state();}
            try{
              if(v.webkitSetPresentationMode&&(!v.webkitSupportsPresentationMode||v.webkitSupportsPresentationMode('picture-in-picture')))v.webkitSetPresentationMode('picture-in-picture');
              else {var p=v.requestPictureInPicture();if(p&&p.then)p.then(function(){if(current()){syncPiP(v,c);state();}},failed);}
              syncPiP(v,c);
              setTimeout(function(){if(current()){syncPiP(v,c);state();}},1500);
            }catch(e){failed();}
          }
          function stopPiP(v){
            if(!v)return;var c=pipContext(v),wasPending=c.pendingAt!==null;c.pendingAt=null;c.error='';
            try{
              if(v.webkitPresentationMode==='picture-in-picture'&&v.webkitSetPresentationMode)v.webkitSetPresentationMode('inline');
              else if(document.pictureInPictureElement===v&&document.exitPictureInPicture){var p=document.exitPictureInPicture();if(p&&p.catch)p.catch(function(){});}
            }catch(e){}
            syncPiP(v,c);if(wasPending&&!pipActive(v))pipNotice(c,'stopped','stopped');
          }
    """
}
