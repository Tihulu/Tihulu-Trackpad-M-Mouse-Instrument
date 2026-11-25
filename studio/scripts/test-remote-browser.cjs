const {test}=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const path=require("node:path");
const source=fs.readFileSync(path.join(__dirname,"../Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"),"utf8");
const script=source.split('private static let script = #"""')[1].split('"""#')[0]
  .replaceAll("__REMOTE_ORIGIN__","https://local.test").replaceAll("__REMOTE_SOCKET__","wss://local.test");
const fullManifest={kind:"capabilities",version:7,touch:true,tilt:true,acceleration:true,rotation:true,airDrums:true,drums:255,piano:67108863,pedals:63};
function setup(permission="granted",manifest=fullManifest,experimental=true,autoMapping=true,groupNeutral=false,stored=new Map()){
  let time=1000, ticker, socket, nextTimer=0;const timers=new Map();
  function target(){return {events:new Map(),disabled:false,value:"",style:{},textContent:"",attributes:{},children:[],
    setAttribute(n,v){this.attributes[n]=v},replaceChildren(...children){this.children=children},
    appendChild(child){if(child.parent)child.parent.children=child.parent.children.filter(x=>x!==child);this.children=this.children.filter(x=>x!==child);this.children.push(child);child.parent=this;return child},addEventListener(n,f){this.events.set(n,f)},removeEventListener(n,f){if(this.events.get(n)===f)this.events.delete(n)},
    emit(n,e={}){return this.events.get(n)?.(e)},setPointerCapture(){},getBoundingClientRect(){return {width:100,height:100,left:0,top:0}}};}
  const elements=Object.fromEntries(["sliderEditor","sliderChoice","sliderDirection","sliderDefault","sliderApply","customEditor","customColumns","customAddChoice","customChoice","customAdd","customRemove","customUp","customDown","customSection","customGrid","customDrumEnable","customPedalEnable","customDrumRelease","customPedalRelease","gridOrderEditor","gridControl","gridControlUp","gridControlDown",...Array.from({length:6},(_,i)=>"pedalCell"+i),"pedalBehavior","pedalMode3","pedalMode4","pedalMode5","panelSize","panelColumns","drumGrid","pedalGrid","layoutSection","layoutDragList","layoutPanel","layoutUp","layoutDown","layoutWide","layoutSize","layoutSave","layoutReset","layoutStatus","playWorkloadStatus","navPlay","navSetup","navConnection","navStatus","playView","setupView","connectionView","ackLatency","releaseAll","mappingSection","mappingStatus","mappingDetails","pianoBoard","pianoStrips","pianoStripHint","workloadSection","workloadMode","workloadStatus","touchSection","drumSection","pianoSection","pedalSection","tiltSection","inertialSection","accelSection","rotationSection","airDrumNotice","pad","dot","secret","connect","disconnect","status","motionStart","motionStop","tiltMeter","motionStatus","accelStart","accelStop","accelMeter","accelStatus","rotationStart","rotationStop","rotationMeter","rotationStatus","drumEnable","drumRelease","drumStatus",...Array.from({length:8},(_,i)=>"drum"+i),"pianoEnable","pianoRelease","pianoStatus","pianoSustain","octaveDown","octaveUp","octaveLabel","pianoScale","pianoRoot",...Array.from({length:13},(_,i)=>"piano"+i),"pedalEnable","pedalRelease","pedalStatus",...Array.from({length:6},(_,i)=>"pedalToggle"+i),...Array.from({length:3},(_,i)=>"pedalLevel"+i),...Array.from({length:3},(_,i)=>"pedalValue"+i)].map(k=>[k,target()]));
  const document=Object.assign(target(),{hidden:false,getElementById:id=>elements[id],createElement:()=>target()});
  const window=Object.assign(target(),{isSecureContext:true,DeviceOrientationEvent:{requestPermission:async()=>permission},DeviceMotionEvent:{requestPermission:async()=>permission},screen:{orientation:target()},localStorage:{
    getItem:key=>stored.get(key)??null,setItem:(key,value)=>stored.set(key,value),removeItem:key=>stored.delete(key)}});
  class WS{
    static OPEN=1;
    constructor(){socket=this;this.readyState=1;this.bufferedAmount=0;this.protocol="tihulu-touch-v1";this.frames=[];}
    send(data){if(typeof data==="string"){this.frames.push(JSON.parse(data));this.sentAt=time;(this.sendTimes??=[]).push(time);}}
    close(){this.closed=true;}
  }
  vm.runInNewContext(script.replaceAll("__GROUP_NEUTRAL__",groupNeutral?"enabled":"disabled"),{document,window,location:{origin:"https://local.test"},WebSocket:WS,performance:{now:()=>time},
    setTimeout:(f,ms)=>{const id=++nextTimer;timers.set(id,{f,at:time+ms});return id;},clearTimeout:id=>timers.delete(id),setInterval:f=>(ticker=f,1),clearInterval(){ticker=null;}});
  elements.secret.value="aa".repeat(32);elements.connect.emit("click");socket.onopen();socket.onmessage({data:"admitted"});
  const query=socket.frames.shift();
  time+=13;if(manifest!==null)socket.onmessage({data:typeof manifest==="string"?manifest:JSON.stringify(manifest)});
  function step(ms=25){time+=ms;for(const [id,t] of [...timers])if(t.at<=time&&timers.delete(id))t.f();ticker?.()}
  function withheld(){step(50);const q=socket.frames.at(-1);if(q?.kind==="mapping"){socket.frames.pop();time+=13;socket.onmessage({data:JSON.stringify({kind:"mapping",version:8,sequence:q.sequence,page:0,pages:1,total:0,detail:false,rows:[]})});}}
  function withheldLabels(){step(50);const q=socket.frames.at(-1);if(q?.kind==="mappingLabels"){socket.frames.pop();time+=13;socket.onmessage({data:JSON.stringify({kind:"mappingLabels",version:8,sequence:q.sequence,page:0,pages:1,total:0,rows:[]})});}}
  if(autoMapping&&!socket.closed&&manifest!==null){withheld();if(groupNeutral&&!socket.closed)withheldLabels();}
  if(experimental&&!socket.closed&&manifest!==null){elements.navSetup.emit("click");elements.workloadMode.emit("click");elements.navPlay.emit("click");}
  return {query,elements,window,document,socket,step,withheld,ack(ms=13){time+=ms;socket.onmessage({data:"accepted"})},
    orientation(beta=0){window.emit("deviceorientation",{alpha:0,beta,gamma:0})}};
}
test("permission denial never attaches listener or sends motion",async()=>{
  const a=setup("denied");await a.elements.motionStart.emit("click");a.orientation();a.step();
  assert.equal(a.window.events.has("deviceorientation"),false);
  assert.equal(a.socket.frames.length,0);
  assert.match(a.elements.motionStatus.textContent,/denied/);
});
test("arm, sample, one outstanding ACK, explicit release",async()=>{
  const a=setup();await a.elements.motionStart.emit("click");a.orientation(5);a.step();
  assert.equal(a.socket.frames.at(-1).kind,"orientationArm");assert.equal(a.socket.frames.at(-1).version,2);
  a.step(25);a.orientation(30);a.step(25);assert.equal(a.socket.frames.length,1);
  a.ack();a.step();assert.equal(a.socket.frames.at(-1).kind,"orientation");
  a.elements.motionStop.emit("click");assert.equal(a.socket.frames.length,2);
  a.ack();assert.equal(a.socket.frames.at(-1).kind,"motionRelease");a.ack();
  assert.equal(a.window.events.has("deviceorientation"),false);
  assert.equal(a.elements.motionStart.disabled,false);
});
test("stale orientation disconnects without repeating sample",async()=>{
  const a=setup();await a.elements.motionStart.emit("click");a.orientation();a.step();a.ack();
  a.step(60);assert.equal(a.socket.frames.length,1);
  a.step(250);assert.equal(a.socket.closed,true);
  assert.equal(a.window.events.has("deviceorientation"),false);
});
test("screen rotation closes armed connection",async()=>{
  const a=setup();await a.elements.motionStart.emit("click");a.orientation();a.step();a.ack();
  a.window.screen.orientation.emit("change");assert.equal(a.socket.closed,true);
});
test("v1 touch still works with motion disabled",()=>{
  const a=setup();a.elements.pad.emit("pointerdown",{pointerId:1,button:0,clientX:25,clientY:25,preventDefault(){}});
  assert.equal(a.socket.frames.at(-1).kind,"touch");assert.equal(a.socket.frames.at(-1).version,1);a.ack();
  a.elements.pad.emit("pointerup",{pointerId:1});assert.equal(a.socket.frames.at(-1).kind,"release");
});

test("touch and tilt alternate on a single ACK lane and release independently",async()=>{
  const a=setup();await a.elements.motionStart.emit("click");a.orientation();a.step();a.ack();
  const down={pointerId:1,button:0,clientX:25,clientY:25,preventDefault(){}};
  a.elements.pad.emit("pointerdown",down);
  assert.equal(a.socket.frames.at(-1).kind,"touch");a.ack();
  a.orientation(25);a.step(50);
  assert.equal(a.socket.frames.at(-1).kind,"orientation");a.ack();
  a.step(25);assert.equal(a.socket.frames.at(-1).kind,"touch");a.ack();
  a.elements.pad.emit("pointerup",{pointerId:1});
  assert.equal(a.socket.frames.at(-1).kind,"release");a.ack();
  assert.equal(a.window.events.has("deviceorientation"),true);
  a.orientation(30);a.step(50);assert.equal(a.socket.frames.at(-1).kind,"orientation");a.ack();
  a.elements.motionStop.emit("click");assert.equal(a.socket.frames.at(-1).kind,"motionRelease");a.ack();
  assert.equal(a.socket.closed,undefined);
});

