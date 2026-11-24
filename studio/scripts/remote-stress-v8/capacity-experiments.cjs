"use strict";
// R9-PERF2: isolated in-memory browser scheduler experiments.
// Original source, inherited harness, production deadlines and files are unchanged.
const names=["touch","orientation","acceleration","rotation","drumPads","pianoKeys","pedalboard"];
const profiles={rtt5:{rtt:5},rtt20:{rtt:20},rtt40:{rtt:40},rtt60:{rtt:60},jitter20:{rtt:20,jitter:10},jitter40:{rtt:40,jitter:15}};
const ptr=id=>({pointerId:id,button:0,clientX:25,clientY:25,preventDefault(){}});
function replaceOnce(s,a,b){if(s.split(a).length!==2)throw Error("Unexpected frozen anchor: "+a);return s.replace(a,b);}
function variant(s,policy){
  if(policy==="frozen")return s;
  const R=(a,b)=>{s=replaceOnce(s,a,b);};
  // Queue XY onsets and releases in order, coalesce movement only while held.
  R('let caps=null;','let caps=null;let touchEdges=[];');
  R('releaseDue=false;\n    clearDeadline();','releaseDue=false;touchEdges=[];\n    clearDeadline();');
  R('if(drumQueue.length&&now-drumQueue[0].at>=150)', 'if(touchEdges.length&&now-touchEdges[0].at>=150){close("Touch input delayed. Reconnect explicitly.");return;}\n    if(drumQueue.length&&now-drumQueue[0].at>=150)');
  R('if(releaseDue){releaseDue=false;send("release");return;}','if(touchEdges[0]?.kind==="release"){touchEdges.shift();send("release");return;}');
  R('if(pointer!==null&&position&&now-lastTouchSend>=50)ready.push({last:lastTouchSend,run:()=>send("touch",position)});',
    'if(touchEdges.length)ready.push({last:lastTouchSend,edge:touchEdges[0].at,run:()=>send("touch",touchEdges.shift().position)});\n    else if(pointer!==null&&position&&now-lastTouchSend>=50)ready.push({last:lastTouchSend,run:()=>send("touch",position)});');
  R('if(!admitted||!caps?.touch||pointer!==null||releaseDue||e.button!==0)return;',
    'if(!admitted||!caps?.touch||pointer!==null||e.button!==0)return;');
  R('lastTouchSend=-Infinity;move(e);syncControls();tick();',
    'move(e);if(!position){close("Invalid touch geometry.");return;}if(touchEdges.length>=8){close("Touch input backlog.");return;}touchEdges.push({kind:"touch",position:{...position},at:performance.now()});syncControls();tick();');
  R('pointer=null;position=null;dot.hidden=true;releaseDue=true;syncControls();tick();',
    'pointer=null;position=null;dot.hidden=true;if(touchEdges.length>=8){close("Touch input backlog.");return;}touchEdges.push({kind:"release",at:performance.now()});syncControls();tick();');
  R('if(pointer===null&&pedalSentMask===0','if(pointer===null&&!touchEdges.length&&pedalSentMask===0');
  for(const [q,last,send] of [["pedalQueue","lastPedalSend","sendPedals"],["pianoQueue","lastPianoSend","sendPiano"],["drumQueue","lastDrumSend","sendDrum"]]){
    const tail=",run:()=>"+send+"("+q+".shift()";
    R("ready.push({last:"+last+tail,"ready.push({last:"+last+",edge:"+q+"[0].at"+tail);
  }
  // ACK-driven work conservation; the original 25/50 ms eligibility remains.
  R('syncControls();if(pedalEmergency||pedalQueue.length||pedalDirty||pianoEmergency||pianoQueue.length||drumEmergency||drumQueue.length||releaseDue||mode==="releasing"||streams.some(s=>s.mode==="releasing"))tick();','syncControls();tick();');
  const rank=policy!=="deadlineAware"
    ?'x=>[x.edge===undefined?1:0,x.edge??x.last]'
    // 250 ms target for refresh prioritization gives headroom under 350 ms
    // watchdog; not a safety deadline change. Arms have no active ownership.
    :'x=>[0,x.edge!==undefined?x.edge+150:Number.isFinite(x.last)?x.last+250:Infinity]';
  R('if(ready.length){ready.reduce((a,b)=>a.last<b.last?a:b).run();return;}',
    'if(ready.length){const rank='+rank+';ready.reduce((a,b)=>{const x=rank(a),y=rank(b);return x[0]<y[0]||(x[0]===y[0]&&x[1]<y[1])?a:b;}).run();return;}');
  if(policy==="pacedEdgeFirst"){
    R("let caps=null;let touchEdges=[];","let caps=null;let touchEdges=[];let paceTimer=null;");
    R("clearDeadline();if(timer!==null)","if(paceTimer!==null)clearTimeout(paceTimer);paceTimer=null;clearDeadline();if(timer!==null)");
    R("if(pending)return;\n    // Release", "if(pending)return;\n    // Bound all sends to <=77 per second, including releases. No queue is popped while waiting.\n    if(now-lastSend<13){if(paceTimer===null)paceTimer=setTimeout(()=>{paceTimer=null;tick();},13-(now-lastSend));return;}\n    // Release");
  }
  // Assert the existing deadlines are still present. No changes to host policy.
  for(const anchor of ['wait(220)','now-drumQueue[0].at>=150','now-pianoQueue[0].at>=150','now-pedalQueue[0].at>=150','now-sampleAt>=250','setInterval(tick,25)'])
    if(!s.includes(anchor))throw Error("Safety anchor lost: "+anchor);
  return s;
}
function helpers(inherited){
  const mod={exports:{}};
  // Inherited harness is evaluated unchanged, with additional exports only.
  new Function("module",inherited+'\nmodule.exports={setup,extract,kindOf,isRelease,stats};')(mod);
  return mod.exports;
}
function setupSensors(a,selected){
  if(selected.includes("orientation"))a.window.emit("deviceorientation",{alpha:0,beta:10,gamma:0});
  if(selected.includes("acceleration")||selected.includes("rotation"))a.window.emit("devicemotion",{acceleration:{x:2,y:0,z:0},rotationRate:{alpha:10,beta:0,gamma:0}});
}
const edgeKinds=["touch","drumPads","pianoKeys","pedalboard"];
function edges(a,kind,on,id=1){
  const el=a.el;
  if(kind==="touch")el("pad").emit(on?"pointerdown":"pointerup",ptr(id));
  if(kind==="drumPads")el("drum0").emit(on?"pointerdown":"pointerup",ptr(id));
  if(kind==="pianoKeys")el("piano0").emit(on?"pointerdown":"pointerup",ptr(id));
  if(kind==="pedalboard")el("pedalToggle3").emit("click");
}
function edgeState(f){return f.kind==="touch"?1:f.kind==="release"?0:f.mask?1:0;}
async function scenario(h,script,execute,profile,selected,workload){
  const a=h.setup(script,execute,profile);a.c.run(350);
  if(a.admittedAt===null)throw Error("admission failed");
  for(const [k,id] of [["orientation","motionStart"],["acceleration","accelStart"],["rotation","rotationStart"]])
    if(selected.includes(k))await a.el(id).emit("click");
  setupSensors(a,selected);a.c.add(()=>setupSensors(a,selected),10,10);
  for(const [k,id] of [["drumPads","drumEnable"],["pianoKeys","pianoEnable"],["pedalboard","pedalEnable"]])
    if(selected.includes(k))a.el(id).emit("click");
  const start=a.c.now,expected=Object.fromEntries(selected.filter(k=>edgeKinds.includes(k)).map(k=>[k,[]]));
  function emit(on,id){for(const k of Object.keys(expected)){expected[k].push({state:on?1:0,at:a.c.now});edges(a,k,on,id);}}
  if(workload==="hold"){
    emit(true,1);a.c.run(1600);
  }else{
    // Eight simultaneous short gestures (15 ms), 250 ms cycle spacing.
    for(let i=0;i<8&&!a.closed;i++){emit(true,i+1);a.c.run(15);if(!a.closed)emit(false,i+1);a.c.run(235);}
  }
  const holdEnd=a.closed?.at??a.c.now;
  if(!a.closed){
    if(workload==="hold")emit(false,1);
    for(const [k,id] of [["orientation","motionStop"],["acceleration","accelStop"],["rotation","rotationStop"]])
      if(selected.includes(k))a.el(id).emit("click");
    a.c.run(500);
  }
  const perEdge={};
  for(const [kind,want] of Object.entries(expected)){
    let prior=0;const got=a.received.filter(x=>h.kindOf(x.f.kind)===kind).filter(x=>{const next=edgeState(x.f);if(next===prior)return false;prior=next;return true;});
    let matched=0;const delays=[];
    for(let i=0;i<Math.min(want.length,got.length);i++){if(edgeState(got[i].f)!==want[i].state||got[i].at<want[i].at)break;matched++;delays.push(got[i].at-want[i].at);}
    perEdge[kind]={expected:want.length,observed:got.length,matched,missed:want.length-matched,latency:h.stats(delays)};
  }
  const service={};
  for(const k of selected){
    const times=a.received.filter(x=>x.at<=holdEnd&&h.kindOf(x.f.kind)===k&&!h.isRelease(x.f)).map(x=>x.at);
    // Burst edge streams intentionally idle between gestures; do not use their
    // inter-onset intervals as watchdog measurements.
    service[k]={count:times.length,maxGap:times.length>1?Math.max(...times.slice(1).map((t,i)=>t-times[i])):null,
      tail:times.length?holdEnd-times.at(-1):null,first:times.length?times[0]-start:null};
  }
  const continuous=selected.filter(k=>workload==="hold"||!edgeKinds.includes(k));
  const missing=Object.values(perEdge).reduce((n,x)=>n+x.missed,0);
  const unexpected=Object.values(perEdge).reduce((n,x)=>n+Math.max(0,x.observed-x.expected),0);
  const gaps=continuous.map(k=>Math.max(service[k].maxGap??0,service[k].tail??0));
  const unserved=selected.filter(k=>service[k].count===0);
  const fail=Boolean(a.closed)||a.host.active.size>0||a.maxFlight!==1||missing>0||unexpected>0||unserved.length>0||gaps.some(g=>g>=350);
  return {selected,workload,closed:a.closed,missing,unexpected,maxFlight:a.maxFlight,modelActive:[...a.host.active.keys()],service,perEdge,
    maxGap:gaps.length?Math.max(...gaps):null,ack:h.stats(a.ack.map(x=>x.rtt)),pass:!fail};
}
// Targeted XY cases: gesture during each other kind's outstanding ACK,
// repeated short taps, cancellation and lost capture. Compare actual wire transitions.
async function xyCases(h,script,execute){
  const out=[];
  for(const blocker of ["drumPads","pianoKeys","pedalboard","orientation","acceleration","rotation"]){
    const a=h.setup(script,execute,{rtt:60});a.c.run(350);
    if(edgeKinds.includes(blocker)){
      a.el({drumPads:"drumEnable",pianoKeys:"pianoEnable",pedalboard:"pedalEnable"}[blocker]).emit("click");edges(a,blocker,true);
    }else{
      await a.el({orientation:"motionStart",acceleration:"accelStart",rotation:"rotationStart"}[blocker]).emit("click");setupSensors(a,[blocker]);a.c.add(()=>setupSensors(a,[blocker]),10,10);a.c.run(25);
    }
    a.c.run(5);a.el("pad").emit("pointerdown",ptr(10));a.c.run(10);a.el("pad").emit("pointerup",ptr(10));a.c.run(180);
    const wire=a.received.filter(x=>["touch","release"].includes(x.f.kind)).map(x=>x.f.kind);
    out.push({case:"pending-"+blocker,wire,closed:a.closed,pass:wire.join(",")==="touch,release"&&!a.closed});
  }
  for(const end of ["pointerup","pointercancel","lostpointercapture"]){
    const a=h.setup(script,execute,{rtt:20});a.c.run(350);a.el("pianoEnable").emit("click");edges(a,"pianoKeys",true);
    for(let i=0;i<2;i++){a.el("pad").emit("pointerdown",ptr(i+10));a.c.run(3);a.el("pad").emit(end,ptr(i+10));a.c.run(2);}
    a.c.run(200);
    const wire=a.received.filter(x=>["touch","release"].includes(x.f.kind)).map(x=>x.f.kind);
    out.push({case:"two-taps-"+end,wire,closed:a.closed,pass:wire.join(",")==="touch,release,touch,release"&&!a.closed});
  }
  // A bounded queue must disconnect under overload, not silently discard onset.
  const a=h.setup(script,execute,{rtt:60});a.c.run(350);a.el("pianoEnable").emit("click");edges(a,"pianoKeys",true);
  for(let i=0;i<6;i++){a.el("pad").emit("pointerdown",ptr(i+20));a.el("pad").emit("pointerup",ptr(i+20));}
  a.c.run(250);out.push({case:"touch-overflow",closed:a.closed,modelActive:[...a.host.active.keys()],pass:Boolean(a.closed)&&a.host.active.size===0});
  return out;
}
// Model only. Reserve physical source slots before assigning remote capacity.
class Budget{
  constructor(localReserve){if(!Number.isInteger(localReserve)||localReserve<0||localReserve>5)throw Error("invalid local reserve");this.localReserve=localReserve;this.peers=new Map();}
  get used(){return [...this.peers.values()].reduce((n,s)=>n+s.size,0);}
  reserve(peer,streams){
    if(!Array.isArray(streams)||new Set(streams).size!==streams.length||streams.some(s=>!names.includes(s)))return false;
    if(!this.peers.has(peer)&&this.peers.size>=4)return false;
    const old=this.peers.get(peer)??new Set(),next=new Set([...old,...streams]);
    if(this.used-old.size+next.size+this.localReserve>16)return false;
    this.peers.set(peer,next);return true;
  }
  // Call only after confirmed host release; pending release retains reservation.
  release(peer,streams){const p=this.peers.get(peer);if(!p)return;for(const s of streams)p.delete(s);}
  disconnect(peer){this.peers.delete(peer);}
}
function resource(){
  const cases=[];
  for(const local of [0,1,3,5]){
    for(const request of [[7,7,7],[7,4,1],[4,4,4,4],[2,2,2,2],[7,7,0,0,0]]){
      const b=new Budget(local),accepted=[];
      for(let i=0;i<request.length;i++)accepted.push(b.reserve("p"+i,names.slice(0,request[i])));
      cases.push({local,request,accepted,used:b.used,peers:b.peers.size,invariant:b.used+local<=16&&b.peers.size<=4});
    }
  }
  const b=new Budget(5);b.reserve("a",names);b.reserve("b",names.slice(0,4));
  const before=b.used,denied=b.reserve("c",["touch"]),unchanged=b.used===before&&!b.peers.has("c");
  b.release("a",["touch"]);const afterConfirmed=b.reserve("c",["touch"]);b.disconnect("a");
  return {cases,atomicDenial:!denied&&unchanged,afterConfirmed,usedAfterDisconnect:b.used,localReserve:5};
}
const combinations={
  touch:["touch"],piano:["pianoKeys"],drum:["drumPads"],pedal:["pedalboard"],tilt:["orientation"],
  touchTilt:["touch","orientation"],pianoPedal:["pianoKeys","pedalboard"],drumPiano:["drumPads","pianoKeys"],
  touchPianoPedal:["touch","pianoKeys","pedalboard"],inertial:["orientation","acceleration","rotation"],
  drumPianoPedal:["drumPads","pianoKeys","pedalboard"],touchTiltAccel:["touch","orientation","acceleration"],
  four:["touch","orientation","pianoKeys","pedalboard"],five:["touch","orientation","acceleration","pianoKeys","pedalboard"],
  six:["touch","orientation","acceleration","rotation","pianoKeys","pedalboard"],seven:names
};
async function run(source,inherited,execute){
  const h=helpers(inherited),original=h.extract(source),results=[],xy={};
  for(const policy of ["frozen","edgeFirst","deadlineAware","pacedEdgeFirst"]){
    const script=variant(original,policy);
    for(const [profile,options] of Object.entries(profiles))
      for(const [combo,selected] of Object.entries(combinations))
        for(const workload of ["hold","burst"])
          results.push({policy,profile,combo,...await scenario(h,script,execute,options,selected,workload)});
    xy[policy]=await xyCases(h,script,execute);
  }
  const summary={};
  for(const policy of ["frozen","edgeFirst","deadlineAware","pacedEdgeFirst"]){
    summary[policy]={};
    for(const profile of Object.keys(profiles)){
      const subset=results.filter(x=>x.policy===policy&&x.profile===profile);
      summary[policy][profile]={passed:subset.filter(x=>x.pass).length,total:subset.length,
        holdPassed:subset.filter(x=>x.workload==="hold"&&x.pass).map(x=>x.combo),
        burstPassed:subset.filter(x=>x.workload==="burst"&&x.pass).map(x=>x.combo)};
    }
  }
  return {profiles,combinations,summary,xy,resource:resource(),results};
}
if(typeof module!=="undefined")module.exports={run};
if(typeof require!=="undefined"&&typeof module!=="undefined"&&require.main===module){
  const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
  run(fs.readFileSync(process.argv[2]||path.join(__dirname,"../../Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"),"utf8"),
    fs.readFileSync(path.join(__dirname,"stress.cjs"),"utf8"),(s,g)=>vm.runInNewContext(s,g))
    .then(x=>console.log(JSON.stringify(x,null,2))).catch(e=>{console.error(e);process.exitCode=2;});
}
