const {test}=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const path=require("node:path");
const source=fs.readFileSync(path.join(__dirname,"../Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"),"utf8");
const script=source.split('private static let script = #"""')[1].split('"""#')[0]
  .replaceAll("__REMOTE_ORIGIN__","https://local.test").replaceAll("__REMOTE_SOCKET__","wss://local.test");
function setup(permission="granted"){
  let time=1000, ticker, socket;
  function target(){return {events:new Map(),disabled:false,value:"",style:{},textContent:"",
    setAttribute(){},addEventListener(n,f){this.events.set(n,f)},removeEventListener(n,f){if(this.events.get(n)===f)this.events.delete(n)},
    emit(n,e={}){return this.events.get(n)?.(e)},setPointerCapture(){},getBoundingClientRect(){return {width:100,height:100,left:0,top:0}}};}
  const elements=Object.fromEntries(["pad","dot","secret","connect","disconnect","status","motionStart","motionStop","tiltMeter","motionStatus"].map(k=>[k,target()]));
  const document=Object.assign(target(),{hidden:false,getElementById:id=>elements[id]});
  const window=Object.assign(target(),{isSecureContext:true,DeviceOrientationEvent:{requestPermission:async()=>permission},screen:{orientation:target()}});
  class WS{
    static OPEN=1;
    constructor(){socket=this;this.readyState=1;this.bufferedAmount=0;this.protocol="tihulu-touch-v1";this.frames=[];}
    send(data){if(typeof data==="string")this.frames.push(JSON.parse(data));}
    close(){this.closed=true;}
  }
  vm.runInNewContext(script,{document,window,location:{origin:"https://local.test"},WebSocket:WS,performance:{now:()=>time},
    setTimeout:()=>1,clearTimeout(){},setInterval:f=>(ticker=f,1),clearInterval(){ticker=null;}});
  elements.secret.value="aa".repeat(32);elements.connect.emit("click");socket.onopen();socket.onmessage({data:"admitted"});
  return {elements,window,document,socket,step(ms=25){time+=ms;ticker?.()},ack(){socket.onmessage({data:"accepted"})},
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