test("inertial permission denial does not attach or transmit",async()=>{
  const a=setup("denied");await a.elements.accelStart.emit("click");
  assert.equal(a.window.events.has("devicemotion"),false);
  assert.equal(a.socket.frames.length,0);
  assert.match(a.elements.accelStatus.textContent,/denied/);
});
test("gravity-only data does not arm acceleration",async()=>{
  const a=setup();await a.elements.accelStart.emit("click");
  a.window.emit("devicemotion",{acceleration:null,accelerationIncludingGravity:{x:9.8,y:0,z:0}});
  a.step();assert.equal(a.socket.frames.length,0);
  a.step(3100);assert.equal(a.window.events.has("devicemotion"),false);
  assert.match(a.elements.accelStatus.textContent,/No valid/);
});
test("independent inertial permission, v3 arms, samples and releases",async()=>{
  const a=setup();await a.elements.accelStart.emit("click");await a.elements.rotationStart.emit("click");
  const motion=()=>a.window.emit("devicemotion",{acceleration:{x:10,y:0,z:0},rotationRate:{alpha:180,beta:0,gamma:0}});
  motion();a.step();assert.equal(a.socket.frames.at(-1).kind,"accelerationArm");a.ack();
  a.step();assert.equal(a.socket.frames.at(-1).kind,"rotationArm");a.ack();
  motion();a.step(50);assert.equal(a.socket.frames.at(-1).kind,"acceleration");
  assert.equal(a.socket.frames.at(-1).version,3);assert.equal(a.socket.frames.at(-1).x,10);a.ack();
  a.step();assert.equal(a.socket.frames.at(-1).kind,"rotation");a.ack();
  a.elements.accelStop.emit("click");assert.equal(a.socket.frames.at(-1).kind,"accelerationRelease");a.ack();
  assert.equal(a.window.events.has("devicemotion"),true);
  motion();a.step(50);assert.equal(a.socket.frames.at(-1).kind,"rotation");a.ack();
  a.elements.rotationStop.emit("click");assert.equal(a.socket.frames.at(-1).kind,"rotationRelease");a.ack();
  assert.equal(a.window.events.has("devicemotion"),false);
});
test("missing active inertial sample closes and removes listener",async()=>{
  const a=setup();await a.elements.accelStart.emit("click");
  a.window.emit("devicemotion",{acceleration:{x:1,y:0,z:0}});a.step();a.ack();
  a.window.emit("devicemotion",{acceleration:null});
  assert.equal(a.socket.closed,true);assert.equal(a.window.events.has("devicemotion"),false);
});
test("stale inertial sample cannot be repeated",async()=>{
  const a=setup();await a.elements.rotationStart.emit("click");
  a.window.emit("devicemotion",{rotationRate:{alpha:10,beta:0,gamma:0}});a.step();a.ack();
  a.step(100);assert.equal(a.socket.frames.length,1);
  a.step(200);assert.equal(a.socket.closed,true);
});

function drumEvent(id){return {pointerId:id,button:0,preventDefault(){}};}
test("drum short tap queues release behind outstanding ACK",()=>{
  const a=setup();a.elements.drumEnable.emit("click");
  a.elements.drum0.emit("pointerdown",drumEvent(1));
  assert.equal(a.socket.frames.at(-1).mask,1);
  assert.equal(a.socket.frames.at(-1).version,4);
  a.elements.drum0.emit("pointerup",drumEvent(1));assert.equal(a.socket.frames.length,1);
  a.ack();a.step(25);assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  assert.equal(a.socket.closed,undefined);
});
test("multiple drum fingers hold same and different pads independently",()=>{
  const a=setup();a.elements.drumEnable.emit("click");
  a.elements.drum0.emit("pointerdown",drumEvent(1));a.ack();
  a.elements.drum0.emit("pointerdown",drumEvent(2));
  a.elements.drum1.emit("pointerdown",drumEvent(3));a.step();assert.equal(a.socket.frames.at(-1).mask,3);a.ack();
  a.elements.drum0.emit("pointerup",drumEvent(1));assert.equal(a.socket.frames.length,2);
  a.elements.drum0.emit("pointercancel",drumEvent(2));a.step();assert.equal(a.socket.frames.at(-1).mask,2);a.ack();
  a.elements.drum1.emit("lostpointercapture",drumEvent(3));a.step();assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
});
test("release all discards unsent hits and clears held snapshot",()=>{
  const a=setup();a.elements.drumEnable.emit("click");
  a.elements.drum0.emit("pointerdown",drumEvent(1));
  a.elements.drum1.emit("pointerdown",drumEvent(2));
  a.elements.drumRelease.emit("click");a.ack();
  assert.deepEqual(a.socket.frames.map(x=>x.mask),[1,0]);a.ack();
  a.step(60);assert.equal(a.socket.frames.length,2);
});
test("held drum snapshots refresh but stale edge backlog closes",()=>{
  const a=setup();a.elements.drumEnable.emit("click");
  a.elements.drum0.emit("pointerdown",drumEvent(1));a.ack();a.step(50);
  assert.equal(a.socket.frames.at(-1).mask,1);
  a.elements.drum0.emit("pointerup",drumEvent(1));a.step(151);
  assert.equal(a.socket.closed,true);
});
test("drum disabled by default and page hide closes active notes",()=>{
  const a=setup();a.elements.drum0.emit("pointerdown",drumEvent(1));assert.equal(a.socket.frames.length,0);
  a.elements.drumEnable.emit("click");a.elements.drum0.emit("pointerdown",drumEvent(1));
  a.window.emit("pagehide");assert.equal(a.socket.closed,true);
});

test("piano polyphonic short taps and independent release",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");
  a.elements.piano0.emit("pointerdown",drumEvent(1));
  assert.equal(a.socket.frames.at(-1).version,5);assert.equal(a.socket.frames.at(-1).mask,1);
  a.elements.piano4.emit("pointerdown",drumEvent(2));
  a.elements.piano0.emit("pointerup",drumEvent(1));
  a.ack();a.step();assert.equal(a.socket.frames.at(-1).mask,17);a.ack();
  a.step();assert.equal(a.socket.frames.at(-1).mask,16);a.ack();
  a.elements.piano4.emit("pointerup",drumEvent(2));a.step();
  assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
});
test("octave change waits for zero snapshot ACK",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");
  a.elements.piano0.emit("pointerdown",drumEvent(1));a.ack();
  a.elements.octaveUp.emit("click");assert.equal(a.elements.octaveLabel.textContent,"Keys 1–13");
  a.elements.piano0.emit("pointerup",drumEvent(1));a.step();
  a.elements.octaveUp.emit("click");assert.equal(a.elements.octaveLabel.textContent,"Keys 1–13");
  a.ack();a.elements.octaveUp.emit("click");assert.equal(a.elements.octaveLabel.textContent,"Keys 13–25");
  a.elements.piano12.emit("pointerdown",drumEvent(2));a.step();
  assert.equal(a.socket.frames.at(-1).mask,1<<24);
});
test("sustain owns independent bit and blocks octave until released",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");
  a.elements.pianoSustain.emit("pointerdown",drumEvent(1));a.ack();
  assert.equal(a.socket.frames.at(-1).mask,1<<25);
  a.elements.piano0.emit("pointerdown",drumEvent(2));a.step();a.ack();
  assert.equal(a.socket.frames.at(-1).mask,(1<<25)|1);
  a.elements.piano0.emit("pointerup",drumEvent(2));a.step();a.ack();
  assert.equal(a.socket.frames.at(-1).mask,1<<25);assert.equal(a.elements.octaveUp.disabled,true);
  a.elements.pianoRelease.emit("click");assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  assert.equal(a.elements.octaveUp.disabled,false);
});
test("piano release all preserves drum ownership",()=>{
  const a=setup();a.elements.drumEnable.emit("click");a.elements.pianoEnable.emit("click");
  a.elements.drum0.emit("pointerdown",drumEvent(1));a.ack();
  a.elements.piano0.emit("pointerdown",drumEvent(2));a.ack();
  a.elements.pianoRelease.emit("click");assert.equal(a.socket.frames.at(-1).kind,"pianoKeys");
  assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  a.step(50);assert.equal(a.socket.frames.at(-1).kind,"drumPads");assert.equal(a.socket.frames.at(-1).mask,1);
});
test("scale guide does not send MIDI and stale piano edge fails closed",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");
  a.elements.pianoScale.value="major";a.elements.pianoRoot.value="2";a.elements.pianoScale.emit("change");
  assert.equal(a.socket.frames.length,0);
  a.elements.piano0.emit("pointerdown",drumEvent(1));a.elements.piano0.emit("pointerup",drumEvent(1));
  a.step(151);assert.equal(a.socket.closed,true);
});

