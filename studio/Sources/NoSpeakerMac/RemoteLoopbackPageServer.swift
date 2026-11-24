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
</style></head>
<body><h1>TIHULU Remote</h1><p>Local touch &amp; tilt controller · Experimental</p>
<label for="secret">One-time invitation (64 hexadecimal characters)</label>
<input id="secret" type="password" maxlength="64" autocomplete="off" autocapitalize="off" spellcheck="false">
<button id="connect">Connect</button><button id="disconnect" disabled>Disconnect / release</button>
<p id="status" role="status" aria-live="polite">Not connected.</p>
<div id="pad" aria-label="XY touch surface" aria-disabled="true"><span>Touch and move</span><div id="dot" hidden></div></div>
<p><small>X and Y control the mapped instrument. Lift to release. One contact only.</small></p>
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
<small>Live meters are before Mac mapping. Use only the sensors your instrument maps. No shake-triggered notes in this version.</small></section>
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
    pad.setAttribute("aria-disabled",String(!admitted));
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
    clearDeadline();if(timer!==null)clearInterval(timer);timer=null;pendingKind=null;lastTouchSend=-Infinity;lastTiltSend=-Infinity;resetMotion("Motion off.");for(const s of streams)resetInertial(s,"Off.");
    if(old){old.onopen=old.onmessage=old.onclose=old.onerror=null;try{old.close();}catch{}}
    dot.hidden=true;pad.setAttribute("aria-disabled","true");connect.disabled=false;disconnect.disabled=true;status.textContent=message;
  }
  function wait(ms){clearDeadline();deadline=setTimeout(()=>close("Connection timed out. Request a new invitation."),ms);}
  function send(kind, axes){
    if(!ws||!admitted||pending||ws.readyState!==WebSocket.OPEN)return;
    if(ws.bufferedAmount>256){close("Backlog. Controls released by host watchdog.");return;}
    const motion=kind==="orientationArm"||kind==="orientation"||kind==="motionRelease";
    const inertial=streams.find(s=>kind===s.kind||kind===s.kind+"Arm"||kind===s.kind+"Release");
    const frame={version:inertial?3:motion?2:1,sequence:++sequence,kind};
    if(axes){if(motion){frame.alpha=axes.alpha;frame.beta=axes.beta;frame.gamma=axes.gamma;}else{frame.x=axes.x;frame.y=axes.y;if(inertial)frame.z=axes.z;}}
    pending=true;pendingKind=kind;lastSend=performance.now();
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
    if(pending)return;
    // Release takes precedence over new samples; one frame per ACK.
    if(releaseDue){releaseDue=false;send("release");return;}
    if(mode==="releasing"){send("motionRelease");return;}
    const releasing=streams.find(s=>s.mode==="releasing");
    if(releasing){send(releasing.kind+"Release");return;}
    const ready=[];
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
    if(pointer===null&&mode!=="active"&&mode!=="arming"&&!streams.some(s=>s.mode==="active"||s.mode==="arming")&&now-lastSend>=500)send("heartbeat");
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
      syncControls();if(releaseDue||mode==="releasing"||streams.some(s=>s.mode==="releasing"))tick();
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
  motionStart.addEventListener("click",startMotion);
  motionStop.addEventListener("click",stopMotion);
  for(const s of streams){s.start.addEventListener("click",()=>startInertial(s));s.stop.addEventListener("click",()=>stopInertial(s));}
  function rotated(){if(ws&&(mode!=="idle"||streams.some(s=>s.mode!=="idle")))close("Screen rotated. Reconnect and calibrate again.");}
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
