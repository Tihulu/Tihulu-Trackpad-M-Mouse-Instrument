"use strict";
// Exhaustive nonempty subsets, using the isolated paced prototype.
// This is an admission-policy experiment, not production logic.
function load(source,extra){
  const m={exports:{}};new Function("module",source+"\nmodule.exports="+extra+";")(m);return m.exports;
}
async function run(source,inherited,experiment,execute){
  const e=load(experiment,"{helpers,variant,scenario,profiles,names}"),h=e.helpers(inherited);
  const script=e.variant(h.extract(source),"pacedEdgeFirst"),rows=[];
  for(let mask=1;mask<128;mask++){
    const selected=e.names.filter((_,i)=>mask&(1<<i));
    for(const [profile,options] of Object.entries(e.profiles)){
      const hold=await e.scenario(h,script,execute,options,selected,"hold");
      const burst=await e.scenario(h,script,execute,options,selected,"burst");
      rows.push({mask,selected,profile,hold:hold.pass,burst:burst.pass,
        holdGap:hold.maxGap,burstGap:burst.maxGap,missing:hold.missing+burst.missing,
        holdClosed:hold.closed?.status??null,burstClosed:burst.closed?.status??null});
    }
  }
  const profiles=Object.keys(e.profiles),summary={};
  for(const profile of profiles){
    const r=rows.filter(x=>x.profile===profile),both=r.filter(x=>x.hold&&x.burst);
    summary[profile]={both:both.length,total:r.length,hold:r.filter(x=>x.hold).length,burst:r.filter(x=>x.burst).length,
      bySize:Array.from({length:7},(_,i)=>({size:i+1,passed:both.filter(x=>x.selected.length===i+1).length,total:r.filter(x=>x.selected.length===i+1).length})),
      masks:both.map(x=>x.mask)};
  }
  // Conservative profile families: require all profiles in the family,
  // AND every nonempty subset. This prevents a fragile 'passing superset'
  // from being advertised as permission to operate its failing subgroups.
  const families={low:["rtt5","rtt20","jitter20"],moderate:["rtt5","rtt20","jitter20","rtt40","jitter40"],all:profiles};
  const admission={};
  for(const [family,ps] of Object.entries(families)){
    const intersection=new Set(Array.from({length:127},(_,i)=>i+1).filter(m=>ps.every(p=>summary[p].masks.includes(m))));
    const safe=[...intersection].filter(m=>{for(let sub=m;sub;sub=(sub-1)&m)if(!intersection.has(sub))return false;return true;});
    const maximal=safe.filter(m=>!safe.some(n=>n!==m&&(m&n)===m));
    admission[family]={profiles:ps,intersection:intersection.size,downwardClosed:safe.length,
      masks:safe,maximal:maximal.map(mask=>({mask,streams:e.names.filter((_,i)=>mask&(1<<i))}))};
  }
  return {rows,summary,admission};
}
if(typeof module!=="undefined")module.exports={run};
if(typeof require!=="undefined"&&typeof module!=="undefined"&&require.main===module){
  const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
  run(fs.readFileSync(process.argv[2]||path.join(__dirname,"../../Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift"),"utf8"),
    fs.readFileSync(path.join(__dirname,"stress.cjs"),"utf8"),fs.readFileSync(path.join(__dirname,"capacity-experiments.cjs"),"utf8"),(s,g)=>vm.runInNewContext(s,g))
    .then(x=>console.log(JSON.stringify(x,null,2))).catch(e=>{console.error(e);process.exitCode=2;});
}