test("pedalboard explicit enable and per-control ownership",()=>{
  const a=setup();
  a.elements.pedalToggle0.emit("click");assert.equal(a.socket.frames.length,0);
  a.elements.pedalEnable.emit("click");assert.equal(a.socket.frames.length,0);
  a.elements.pedalToggle0.emit("click");
  assert.equal(a.socket.frames.at(-1).version,6);assert.equal(a.socket.frames.at(-1).mask,1);
  assert.deepEqual(a.socket.frames.at(-1).levels,[1,0,0,0,0,0]);a.ack();
  a.elements.pedalLevel0.value="45";a.elements.pedalLevel0.emit("input");a.step(50);
  assert.deepEqual(a.socket.frames.at(-1).levels,[0.45,0,0,0,0,0]);a.ack();
  a.elements.pedalToggle0.emit("click");a.step();
  assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
});
test("pedal binary edges survive pending ACK and independent sustain",()=>{
  const a=setup();a.elements.pedalEnable.emit("click");
  a.elements.pedalToggle3.emit("click");
  a.elements.pedalToggle4.emit("click");a.elements.pedalToggle4.emit("click");
  a.ack();a.step();assert.equal(a.socket.frames.at(-1).mask,24);a.ack();
  a.step();assert.equal(a.socket.frames.at(-1).mask,8);a.ack();
  assert.deepEqual(a.socket.frames.at(-1).levels,[0,0,0,1,0,0]);
  a.elements.pedalRelease.emit("click");assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
});
test("pedal continuous movements coalesce without consuming edge queue",()=>{
  const a=setup();a.elements.pedalEnable.emit("click");a.elements.pedalToggle2.emit("click");
  for(let i=0;i<30;i++){a.elements.pedalLevel2.value=String(i);a.elements.pedalLevel2.emit("input");}
  assert.equal(a.socket.closed,undefined);assert.equal(a.socket.frames.length,1);
  a.ack();a.step(50);assert.deepEqual(a.socket.frames.at(-1).levels,[0,0,0.29,0,0,0]);a.ack();
});
test("pedal release all discards unsent switches and preserves piano",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");a.elements.pedalEnable.emit("click");
  a.elements.piano0.emit("pointerdown",drumEvent(1));a.ack();
  a.elements.pedalToggle0.emit("click");a.elements.pedalToggle5.emit("click");
  a.elements.pedalRelease.emit("click");a.ack();
  assert.equal(a.socket.frames.at(-1).kind,"pedalboard");assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  a.step(50);assert.equal(a.socket.frames.at(-1).kind,"pianoKeys");assert.equal(a.socket.frames.at(-1).mask,1);
});
test("pedal held refresh and stale binary edge fail closed",()=>{
  const a=setup();a.elements.pedalEnable.emit("click");a.elements.pedalToggle4.emit("click");a.ack();a.step(50);
  assert.equal(a.socket.frames.at(-1).mask,16);
  a.elements.pedalToggle4.emit("click");a.step(151);
  assert.equal(a.socket.closed,true);
});

test("authenticated manifest required before any control input",()=>{
  const a=setup("granted",null);
  assert.deepEqual(a.query,{version:7,sequence:1,kind:"capabilities"});
  assert.equal(a.elements.touchSection.hidden,true);
  a.elements.drumEnable.emit("click");a.elements.drum0.emit("pointerdown",drumEvent(1));
  a.elements.pad.emit("pointerdown",{...drumEvent(2),clientX:25,clientY:25});
  assert.equal(a.socket.frames.length,0);
  a.socket.onmessage({data:JSON.stringify(fullManifest)});a.withheld();
  assert.equal(a.elements.drumSection.hidden,false);
});
test("partial manifest hides absent sections and rejects unmapped events",async()=>{
  const a=setup("granted",{...fullManifest,touch:false,tilt:false,acceleration:false,rotation:false,airDrums:false,drums:2,piano:0,pedals:0});
  assert.equal(a.elements.touchSection.hidden,true);assert.equal(a.elements.pianoSection.hidden,true);
  assert.equal(a.elements.inertialSection.hidden,true);assert.equal(a.elements.drum0.hidden,true);
  await a.elements.motionStart.emit("click");await a.elements.accelStart.emit("click");
  a.elements.drumEnable.emit("click");a.elements.drum0.emit("pointerdown",drumEvent(1));
  assert.equal(a.socket.frames.length,0);
  a.elements.drum1.emit("pointerdown",drumEvent(2));assert.equal(a.socket.frames.at(-1).mask,2);
});
test("high-octave-only piano selects available view and rejects missing sustain",()=>{
  const a=setup("granted",{...fullManifest,piano:1<<24});
  assert.equal(a.elements.octaveLabel.textContent,"Keys 13–25");
  a.elements.pianoEnable.emit("click");a.elements.octaveDown.emit("click");
  assert.equal(a.elements.octaveLabel.textContent,"Keys 13–25");
  assert.equal(a.elements.piano0.disabled,true);assert.equal(a.elements.pianoSustain.hidden,true);
  a.elements.piano0.emit("pointerdown",drumEvent(1));assert.equal(a.socket.frames.length,0);
  a.elements.piano12.emit("pointerdown",drumEvent(2));assert.equal(a.socket.frames.at(-1).mask,1<<24);
});
test("malformed manifest closes, with no legacy fallback",()=>{
  for(const m of ["accepted",{...fullManifest,pedals:64},{...fullManifest,airDrums:true,acceleration:false},{...fullManifest,extra:1}]){
    const a=setup("granted",m);assert.equal(a.socket.closed,true);assert.equal(a.elements.drumSection.hidden,true);
  }
});
test("partial pedals and sensor notices reflect manifest",()=>{
  const a=setup("granted",{...fullManifest,pedals:16,rotation:false,airDrums:false});
  assert.equal(a.elements.rotationSection.hidden,true);assert.equal(a.elements.airDrumNotice.hidden,true);
  a.elements.pedalEnable.emit("click");assert.equal(a.elements.pedalToggle0.disabled,true);
  a.elements.pedalToggle0.emit("click");assert.equal(a.socket.frames.length,0);
  a.elements.pedalToggle4.emit("click");assert.equal(a.socket.frames.at(-1).mask,16);
});

test("manifest rejects duplicate decoded names including escapes",()=>{
  const valid=JSON.stringify(fullManifest);
  for(const bad of [valid.replace('"touch":true','"touch":false,"touch":true'),
    valid.replace('"version":7','"version":7,"\\u0076ersion":7'),
    valid.replace('"drums":255','"drums":0,"drums":255')]){
    const a=setup("granted",bad);assert.equal(a.socket.closed,true);assert.equal(a.elements.touchSection.hidden,true);
  }
});

function xyEvent(id,x=25,y=25){return {pointerId:id,button:0,clientX:x,clientY:y,preventDefault(){}};}
test("short XY tap survives outstanding piano ACK in order",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));
  a.elements.pad.emit("pointerdown",xyEvent(2));a.elements.pad.emit("pointerup",xyEvent(2));
  assert.equal(a.socket.frames.length,1);a.ack();
  assert.equal(a.socket.frames.at(-1).kind,"touch");assert.equal(a.socket.frames.at(-1).x,0.25);a.ack();
  assert.equal(a.socket.frames.at(-1).kind,"release");a.ack();
  assert.equal(a.socket.closed,undefined);
});
test("rapid XY taps retain ordered onsets and releases",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));
  for(const id of [2,3]){a.elements.pad.emit("pointerdown",xyEvent(id,id*10));a.elements.pad.emit("pointerup",xyEvent(id));}
  for(let i=0;i<5;i++)a.ack();
  assert.deepEqual(a.socket.frames.filter(f=>f.kind!=="pianoKeys").map(f=>f.kind),["touch","release","touch","release"]);
  assert.equal(a.socket.frames[1].x,0.2);assert.equal(a.socket.frames[3].x,0.3);
});
test("stale queued XY edge closes rather than replaying delayed onset",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));
  a.elements.pad.emit("pointerdown",xyEvent(2));a.elements.pad.emit("pointerup",xyEvent(2));
  a.step(150);assert.equal(a.socket.closed,true);assert.equal(a.socket.frames.length,1);
});
test("XY cancel discards queued onset and closes fail safe",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));
  a.elements.pad.emit("pointerdown",xyEvent(2));a.elements.pad.emit("pointercancel",xyEvent(2));
  assert.equal(a.socket.closed,true);assert.equal(a.socket.frames.length,1);
});
test("XY queue overflow closes without playing stale taps",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));
  for(let id=2;id<=6;id++){a.elements.pad.emit("pointerdown",xyEvent(id));a.elements.pad.emit("pointerup",xyEvent(id));}
  assert.equal(a.socket.closed,true);assert.equal(a.socket.frames.length,1);
});

test("fast ACK cannot bypass 13 ms send pacing",()=>{
  const a=setup();a.elements.pad.emit("pointerdown",xyEvent(1));a.elements.pad.emit("pointerup",xyEvent(1));
  a.ack(1);assert.equal(a.socket.frames.length,1);
  a.step(11);assert.equal(a.socket.frames.length,1);
  a.step(1);assert.equal(a.socket.frames.at(-1).kind,"release");
  assert.equal(a.socket.sendTimes.at(-1)-a.socket.sendTimes.at(-2),13);a.ack();
});
test("missing ACK closes at existing deadline and cancels queued touch",()=>{
  const a=setup();a.elements.pad.emit("pointerdown",xyEvent(1));
  a.step(219);assert.equal(a.socket.closed,undefined);
  a.step(1);assert.equal(a.socket.closed,true);
});
test("pace wake cannot resurrect closed connection",()=>{
  const a=setup();a.elements.pad.emit("pointerdown",xyEvent(1));a.elements.pad.emit("pointerup",xyEvent(1));a.ack(1);
  a.window.emit("pagehide");a.step(50);assert.equal(a.socket.frames.length,1);assert.equal(a.socket.closed,true);
});

test("manifest rejects fractional or exponent bitsets and BOM",()=>{
  const valid=JSON.stringify(fullManifest);
  for(const bad of [valid.replace('"drums":255','"drums":254.999999999999999999'),
    valid.replace('"piano":67108863','"piano":1e-999'),valid.replace('"version":7','"version":7.0'),
    valid.replace('"pedals":63','"pedals":6.3e1'),"\uFEFF"+valid]){
    const a=setup("granted",bad);assert.equal(a.socket.closed,true);assert.equal(a.elements.touchSection.hidden,true);
  }
});

