"use strict";
function load(s,exports){const m={exports:{}};new Function("module",s+"\nmodule.exports="+exports+";")(m);return m.exports;}
const pointer=(id,x=25,y=25)=>({pointerId:id,button:0,clientX:x,clientY:y,preventDefault(){}});
async function run(source,inherited,experiment,execute){
  const e=load(experiment,"{helpers,variant}"),h=e.helpers(inherited),s=e.variant(h.extract(source),"pacedEdgeFirst"),rows=[];
  function setup(options){const a=h.setup(s,execute,options);a.c.run(100);return a;}
  function record(name,a,pass,extra={}){rows.push({name,pass,closed:a.closed,active:[...a.host.active.keys()],maxFlight:a.maxFlight,...extra});}
  {
    const a=setup({rtt:10,drop:f=>f.kind==="touch"});
    const at=a.c.now;a.el("pad").emit("pointerdown",pointer(1));a.c.run(219);
    const before=!a.closed;a.c.run(1);record("missing ACK closes at 220 ms",a,before&&a.closed?.at-at===220&&a.host.active.size===0,{elapsed:a.closed?.at-at});
  }
  {
    const a=setup({rtt:10,drop:f=>f.kind==="pianoKeys"});
    a.el("pianoEnable").emit("click");a.el("piano0").emit("pointerdown",pointer(1));a.c.run(10);
    const at=a.c.now;a.el("pad").emit("pointerdown",pointer(2));a.el("pad").emit("pointerup",pointer(2));a.c.run(200);
    const touch=a.received.filter(x=>x.f.kind==="touch");
    record("stale queued XY onset closes without stale send",a,Boolean(a.closed)&&a.closed.status.includes("Touch input delayed")&&touch.length===0&&a.host.active.size===0,{age:a.closed?.at-at,touchFrames:touch.length});
  }
  {
    const a=setup({rtt:10});a.socket.bufferedAmount=257;a.el("pad").emit("pointerdown",pointer(1));a.c.run(50);
    record("transport backlog closes",a,Boolean(a.closed)&&a.closed.status.includes("Backlog")&&a.host.active.size===0);
  }
  {
    const a=setup({rtt:20});a.el("pad").emit("pointerdown",pointer(1));a.c.run(40);a.window.emit("pagehide");a.c.run(100);
    record("pagehide closes active touch",a,Boolean(a.closed)&&a.closed.status==="Page hidden."&&a.host.active.size===0);
  }
  {
    const a=setup({rtt:20});a.el("pianoEnable").emit("click");a.el("piano0").emit("pointerdown",pointer(1));
    a.c.run(2);a.el("pad").emit("pointerdown",pointer(2,25,25));a.c.run(2);a.el("pad").emit("pointermove",pointer(2,80,80));a.c.run(2);
    a.el("pad").emit("pointerup",pointer(3));a.el("pad").emit("pointerup",pointer(2));a.c.run(150);
    const wire=a.received.filter(x=>["touch","release"].includes(x.f.kind)).map(x=>x.f);
    record("queued onset retains down coordinates; foreign lift ignored",a,!a.closed&&wire.length===2&&wire[0].kind==="touch"&&wire[0].x===.25&&wire[0].y===.75&&wire[1].kind==="release",{wire});
  }
  {
    const a=setup({rtt:10});await a.el("motionStart").emit("click");a.window.emit("deviceorientation",{alpha:0,beta:10,gamma:0});a.c.run(300);
    record("stale sensor stops connection",a,Boolean(a.closed)&&a.closed.status.includes("Orientation stopped")&&a.host.active.size===0);
  }
  return rows;
}
if(typeof module!=="undefined")module.exports={run};
if(typeof require!=="undefined"&&typeof module!=="undefined"&&require.main===module){
  const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
  run(fs.readFileSync(process.argv[2]||path.join(__dirname,"../../Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"),"utf8"),fs.readFileSync(path.join(__dirname,"stress.cjs"),"utf8"),fs.readFileSync(path.join(__dirname,"capacity-experiments.cjs"),"utf8"),(s,g)=>vm.runInNewContext(s,g))
    .then(x=>{console.log(JSON.stringify(x,null,2));process.exitCode=x.every(r=>r.pass)?0:1;}).catch(e=>{console.error(e);process.exitCode=2;});
}
