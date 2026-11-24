"use strict";
// Read-only candidate verification and in-memory scheduler alternatives.
// Run on pinned #84/#87 browser source; never patch tracked production.
function load(s,exports){const m={exports:{}};new Function("module",s+"\nmodule.exports="+exports+";")(m);return m.exports;}
function transform(s,policy){
  if(policy==="actual")return s;
  const R=(a,b)=>{if(s.split(a).length!==2)throw Error("Anchor mismatch: "+a);s=s.replace(a,b);};
  R("let touchQueue=[],touchSent=false;","let touchQueue=[],touchSent=false,paceTimer=null;");
  R("clearDeadline();if(timer!==null)","if(paceTimer!==null)clearTimeout(paceTimer);paceTimer=null;clearDeadline();if(timer!==null)");
  R("if(pending)return;\n    // Release","if(pending)return;\n    // Bound sends before dequeue, including releases.\n    if(now-lastSend<13){if(paceTimer===null)paceTimer=setTimeout(()=>{paceTimer=null;tick();},13-(now-lastSend));return;}\n    // Release");
  for(const [q,last,send] of [["pedalQueue","lastPedalSend","sendPedals"],["pianoQueue","lastPianoSend","sendPiano"],["drumQueue","lastDrumSend","sendDrum"]]){
    const tail=",run:()=>"+send+"("+q+".shift()";
    R("ready.push({last:"+last+tail,"ready.push({last:"+last+",edge:"+q+"[0].at"+tail);
  }
  // Explicit emergency releases and sensor stop retain original priority.
  // Ordinary XY release is ranked with all other ordinary queued edges, but
  // cannot overtake its own onset (one FIFO).
  if(policy==="releaseAware"){
    const originalRelease='if(pedalEmergency){pedalEmergency=false;sendPedals({mask:0,levels:[0,0,0,0,0,0]});return;}\n    if(pianoEmergency){pianoEmergency=false;sendPiano(0);return;}\n    if(drumEmergency){drumEmergency=false;sendDrum(0);return;}\n    if(touchQueue[0]?.kind==="release"){sendTouchEdge();return;}\n    if(mode==="releasing"){send("motionRelease");return;}\n    const releasing=streams.find(s=>s.mode==="releasing");\n    if(releasing){send(releasing.kind+"Release");return;}';
    const rankedRelease='const releases=[];const due=last=>Number.isFinite(last)?last+300:now;\n    if(pedalEmergency)releases.push({due:due(lastPedalSend),run:()=>{pedalEmergency=false;sendPedals({mask:0,levels:[0,0,0,0,0,0]});}});\n    if(pianoEmergency)releases.push({due:due(lastPianoSend),run:()=>{pianoEmergency=false;sendPiano(0);}});\n    if(drumEmergency)releases.push({due:due(lastDrumSend),run:()=>{drumEmergency=false;sendDrum(0);}});\n    if(touchQueue[0]?.kind==="release")releases.push({due:Math.min(due(lastTouchSend),touchQueue[0].at+150),run:sendTouchEdge});\n    if(mode==="releasing")releases.push({due:due(lastTiltSend),run:()=>send("motionRelease")});\n    for(const s of streams)if(s.mode==="releasing")releases.push({due:due(s.last),run:()=>send(s.kind+"Release")});\n    if(releases.length){releases.reduce((a,b)=>a.due<=b.due?a:b).run();return;}';
    R(originalRelease,rankedRelease);
  }else R('if(touchQueue[0]?.kind==="release"){sendTouchEdge();return;}','');
  R("if(touchQueue.length)ready.push({last:lastTouchSend,run:sendTouchEdge});","if(touchQueue.length)ready.push({last:lastTouchSend,edge:touchQueue[0].at,run:sendTouchEdge});");
  R("ready.push({last:-Infinity,run:()=>{\n      neutral","ready.push({last:-Infinity,arm:waitingSince,run:()=>{\n      neutral");
  R("ready.push({last:-Infinity,run:()=>{\n        s.sent","ready.push({last:-Infinity,arm:s.waiting,run:()=>{\n        s.sent");
  R('syncControls();if(pedalEmergency||pedalQueue.length||pedalDirty||pianoEmergency||pianoQueue.length||drumEmergency||drumQueue.length||touchQueue.length||mode==="releasing"||streams.some(s=>s.mode==="releasing"))tick();','syncControls();tick();');
  // Same 150 ms age for all discrete transitions. Finite arm timestamps
  // avoid starvation; guarded variant raises near-watchdog refresh priority.
  const rank=policy!=="guarded"
    ?'x=>[x.edge!==undefined?0:x.arm!==undefined?1:2,x.edge??x.arm??x.last]'
    :'x=>x.edge!==undefined?[0,x.edge+150]:x.arm!==undefined?[now-x.arm>=150?0:1,x.arm+150]:now-x.last>=225?[0,x.last+250]:[2,x.last]';
  R("if(ready.length){ready.reduce((a,b)=>a.last<b.last?a:b).run();return;}",
    "if(ready.length){const rank="+rank+";ready.reduce((a,b)=>{const x=rank(a),y=rank(b);return x[0]<y[0]||(x[0]===y[0]&&x[1]<=y[1])?a:b;}).run();return;}");
  for(const anchor of ["wait(220)","now-touchQueue[0].at>=150","now-drumQueue[0].at>=150","now-pianoQueue[0].at>=150","now-pedalQueue[0].at>=150","now-sampleAt>=250","setInterval(tick,25)","Touch cancelled. Reconnect explicitly."])
    if(!s.includes(anchor))throw Error("Safety anchor missing: "+anchor);
  return s;
}
const ptr=(id,x=25,y=25)=>({pointerId:id,button:0,clientX:x,clientY:y,preventDefault(){}});
async function lifecycle(h,script,execute){
  const results=[];
  function record(name,a,ok,extra={}){results.push({name,pass:!!ok,closed:a.closed,wire:a.received.filter(x=>["touch","release"].includes(x.f.kind)).map(x=>x.f),...extra});}
  const make=(options={rtt:60})=>{const a=h.setup(script,execute,options);a.c.run(100);return a;};
  for(const blocker of ["drumPads","pianoKeys","pedalboard","orientation","acceleration","rotation"]){
    const a=make();
    if(["drumPads","pianoKeys","pedalboard"].includes(blocker)){
      const [enable,control]=({drumPads:["drumEnable","drum0"],pianoKeys:["pianoEnable","piano0"],pedalboard:["pedalEnable","pedalToggle3"]})[blocker];
      a.el(enable).emit("click");a.el(control).emit(blocker==="pedalboard"?"click":"pointerdown",ptr(1));
    }else{
      await a.el({orientation:"motionStart",acceleration:"accelStart",rotation:"rotationStart"}[blocker]).emit("click");
      const sense=()=>{a.window.emit("deviceorientation",{alpha:0,beta:10,gamma:0});a.window.emit("devicemotion",{acceleration:{x:2,y:0,z:0},rotationRate:{alpha:10,beta:0,gamma:0}});};
      sense();a.c.add(sense,10,10);a.c.run(25);
    }
    a.c.run(5);a.el("pad").emit("pointerdown",ptr(2));a.c.run(10);a.el("pad").emit("pointerup",ptr(2));a.c.run(250);
    const wire=a.received.filter(x=>["touch","release"].includes(x.f.kind));
    record("tap behind "+blocker,a,!a.closed&&wire.length===2&&wire[0].f.kind==="touch"&&wire[1].f.kind==="release");
  }
  for(const event of ["pointercancel","lostpointercapture","orientationchange","pagehide"]){
    const a=make();a.el("pianoEnable").emit("click");a.el("piano0").emit("pointerdown",ptr(1));a.el("pad").emit("pointerdown",ptr(2));
    if(event.startsWith("pointer")||event==="lostpointercapture")a.el("pad").emit(event,ptr(2));else a.window.emit(event);
    a.c.run(250);record("queued onset "+event,a,a.closed&&a.host.active.size===0&&!a.received.some(x=>x.f.kind==="touch"));
  }
  {
    const a=make({rtt:20});a.el("pianoEnable").emit("click");a.el("piano0").emit("pointerdown",ptr(1));
    for(let i=0;i<2;i++){a.el("pad").emit("pointerdown",ptr(i+2,20+i*10));a.c.run(3);a.el("pad").emit("pointermove",ptr(i+2,80));a.el("pad").emit("pointerup",ptr(i+2));a.el("pad").emit("lostpointercapture",ptr(i+2));}
    a.c.run(250);const w=a.received.filter(x=>["touch","release"].includes(x.f.kind)).map(x=>x.f);
    record("two completed taps, post-up lost capture",a,!a.closed&&w.map(x=>x.kind).join(",")==="touch,release,touch,release"&&w[0].x===.2&&w[2].x===.3);
  }
  for(const type of ["overflow","stale","missingAck"]){
    const a=make({rtt:10,drop:f=>type==="missingAck"?f.kind==="touch":f.kind==="pianoKeys"});
    const at=a.c.now;
    if(type==="missingAck")a.el("pad").emit("pointerdown",ptr(1));
    else{a.el("pianoEnable").emit("click");a.el("piano0").emit("pointerdown",ptr(1));for(let i=0;i<(type==="overflow"?5:1);i++){a.el("pad").emit("pointerdown",ptr(i+2));a.el("pad").emit("pointerup",ptr(i+2));}}
    a.c.run(300);const reason=({overflow:"Touch input backlog",stale:"Touch input delayed",missingAck:"Connection timed out"})[type];
    record(type,a,a.closed?.status.includes(reason)&&a.host.active.size===0&&(type==="missingAck"?a.closed.at-at===220:!a.received.some(x=>x.f.kind==="touch")),{elapsed:a.closed?.at-at});
  }
  return results;
}
async function run(source,inherited,experiment,execute,policies=["actual","oldest","guarded","releaseAware"]){
  const e=load(experiment,"{helpers,scenario,profiles,names,combinations}"),h=e.helpers(inherited);
  const original=h.extract(source),rows=[],faults={};
  for(const policy of policies){
    const script=transform(original,policy);
    for(const [profile,options] of Object.entries(e.profiles))
      for(const [combo,selected] of Object.entries(e.combinations))
        for(const workload of ["hold","burst"])rows.push({policy,profile,combo,...await e.scenario(h,script,execute,options,selected,workload)});
    faults[policy]=await lifecycle(h,script,execute);
  }
  const summary={};
  for(const policy of policies){
    summary[policy]={};
    for(const profile of Object.keys(e.profiles)){
      const q=rows.filter(x=>x.policy===policy&&x.profile===profile);summary[policy][profile]={passed:q.filter(x=>x.pass).length,total:q.length,seven:q.filter(x=>x.combo==="seven").map(x=>({workload:x.workload,pass:x.pass,maxGap:x.maxGap,missing:x.missing,closed:x.closed?.status??null}))};
    }
  }
  return {summary,faults,rows};
}
async function subsets(source,inherited,experiment,execute,policy){
  const e=load(experiment,"{helpers,scenario,profiles,names}"),h=e.helpers(inherited),script=transform(h.extract(source),policy),rows=[];
  for(let mask=1;mask<128;mask++){
    const selected=e.names.filter((_,i)=>mask&(1<<i));
    for(const [profile,options] of Object.entries(e.profiles)){
      const hold=await e.scenario(h,script,execute,options,selected,"hold"),burst=await e.scenario(h,script,execute,options,selected,"burst");
      rows.push({mask,profile,hold:hold.pass,burst:burst.pass,gap:hold.maxGap,missing:hold.missing+burst.missing,holdClosed:hold.closed?.status??null,burstClosed:burst.closed?.status??null});
    }
  }
  const summary=Object.fromEntries(Object.keys(e.profiles).map(p=>{const q=rows.filter(x=>x.profile===p);return [p,{hold:q.filter(x=>x.hold).length,burst:q.filter(x=>x.burst).length,both:q.filter(x=>x.hold&&x.burst).length}]}));
  return {policy,summary,rows};
}
if(typeof module!=="undefined")module.exports={run,subsets};
if(typeof require!=="undefined"&&typeof module!=="undefined"&&require.main===module){
  const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
  if(!process.argv[2])throw Error("Pass exact #84 or #87 RemoteLoopbackPageServer.swift");
  const args=[fs.readFileSync(process.argv[2],"utf8"),fs.readFileSync(path.join(__dirname,"stress.cjs"),"utf8"),fs.readFileSync(path.join(__dirname,"capacity-experiments.cjs"),"utf8"),(s,g)=>vm.runInNewContext(s,g)];
  (process.argv[3]?subsets(...args,process.argv[3]):run(...args)).then(x=>console.log(JSON.stringify(x,null,2))).catch(e=>{console.error(e);process.exitCode=2;});
}