test("default workload refuses a second discrete surface without disturbing the first",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));a.ack();
  a.elements.drumEnable.emit("click");a.elements.drum0.emit("pointerdown",drumEvent(2));
  a.elements.pad.emit("pointerdown",xyEvent(3));assert.equal(a.socket.frames.length,1);
  assert.match(a.elements.workloadStatus.textContent,/Combination unavailable/);
  a.elements.pianoEnable.emit("click");assert.equal(a.socket.frames.at(-1).mask,0);
  a.elements.drumEnable.emit("click");assert.match(a.elements.workloadStatus.textContent,/Combination unavailable/);
  a.ack();a.elements.drumEnable.emit("click");a.elements.drum0.emit("pointerdown",drumEvent(2));a.step(13);
  assert.equal(a.socket.frames.at(-1).kind,"drumPads");
});
test("conservative mode allows three sensors or one discrete plus two sensors",async()=>{
  const a=setup("granted",fullManifest,false);
  await a.elements.motionStart.emit("click");await a.elements.accelStart.emit("click");
  a.elements.pianoEnable.emit("click");await a.elements.rotationStart.emit("click");
  assert.match(a.elements.workloadStatus.textContent,/Combination unavailable/);
  assert.equal(a.elements.rotationStatus.textContent,"");
  a.elements.pianoEnable.emit("click");await a.elements.rotationStart.emit("click");
  assert.match(a.elements.rotationStatus.textContent,/Waiting for a valid/);
  assert.equal(a.socket.frames.length,0);
});
test("experimental choice only when idle; reset on disconnect",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.pianoEnable.emit("click");
  a.elements.workloadMode.emit("click");assert.match(a.elements.workloadMode.textContent,/Enable experimental/);
  a.elements.pianoEnable.emit("click");a.elements.navSetup.emit("click");a.elements.workloadMode.emit("click");a.elements.navPlay.emit("click");
  assert.match(a.elements.workloadMode.textContent,/Use conservative/);
  a.elements.drumEnable.emit("click");a.elements.pianoEnable.emit("click");
  assert.match(a.elements.workloadStatus.textContent,/streams: 2/);
  a.window.emit("pagehide");assert.equal(a.elements.workloadSection.hidden,true);
  assert.match(a.elements.workloadMode.textContent,/Enable experimental/);
});

const touchOnly={...fullManifest,tilt:false,acceleration:false,rotation:false,airDrums:false,drums:0,piano:0,pedals:0};
function mappingResponse(a,rows,overrides={},autoLabels=true){
  a.step(50);const q=a.socket.frames.at(-1);
  a.socket.onmessage({data:JSON.stringify({kind:"mapping",version:8,sequence:q.sequence,page:q.page,pages:1,total:rows.length,detail:true,rows,...overrides})});
  if(autoLabels&&!a.socket.closed&&(overrides.pages??1)===(q.page+1))labelResponse(a,[]);
}
test("v8 keeps controls hidden until complete validated mapping",()=>{
  const a=setup("granted",touchOnly,false,false);
  a.elements.pad.emit("pointerdown",xyEvent(1));assert.equal(a.socket.frames.length,0);
  mappingResponse(a,[[0,1,2,74,1],[2,0,0,60,2]]);
  assert.equal(a.elements.touchSection.hidden,false);
  assert.match(a.elements.mappingDetails.textContent,/Ch 3 · CC 74/);
  assert.match(a.elements.mappingDetails.textContent,/Note 60 ×2/);
  a.step(13);a.elements.pad.emit("pointerdown",xyEvent(1));assert.equal(a.socket.frames.at(-1).kind,"touch");
});
test("v8 rejects wrong coverage, malformed targets, wrong sequence and duplicate members",()=>{
  for(const [rows,overrides] of [[[[9,0,0,60,1]],{}],[[[0,1,0,64,1]],{}],[[[0,1,0,74,1]],{sequence:99}],[[[0,1,0,74,1],[0,1,0,74,1]],{}]]){
    const a=setup("granted",touchOnly,false,false);mappingResponse(a,rows,overrides);assert.equal(a.socket.closed,true);assert.equal(a.elements.touchSection.hidden,true);
  }
  const a=setup("granted",touchOnly,false,false);a.step(50);
  a.socket.onmessage({data:'{"kind":"mapping","version":8,"sequence":2,"page":0,"pages":1,"total":1,"detail":true,"rows":[[0,1,0,74,1]],"page":0}'});
  assert.equal(a.socket.closed,true);
});
test("v8 stages two pages and rejects interrupted negotiation",()=>{
  const a=setup("granted",touchOnly,false,false);
  mappingResponse(a,Array.from({length:8},(_,i)=>[0,1,0,70+i,1]),{pages:2,total:9});
  assert.equal(a.elements.touchSection.hidden,true);
  mappingResponse(a,[[2,0,0,60,1]],{pages:2,total:9});
  assert.equal(a.elements.touchSection.hidden,false);assert.match(a.elements.mappingDetails.textContent,/Note 60/);
  a.window.emit("pagehide");assert.equal(a.elements.mappingDetails.textContent,"");
  const b=setup("granted",touchOnly,false,false);b.step(50);b.step(220);assert.equal(b.socket.closed,true);
});
test("v8 custom piano disables scale; exact default note enables it",()=>{
  const manifest={...touchOnly,touch:false,piano:1};
  for(const note of [48,62]){
    const a=setup("granted",manifest,false,false);mappingResponse(a,[[17,0,0,note,1]]);
    assert.equal(a.elements.pianoScale.disabled,note!==48);
    assert.equal(a.elements.piano0.textContent,note===48?"C3":"K1");
  }
});

function labelResponse(a,rows,overrides={}){
  a.step(50);const q=a.socket.frames.at(-1);
  a.socket.onmessage({data:JSON.stringify({kind:"mappingLabels",version:8,sequence:q.sequence,page:q.page,pages:1,total:rows.length,rows,...overrides})});
}
test("label negotiation stages metadata and renders literal custom text",()=>{
  const a=setup("granted",touchOnly,false,false);
  mappingResponse(a,[[0,1,0,74,1]],{},false);
  assert.equal(a.elements.touchSection.hidden,true);
  labelResponse(a,[[0,"PGI-bGl0ZXJhbDwvYj4"]]);
  assert.equal(a.elements.touchSection.hidden,false);
  assert.match(a.elements.mappingDetails.textContent,/<b>literal<\/b> \(X\)/);
  a.window.emit("pagehide");assert.equal(a.elements.mappingDetails.textContent,"");
});
test("labels reject noncanonical base64, invalid UTF8, controls and unknown IDs",()=>{
  for(const row of [[0,"YR"],[0,"_w"],[0,"Cg"],[0,"4oCu"],[1,"YQ"]]){
    const a=setup("granted",touchOnly,false,false);
    mappingResponse(a,[[0,1,0,74,1]],{},false);labelResponse(a,[row]);
    assert.equal(a.socket.closed,true);assert.equal(a.elements.touchSection.hidden,true);
  }
});
test("labels remain hidden during multiple pages and reject duplicates",()=>{
  const a=setup("granted",touchOnly,false,false);
  mappingResponse(a,[[0,1,0,74,1],[2,0,0,60,1]],{},false);
  labelResponse(a,[[0,"V2Fo"]],{pages:2,total:2});
  assert.equal(a.elements.touchSection.hidden,true);
  labelResponse(a,[[0,"V2Fo"]],{pages:2,total:2});assert.equal(a.socket.closed,true);
});

test("global release cancels unsent onsets and awaits pending owner release",()=>{
  const a=setup();a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));
  a.elements.pad.emit("pointerdown",xyEvent(2));a.elements.pad.emit("pointerup",xyEvent(2));
  a.elements.releaseAll.emit("click");
  a.elements.drumEnable.emit("click");a.elements.drum0.emit("pointerdown",drumEvent(3));
  a.ack();assert.equal(a.socket.frames.at(-1).kind,"pianoKeys");assert.equal(a.socket.frames.at(-1).mask,0);
  assert.equal(a.socket.frames.some(f=>f.kind==="touch"),false);
  assert.equal(a.elements.releaseAll.disabled,true);a.ack();
  assert.match(a.elements.status.textContent,/required Mac acknowledgments received/);
  assert.equal(a.elements.releaseAll.disabled,false);
});
test("global release pending sensor arm follows ACK with release",async()=>{
  const a=setup();await a.elements.motionStart.emit("click");a.orientation(5);a.step();
  assert.equal(a.socket.frames.at(-1).kind,"orientationArm");a.elements.releaseAll.emit("click");a.ack();
  assert.equal(a.socket.frames.at(-1).kind,"motionRelease");a.ack();
  assert.equal(a.window.events.has("deviceorientation"),false);
  assert.match(a.elements.status.textContent,/required Mac acknowledgments received/);
});
test("global release preserves touch release order and closes on missing ACK",()=>{
  const a=setup();a.elements.pad.emit("pointerdown",xyEvent(1));a.elements.releaseAll.emit("click");a.ack();
  assert.equal(a.socket.frames.at(-1).kind,"release");
  a.step(220);assert.equal(a.socket.closed,true);
});
test("global release idle sends no synthetic MIDI frame",()=>{
  const a=setup();a.elements.releaseAll.emit("click");assert.equal(a.socket.frames.length,0);
  assert.match(a.elements.status.textContent,/My controls released locally/);
});

