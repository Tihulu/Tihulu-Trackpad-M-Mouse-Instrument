"use strict";
// Sustained-load and release probe with explicit sender pacing observations.
// Added host delay is a sensitivity variable, not measured parser overhead.
function load(s,exports){const m={exports:{}};new Function("module",s+"\nmodule.exports="+exports+";")(m);return m.exports;}
const ptr=id=>({pointerId:id,button:0,clientX:25,clientY:25,preventDefault(){}});
const combos={motion:["touch","orientation","acceleration"],keys:["pianoKeys","pedalboard"],all:["touch","orientation","acceleration","rotation","drumPads","pianoKeys","pedalboard"]};
function maxWindow(times){let lo=0,max=0;for(let hi=0;hi<times.length;hi++){while(times[hi]-times[lo]>=1000)lo++;max=Math.max(max,hi-lo+1);}return max;}
async function run(source,inherited,experiment,scheduler,execute,policies=["actual","oldest","guarded","releaseAware"]){
 const h=load(experiment,"{helpers}").helpers(inherited),t=load(scheduler,"{transform}").transform,original=h.extract(source),rows=[];
 for(const policy of policies)for(const [profile,opts] of Object.entries({rtt5:{rtt:5},rtt20:{rtt:20},jitter40:{rtt:40,jitter:15},rtt60:{rtt:60}}))for(const hostDelay of [0,2])for(const [combo,selected] of Object.entries(combos)){
  const a=h.setup(t(original,policy),execute,{...opts,hostDelay});a.c.run(100);
  const has=k=>selected.includes(k);
  for(const [k,id] of [["orientation","motionStart"],["acceleration","accelStart"],["rotation","rotationStart"]])if(has(k))await a.el(id).emit("click");
  const sense=()=>{a.window.emit("deviceorientation",{alpha:0,beta:10,gamma:0});a.window.emit("devicemotion",{acceleration:{x:2,y:0,z:0},rotationRate:{alpha:10,beta:0,gamma:0}});};
  sense();a.c.add(sense,10,10);
  for(const [k,id] of [["drumPads","drumEnable"],["pianoKeys","pianoEnable"],["pedalboard","pedalEnable"]])if(has(k))a.el(id).emit("click");
  const start=a.c.now;
  if(has("touch"))a.el("pad").emit("pointerdown",ptr(1));
  if(has("drumPads"))a.el("drum0").emit("pointerdown",ptr(2));
  if(has("pianoKeys"))a.el("piano0").emit("pointerdown",ptr(3));
  if(has("pedalboard"))a.el("pedalToggle3").emit("click");
  a.c.run(12000);const holdEnd=a.closed?.at??a.c.now;
  const holdClosed=a.closed?.status??null,service={};
  for(const k of selected){
    const ts=a.received.filter(x=>x.at<=holdEnd&&h.kindOf(x.f.kind)===k&&!h.isRelease(x.f)).map(x=>x.at);
    service[k]={count:ts.length,maxGap:ts.length?Math.max(ts[0]-start,holdEnd-ts.at(-1),...ts.slice(1).map((t,i)=>t-ts[i])):null};
  }
  const holdPass=!a.closed&&selected.every(k=>service[k].count>1&&service[k].maxGap<350);
  const releaseAt=a.c.now;
  if(!a.closed){
   if(has("touch"))a.el("pad").emit("pointerup",ptr(1));
   for(const [k,id] of [["drumPads","drumRelease"],["pianoKeys","pianoRelease"],["pedalboard","pedalRelease"],["orientation","motionStop"],["acceleration","accelStop"],["rotation","rotationStop"]])if(has(k))a.el(id).emit("click");
   a.c.run(500);
  }
  const releaseFrames=a.received.filter(x=>x.at>=releaseAt&&h.isRelease(x.f)).map(x=>({kind:h.kindOf(x.f.kind),ms:x.at-releaseAt}));
  const sends=a.sent.map(x=>x.at),receipts=a.received.map(x=>x.at),minSendGap=sends.length>1?Math.min(...sends.slice(1).map((t,i)=>t-sends[i])):null;
  const releasePass=holdPass&&!a.closed&&a.host.active.size===0&&selected.every(k=>releaseFrames.some(x=>x.kind===k));
  const pacingPass=policy==="actual"?null:minSendGap===null||minSendGap>=13;
  rows.push({policy,profile,hostDelay,combo,holdPass,releasePass,holdClosed,closed:a.closed,service,releaseFrames,minSendGap,senderMaxSlidingSecond:maxWindow(sends),receiverMaxSlidingSecond:maxWindow(receipts),maxFlight:a.maxFlight,pacingPass});
 }
 return rows;
}
if(typeof module!=="undefined")module.exports={run};
if(typeof require!=="undefined"&&typeof module!=="undefined"&&require.main===module){
 const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
 const read=n=>fs.readFileSync(path.join(__dirname,n),"utf8");
 if(!process.argv[2])throw Error("Pass exact candidate Swift browser source");
 run(fs.readFileSync(process.argv[2],"utf8"),read("stress.cjs"),read("capacity-experiments.cjs"),read("perf3-scheduler.cjs"),(s,g)=>vm.runInNewContext(s,g)).then(x=>console.log(JSON.stringify(x,null,2))).catch(e=>{console.error(e);process.exitCode=2;});
}
