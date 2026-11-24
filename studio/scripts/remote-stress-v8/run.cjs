"use strict";
const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
const {run,subsets}=require("./perf3-scheduler.cjs");
const source=fs.readFileSync(process.argv[2]||path.join(__dirname,"../../Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"),"utf8");
const inherited=fs.readFileSync(path.join(__dirname,"stress.cjs"),"utf8"),experiment=fs.readFileSync(path.join(__dirname,"capacity-experiments.cjs"),"utf8");
const execute=(script,g)=>vm.runInNewContext(script,g);
(async()=>{
 const result=await run(source,inherited,experiment,execute,["actual"]);
 const sub=await subsets(source,inherited,experiment,execute,"actual");
 const safe=await subsets(source,inherited,experiment.replace("h.setup(script,execute,profile)","h.setup(script,execute,{...profile,experimental:false})"),execute,"actual");
 const eligible=safe.rows.filter(x=>{let d=0,q=0;for(let i=0;i<7;i++)if(x.mask&(1<<i)){if([0,4,5,6].includes(i))d++;else q++;}return d===0||d===1&&q<=2;});
 console.log(JSON.stringify({representative:result,lifecycle:result.faults,experimental:sub,conservative:eligible},null,2));
 process.exitCode=eligible.some(x=>!x.hold||!x.burst)||result.faults.actual.some(x=>!x.pass)?1:0;
})().catch(e=>{console.error(e);process.exitCode=2;});