test("views are gated by readiness and release acknowledgments",()=>{
  const a=setup("granted",fullManifest,false,false);
  a.elements.navPlay.emit("click");assert.equal(a.elements.connectionView.hidden,false);
  a.withheld();assert.equal(a.elements.playView.hidden,false);
  a.elements.pianoEnable.emit("click");a.elements.piano0.emit("pointerdown",drumEvent(1));
  a.elements.navSetup.emit("click");assert.equal(a.elements.playView.hidden,false);
  a.elements.releaseAll.emit("click");a.ack();
  a.elements.navSetup.emit("click");assert.equal(a.elements.setupView.hidden,true);
  a.ack();a.elements.navSetup.emit("click");assert.equal(a.elements.setupView.hidden,false);
  a.elements.pad.emit("pointerdown",xyEvent(2));assert.equal(a.socket.frames.at(-1).mask,0);
  a.elements.navConnection.emit("click");assert.equal(a.elements.connectionView.hidden,false);
  a.window.emit("pagehide");assert.equal(a.elements.navPlay.disabled,true);
});
test("ACK latency reports only observed response time and resets on close",()=>{
  const a=setup();assert.match(a.elements.ackLatency.textContent,/no recent sample/);
  a.elements.pad.emit("pointerdown",xyEvent(1));a.ack(37);
  assert.match(a.elements.ackLatency.textContent,/37 ms/);
  assert.match(a.elements.ackLatency.textContent,/Not MIDI\/audio latency/);
  a.window.emit("pagehide");assert.match(a.elements.ackLatency.textContent,/no recent sample/);
});

test("metadata waits a full 50ms after ACK despite delayed delivery",()=>{
  const a=setup("granted",touchOnly,false,false);
  a.step(50);const first=a.socket.frames.at(-1);
  a.step(40);
  a.socket.onmessage({data:JSON.stringify({kind:"mapping",version:8,sequence:first.sequence,page:0,pages:1,total:1,detail:true,rows:[[0,1,0,74,1]]})});
  a.step(49);assert.equal(a.socket.frames.length,1);
  a.step(1);assert.equal(a.socket.frames.at(-1).kind,"mappingLabels");
  assert.equal(a.socket.sendTimes.at(-1)-a.socket.sendTimes.at(-2),90);
});
test("full 64 destination rows and 49 labels complete within bounded metadata phase",()=>{
  const a=setup("granted",fullManifest,false,false);
  const rows=Array.from({length:15},(_,i)=>[0,0,0,60+i,1]);
  for(let i=0;i<49;i++){
    const kind=i===42||i===46?3:i>=8&&i<=41?0:1;
    rows.push([i,kind,0,kind===3?0:kind===0?60:74,1]);
  }
  for(let i=0;i<8;i++){
    a.step(50);const q=a.socket.frames.at(-1);assert.equal(q.kind,"mapping");assert.equal(q.page,i);
    const payload=JSON.stringify({kind:"mapping",version:8,sequence:q.sequence,page:i,pages:8,total:64,detail:true,rows:rows.slice(i*8,i*8+8)});
    assert.equal(payload.length<=256,true);a.step(60);a.socket.onmessage({data:payload});
    assert.equal(a.elements.playView.hidden,true);
  }
  for(let i=0;i<49;i++){
    a.step(50);const q=a.socket.frames.at(-1);assert.equal(q.kind,"mappingLabels");assert.equal(q.page,i);
    const payload=JSON.stringify({kind:"mappingLabels",version:8,sequence:q.sequence,page:i,pages:49,total:49,rows:[[i,"QUFB".repeat(21)+"QQ"]]});
    assert.equal(payload.length<=256,true);a.step(60);a.socket.onmessage({data:payload});
    assert.equal(a.elements.playView.hidden,i!==48);
  }
  assert.equal(a.socket.closed,undefined);assert.match(a.elements.mappingDetails.textContent,/A{64}/);
  assert.equal(a.socket.frames.length,57);
});
test("workload refusal is visible in Play and hidden mode action is rejected",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.workloadMode.emit("click");assert.match(a.elements.workloadMode.textContent,/Enable experimental/);
  a.elements.pianoEnable.emit("click");a.elements.drumEnable.emit("click");
  assert.match(a.elements.playWorkloadStatus.textContent,/Combination unavailable/);
});
test("ACK sample median uses even pair average",()=>{
  const a=setup();a.elements.pad.emit("pointerdown",xyEvent(1));a.ack(20);
  a.elements.pad.emit("pointerup",xyEvent(1));a.ack(40);
  assert.match(a.elements.ackLatency.textContent,/30 ms/);
});

test("note strips glide only through mapped zones and retain shared finger ownership",()=>{
  const a=setup("granted",{...fullManifest,piano:(1<<0)|(1<<4)|(1<<7)});
  a.elements.pianoStrips.emit("click");
  assert.equal(a.elements.piano1.hidden,true);
  assert.equal(a.elements.piano4.hidden,false);
  a.elements.pianoEnable.emit("click");
  a.elements.piano0.emit("pointerdown",drumEvent(1));a.ack();
  a.elements.piano0.emit("pointerdown",drumEvent(2));
  a.elements.piano0.emit("pointermove",xyEvent(1,50,50));a.step(25);
  assert.equal(a.socket.frames.at(-1).mask,17);a.ack();
  a.elements.piano0.emit("pointerup",drumEvent(2));a.step(25);
  assert.equal(a.socket.frames.at(-1).mask,16);a.ack();
  a.elements.piano0.emit("pointerup",drumEvent(1));a.step(25);
  assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
});
test("note strips layout cannot change during a held or unacknowledged note",()=>{
  const a=setup();a.elements.pianoStrips.emit("click");a.elements.pianoEnable.emit("click");
  a.elements.piano0.emit("pointerdown",drumEvent(1));
  a.elements.pianoStrips.emit("click");assert.equal(a.elements.pianoStrips.textContent,"Piano layout");
  a.ack();a.elements.piano0.emit("pointerup",drumEvent(1));a.step(25);
  a.elements.pianoStrips.emit("click");assert.equal(a.elements.pianoStrips.textContent,"Piano layout");
  a.ack();a.elements.pianoStrips.emit("click");assert.equal(a.elements.pianoStrips.textContent,"Note strips");
});
test("note strip exit releases once and cannot reattack from a stale pointer",()=>{
  const a=setup();a.elements.pianoStrips.emit("click");a.elements.pianoEnable.emit("click");
  a.elements.piano0.emit("pointerdown",drumEvent(1));a.ack();
  a.elements.piano0.emit("pointermove",xyEvent(1,120,50));a.step(25);
  assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  const count=a.socket.frames.length;
  a.elements.piano0.emit("pointermove",xyEvent(1,50,50));a.step(25);
  assert.equal(a.socket.frames.length,count);
});
test("cancelled strip contact fails closed instead of replaying stale attacks",()=>{
  const a=setup();a.elements.pianoStrips.emit("click");a.elements.pianoEnable.emit("click");
  a.elements.piano0.emit("pointerdown",drumEvent(1));
  a.elements.piano0.emit("pointercancel",drumEvent(1));
  assert.equal(a.socket.closed,true);
  assert.equal(a.elements.pianoEnable.disabled,true);
});


test("group browser waits for neutral ACK before first musical touch",()=>{
  const a=setup("granted",touchOnly,false,true,true);
  assert.equal(a.socket.frames.at(-1).kind,"release");
  assert.equal(a.elements.playView.hidden,true);
  a.elements.pad.emit("pointerdown",xyEvent(1));
  assert.equal(a.socket.frames.length,1);
  a.ack();
  assert.equal(a.elements.playView.hidden,false);
  a.elements.pad.emit("pointerdown",xyEvent(2));
  assert.equal(a.socket.frames.at(-1).kind,"touch");
});
test("group browser neutral handshake covers drum piano and pedal masks",()=>{
  for(const [key,mask,kind] of [["drums",1,"drumPads"],["piano",1,"pianoKeys"],["pedals",8,"pedalboard"]]){
    const manifest={...touchOnly,touch:false,[key]:mask};
    const a=setup("granted",manifest,false,true,true);
    const neutral=a.socket.frames.at(-1);
    assert.equal(neutral.kind,kind);
    assert.equal(neutral.mask,0);
    if(key==="pedals")assert.deepEqual(neutral.levels,[0,0,0,0,0,0]);
    assert.equal(a.elements.playView.hidden,true);
    a.ack();
    assert.equal(a.elements.playView.hidden,false);
  }
});
test("group browser rejects more than two families and missing neutral ACK",()=>{
  const mixed=setup("granted",{...touchOnly,drums:1,piano:1},false,true,true);
  assert.equal(mixed.socket.closed,true);
  const a=setup("granted",touchOnly,false,true,true);
  a.step(221);
  assert.equal(a.socket.closed,true);
  assert.equal(a.elements.playView.hidden,true);
});


