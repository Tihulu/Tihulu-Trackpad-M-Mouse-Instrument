"use strict";
// Deterministic simulation of the actual embedded Remote browser script.
// No network, real device, MIDI or application installation.
const manifest={kind:"capabilities",version:7,touch:true,tilt:true,acceleration:true,rotation:true,airDrums:true,drums:255,piano:67108863,pedals:63};
const streams=["touch","orientation","acceleration","rotation","drumPads","pianoKeys","pedalboard"];
const check=(x,msg)=>{if(!x)throw Error(msg)};
function extract(source){
  const marker='private static let script = #"""';
  check(source.includes(marker),"embedded script missing");
  return source.split(marker)[1].split('"""#')[0].replaceAll("__REMOTE_ORIGIN__","https://local.test").replaceAll("__REMOTE_SOCKET__","wss://local.test");
}
function clock(){
  let now=1000,id=0;const tasks=new Map();
  function add(fn,delay,interval=0){const n=++id;tasks.set(n,{fn,at:now+delay,interval});return n;}
  function run(ms){const end=now+ms;let steps=0;
    while(true){let next=null;for(const [n,t] of tasks)if(t.at<=end&&(!next||t.at<next[1].at||(t.at===next[1].at&&n<next[0])))next=[n,t];
      if(!next)break;check(++steps<100000,"virtual clock runaway");const [n,t]=next;now=t.at;
      if(t.interval)t.at+=t.interval;else tasks.delete(n);t.fn();
    }now=end;
  }
  return {get now(){return now},add,run,clear:n=>tasks.delete(n)};
}
function target(){return {events:new Map(),disabled:false,value:"",style:{},textContent:"",
  setAttribute(){},addEventListener(n,f){this.events.set(n,f)},removeEventListener(n,f){if(this.events.get(n)===f)this.events.delete(n)},
  emit(n,e={}){return this.events.get(n)?.(e)},setPointerCapture(){},getBoundingClientRect(){return {width:100,height:100,left:0,top:0}}};}
