#if os(macOS)
import Foundation
import Network
import Security
import NoSpeakerCore

/// One bounded static HTTPS server on an explicitly selected local address. Separate
/// port from WSS, with fixed page origin; no dynamic content or file access.
public final class RemoteLoopbackPageServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tihulu.remote.page")
    private let lock = NSLock()
    public enum Status: Sendable { case starting, ready, failed, stopped }
    private var state: Status = .starting
    public var status: Status { lock.lock(); defer { lock.unlock() }; return state }
    private func setStatus(_ value: Status) { lock.lock(); state = value; lock.unlock() }
    private let parameters: NWParameters
    public let endpoint: RemoteEndpoint
    private var attemptStart = 0.0
    private var attempts = 0
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false

    public init(identity: SecIdentity, endpoint: RemoteEndpoint = .loopback) throws {
        self.endpoint = endpoint
        guard let localIdentity = sec_identity_create(identity) else { throw RemoteLoopbackTransport.Failure.identity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(endpoint.host), port: 9444)
    }
    public func start() {
        queue.async { [self] in
            guard !stopped, listener == nil else { return }
            do {
                let server = try NWListener(using: parameters, on: 9444)
                listener = server
                server.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready: self.setStatus(.ready)
                    case .failed: self.shutdown(failed: true)
                    default: break
                    }
                }
                server.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
                server.start(queue: queue)
            } catch { shutdown(failed: true) }
        }
    }
    private func accept(_ connection: NWConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if now-attemptStart >= 60 { attemptStart = now; attempts = 0 }
        guard !stopped, connections.count < 8, attempts < 120 else { connection.cancel(); return }
        attempts += 1
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.read(id, accumulated: Data())
            case .failed, .cancelled: self.close(id)
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in self?.close(id) }
        connection.start(queue: queue)
    }
    private func read(_ id: UUID, accumulated: Data) {
        guard let connection = connections[id], accumulated.count < RemotePageRequest.maximumBytes else { close(id); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: RemotePageRequest.maximumBytes - accumulated.count) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            guard error == nil, let data, !data.isEmpty else { self.close(id); return }
            var next = accumulated
            next.append(data)
            switch RemotePageRequest.parse(next, authority: self.endpoint.pageAuthority) {
            case .incomplete:
                if complete { self.close(id) } else { self.read(id, accumulated: next) }
            case .page: self.respond(id, content: Self.page, type: "text/html; charset=utf-8")
            case .script: self.respond(id, content: Self.script.replacingOccurrences(of: "__REMOTE_ORIGIN__", with: self.endpoint.origin).replacingOccurrences(of: "__REMOTE_SOCKET__", with: self.endpoint.socketURL), type: "text/javascript; charset=utf-8")
            case .rejected: self.close(id)
            }
        }
    }
    private func respond(_ id: UUID, content: String, type: String) {
        guard let connection = connections[id] else { return }
        let body = Data(content.utf8)
        let headers = [
            "HTTP/1.1 200 OK", "Content-Type: " + type, "Content-Length: " + String(body.count),
            "Connection: close", "Cache-Control: no-store", "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff", "X-Frame-Options: DENY",
            "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src wss://\(endpoint.socketAuthority); frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
    public func stop() { queue.async { [self] in shutdown(failed: false) } }
    private func shutdown(failed: Bool) {
        guard !stopped else { return }
        stopped = true
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
        setStatus(failed ? .failed : .stopped)
    }
    private static let page = #"""
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>TIHULU Remote</title>
<style>
:root{color-scheme:dark; font:16px system-ui; background:#171717;color:#f5f5f5}
body{margin:0 auto;max-width:600px;padding:20px}h1{font-size:1.5rem;margin:0 0 6px}
p{color:#c8c8c8;line-height:1.45}label{display:block;margin:12px 0 6px}
input,button{font:inherit;box-sizing:border-box;padding:12px;border-radius:8px;border:1px solid #777;background:#252525;color:inherit}
input{width:100%}button{margin:8px 8px 8px 0}button:disabled{opacity:.45}
#pad{position:relative;height:clamp(180px,42vh,340px);border:1px solid #888;border-radius:12px;background:linear-gradient(90deg,transparent 49.7%,#454545 50%,transparent 50.3%),linear-gradient(transparent 49.7%,#454545 50%,transparent 50.3%),#252525;touch-action:none;user-select:none;display:grid;place-items:center}
#pad[aria-disabled=true]{opacity:.45}#dot{position:absolute;width:22px;height:22px;background:#e34f4f;border:2px solid white;border-radius:50%;transform:translate(-50%,-50%);pointer-events:none}#dot[hidden]{display:none}
#status{min-height:2.8em}small{color:#bdbdbd}
#drumGrid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px}#drumGrid button{margin:0;min-height:80px;padding:8px;touch-action:none;user-select:none;overflow-wrap:anywhere}#drumGrid button[aria-pressed=true]{background:#286b50;border-color:#79c9a5} @media(max-width:420px){#drumGrid{grid-template-columns:repeat(2,minmax(0,1fr))}}
#pianoBoard{position:relative;height:clamp(145px,30vh,240px);touch-action:none;user-select:none}
#pianoBoard button{position:absolute;margin:0;border-radius:0 0 6px 6px;padding:0 0 8px;display:flex;align-items:flex-end;justify-content:center;touch-action:none;user-select:none;font-size:12px}
#pianoBoard .whiteKey{top:0;height:100%;background:#f1f1f1;color:#252525;border-color:#555;z-index:1}
#pianoBoard .blackKey{top:0;height:60%;background:#222;color:white;border-color:#666;z-index:2}
#pianoBoard button[data-scale=true]{border-bottom:7px solid #79a8d2}
#pianoBoard button[aria-pressed=true],#pianoSustain[aria-pressed=true]{background:#286b50;color:white;border-color:#79c9a5}
#pianoBoard button:focus-visible{outline:3px solid #e5a33b;outline-offset:-4px}
</style></head>
<body><h1>TIHULU Remote</h1><p>Local touch &amp; tilt controller · Experimental</p>
<label for="secret">One-time invitation (64 hexadecimal characters)</label>
<input id="secret" type="password" maxlength="64" autocomplete="off" autocapitalize="off" spellcheck="false">
<button id="connect">Connect</button><button id="disconnect" disabled>Disconnect / release</button>
<p id="status" role="status" aria-live="polite">Not connected.</p>
<div id="pad" aria-label="XY touch surface" aria-disabled="true"><span>Touch and move</span><div id="dot" hidden></div></div>
<p><small>X and Y control the mapped instrument. Lift to release. One contact only.</small></p>
<section aria-labelledby="drum-title"><h2 id="drum-title">Drum Pads</h2>
<p>Add the eight-pad preset for the paired device in the Mac Instrument Builder first. Pad labels show default General MIDI mappings; custom mappings are set on the Mac.</p>
<button id="drumEnable" disabled>Enable drum pads</button><button id="drumRelease" disabled>Release all pads</button>
<p id="drumStatus" role="status">Off.</p><div id="drumGrid"><button id="drum0" type="button" aria-pressed="false" disabled>1 · Kick</button><button id="drum1" type="button" aria-pressed="false" disabled>2 · Snare</button><button id="drum2" type="button" aria-pressed="false" disabled>3 · Closed Hi-Hat</button><button id="drum3" type="button" aria-pressed="false" disabled>4 · Open Hi-Hat</button><button id="drum4" type="button" aria-pressed="false" disabled>5 · Low Tom</button><button id="drum5" type="button" aria-pressed="false" disabled>6 · High Tom</button><button id="drum6" type="button" aria-pressed="false" disabled>7 · Crash</button><button id="drum7" type="button" aria-pressed="false" disabled>8 · Ride</button></div>
<small>Multiple fingers supported. Hold a pad to sustain its note; lift to release. Fixed host velocity, no pressure sensing. Release all clears pending hits.</small></section>
<section aria-labelledby="piano-title"><h2 id="piano-title">Piano</h2>
<p>Add the full 25-key and sustain preset for the paired source in the Mac Instrument Builder. Labels and scale hints refer to the default chromatic mapping.</p>
<button id="pianoEnable" disabled>Enable piano</button><button id="pianoRelease" disabled>Release keys &amp; pedal</button>
<p id="pianoStatus" role="status">Off.</p>
<button id="octaveDown" disabled>Octave −</button><span id="octaveLabel">C3–C4</span><button id="octaveUp" disabled>Octave +</button>
<label for="pianoScale">Scale guide (visual only)</label><select id="pianoScale"><option value="all">Chromatic</option><option value="major">Major</option><option value="minor">Natural minor</option><option value="pentatonic">Major pentatonic</option></select>
<label for="pianoRoot">Root note</label><select id="pianoRoot"><option value="0">C</option><option value="1">C♯</option><option value="2">D</option><option value="3">D♯</option><option value="4">E</option><option value="5">F</option><option value="6">F♯</option><option value="7">G</option><option value="8">G♯</option><option value="9">A</option><option value="10">A♯</option><option value="11">B</option></select>
<div id="pianoBoard" aria-label="Piano keyboard"><button id="piano0" class="whiteKey" type="button" style="left:0%;width:12.5%" aria-pressed="false" disabled></button><button id="piano2" class="whiteKey" type="button" style="left:12.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano4" class="whiteKey" type="button" style="left:25%;width:12.5%" aria-pressed="false" disabled></button><button id="piano5" class="whiteKey" type="button" style="left:37.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano7" class="whiteKey" type="button" style="left:50%;width:12.5%" aria-pressed="false" disabled></button><button id="piano9" class="whiteKey" type="button" style="left:62.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano11" class="whiteKey" type="button" style="left:75%;width:12.5%" aria-pressed="false" disabled></button><button id="piano12" class="whiteKey" type="button" style="left:87.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano1" class="blackKey" type="button" style="left:8.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano3" class="blackKey" type="button" style="left:21.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano6" class="blackKey" type="button" style="left:46.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano8" class="blackKey" type="button" style="left:58.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano10" class="blackKey" type="button" style="left:71.1%;width:7.8%" aria-pressed="false" disabled></button></div>
<button id="pianoSustain" type="button" aria-pressed="false" disabled>Sustain (hold)</button>
<small>Hold multiple keys or the pedal. Lift to release. Octave changes are available only after all piano messages are acknowledged. Scale guide does not alter MIDI routing.</small></section>
<section aria-labelledby="tilt-title"><h2 id="tilt-title">Pocket Wah / Tilt</h2>
<p>First map a phone or tablet tilt axis on the Mac. Hold the phone comfortably, nearly upright or flat but away from extreme angles, then enable and calibrate. Touch and tilt can be used together. Release either control independently.</p>
<button id="motionStart" disabled>Enable &amp; calibrate tilt</button><button id="motionStop" disabled>Release tilt</button>
<label for="tiltMeter">Relative pitch (before Mac mapping)</label><meter id="tiltMeter" min="0" max="1" value="0.5" style="width:100%;height:24px"></meter>
<p id="motionStatus" role="status">Motion off.</p><small>Motion is opt-in, sent only to the paired Mac. No microphone, camera or storage. The host decides MIDI routing.</small></section>
<section aria-labelledby="inertial-title"><h2 id="inertial-title">Motion dynamics</h2>
<p>Map acceleration magnitude or rotation magnitude on the Mac first. Each control is optional and separately released. Gravity-free acceleration is required; missing readings are not simulated.</p>
<label for="accelMeter">Acceleration · 0–20 m/s²</label><meter id="accelMeter" min="0" max="1" value="0" style="width:100%;height:24px"></meter>
<button id="accelStart" disabled>Enable acceleration</button><button id="accelStop" disabled>Release acceleration</button><p id="accelStatus" role="status">Off.</p>
<label for="rotationMeter">Rotation speed · 0–360°/s</label><meter id="rotationMeter" min="0" max="1" value="0" style="width:100%;height:24px"></meter>
<button id="rotationStart" disabled>Enable rotation</button><button id="rotationStop" disabled>Release rotation</button><p id="rotationStatus" role="status">Off.</p>
<small>Live meters are before Mac mapping. Use only the sensors your instrument maps. If the Mac instrument maps Air Drums, enabling acceleration also enables motion-triggered notes. Hold your device securely; use small controlled motions. Never strike a surface with it.</small></section>
<script src="/control.js" defer></script></body></html>
"""#
    private static let script = #"""
"use strict";
(() => {
  const get = id => document.getElementById(id);
  const pad=get("pad"), dot=get("dot"), secret=get("secret"), connect=get("connect"), disconnect=get("disconnect"), status=get("status");
  let ws=null, admitted=false, pending=false, sequence=0, pointer=null, position=null, releaseDue=false, timer=null, deadline=null, lastSend=0;
  const motionStart=get("motionStart"), motionStop=get("motionStop"), meter=get("tiltMeter"), motionStatus=get("motionStatus");
  let mode="idle", sample=null, neutral=null, sampleAt=0, sentAt=-1, permissionEpoch=0, waitingSince=0, pendingKind=null;
  let lastTouchSend=-Infinity,lastTiltSend=-Infinity;
  const drumButtons=Array.from({length:8},(_,i)=>get("drum"+i));
  const drumEnable=get("drumEnable"),drumRelease=get("drumRelease"),drumStatus=get("drumStatus");
  let drumEnabled=false,drumOwners=new Map(),drumQueue=[],drumDesired=0,drumSent=0,lastDrumSend=-Infinity,drumEmergency=false;
  function syncDrums(){
    drumEnable.disabled=!admitted;drumEnable.textContent=drumEnabled?"Disable drum pads":"Enable drum pads";
    drumRelease.disabled=!admitted||(!drumDesired&&!drumSent&&!drumQueue.length);
    drumButtons.forEach((b,i)=>{b.disabled=!admitted||!drumEnabled;b.setAttribute("aria-pressed",String(Boolean(drumDesired&(1<<i))));});
  }
  function resetDrums(){drumEnabled=false;drumOwners.clear();drumQueue=[];drumDesired=0;drumSent=0;lastDrumSend=-Infinity;drumEmergency=false;drumStatus.textContent="Off.";syncDrums();}
  function drumChanged(){
    let mask=0;for(const index of drumOwners.values())mask|=1<<index;
    if(mask===drumDesired)return;
    drumDesired=mask;
    if(drumQueue.length>=8){close("Drum input backlog. Reconnect explicitly.");return;}
    drumQueue.push({mask,at:performance.now()});syncDrums();tick();
  }
  function releaseDrums(){
    drumOwners.clear();drumDesired=0;drumQueue=[];
    drumEmergency=drumSent!==0;syncDrums();tick();
  }
  function drumDown(owner,index){
    if(!admitted||!drumEnabled||drumEmergency||drumOwners.has(owner))return;
    if(drumOwners.size>=16){close("Too many drum contacts. Reconnect explicitly.");return;}
    drumOwners.set(owner,index);drumChanged();
  }
  function drumUp(owner){if(drumOwners.delete(owner))drumChanged();}
  function sendDrum(mask){send("drumPads",{mask});}
  const pianoButtons=Array.from({length:13},(_,i)=>get("piano"+i));
  const pianoPedal=get("pianoSustain"),pianoEnable=get("pianoEnable"),pianoRelease=get("pianoRelease"),pianoStatus=get("pianoStatus");
  const octaveDown=get("octaveDown"),octaveUp=get("octaveUp"),octaveLabel=get("octaveLabel"),pianoScale=get("pianoScale"),pianoRoot=get("pianoRoot");
  const pitchNames=["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"];
  const scaleDegrees={all:[0,1,2,3,4,5,6,7,8,9,10,11],major:[0,2,4,5,7,9,11],minor:[0,2,3,5,7,8,10],pentatonic:[0,2,4,7,9]};
  let pianoEnabled=false,pianoOctave=0,pianoOwners=new Map(),pianoQueue=[],pianoDesired=0,pianoSent=0,lastPianoSend=-Infinity,pianoEmergency=false;
  function pianoBusy(){return pianoDesired!==0||pianoSent!==0||pianoQueue.length!==0||pianoEmergency||pendingKind==="pianoKeys";}
  function syncPiano(){
    pianoEnable.disabled=!admitted;pianoEnable.textContent=pianoEnabled?"Disable piano":"Enable piano";
    pianoRelease.disabled=!admitted||!pianoBusy();
    octaveDown.disabled=!admitted||!pianoEnabled||pianoOctave===0||pianoBusy();
    octaveUp.disabled=!admitted||!pianoEnabled||pianoOctave===1||pianoBusy();
    octaveLabel.textContent="C"+(3+pianoOctave)+"–C"+(4+pianoOctave);
    const scale=scaleDegrees[pianoScale.value]||scaleDegrees.all;
    const root=Number(pianoRoot.value)||0;
    pianoButtons.forEach((b,i)=>{
      const index=i+12*pianoOctave,note=pitchNames[index%12]+(3+Math.floor(index/12));
      b.disabled=!admitted||!pianoEnabled||pianoEmergency;
      b.textContent=note;b.setAttribute("aria-label",note);
      b.setAttribute("aria-pressed",String(Boolean(pianoDesired&(1<<index))));
      b.setAttribute("data-scale",String(pianoScale.value!=="all"&&scale.includes((index-root+12)%12)));
    });
    pianoPedal.disabled=!admitted||!pianoEnabled||pianoEmergency;
    pianoPedal.setAttribute("aria-pressed",String(Boolean(pianoDesired&(1<<25))));
  }
  function resetPiano(){pianoEnabled=false;pianoOctave=0;pianoOwners.clear();pianoQueue=[];pianoDesired=0;pianoSent=0;lastPianoSend=-Infinity;pianoEmergency=false;pianoStatus.textContent="Off.";syncPiano();}
  function pianoChanged(){
    let mask=0;for(const index of pianoOwners.values())mask|=1<<index;
    if(mask===pianoDesired)return;
    pianoDesired=mask;
    if(pianoQueue.length>=8){close("Piano input backlog. Reconnect explicitly.");return;}
    pianoQueue.push({mask,at:performance.now()});syncPiano();tick();
  }
  function releasePiano(){
    pianoOwners.clear();pianoDesired=0;pianoQueue=[];
    pianoEmergency=pianoSent!==0;syncPiano();tick();
  }
  function pianoDown(owner,index){
    if(!admitted||!pianoEnabled||pianoEmergency||pianoOwners.has(owner))return;
    if(pianoOwners.size>=32){close("Too many piano contacts. Reconnect explicitly.");return;}
    pianoOwners.set(owner,index);pianoChanged();
  }
  function pianoUp(owner){if(pianoOwners.delete(owner))pianoChanged();}
  function sendPiano(mask){send("pianoKeys",{mask});}
  function changeOctave(value){if(!admitted||!pianoEnabled||pianoBusy())return;pianoOctave=value;syncPiano();}
  function inertialState(kind,prefix,limit,scale){return {kind,start:get(prefix+"Start"),stop:get(prefix+"Stop"),meter:get(prefix+"Meter"),status:get(prefix+"Status"),limit,scale,mode:"idle",epoch:0,sample:null,at:0,sent:-1,last:-Infinity,waiting:0};}
  const streams=[inertialState("acceleration","accel",100,20),inertialState("rotation","rotation",2000,360)];
  const capturing=s=>["waiting","arming","active"].includes(s.mode);
  function syncInertialListener(){
    window.removeEventListener("devicemotion",deviceMotion);
    if(streams.some(capturing))window.addEventListener("devicemotion",deviceMotion);
  }
  function resetInertial(s,message){
    s.epoch++;s.mode="idle";s.sample=null;s.at=0;s.sent=-1;s.last=-Infinity;s.meter.value=0;s.status.textContent=message;
    syncInertialListener();syncControls();
  }
  function deviceMotion(e){
    for(const s of streams){
      if(!capturing(s))continue;
      const v=s.kind==="acceleration"?e.acceleration:e.rotationRate;
      const axes=v?(s.kind==="acceleration"?[v.x,v.y,v.z]:[v.alpha,v.beta,v.gamma]):[];
      if(axes.length!==3||!axes.every(v=>Number.isFinite(v)&&Math.abs(v)<=s.limit)){
        if(s.mode==="active"||s.mode==="arming"){close(s.kind+" unavailable. Host releases controls.");return;}
        continue;
      }
      s.sample={x:axes[0],y:axes[1],z:axes[2]};s.at=performance.now();
      s.meter.value=Math.min(1,Math.hypot(...axes)/s.scale);
    }
  }
  async function startInertial(s){
    if(!admitted||s.mode!=="idle"||streams.some(x=>x.mode==="requesting")||mode==="requesting")return;
    if(!window.isSecureContext||typeof window.DeviceMotionEvent==="undefined"){s.status.textContent="DeviceMotion unavailable.";return;}
    const epoch=++s.epoch;s.mode="requesting";s.status.textContent="Waiting for permission…";syncControls();
    try{
      const api=window.DeviceMotionEvent;
      if(typeof api.requestPermission==="function"&&await api.requestPermission()!=="granted"){
        if(epoch===s.epoch)resetInertial(s,"Motion permission denied.");return;
      }
    }catch{if(epoch===s.epoch)resetInertial(s,"Motion permission unavailable.");return;}
    if(epoch!==s.epoch||!admitted||s.mode!=="requesting")return;
    s.mode="waiting";s.waiting=performance.now();s.status.textContent="Waiting for a valid sensor sample…";syncInertialListener();syncControls();
  }
  function stopInertial(s){
    if(s.mode==="idle"||s.mode==="releasing")return;
    if(s.mode==="requesting"||s.mode==="waiting"){resetInertial(s,"Off.");return;}
    s.epoch++;s.mode="releasing";s.sample=null;s.status.textContent="Releasing…";syncInertialListener();syncControls();tick();
  }
  function syncControls(){
    pad.setAttribute("aria-disabled",String(!admitted));syncDrums();syncPiano();
    const asking=mode==="requesting"||streams.some(s=>s.mode==="requesting");
    motionStart.disabled=!admitted||mode!=="idle"||asking;
    for(const s of streams){s.start.disabled=!admitted||s.mode!=="idle"||asking;s.stop.disabled=!admitted||s.mode==="idle"||s.mode==="releasing";}
    motionStop.disabled=!admitted||mode==="idle"||mode==="releasing";
  }
  function resetMotion(message){
    permissionEpoch++;window.removeEventListener("deviceorientation",orientation);
    mode="idle";sample=null;neutral=null;sampleAt=0;sentAt=-1;meter.value=0.5;
    motionStatus.textContent=message;syncControls();
  }
  function orientation(e){
    if(mode!=="waiting"&&mode!=="arming"&&mode!=="active")return;
    const {alpha,beta,gamma}=e;
    if(![alpha,beta,gamma].every(Number.isFinite)||alpha<0||alpha>=360||Math.abs(beta)>80||Math.abs(gamma)>80){
      if(mode==="arming"||mode==="active")close("Tilt unavailable or outside safe range. Reconnect and calibrate.");
      return;
    }
    sample={alpha,beta,gamma};sampleAt=performance.now();
    if(neutral){let delta=((beta-neutral.beta+540)%360)-180;meter.value=Math.max(0,Math.min(1,0.5+delta/90));}
  }
  async function startMotion(){
    if(!admitted||mode!=="idle"||streams.some(s=>s.mode==="requesting"))return;
    if(!window.isSecureContext||typeof window.DeviceOrientationEvent==="undefined"){
      motionStatus.textContent="Orientation unavailable in this secure browser.";return;
    }
    const epoch=++permissionEpoch;mode="requesting";syncControls();motionStatus.textContent="Waiting for permission…";
    try{
      const api=window.DeviceOrientationEvent;
      if(typeof api.requestPermission==="function"&&await api.requestPermission()!=="granted"){
        if(epoch===permissionEpoch)resetMotion("Orientation permission denied.");return;
      }
    }catch{if(epoch===permissionEpoch)resetMotion("Orientation permission unavailable.");return;}
    if(epoch!==permissionEpoch||!admitted||mode!=="requesting")return;
    mode="waiting";waitingSince=performance.now();sample=null;neutral=null;sentAt=-1;
    window.addEventListener("deviceorientation",orientation);motionStatus.textContent="Hold steady; waiting for a valid orientation sample.";
    syncControls();
  }
  function stopMotion(){
    if(mode==="idle"||mode==="releasing")return;
    if(mode==="requesting"||mode==="waiting"){resetMotion("Motion off.");return;}
    permissionEpoch++;window.removeEventListener("deviceorientation",orientation);
    mode="releasing";sample=null;motionStatus.textContent="Releasing tilt…";syncControls();tick();
  }
  function clearDeadline(){if(deadline!==null)clearTimeout(deadline);deadline=null;}
  function close(message){
    const old=ws;ws=null;admitted=false;pending=false;sequence=0;pointer=null;position=null;releaseDue=false;
    clearDeadline();if(timer!==null)clearInterval(timer);timer=null;pendingKind=null;lastTouchSend=-Infinity;lastTiltSend=-Infinity;resetMotion("Motion off.");for(const s of streams)resetInertial(s,"Off.");resetDrums();resetPiano();
    if(old){old.onopen=old.onmessage=old.onclose=old.onerror=null;try{old.close();}catch{}}
    dot.hidden=true;pad.setAttribute("aria-disabled","true");connect.disabled=false;disconnect.disabled=true;status.textContent=message;
  }
  function wait(ms){clearDeadline();deadline=setTimeout(()=>close("Connection timed out. Request a new invitation."),ms);}
  function send(kind, axes){
    if(!ws||!admitted||pending||ws.readyState!==WebSocket.OPEN)return;
    if(ws.bufferedAmount>256){close("Backlog. Controls released by host watchdog.");return;}
    const motion=kind==="orientationArm"||kind==="orientation"||kind==="motionRelease";
    const inertial=streams.find(s=>kind===s.kind||kind===s.kind+"Arm"||kind===s.kind+"Release");
    const drum=kind==="drumPads",piano=kind==="pianoKeys";
    const frame={version:piano?5:drum?4:inertial?3:motion?2:1,sequence:++sequence,kind};
    if(drum||piano){frame.mask=axes.mask;}
    else if(axes){if(motion){frame.alpha=axes.alpha;frame.beta=axes.beta;frame.gamma=axes.gamma;}else{frame.x=axes.x;frame.y=axes.y;if(inertial)frame.z=axes.z;}}
    pending=true;pendingKind=kind;lastSend=performance.now();
    if(drum){lastDrumSend=lastSend;drumSent=axes.mask;}
    if(piano){lastPianoSend=lastSend;pianoSent=axes.mask;}
    if(kind==="touch")lastTouchSend=lastSend;
    if(kind==="orientationArm"||kind==="orientation")lastTiltSend=lastSend;
    if(inertial&&kind!==inertial.kind+"Release")inertial.last=lastSend;
    syncControls();wait(220);
    try{ws.send(JSON.stringify(frame));}catch{close("Send failed. Request a new invitation.");}
  }
  function tick(){
    if(!admitted)return;
    const now=performance.now();
    if(mode==="waiting"&&now-waitingSince>=3000){resetMotion("No valid orientation data. Check permission and device support.");}
    if((mode==="active"||mode==="arming")&&now-sampleAt>=250){close("Orientation stopped. Host releases tilt; reconnect explicitly.");return;}
    for(const s of streams){
      if(s.mode==="waiting"&&now-s.waiting>=3000)resetInertial(s,"No valid sensor data. Check device support.");
      if((s.mode==="arming"||s.mode==="active")&&now-s.at>=250){close(s.kind+" stopped. Reconnect explicitly.");return;}
    }
    if(drumQueue.length&&now-drumQueue[0].at>=150){close("Drum input delayed. Reconnect explicitly.");return;}
    if(pianoQueue.length&&now-pianoQueue[0].at>=150){close("Piano input delayed. Reconnect explicitly.");return;}
    if(pending)return;
    // Release takes precedence over new samples; one frame per ACK.
    if(pianoEmergency){pianoEmergency=false;sendPiano(0);return;}
    if(drumEmergency){drumEmergency=false;sendDrum(0);return;}
    if(releaseDue){releaseDue=false;send("release");return;}
    if(mode==="releasing"){send("motionRelease");return;}
    const releasing=streams.find(s=>s.mode==="releasing");
    if(releasing){send(releasing.kind+"Release");return;}
    const ready=[];
    if(pianoQueue.length&&now-lastPianoSend>=25)ready.push({last:lastPianoSend,run:()=>sendPiano(pianoQueue.shift().mask)});
    else if(pianoSent!==0&&!pianoQueue.length&&now-lastPianoSend>=50)ready.push({last:lastPianoSend,run:()=>sendPiano(pianoSent)});
    if(drumQueue.length&&now-lastDrumSend>=25)ready.push({last:lastDrumSend,run:()=>sendDrum(drumQueue.shift().mask)});
    else if(drumSent!==0&&!drumQueue.length&&now-lastDrumSend>=50)ready.push({last:lastDrumSend,run:()=>sendDrum(drumSent)});
    if(pointer!==null&&position&&now-lastTouchSend>=50)ready.push({last:lastTouchSend,run:()=>send("touch",position)});
    if(mode==="waiting"&&sample&&now-sampleAt<150)ready.push({last:-Infinity,run:()=>{
      neutral={...sample};sentAt=sampleAt;mode="arming";motionStatus.textContent="Calibrating…";send("orientationArm",sample);
    }});
    if(mode==="active"&&sample&&sampleAt>sentAt&&now-lastTiltSend>=50&&now-sampleAt<150)
      ready.push({last:lastTiltSend,run:()=>{sentAt=sampleAt;send("orientation",sample);}});
    for(const s of streams){
      if(s.mode==="waiting"&&s.sample&&now-s.at<150)ready.push({last:-Infinity,run:()=>{
        s.sent=s.at;s.mode="arming";s.status.textContent="Arming…";send(s.kind+"Arm",s.sample);
      }});
      if(s.mode==="active"&&s.sample&&s.at>s.sent&&now-s.last>=50&&now-s.at<150)
        ready.push({last:s.last,run:()=>{s.sent=s.at;send(s.kind,s.sample);}});
    }
    // One ACK lane, oldest serviced eligible stream wins; ties favor the
    // later candidate (preserves tilt's initial refresh priority).
    if(ready.length){ready.reduce((a,b)=>a.last<b.last?a:b).run();return;}
    if(pointer===null&&pianoSent===0&&!pianoQueue.length&&drumSent===0&&!drumQueue.length&&mode!=="active"&&mode!=="arming"&&!streams.some(s=>s.mode==="active"||s.mode==="arming")&&now-lastSend>=500)send("heartbeat");
  }
  connect.addEventListener("click",()=>{
    if(ws)return;
    const value=secret.value.trim();secret.value="";
    if(!/^[0-9a-fA-F]{64}$/.test(value)){status.textContent="Enter a valid invitation.";return;}
    const key=new Uint8Array(32);for(let i=0;i<32;i++)key[i]=parseInt(value.slice(i*2,i*2+2),16);
    if(location.origin!=="__REMOTE_ORIGIN__"){key.fill(0);close("Wrong origin. Open the local HTTPS page from the Mac app.");return;}
    let socket;
    try{socket=new WebSocket("__REMOTE_SOCKET__","tihulu-touch-v1");}catch{key.fill(0);close("Connection unavailable.");return;}
    ws=socket;connect.disabled=true;disconnect.disabled=false;status.textContent="Connecting…";wait(5000);
    socket.onopen=()=>{if(ws!==socket){key.fill(0);return;}try{socket.send(key);}catch{close("Pairing failed.");}finally{key.fill(0);}};
    socket.onmessage=e=>{
      if(ws!==socket)return;
      if(!admitted){
        if(e.data!=="admitted"||socket.protocol!=="tihulu-touch-v1"){close("Pairing rejected.");return;}
        clearDeadline();admitted=true;lastSend=performance.now();syncControls();status.textContent="Connected. Touch and optionally enable tilt.";
        timer=setInterval(tick,25);tick();return;
      }
      if(!pending||e.data!=="accepted"){close("Unexpected response.");return;}
      clearDeadline();pending=false;const kind=pendingKind;pendingKind=null;
      if(kind==="orientationArm"&&mode==="arming"){mode="active";motionStatus.textContent="Tilt active. Move gently; release when finished.";}
      if(kind==="motionRelease")resetMotion("Tilt released.");
      for(const s of streams){
        if(kind===s.kind+"Arm"&&s.mode==="arming"){s.mode="active";s.status.textContent="Active. Release when finished.";}
        if(kind===s.kind+"Release")resetInertial(s,"Released.");
      }
      syncControls();if(pianoEmergency||pianoQueue.length||drumEmergency||drumQueue.length||releaseDue||mode==="releasing"||streams.some(s=>s.mode==="releasing"))tick();
    };
    socket.onerror=()=>{key.fill(0);if(ws===socket)close("TLS or connection failed. Do not bypass certificate validation.");};
    socket.onclose=()=>{key.fill(0);if(ws===socket)close("Disconnected. Request a new invitation.");};
  });
  function move(e){
    const rect=pad.getBoundingClientRect();if(!rect.width||!rect.height)return;
    const clamp=v=>Math.max(0,Math.min(1,v));
    position={x:clamp((e.clientX-rect.left)/rect.width),y:1-clamp((e.clientY-rect.top)/rect.height)};
    dot.hidden=false;dot.style.left=(position.x*100)+"%";dot.style.top=((1-position.y)*100)+"%";
  }
  pad.addEventListener("pointerdown",e=>{
    if(!admitted||pointer!==null||releaseDue||e.button!==0)return;
    e.preventDefault();pointer=e.pointerId;try{pad.setPointerCapture(pointer);}catch{close("Pointer capture failed.");return;}
    lastTouchSend=-Infinity;move(e);syncControls();tick();
  });
  pad.addEventListener("pointermove",e=>{if(e.pointerId===pointer){e.preventDefault();move(e);}});
  function lift(e){
    if(e.pointerId!==pointer)return;
    pointer=null;position=null;dot.hidden=true;releaseDue=true;syncControls();tick();
  }
  for(const event of ["pointerup","pointercancel","lostpointercapture"])pad.addEventListener(event,lift);
  drumEnable.addEventListener("click",()=>{
    if(!admitted)return;
    drumEnabled=!drumEnabled;
    if(!drumEnabled)releaseDrums();
    drumStatus.textContent=drumEnabled?"Enabled. Use only with the mapped Mac preset.":"Off.";
    syncDrums();
  });
  drumRelease.addEventListener("click",releaseDrums);
  drumButtons.forEach((b,index)=>{
    b.addEventListener("pointerdown",e=>{
      if(!admitted||!drumEnabled||e.button!==0)return;
      e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{close("Drum pointer capture failed.");return;}
      drumDown("p"+e.pointerId,index);
    });
    for(const name of ["pointerup","pointercancel","lostpointercapture"])b.addEventListener(name,e=>drumUp("p"+e.pointerId));
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)drumDown("k"+index,index);}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();drumUp("k"+index);}});
    b.addEventListener("blur",()=>drumUp("k"+index));
  });
  pianoEnable.addEventListener("click",()=>{
    if(!admitted)return;
    pianoEnabled=!pianoEnabled;
    if(!pianoEnabled)releasePiano();
    pianoStatus.textContent=pianoEnabled?"Enabled. Use only with the mapped Mac preset.":"Off.";syncPiano();
  });
  pianoRelease.addEventListener("click",releasePiano);
  octaveDown.addEventListener("click",()=>changeOctave(0));
  octaveUp.addEventListener("click",()=>changeOctave(1));
  pianoScale.addEventListener("change",syncPiano);pianoRoot.addEventListener("change",syncPiano);
  [...pianoButtons,pianoPedal].forEach((b,i)=>{
    const index=()=>i===13?25:i+12*pianoOctave;
    b.addEventListener("pointerdown",e=>{
      if(!admitted||!pianoEnabled||e.button!==0)return;
      e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{close("Piano pointer capture failed.");return;}
      pianoDown("p"+e.pointerId,index());
    });
    for(const name of ["pointerup","pointercancel","lostpointercapture"])b.addEventListener(name,e=>pianoUp("p"+e.pointerId));
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)pianoDown("k"+i,index());}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();pianoUp("k"+i);}});
    b.addEventListener("blur",()=>pianoUp("k"+i));
  });
  motionStart.addEventListener("click",startMotion);
  motionStop.addEventListener("click",stopMotion);
  for(const s of streams){s.start.addEventListener("click",()=>startInertial(s));s.stop.addEventListener("click",()=>stopInertial(s));}
  function rotated(){if(ws&&(pianoBusy()||drumDesired!==0||drumSent!==0||drumQueue.length||mode!=="idle"||streams.some(s=>s.mode!=="idle")))close("Screen rotated. Reconnect and calibrate again.");}
  window.addEventListener("orientationchange",rotated);
  if(window.screen&&window.screen.orientation&&typeof window.screen.orientation.addEventListener==="function")window.screen.orientation.addEventListener("change",rotated);
  disconnect.addEventListener("click",()=>close("Disconnected. Host releases owned controls."));
  window.addEventListener("blur",()=>{if(ws)close("Window lost focus. Reconnect explicitly.");});
  window.addEventListener("pagehide",()=>{if(ws)close("Page hidden.");});
  document.addEventListener("visibilitychange",()=>{if(document.hidden&&ws)close("Page hidden. Reconnect explicitly.");});
})();
"""#
}
#endif