test("group browser arms two families before Play and preserves explicit workload consent",()=>{
  const a=setup("granted",{...touchOnly,drums:1},false,true,true);
  assert.equal(a.socket.frames.at(-1).kind,"release");
  a.ack();
  assert.equal(a.socket.frames.at(-1).kind,"drumPads");
  assert.equal(a.socket.frames.at(-1).mask,0);
  assert.equal(a.elements.playView.hidden,true);
  a.ack();
  assert.equal(a.elements.playView.hidden,false);
  a.elements.navSetup.emit("click");
  a.elements.workloadMode.emit("click");
  a.elements.navPlay.emit("click");
  a.elements.drumEnable.emit("click");
  a.elements.drum0.emit("pointerdown",drumEvent(1));
  a.step(25);
  assert.equal(a.socket.frames.at(-1).kind,"drumPads");
  assert.equal(a.socket.frames.at(-1).mask,1);
  a.ack();
  a.elements.pad.emit("pointerdown",xyEvent(2));
  a.step(25);
  assert.equal(a.socket.frames.at(-1).kind,"touch");
  a.ack();
  // The ACK may already have dispatched a due held-drum refresh.
  // A release cannot overtake an in-flight frame on the single ACK lane.
  const beforeRelease=a.socket.frames.length;
  a.elements.pad.emit("pointerup",xyEvent(2));
  if(a.socket.frames.at(-1).kind==="drumPads"){
    assert.equal(a.socket.frames.length,beforeRelease);
    assert.equal(a.socket.frames.at(-1).mask,1);
    a.ack();
  }
  a.step(25);
  assert.equal(a.socket.frames.at(-1).kind,"release");
  a.ack();
  assert.equal(a.socket.closed,undefined);
});

test("group browser cannot enter Play when second neutral ACK is missing",()=>{
  const a=setup("granted",{...touchOnly,pedals:8},false,true,true);
  a.ack();
  assert.equal(a.socket.frames.at(-1).kind,"pedalboard");
  a.step(221);
  assert.equal(a.socket.closed,true);
  assert.equal(a.elements.playView.hidden,true);
});


test("group labels remain read-only and Play waits for labels and neutral ACK",()=>{
  const a=setup("granted",{...touchOnly,touch:false,drums:1},false,false,true);
  a.withheld();
  a.step(50);
  const q=a.socket.frames.at(-1);
  assert.equal(q.kind,"mappingLabels");
  assert.equal(a.elements.playView.hidden,true);
  a.socket.onmessage({data:JSON.stringify({kind:"mappingLabels",version:8,sequence:q.sequence,page:0,pages:1,total:1,rows:[[9,Buffer.from("<Kick>").toString("base64url")]]})});
  assert.equal(a.socket.frames.at(-1).kind,"drumPads");
  assert.equal(a.elements.playView.hidden,true);
  a.ack();
  assert.equal(a.elements.playView.hidden,false);
  assert.match(a.elements.drum0.textContent,/<Kick>/);
  assert.match(a.elements.mappingStatus.textContent,/MIDI addresses remain hidden/);
  assert.doesNotMatch(a.elements.mappingDetails.textContent,/Ch \d/);
  a.elements.disconnect.emit("click");
  assert.doesNotMatch(a.elements.drum0.textContent,/<Kick>/);
});
test("group label for unmapped discrete control fails closed",()=>{
  const a=setup("granted",{...touchOnly,touch:false,drums:1},false,false,true);
  a.withheld();a.step(50);
  const q=a.socket.frames.at(-1);
  a.socket.onmessage({data:JSON.stringify({kind:"mappingLabels",version:8,sequence:q.sequence,page:0,pages:1,total:1,rows:[[10,"U25hcmU"]]})});
  assert.equal(a.socket.closed,true);
  assert.equal(a.elements.playView.hidden,true);
});
test("group refuses misleading channel-only mapping details",()=>{
  const a=setup("granted",touchOnly,false,false,true);
  mappingResponse(a,[[0,1,0,74,1]],{},false);
  assert.equal(a.socket.closed,true);
});


test("layout presentation edits save and restore without sending MIDI",()=>{
  const stored=new Map(),a=setup("granted",fullManifest,false,true,false,stored);
  a.elements.navSetup.emit("click");
  a.elements.layoutPanel.value="pianoSection";a.elements.layoutPanel.emit("change");
  a.elements.layoutUp.emit("click");a.elements.layoutWide.emit("click");
  a.elements.layoutSize.value="large";a.elements.layoutSize.emit("change");
  a.elements.layoutSave.emit("click");
  assert.equal(a.socket.frames.length,0);
  assert.equal(a.elements.pianoSection.style.order,"1");
  assert.equal(a.elements.playView.children[1],a.elements.pianoSection);
  assert.equal(a.elements.pianoSection.attributes["data-wide"],"false");
  assert.equal(a.elements.playView.attributes["data-size"],"large");
  const data=JSON.parse(stored.get("tihulu.remote.presentation.v1"));
  assert.deepEqual(Object.keys(data).sort(),["order","size","version","wide"]);
  const b=setup("granted",fullManifest,false,true,false,stored);
  assert.equal(b.elements.pianoSection.style.order,"1");
  assert.equal(b.elements.playView.attributes["data-size"],"large");
  b.elements.navSetup.emit("click");b.elements.layoutReset.emit("click");
  assert.equal(stored.size,0);assert.equal(b.elements.pianoSection.style.order,"2");
});

test("layout cannot change during active or pending musical ownership",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.pad.emit("pointerdown",{pointerId:1,button:0,clientX:25,clientY:25,preventDefault(){}});
  a.elements.navSetup.emit("click");a.elements.layoutPanel.value="pianoSection";
  a.elements.layoutUp.emit("click");a.elements.layoutSize.value="large";a.elements.layoutSize.emit("change");
  assert.equal(a.elements.pianoSection.style.order,"2");
  assert.equal(a.elements.playView.attributes["data-size"],"normal");
  assert.equal(a.socket.frames.length,1);
  a.ack();a.elements.pad.emit("pointerup",{pointerId:1});a.ack();
  a.elements.navSetup.emit("click");a.elements.layoutUp.emit("click");
  assert.equal(a.elements.pianoSection.style.order,"1");
});

test("malformed stored layout fails closed and unmapped panels cannot be edited",()=>{
  const stored=new Map([["tihulu.remote.presentation.v1",JSON.stringify({version:1,order:["pianoSection"],wide:[],size:"large"})]]);
  const a=setup("granted",{...fullManifest,touch:true,drums:0,piano:0,pedals:0,tilt:false,acceleration:false,rotation:false,airDrums:false},false,true,false,stored);
  assert.equal(a.elements.playView.attributes["data-size"],"normal");
  a.elements.navSetup.emit("click");
  assert.deepEqual(a.elements.layoutPanel.children.map(x=>x.value),["touchSection"]);
  a.elements.layoutPanel.value="pianoSection";a.elements.layoutWide.emit("click");
  assert.equal(a.elements.pianoSection.attributes["data-wide"],"true");
  assert.equal(a.socket.frames.length,0);
});


test("layout preferences never change host admission and storage failure remains local",()=>{
  const stored=new Map();
  stored.set=()=>{throw Error("Storage unavailable")};
  const a=setup("granted",fullManifest,false,true,false,stored);
  a.elements.navSetup.emit("click");
  a.elements.layoutSize.value="compact";a.elements.layoutSize.emit("change");
  a.elements.layoutSave.emit("click");
  assert.match(a.elements.layoutStatus.textContent,/Storage unavailable/);
  assert.equal(a.elements.playView.attributes["data-size"],"compact");
  a.elements.navPlay.emit("click");
  assert.equal(a.elements.layoutSection.hidden,true);
  a.elements.drum0.emit("pointerdown",drumEvent(1));
  assert.equal(a.socket.frames.length,0);
  a.elements.drumEnable.emit("click");
  a.elements.drum0.emit("pointerdown",drumEvent(1));
  assert.equal(a.socket.frames.at(-1).mask,1);
  a.ack();a.elements.drum0.emit("pointerup",drumEvent(1));a.step();a.ack();
  assert.equal(a.socket.frames.at(-1).mask,0);
});


function layoutDragRows(a){
  const handles=a.elements.layoutDragList.children;
  handles.forEach((h,i)=>h.getBoundingClientRect=()=>({top:i*48,height:44,width:200,left:0}));
  return handles;
}
function layoutPointer(pointerId,clientY){return {pointerId,clientY,button:0,preventDefault(){}};}
test("mobile pointer drag reorders mapped panels without any musical messages",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.navSetup.emit("click");
  const handles=layoutDragRows(a),piano=handles[2];
  piano.emit("pointerdown",layoutPointer(1,110));
  piano.emit("pointermove",layoutPointer(1,5));
  assert.equal(handles[0].attributes["data-target"],"true");
  piano.emit("pointerup",layoutPointer(1,5));
  assert.equal(a.elements.playView.children[0],a.elements.pianoSection);
  assert.equal(a.elements.playView.children[1],a.elements.touchSection);
  assert.equal(a.elements.playView.children[2],a.elements.drumSection);
  assert.equal(a.socket.frames.length,0);
});
test("mobile layout drag cancellation and stale pointer cannot reorder",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.navSetup.emit("click");
  const handles=layoutDragRows(a),piano=handles[2];
  piano.emit("pointerdown",layoutPointer(1,110));
  piano.emit("pointercancel",layoutPointer(1,5));
  piano.emit("pointerup",layoutPointer(1,5));
  assert.equal(a.elements.pianoSection.style.order,"2");
  piano.emit("pointerdown",layoutPointer(2,110));
  a.elements.navPlay.emit("click");
  piano.emit("pointerup",layoutPointer(2,5));
  assert.equal(a.elements.pianoSection.style.order,"2");
  assert.equal(a.socket.frames.length,0);
});