const ptr=(id)=>({pointerId:id,button:0,clientX:25,clientY:25,preventDefault(){}});
const kindOf=k=>({orientationArm:"orientation",motionRelease:"orientation",accelerationArm:"acceleration",accelerationRelease:"acceleration",rotationArm:"rotation",rotationRelease:"rotation",release:"touch"}[k]||k);
const isRelease=f=>["release","motionRelease","accelerationRelease","rotationRelease"].includes(f.kind)||(["drumPads","pianoKeys","pedalboard"].includes(f.kind)&&f.mask===0);
function stats(xs){if(!xs.length)return null;const a=[...xs].sort((a,b)=>a-b);return {n:a.length,p50:a[Math.ceil(a.length*.5)-1],p95:a[Math.ceil(a.length*.95)-1],max:a.at(-1)};}
// Deliberately limited host policy model, not an execution of Swift.
// Mirrors frozen peer watchdog, rate window and stream ownership for browser experiments.
function hostPolicy(start){
  let last=start,window=start,count=0,seq=0;const active=new Map();
  function expire(now){return now-last>=2000||[...active.values()].some(t=>now-t>=350);}
  function accept(f,now){
    if(expire(now)||f.sequence<=seq)return false;
    if(now-window>=1000){window=now;count=0;}
    if(count>=90)return false;
    if(["heartbeat","capabilities","mapping","mappingLabels"].includes(f.kind)&&active.size)return false;
    count++;seq=f.sequence;last=now;
    if(streams.includes(kindOf(f.kind))){if(isRelease(f))active.delete(kindOf(f.kind));else active.set(kindOf(f.kind),now);}
    return true;
  }
  return {active,expire,accept,clear:()=>active.clear()};
}
function setup(script,execute,{rtt=10,jitter=0,drop=()=>false,hostDelay=0,experimental=true}={}){
  const c=clock(), elements=new Map(), el=id=>{if(!elements.has(id))elements.set(id,target());return elements.get(id)};
  const document=Object.assign(target(),{hidden:false,getElementById:el});
  const window=Object.assign(target(),{isSecureContext:true,DeviceOrientationEvent:{requestPermission:async()=>"granted"},DeviceMotionEvent:{requestPermission:async()=>"granted"},screen:{orientation:target()}});
  let socket, closed=null, inFlight=0, maxFlight=0, admittedAt=null, hostReason=null;
  const sent=[],received=[],ack=[],releaseEvents=[],host=hostPolicy(c.now);
  function clearHost(reason){if(host.active.size)releaseEvents.push({at:c.now,reason,streams:[...host.active.keys()]});host.clear();}
  class WS{
    static OPEN=1;
    constructor(){socket=this;this.readyState=1;this.protocol="tihulu-touch-v1";this.bufferedAmount=0;}
    send(data){
      if(typeof data!=="string"){c.add(()=>this.onmessage?.({data:"admitted"}),1);return;}
      const f=JSON.parse(data),at=c.now,processingDelay=typeof hostDelay==="function"?hostDelay(f):hostDelay,delay=Math.max(2,rtt+(jitter?[-jitter,0,jitter,0][sent.length%4]:0));
      check(data.length<=256,"oversized outbound frame");sent.push({f,at});maxFlight=Math.max(maxFlight,++inFlight);
      c.add(()=>{
        if(this.readyState!==1)return;
        if(processingDelay>=100||!host.accept(f,c.now)){hostReason=processingDelay>=100?"stale host delivery":"host policy rejection";this.close();return;}
        received.push({f,at:c.now});if(drop(f))return;
        c.add(()=>{if(this.readyState!==1)return;inFlight--;ack.push({f,at:c.now,rtt:c.now-at});this.onmessage?.({data:f.kind==="capabilities"?JSON.stringify(manifest):f.kind==="mapping"?JSON.stringify({kind:"mapping",version:8,sequence:f.sequence,page:0,pages:1,total:0,detail:false,rows:[]}):"accepted"});if(f.kind==="mapping"){admittedAt=c.now;if(experimental){el("navSetup").emit("click");el("workloadMode").emit("click");el("navPlay").emit("click");}}},Math.ceil(delay/2));
      },Math.floor(delay/2)+processingDelay);
    }
    close(){if(this.readyState!==1)return;this.readyState=3;closed={at:c.now,status:el("status").textContent,hostReason};clearHost("simulated disconnect");this.onclose?.();}
  }
  execute(script,{document,window,location:{origin:"https://local.test"},WebSocket:WS,performance:{now:()=>c.now},setTimeout:(f,ms)=>c.add(f,ms),clearTimeout:c.clear,setInterval:(f,ms)=>c.add(f,ms,ms),clearInterval:c.clear});
  el("secret").value="aa".repeat(32);el("connect").emit("click");socket.onopen();
  c.add(()=>{if(socket.readyState===1&&host.expire(c.now)){hostReason="host watchdog";socket.close();}},1,1);
  return {c,el,window,document,host,sent,received,ack,releaseEvents,get closed(){return closed?{...closed,status:el("status").textContent}:null},get maxFlight(){return maxFlight},get socket(){return socket},get admittedAt(){return admittedAt}};
}
function sensors(a){a.window.emit("deviceorientation",{alpha:0,beta:10,gamma:0});a.window.emit("devicemotion",{acceleration:{x:2,y:0,z:0},rotationRate:{alpha:10,beta:0,gamma:0}});}
function summary(a,start,end){
  const rr=a.received.filter(x=>x.at>=start&&x.at<=end), gaps={};
  for(const k of streams){const times=rr.filter(x=>kindOf(x.f.kind)===k&&!isRelease(x.f)).map(x=>x.at);gaps[k]={count:times.length,intervals:stats(times.slice(1).map((t,i)=>t-times[i])),endGap:times.length?end-times.at(-1):null};}
  return {rtt:stats(a.ack.filter(x=>x.at>=start&&x.at<=end).map(x=>x.rtt)),gaps,maxFlight:a.maxFlight,closed:a.closed,modelDisconnectReleases:a.releaseEvents};
}
async function concurrent(script,execute,options){
  const a=setup(script,execute,options);a.c.run(350);
  check(a.admittedAt!==null,"manifest not admitted");
  const c=a.c,el=a.el;await el("motionStart").emit("click");await el("accelStart").emit("click");await el("rotationStart").emit("click");
  sensors(a);c.add(()=>sensors(a),10,10);
  for(const id of ["drumEnable","pianoEnable","pedalEnable"])el(id).emit("click");
  el("pad").emit("pointerdown",ptr(1));el("drum0").emit("pointerdown",ptr(2));el("piano0").emit("pointerdown",ptr(3));el("pedalToggle3").emit("click");
  const start=c.now;c.run(1800);const end=a.closed?.at??c.now;
  const result=summary(a,start,end);
  // Explicit releases in one burst; do not equate simulated disconnect cleanup with physical MIDI release.
  const releasedAt=c.now;
  if(!a.closed){el("pad").emit("pointerup",ptr(1));el("motionStop").emit("click");el("accelStop").emit("click");el("rotationStop").emit("click");el("drumRelease").emit("click");el("pianoRelease").emit("click");el("pedalRelease").emit("click");c.run(500);}
  result.explicitReleases=a.received.filter(x=>x.at>=releasedAt&&isRelease(x.f)).map(x=>({kind:kindOf(x.f.kind),latency:x.at-releasedAt}));
  result.finalActive=[...a.host.active.keys()];result.finalClosed=a.closed;return result;
}
function tap(script,execute){
  const a=setup(script,execute,{rtt:60});a.c.run(350);a.el("pianoEnable").emit("click");a.el("piano0").emit("pointerdown",ptr(1));
  a.c.run(5);a.el("pad").emit("pointerdown",ptr(2));a.c.run(10);a.el("pad").emit("pointerup",ptr(2));a.c.run(350);
  return {expectedTouchOnsets:1,observedTouchOnsets:a.received.filter(x=>x.f.kind==="touch").length,wire:a.received.map(x=>x.f.kind),closed:a.closed};
}
function fault(script,execute,mode){
  const a=setup(script,execute,{rtt:10,drop:f=>["missingAck","staleQueue","overflow"].includes(mode)&&f.kind==="drumPads",hostDelay:f=>mode==="staleHost"&&f.kind==="drumPads"?100:0});
  a.c.run(350);
  {a.el("drumEnable").emit("click");a.el("drum0").emit("pointerdown",ptr(1));
    if(mode==="staleQueue"){a.c.run(5);a.el("drum0").emit("pointerup",ptr(1));}
    if(mode==="pagehide"){a.c.run(20);a.window.emit("pagehide");}
    if(mode==="overflow"){for(let i=0;i<10;i++){a.el("drum0").emit("pointerup",ptr(1));a.el("drum0").emit("pointerdown",ptr(1));}}
    a.c.run(400);
  }return {closed:a.closed,modelActive:[...a.host.active.keys()],maxFlight:a.maxFlight,received:a.received.map(x=>x.f.kind),releaseEvents:a.releaseEvents};
}
async function edges(script,execute,rtt){
  const a=setup(script,execute,{rtt});a.c.run(350);
  for(const id of ["drumEnable","pianoEnable","pedalEnable"])a.el(id).emit("click");
  const expected={drumPads:[],pianoKeys:[],pedalboard:[]};
  for(let cycle=0;cycle<8;cycle++){
    for(const [kind,el] of [["drumPads","drum0"],["pianoKeys","piano0"],["pedalboard","pedalToggle3"]]){
      expected[kind].push({mask:kind==="pedalboard"?8:1,at:a.c.now});
      a.el(el).emit(kind==="pedalboard"?"click":"pointerdown",ptr(1));
    }
    a.c.run(15);
    for(const [kind,el] of [["drumPads","drum0"],["pianoKeys","piano0"],["pedalboard","pedalToggle3"]]){
      expected[kind].push({mask:0,at:a.c.now});a.el(el).emit(kind==="pedalboard"?"click":"pointerup",ptr(1));
    }
    a.c.run(235);if(a.closed)break;
  }
  const result={closed:a.closed,streams:{}};
  for(const kind of Object.keys(expected)){
    let prev=0;const actual=a.received.filter(x=>x.f.kind===kind).filter(x=>{if(x.f.mask===prev)return false;prev=x.f.mask;return true;});
    let matched=0;const latencies=[];
    for(let i=0;i<Math.min(actual.length,expected[kind].length);i++){
      if(actual[i].f.mask!==expected[kind][i].mask||actual[i].at<expected[kind][i].at)break;
      matched++;latencies.push(actual[i].at-expected[kind][i].at);
    }
    result.streams[kind]={expected:expected[kind].length,observed:actual.length,matched,missed:expected[kind].length-matched,latency:stats(latencies)};
  }
  return result;
}
function capsModel(){
  const p=hostPolicy(1000);let accepted=0;for(let i=1;i<=91;i++)if(p.accept({kind:"heartbeat",sequence:i},1000+i))accepted++;
  // Frozen PhysicalPatchRuntime.maxRemotePeers=4; SensorRouter.maxSessions=16.
  // Capacity arithmetic, not a Swift execution; 7 fully mapped streams per peer.
  return {rateAccepted:accepted,rateAttempted:91,remotePeerLimit:4,routerSessionLimit:16,threeFullyActivePeersDemand:21};
}
async function run(source,execute){
  const script=extract(source);
  const report={simulation:"actual browser JS, virtual timers/ACKs, simplified host model; milliseconds",concurrent:{}};
  for(const [name,options] of Object.entries({fast:{rtt:5},lan:{rtt:20},jitter:{rtt:40,jitter:15},slow:{rtt:60}}))report.concurrent[name]=await concurrent(script,execute,options);
  report.shortTouch=tap(script,execute);report.faults={};
  for(const mode of ["missingAck","staleQueue","overflow","staleHost","pagehide"])report.faults[mode]=fault(script,execute,mode);
  report.edges={fast:await edges(script,execute,5),lan:await edges(script,execute,20),slow:await edges(script,execute,60)};
  report.capsModel=capsModel();
  const failures=[];
  for(const [name,result] of Object.entries(report.concurrent)){
    if(result.maxFlight!==1)failures.push(name+": outstanding frame invariant");
    if(result.finalActive.length)failures.push(name+": model ownership not cleared");
    if(result.closed)failures.push(name+": concurrent load disconnected");
    else if(result.explicitReleases.length!==7)failures.push(name+": not all seven explicit releases observed");
    for(const [kind,gap] of Object.entries(result.gaps))if(!gap.count||gap.intervals?.max>=350||gap.endGap>=350)failures.push(name+": "+kind+" service starvation");
  }
  if(report.shortTouch.observedTouchOnsets!==1)failures.push("short touch onset lost while ACK pending");
  for(const [mode,result] of Object.entries(report.faults))if(!result.closed||result.modelActive.length)failures.push(mode+": did not fail closed in model");
  for(const [name,result] of Object.entries(report.edges))if(result.closed||Object.values(result.streams).some(x=>x.missed||x.observed!==x.expected))failures.push(name+": concurrent edge burst lost or disconnected");
  if(report.capsModel.rateAccepted!==90)failures.push("rate model cap mismatch");
  return {...report,failures,verdict:failures.length?"FAIL":"PASS"};
}
if(typeof module!=="undefined")module.exports={run};
if(typeof require!=="undefined"&&typeof module!=="undefined"&&require.main===module){
  const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
  const source=fs.readFileSync(process.argv[2]||path.join(__dirname,"../../Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"),"utf8");
  run(source,(script,globals)=>vm.runInNewContext(script,globals)).then(result=>{console.log(JSON.stringify(result,null,2));process.exitCode=result.failures.length?1:0;}).catch(e=>{console.error(e);process.exitCode=2;});
}