test("idle heartbeat does not interrupt mobile layout drag or alter liveness wire",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.navSetup.emit("click");
  const handles=layoutDragRows(a),piano=handles[2];
  piano.emit("pointerdown",layoutPointer(1,110));
  a.step(500);
  assert.equal(a.socket.frames.at(-1).kind,"heartbeat");
  piano.emit("pointermove",layoutPointer(1,5));
  piano.emit("pointerup",layoutPointer(1,5));
  assert.equal(a.elements.pianoSection.style.order,"0");
  assert.deepEqual(a.socket.frames.map(x=>x.kind),["heartbeat"]);
  a.ack();
  assert.equal(a.socket.closed,undefined);
});
test("obsolete mobile drag handles cannot mutate a rebuilt layout",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.navSetup.emit("click");
  const old=layoutDragRows(a)[2];
  old.emit("pointerdown",layoutPointer(1,110));
  old.emit("pointerup",layoutPointer(1,5));
  assert.equal(a.elements.pianoSection.style.order,"0");
  old.emit("pointerdown",layoutPointer(1,5));
  old.emit("pointerup",layoutPointer(1,220));
  assert.equal(a.elements.pianoSection.style.order,"0");
  assert.equal(a.socket.frames.length,0);
});

test("per-panel presentation overrides inherit, persist and retain original MIDI masks",()=>{
  const stored=new Map(),a=setup("granted",fullManifest,false,true,false,stored);
  a.elements.navSetup.emit("click");
  a.elements.layoutPanel.value="drumSection";a.elements.layoutPanel.emit("change");
  a.elements.panelSize.value="large";a.elements.panelSize.emit("change");
  a.elements.panelColumns.value="2";a.elements.panelColumns.emit("change");
  a.elements.layoutSize.value="compact";a.elements.layoutSize.emit("change");
  assert.equal(a.elements.drumSection.attributes["data-size"],"large");
  assert.equal(a.elements.touchSection.attributes["data-size"],"compact");
  assert.equal(a.elements.drumGrid.attributes["data-columns"],"2");
  a.elements.layoutSave.emit("click");
  const b=setup("granted",fullManifest,false,true,false,stored);
  assert.equal(b.elements.drumSection.attributes["data-size"],"large");
  assert.equal(b.elements.drumGrid.attributes["data-columns"],"2");
  b.elements.drumEnable.emit("click");b.elements.drum3.emit("pointerdown",drumEvent(2));
  assert.equal(b.socket.frames.at(-1).mask,8);
  b.ack();b.elements.drum3.emit("pointerup",drumEvent(2));b.step();b.ack();
  assert.equal(b.socket.frames.at(-1).mask,0);
});
test("invalid detail data cannot override mapped controls or layout",()=>{
  const stored=new Map([["tihulu.remote.panel-details.v1",JSON.stringify({version:1,sizes:{touchSection:"huge"},columns:{drumSection:"99"}})]]);
  const a=setup("granted",fullManifest,false,true,false,stored);
  assert.equal(a.elements.touchSection.attributes["data-size"],"normal");
  assert.equal(a.elements.drumGrid.attributes["data-columns"],"auto");
  a.elements.navSetup.emit("click");
  a.elements.layoutPanel.value="tiltSection";a.elements.layoutPanel.emit("change");
  assert.equal(a.elements.panelSize.disabled,true);
  a.elements.panelSize.value="large";a.elements.panelSize.emit("change");
  assert.equal(a.elements.tiltSection.attributes["data-size"],"normal");
  assert.equal(a.socket.frames.length,0);
});

function setHoldPedal(a,i){
  a.elements.navSetup.emit("click");
  a.elements["pedalMode"+i].value="hold";a.elements["pedalMode"+i].emit("change");
  a.elements.navPlay.emit("click");a.elements.pedalEnable.emit("click");
}
test("hold pedal queues short press and lift without synthetic click retrigger",()=>{
  const a=setup("granted",fullManifest,false);setHoldPedal(a,3);
  const b=a.elements.pedalToggle3;
  b.emit("pointerdown",drumEvent(1));b.emit("pointerup",drumEvent(1));b.emit("click");
  assert.equal(a.socket.frames.length,1);assert.equal(a.socket.frames[0].mask,8);
  a.ack();a.step();assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  assert.equal(a.socket.frames.length,2);
});
test("hold pedal retains independent fingers and toggle FX",()=>{
  const a=setup("granted",fullManifest,false);setHoldPedal(a,3);
  const b=a.elements.pedalToggle3;
  b.emit("pointerdown",drumEvent(1));a.ack();
  b.emit("pointerdown",drumEvent(2));b.emit("pointerup",drumEvent(1));
  a.elements.pedalToggle4.emit("click");a.step();assert.equal(a.socket.frames.at(-1).mask,24);a.ack();
  b.emit("pointercancel",drumEvent(2));a.step();assert.equal(a.socket.frames.at(-1).mask,16);a.ack();
  a.elements.pedalToggle4.emit("click");a.step();assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
});
test("release all clears held pedal owners before stale pointer up",()=>{
  const a=setup("granted",fullManifest,false);setHoldPedal(a,5);
  const b=a.elements.pedalToggle5;
  b.emit("pointerdown",drumEvent(3));
  a.elements.releaseAll.emit("click");
  a.ack();a.step();assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  b.emit("pointerup",drumEvent(3));b.emit("click");
  assert.equal(a.socket.frames.length,2);
});
test("hold mode persists and keyboard repeat cannot latch a pedal",()=>{
  const stored=new Map(),a=setup("granted",fullManifest,false,true,false,stored);
  a.elements.navSetup.emit("click");a.elements.pedalMode4.value="hold";a.elements.pedalMode4.emit("change");
  a.elements.layoutSave.emit("click");
  const b=setup("granted",fullManifest,false,true,false,stored);
  b.elements.pedalEnable.emit("click");
  const p=b.elements.pedalToggle4,key={key:" ",preventDefault(){}};
  p.emit("keydown",key);p.emit("keydown",{...key,repeat:true});a.elements.pedalMode4.value="toggle";
  b.ack();p.emit("blur");b.step();assert.equal(b.socket.frames.at(-1).mask,0);b.ack();
  assert.deepEqual(b.socket.frames.map(x=>x.mask),[16,0]);
});

test("individual drum order retains unmapped slots and original wire identity",()=>{
  const stored=new Map(),manifest={...fullManifest,drums:5};
  const a=setup("granted",manifest,false,true,false,stored);
  a.elements.navSetup.emit("click");a.elements.layoutPanel.value="drumSection";a.elements.layoutPanel.emit("change");
  assert.deepEqual(a.elements.gridControl.children.map(x=>x.value),["0","2"]);
  a.elements.gridControl.value="2";a.elements.gridControl.emit("change");a.elements.gridControlUp.emit("click");
  assert.equal(a.elements.drumGrid.children[0],a.elements.drum2);
  assert.equal(a.elements.drumGrid.children[1],a.elements.drum1);
  a.elements.layoutSave.emit("click");
  const b=setup("granted",manifest,false,true,false,stored);
  assert.equal(b.elements.drumGrid.children[0],b.elements.drum2);
  b.elements.drumEnable.emit("click");b.elements.drum2.emit("pointerdown",drumEvent(4));
  assert.equal(b.socket.frames.at(-1).mask,4);b.ack();
  b.elements.drum2.emit("pointerup",drumEvent(4));b.step();b.ack();
  assert.equal(b.socket.frames.at(-1).mask,0);
});
test("individual pedal order never changes logical switch or unmapped admission",()=>{
  const a=setup("granted",{...fullManifest,pedals:40},false);
  assert.equal(a.elements.pedalCell0.hidden,true);
  a.elements.navSetup.emit("click");a.elements.layoutPanel.value="pedalSection";a.elements.layoutPanel.emit("change");
  assert.deepEqual(a.elements.gridControl.children.map(x=>x.value),["3","5"]);
  a.elements.gridControl.value="5";a.elements.gridControl.emit("change");a.elements.gridControlUp.emit("click");
  assert.equal(a.elements.pedalGrid.children[3],a.elements.pedalCell5);
  a.elements.navPlay.emit("click");a.elements.pedalEnable.emit("click");
  a.elements.pedalToggle0.emit("click");assert.equal(a.socket.frames.length,0);
  a.elements.pedalToggle5.emit("click");assert.equal(a.socket.frames.at(-1).mask,32);
});

test("custom panel moves existing mapped nodes and retains wire identities",()=>{
  const stored=new Map(),a=setup("granted",fullManifest,true,true,false,stored);
  a.elements.navSetup.emit("click");
  for(const id of ["d2","p4","p0"]){a.elements.customAddChoice.value=id;a.elements.customAdd.emit("click");}
  assert.deepEqual(a.elements.customGrid.children,[a.elements.drum2,a.elements.pedalCell4,a.elements.pedalCell0]);
  assert.equal(a.elements.drumGrid.children.includes(a.elements.drum2),false);
  assert.equal(a.elements.pedalGrid.children.includes(a.elements.pedalCell4),false);
  a.elements.customChoice.value="p4";a.elements.customUp.emit("click");a.elements.layoutSave.emit("click");
  const b=setup("granted",fullManifest,true,true,false,stored);
  assert.equal(b.elements.customGrid.children[0],b.elements.pedalCell4);
  b.elements.customDrumEnable.emit("click");b.elements.drum2.emit("pointerdown",drumEvent(2));
  assert.equal(b.socket.frames.at(-1).mask,4);b.ack();
  b.elements.drum2.emit("pointerup",drumEvent(2));b.step();b.ack();
  b.elements.customDrumEnable.emit("click");b.elements.customPedalEnable.emit("click");
  b.elements.pedalToggle4.emit("click");b.step();assert.equal(b.socket.frames.at(-1).mask,16);
});
test("custom panel rejects unavailable aliases and preserves dormant selections",()=>{
  const stored=new Map([["tihulu.remote.panel-details.v1",JSON.stringify({version:1,sizes:{},columns:{},custom:["d2","p4"]})]]);
  const a=setup("granted",{...fullManifest,drums:1,pedals:0},false,true,false,stored);
  assert.equal(a.elements.customSection.hidden,true);
  a.elements.navSetup.emit("click");a.elements.customAddChoice.value="d2";a.elements.customAdd.emit("click");
  assert.equal(a.elements.customGrid.children.length,0);
  a.elements.customAddChoice.value="d0";a.elements.customAdd.emit("click");
  assert.equal(a.elements.customGrid.children[0],a.elements.drum0);
  a.elements.customChoice.value="d0";a.elements.customRemove.emit("click");
  assert.equal(a.elements.customGrid.children.length,0);
  assert.equal(a.elements.drumGrid.children[0],a.elements.drum0);
  a.elements.layoutSave.emit("click");
  assert.deepEqual(JSON.parse(stored.get("tihulu.remote.panel-details.v1")).custom,["d2","p4"]);
  assert.equal(a.socket.frames.length,0);
});

test("slider orientation and initial level persist without implicit activation",()=>{
  const stored=new Map(),a=setup("granted",fullManifest,false,true,false,stored);
  a.elements.navSetup.emit("click");
  a.elements.sliderChoice.value="2";a.elements.sliderChoice.emit("change");
  a.elements.sliderDirection.value="vertical";a.elements.sliderDefault.value="37";a.elements.sliderApply.emit("click");
  a.elements.layoutSave.emit("click");
  assert.equal(a.elements.pedalLevel2.attributes["aria-orientation"],"vertical");
  assert.equal(a.socket.frames.length,0);
  const b=setup("granted",fullManifest,false,true,false,stored);
  assert.equal(b.elements.pedalLevel2.value,"37");
  assert.equal(b.elements.pedalLevel2.attributes["data-vertical"],"true");
  b.elements.pedalEnable.emit("click");assert.equal(b.socket.frames.length,0);
  b.elements.pedalToggle2.emit("click");assert.equal(b.socket.frames.at(-1).mask,4);
  assert.equal(b.socket.frames.at(-1).levels[2],0.37);
});
test("slider settings reject invalid numeric values and cannot edit while active",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.navSetup.emit("click");
  a.elements.sliderChoice.value="0";a.elements.sliderChoice.emit("change");
  a.elements.sliderDefault.value="101";a.elements.sliderApply.emit("click");
  assert.equal(a.elements.pedalLevel0.value,"100");
  a.elements.navPlay.emit("click");a.elements.pedalEnable.emit("click");a.elements.pedalToggle0.emit("click");a.ack();
  a.elements.navSetup.emit("click");a.elements.sliderDefault.value="1";a.elements.sliderApply.emit("click");
  assert.equal(a.elements.pedalLevel0.value,"100");assert.equal(a.socket.frames.length,1);
});
test("custom panel focus order follows visual order and moved controls leave original editor",()=>{
  const a=setup("granted",fullManifest,false);
  a.elements.navSetup.emit("click");a.elements.customAddChoice.value="d2";a.elements.customAdd.emit("click");
  assert.equal(a.elements.playView.children[0],a.elements.customSection);
  a.elements.layoutPanel.value="drumSection";a.elements.layoutPanel.emit("change");
  assert.equal(a.elements.gridControl.children.some(x=>x.value==="2"),false);
});

test("custom panel family release uses existing owners and ignores inactive families",()=>{
  const stored=new Map([["tihulu.remote.panel-details.v1",JSON.stringify({version:1,sizes:{},columns:{},custom:["d2","p4"]})]]);
  const a=setup("granted",fullManifest,false,true,false,stored);
  a.elements.customDrumRelease.emit("click");a.elements.customPedalRelease.emit("click");
  assert.equal(a.socket.frames.length,0);
  a.elements.customDrumEnable.emit("click");a.elements.drum2.emit("pointerdown",drumEvent(2));
  assert.equal(a.socket.frames.at(-1).mask,4);a.ack();
  a.elements.customDrumRelease.emit("click");a.step();
  assert.equal(a.socket.frames.at(-1).kind,"drumPads");
  assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  a.elements.drum2.emit("pointerup",drumEvent(2));
  a.elements.customDrumEnable.emit("click");a.elements.customPedalEnable.emit("click");
  a.elements.pedalToggle4.emit("click");a.step();
  assert.equal(a.socket.frames.at(-1).mask,16);a.ack();
  a.elements.customPedalRelease.emit("click");a.step();
  assert.equal(a.socket.frames.at(-1).kind,"pedalboard");
  assert.equal(a.socket.frames.at(-1).mask,0);a.ack();
  assert.deepEqual(a.socket.frames.filter(f=>f.kind==="drumPads").map(f=>f.mask),[4,0]);
  assert.deepEqual(a.socket.frames.filter(f=>f.kind==="pedalboard").map(f=>f.mask),[16,0]);
});

test("dormant custom controls can be removed from a full saved panel",()=>{
  const saved=["d1","d2","d3","d4","d5","d6","d7","p4"];
  const stored=new Map([["tihulu.remote.panel-details.v1",JSON.stringify({version:1,sizes:{},columns:{},custom:saved})]]);
  const a=setup("granted",{...fullManifest,drums:1,pedals:0},false,true,false,stored);
  a.elements.navSetup.emit("click");
  assert.equal(a.elements.customAdd.disabled,true);
  assert.equal(a.elements.customChoice.children.length,8);
  a.elements.customChoice.value="p4";a.elements.customChoice.emit("change");
  a.elements.customRemove.emit("click");
  a.elements.customAddChoice.value="d0";a.elements.customAdd.emit("click");
  a.elements.layoutSave.emit("click");
  assert.deepEqual(JSON.parse(stored.get("tihulu.remote.panel-details.v1")).custom,[...saved.slice(0,7),"d0"]);
  assert.deepEqual(a.elements.customGrid.children,[a.elements.drum0]);
  assert.equal(a.socket.frames.length,0);
});
test("dormant custom reorder preserves saved identities and emits no frames",()=>{
  const stored=new Map([["tihulu.remote.panel-details.v1",JSON.stringify({version:1,sizes:{},columns:{},custom:["d1","d0"]})]]);
  const a=setup("granted",{...fullManifest,drums:1,pedals:0},false,true,false,stored);
  a.elements.navSetup.emit("click");
  a.elements.customChoice.value="d1";a.elements.customDown.emit("click");
  a.elements.layoutSave.emit("click");
  assert.deepEqual(JSON.parse(stored.get("tihulu.remote.panel-details.v1")).custom,["d0","d1"]);
  assert.deepEqual(a.elements.customGrid.children,[a.elements.drum0]);
  assert.equal(a.socket.frames.length,0);
});

test("custom grid columns persist and reject invalid or active edits without sending MIDI",()=>{
  const stored=new Map(),a=setup("granted",fullManifest,false,true,false,stored);
  a.elements.navSetup.emit("click");
  a.elements.customColumns.value="3";a.elements.customColumns.emit("change");
  a.elements.layoutSave.emit("click");
  assert.equal(a.elements.customGrid.attributes["data-columns"],"3");
  assert.equal(JSON.parse(stored.get("tihulu.remote.panel-details.v1")).customColumns,"3");
  a.elements.customColumns.value="99";a.elements.customColumns.emit("change");
  assert.equal(a.elements.customColumns.value,"3");
  assert.equal(a.socket.frames.length,0);
  const b=setup("granted",fullManifest,false,true,false,stored);
  assert.equal(b.elements.customGrid.attributes["data-columns"],"3");
  b.elements.customColumns.value="1";b.elements.customColumns.emit("change");
  assert.equal(b.elements.customGrid.attributes["data-columns"],"3");
  assert.equal(b.socket.frames.length,0);
  b.elements.navSetup.emit("click");b.elements.layoutReset.emit("click");
  assert.equal(b.elements.customGrid.attributes["data-columns"],"2");
});

test("fully moved surface hides only empty originals and retains release controls",()=>{
  const stored=new Map(),manifest={...fullManifest,drums:4,pedals:16};
  const a=setup("granted",manifest,false,true,false,stored);
  a.elements.navSetup.emit("click");
  for(const id of ["d2","p4"]){
    a.elements.customAddChoice.value=id;a.elements.customAdd.emit("click");
  }
  assert.equal(a.elements.drumSection.hidden,true);
  assert.equal(a.elements.pedalSection.hidden,true);
  assert.equal(a.elements.customSection.hidden,false);
  assert.equal(a.elements.customDrumRelease.hidden,false);
  assert.equal(a.elements.customPedalRelease.hidden,false);
  a.elements.layoutSave.emit("click");
  const b=setup("granted",manifest,false,true,false,stored);
  assert.equal(b.elements.drumSection.hidden,true);
  b.elements.customDrumEnable.emit("click");
  b.elements.drum2.emit("pointerdown",drumEvent(7));
  assert.equal(b.socket.frames.at(-1).mask,4);b.ack();
  b.elements.customDrumRelease.emit("click");b.step();b.ack();
  assert.equal(b.socket.frames.at(-1).mask,0);
  b.elements.customDrumEnable.emit("click");
  b.elements.navSetup.emit("click");
  b.elements.customChoice.value="d2";b.elements.customRemove.emit("click");
  assert.equal(b.elements.drumSection.hidden,false);
  assert.equal(b.elements.pedalSection.hidden,true);
  assert.equal(b.elements.customDrumRelease.hidden,true);
  assert.equal(b.elements.drumGrid.children.includes(b.elements.drum2),true);
  assert.deepEqual(b.socket.frames.filter(f=>f.kind==="drumPads").map(f=>f.mask),[4,0]);
});
