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
body{margin:0 auto;max-width:1100px;padding:16px} [hidden]{display:none!important} #remoteBar{position:sticky;top:0;z-index:5;background:#171717;padding:6px 0;border-bottom:1px solid #555} #remoteBar button{min-height:44px} #remoteBar button[aria-pressed=true]{border-color:#79c9a5;background:#28513f} #playView:not([hidden]){display:grid;gap:16px;grid-template-columns:minmax(0,1fr)} #playView>section{min-width:0;border:1px solid #555;padding:12px;border-radius:12px} @media(min-width:800px){#playView:not([hidden]){grid-template-columns:repeat(2,minmax(0,1fr))} #pianoSection,#pedalSection{grid-column:span 2}}h1{font-size:1.5rem;margin:0 0 6px}
p{color:#c8c8c8;line-height:1.45}label{display:block;margin:12px 0 6px}
input,button{font:inherit;box-sizing:border-box;padding:12px;border-radius:8px;border:1px solid #777;background:#252525;color:inherit}
input{width:100%}button{margin:8px 8px 8px 0}button:disabled{opacity:.45}
#pad{position:relative;height:clamp(180px,42vh,340px);border:1px solid #888;border-radius:12px;background:linear-gradient(90deg,transparent 49.7%,#454545 50%,transparent 50.3%),linear-gradient(transparent 49.7%,#454545 50%,transparent 50.3%),#252525;touch-action:none;user-select:none;display:grid;place-items:center}
#pad[aria-disabled=true]{opacity:.45}#dot{position:absolute;width:22px;height:22px;background:#e34f4f;border:2px solid white;border-radius:50%;transform:translate(-50%,-50%);pointer-events:none}#dot[hidden]{display:none}
#releaseAll{min-height:44px;border-color:#e5a33b}#status{min-height:2.8em}small{color:#bdbdbd}
#drumGrid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px}#drumGrid button{margin:0;min-height:80px;padding:8px;touch-action:none;user-select:none;overflow-wrap:anywhere}#drumGrid button[aria-pressed=true]{background:#286b50;border-color:#79c9a5} @media(max-width:420px){#drumGrid{grid-template-columns:repeat(2,minmax(0,1fr))}}
#pianoBoard{position:relative;height:clamp(145px,30vh,240px);touch-action:none;user-select:none}
#pianoBoard button{position:absolute;margin:0;border-radius:0 0 6px 6px;padding:0 0 8px;display:flex;align-items:flex-end;justify-content:center;touch-action:none;user-select:none;font-size:12px}
#pianoBoard .whiteKey{top:0;height:100%;background:#f1f1f1;color:#252525;border-color:#555;z-index:1}
#pianoBoard .blackKey{top:0;height:60%;background:#222;color:white;border-color:#666;z-index:2}
#pianoBoard button[data-scale=true]{border-bottom:7px solid #79a8d2}
#pianoBoard button[aria-pressed=true],#pianoSustain[aria-pressed=true]{background:#286b50;color:white;border-color:#79c9a5}
#pianoBoard button:focus-visible{outline:3px solid #e5a33b;outline-offset:-4px}
#pedalGrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
#pedalGrid section{border:1px solid #777;border-radius:10px;padding:8px;min-width:0}
#pedalGrid button{width:100%;margin:4px 0;padding:8px;overflow-wrap:anywhere}
#pedalGrid input[type=range]{padding:8px 0;accent-color:#79c9a5}
#pedalGrid button[aria-pressed=true]{background:#286b50;border-color:#79c9a5}
@media(max-width:420px){#pedalGrid{grid-template-columns:repeat(2,minmax(0,1fr))}}
</style></head>
<body><h1>TIHULU Remote</h1><p>Local MIDI performance controller · Experimental</p>
<div id="remoteBar"><nav aria-label="Controller views"><button id="navPlay" aria-pressed="false" disabled>Play</button><button id="navSetup" aria-pressed="false" disabled>Setup</button><button id="navConnection" aria-pressed="true">Connection</button></nav><button id="releaseAll" disabled>Release my controls</button><button id="disconnect" disabled>Disconnect / release</button><p id="navStatus" role="status"></p><p id="status" role="status" aria-live="polite">Not connected.</p><small id="ackLatency">Mac ACK round trip: no sample.</small></div>
<section id="connectionView"><label for="secret">One-time invitation (64 hexadecimal characters)</label>
<input id="secret" type="password" maxlength="64" autocomplete="off" autocapitalize="off" spellcheck="false">
<button id="connect">Connect</button><p>Use the matching trusted TLS certificate and a new invitation for each connection. ACK round trip includes Mac processing; it is not audio or MIDI latency.</p></section>
<div id="setupView" hidden>
<section id="mappingSection" hidden><h2>Mapped MIDI destinations</h2><p id="mappingStatus" role="status"></p><pre id="mappingDetails" style="white-space:pre-wrap;overflow-wrap:anywhere"></pre></section>
<section id="workloadSection" hidden aria-labelledby="workloadTitle"><h2 id="workloadTitle">Performance combinations</h2>
<p id="workloadStatus" role="status" aria-live="polite">Conservative combinations. No physical latency guarantee.</p>
<button id="workloadMode" type="button" aria-pressed="false" disabled>Enable experimental combinations</button>
<small>Conservative mode allows one touch, drum, piano or pedal surface plus up to two motion streams, or all three motion streams alone. Experimental mode permits additional mapped combinations but may interrupt performance; the same safety limits apply. Change mode only when all controls are disabled and released.</small></section></div>
<div id="playView" hidden><section id="touchSection" hidden><div id="pad" aria-label="XY touch surface" aria-disabled="true"><span>Touch and move</span><div id="dot" hidden></div></div>
<p><small>X and Y control the mapped instrument. Lift to release. One contact only.</small></p></section>
<section id="drumSection" hidden aria-labelledby="drum-title"><h2 id="drum-title">Drum Pads</h2>
<p>Only pads mapped for this paired device are available. Pad numbers identify controls, not assumed MIDI notes. Actual destinations are listed in Setup when shared.</p>
<button id="drumEnable" disabled>Enable drum pads</button><button id="drumRelease" disabled>Release all pads</button>
<p id="drumStatus" role="status">Off.</p><div id="drumGrid"><button id="drum0" type="button" aria-pressed="false" disabled>1 · Kick</button><button id="drum1" type="button" aria-pressed="false" disabled>2 · Snare</button><button id="drum2" type="button" aria-pressed="false" disabled>3 · Closed Hi-Hat</button><button id="drum3" type="button" aria-pressed="false" disabled>4 · Open Hi-Hat</button><button id="drum4" type="button" aria-pressed="false" disabled>5 · Low Tom</button><button id="drum5" type="button" aria-pressed="false" disabled>6 · High Tom</button><button id="drum6" type="button" aria-pressed="false" disabled>7 · Crash</button><button id="drum7" type="button" aria-pressed="false" disabled>8 · Ride</button></div>
<small>Multiple fingers supported. Hold a pad to sustain its note; lift to release. Fixed host velocity, no pressure sensing. Release all clears pending hits.</small></section>
<section id="pianoSection" hidden aria-labelledby="piano-title"><h2 id="piano-title">Piano</h2>
<p>Only keys and sustain mapped for this paired device are available. Key positions identify logical controls. Scale hints are available only for a verified default pitch mapping.</p>
<button id="pianoEnable" disabled>Enable piano</button><button id="pianoRelease" disabled>Release keys &amp; pedal</button>
<p id="pianoStatus" role="status">Off.</p>
<button id="octaveDown" disabled>Octave −</button><span id="octaveLabel">C3–C4</span><button id="octaveUp" disabled>Octave +</button>
<label for="pianoScale">Scale guide (visual only)</label><select id="pianoScale"><option value="all">Chromatic</option><option value="major">Major</option><option value="minor">Natural minor</option><option value="pentatonic">Major pentatonic</option></select>
<label for="pianoRoot">Root note</label><select id="pianoRoot"><option value="0">C</option><option value="1">C♯</option><option value="2">D</option><option value="3">D♯</option><option value="4">E</option><option value="5">F</option><option value="6">F♯</option><option value="7">G</option><option value="8">G♯</option><option value="9">A</option><option value="10">A♯</option><option value="11">B</option></select>
<div id="pianoBoard" aria-label="Piano keyboard"><button id="piano0" class="whiteKey" type="button" style="left:0%;width:12.5%" aria-pressed="false" disabled></button><button id="piano2" class="whiteKey" type="button" style="left:12.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano4" class="whiteKey" type="button" style="left:25%;width:12.5%" aria-pressed="false" disabled></button><button id="piano5" class="whiteKey" type="button" style="left:37.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano7" class="whiteKey" type="button" style="left:50%;width:12.5%" aria-pressed="false" disabled></button><button id="piano9" class="whiteKey" type="button" style="left:62.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano11" class="whiteKey" type="button" style="left:75%;width:12.5%" aria-pressed="false" disabled></button><button id="piano12" class="whiteKey" type="button" style="left:87.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano1" class="blackKey" type="button" style="left:8.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano3" class="blackKey" type="button" style="left:21.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano6" class="blackKey" type="button" style="left:46.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano8" class="blackKey" type="button" style="left:58.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano10" class="blackKey" type="button" style="left:71.1%;width:7.8%" aria-pressed="false" disabled></button></div>
<button id="pianoSustain" type="button" aria-pressed="false" disabled>Sustain (hold)</button>
<small>Hold multiple keys or the pedal. Lift to release. Octave changes are available only after all piano messages are acknowledged. Scale guide does not alter MIDI routing.</small></section>
<section id="pedalSection" hidden aria-labelledby="pedal-title"><h2 id="pedal-title">Pedalboard</h2>
<p>Only pedals mapped for this paired device are available. These are MIDI controls, not audio effects. Labels identify logical controls; actual destinations depend on the Mac mapping.</p>
<button id="pedalEnable" disabled>Enable pedalboard</button><button id="pedalRelease" disabled>Release all pedals</button>
<p id="pedalStatus" role="status">Off.</p>
<div id="pedalGrid"><section><label for="pedalLevel0">Expression</label><button id="pedalToggle0" type="button" aria-pressed="false" disabled>Activate</button><input id="pedalLevel0" type="range" min="0" max="100" step="1" value="100" disabled><output id="pedalValue0" for="pedalLevel0">100%</output></section><section><label for="pedalLevel1">Volume</label><button id="pedalToggle1" type="button" aria-pressed="false" disabled>Activate</button><input id="pedalLevel1" type="range" min="0" max="100" step="1" value="100" disabled><output id="pedalValue1" for="pedalLevel1">100%</output></section><section><label for="pedalLevel2">Wah / Filter</label><button id="pedalToggle2" type="button" aria-pressed="false" disabled>Activate</button><input id="pedalLevel2" type="range" min="0" max="100" step="1" value="0" disabled><output id="pedalValue2" for="pedalLevel2">0%</output></section><section><p>Sustain</p><button id="pedalToggle3" type="button" aria-pressed="false" disabled>Off</button></section><section><p>Switch A</p><button id="pedalToggle4" type="button" aria-pressed="false" disabled>Off</button></section><section><p>Switch B</p><button id="pedalToggle5" type="button" aria-pressed="false" disabled>Off</button></section></div>
<small>Each control is explicitly activated; sliders retain their position until released. Sustain and FX switches latch until switched off. Release sends the Mac-defined neutral or restores another owner's value. For motion-controlled wah, map tilt pitch to CC74 on the Mac and use Pocket Wah below instead of activating the manual wah slider. If both are mapped, existing host priority rules apply.</small></section>
<section id="tiltSection" hidden aria-labelledby="tilt-title"><h2 id="tilt-title">Pocket Wah / Tilt</h2>
<p>First map a phone or tablet tilt axis on the Mac. Hold the phone comfortably, nearly upright or flat but away from extreme angles, then enable and calibrate. Touch and tilt can be used together. Release either control independently.</p>
<button id="motionStart" disabled>Enable &amp; calibrate tilt</button><button id="motionStop" disabled>Release tilt</button>
<label for="tiltMeter">Relative pitch (before Mac mapping)</label><meter id="tiltMeter" min="0" max="1" value="0.5" style="width:100%;height:24px"></meter>
<p id="motionStatus" role="status">Motion off.</p><small>Motion is opt-in, sent only to the paired Mac. No microphone, camera or storage. The host decides MIDI routing.</small></section>
<section id="inertialSection" hidden aria-labelledby="inertial-title"><h2 id="inertial-title">Motion dynamics</h2>
<p>Map acceleration magnitude or rotation magnitude on the Mac first. Each control is optional and separately released. Gravity-free acceleration is required; missing readings are not simulated.</p>
<div id="accelSection" hidden><label for="accelMeter">Acceleration · 0–20 m/s²</label><meter id="accelMeter" min="0" max="1" value="0" style="width:100%;height:24px"></meter>
<button id="accelStart" disabled>Enable acceleration</button><button id="accelStop" disabled>Release acceleration</button><p id="accelStatus" role="status">Off.</p></div>
<div id="rotationSection" hidden><label for="rotationMeter">Rotation speed · 0–360°/s</label><meter id="rotationMeter" min="0" max="1" value="0" style="width:100%;height:24px"></meter>
<button id="rotationStart" disabled>Enable rotation</button><button id="rotationStop" disabled>Release rotation</button><p id="rotationStatus" role="status">Off.</p></div>
<p id="airDrumNotice" hidden>Air Drums is mapped: enabling acceleration can trigger notes. Use gentle controlled movements.</p><small>Live meters are before Mac mapping. Use only the sensors your instrument maps. If the Mac instrument maps Air Drums, enabling acceleration also enables motion-triggered notes. Hold your device securely; use small controlled motions. Never strike a surface with it.</small></section>
</div><script src="/control.js" defer></script></body></html>
"""#
    private static let script = #"""
"use strict";
(() => {
  const get = id => document.getElementById(id);
  const pad=get("pad"), dot=get("dot"), secret=get("secret"), connect=get("connect"), disconnect=get("disconnect"), status=get("status");
  let ws=null, admitted=false, pending=false, sequence=0, pointer=null, position=null, timer=null, deadline=null, lastSend=0;
  const motionStart=get("motionStart"), motionStop=get("motionStop"), meter=get("tiltMeter"), motionStatus=get("motionStatus");
  let mode="idle", sample=null, neutral=null, sampleAt=0, sentAt=-1, permissionEpoch=0, waitingSince=0, pendingKind=null;
  let lastTouchSend=-Infinity,lastTiltSend=-Infinity;
  let touchQueue=[],touchSent=false,paceTimer=null;
  function touchBusy(){return pointer!==null||touchQueue.length!==0||touchSent||pendingKind==="touch"||pendingKind==="release";}
  function queueTouch(kind,axes){
    if(touchQueue.length>=8){close("Touch input backlog. Reconnect explicitly.");return;}
    touchQueue.push({kind,axes,at:performance.now()});syncControls();tick();
  }
  function sendTouchEdge(){const edge=touchQueue.shift();send(edge.kind,edge.axes);}
  let caps=null,experimentalWorkload=false,workloadRefusal="";
  let releasingAll=false,releaseAllTimer=null;
  let currentView="connection",ackSamples=[],ackAt=null;
  const viewNames=["play","setup","connection"];
  const navId=v=>"nav"+v[0].toUpperCase()+v.slice(1);
  function navigationBusy(){return releasingAll||pending||workloadMask()!==0;}
  function syncNavigation(){
    for(const v of viewNames){
      get(v+"View").hidden=currentView!==v;
      const b=get(navId(v));b.setAttribute("aria-pressed",String(currentView===v));
      b.disabled=v!==currentView&&(!caps||navigationBusy());
    }
    get("navStatus").textContent=caps&&navigationBusy()?"Release and disable controls before changing views.":"";
  }
  function chooseView(v){
    if(!viewNames.includes(v)||v===currentView||!caps||navigationBusy())return;
    currentView=v;syncNavigation();
  }
  function syncLatency(){
    const recent=ackAt!==null&&performance.now()-ackAt<2000;
    const median=ackSamples.length?[...ackSamples].sort((a,b)=>a-b)[Math.floor(ackSamples.length/2)]:null;
    get("ackLatency").textContent=recent&&median!==null?"Mac ACK round trip (recent median): "+Math.round(median)+" ms. Not MIDI/audio latency.":"Mac ACK round trip: no recent sample.";
  }
  function recordAck(){
    const now=performance.now(),elapsed=now-lastSend;
    if(Number.isFinite(elapsed)&&elapsed>=0&&elapsed<=220){ackSamples.push(elapsed);if(ackSamples.length>8)ackSamples.shift();ackAt=now;}
    syncLatency();
  }
  const releaseAll=get("releaseAll");
  function cancelGlobalTimer(){if(releaseAllTimer!==null)clearTimeout(releaseAllTimer);releaseAllTimer=null;}
  function finishGlobalRelease(){
    if(!releasingAll||pending||workloadMask()!==0)return false;
    cancelGlobalTimer();releasingAll=false;
    drumStatus.textContent=pianoStatus.textContent=pedalStatus.textContent="Off.";
    status.textContent="My controls released locally; required Mac acknowledgments received. MIDI/audio output not confirmed. Enable controls again to play.";
    syncControls();return true;
  }
  function releaseMyControls(){
    if(!admitted||!caps||releasingAll)return;
    releasingAll=true;const now=performance.now();
    // Cancel unsent onsets; retain the state of every already sent owner.
    pointer=null;position=null;dot.hidden=true;touchQueue=touchSent?[{kind:"release",at:now}]:[];
    drumEnabled=false;drumOwners.clear();drumDesired=0;drumQueue=[];drumEmergency=drumSent!==0;
    pianoEnabled=false;pianoOwners.clear();pianoDesired=0;pianoQueue=[];pianoEmergency=pianoSent!==0;
    pedalEnabled=false;pedalMask=0;pedalQueue=[];pedalDirty=false;pedalEmergency=pedalSentMask!==0;
    drumStatus.textContent=pianoStatus.textContent=pedalStatus.textContent="Off; releasing sent controls.";
    permissionEpoch++;window.removeEventListener("deviceorientation",orientation);
    if(mode==="arming"||mode==="active"||mode==="releasing"){mode="releasing";sample=null;motionStatus.textContent="Releasing…";}
    else resetMotion("Off.");
    for(const s of streams){
      s.epoch++;
      if(s.mode==="arming"||s.mode==="active"||s.mode==="releasing"){s.mode="releasing";s.sample=null;s.status.textContent="Releasing…";}
      else resetInertial(s,"Off.");
    }
    syncInertialListener();workloadRefusal="";
    status.textContent="Releasing my controls; unsent inputs canceled…";
    releaseAllTimer=setTimeout(()=>close("Release not fully acknowledged. Mac cleanup not confirmed. Request a new invitation."),350);
    syncControls();if(!finishGlobalRelease())tick();
  }
  // This page is served only with the compatible host implementation.
  const mappingV8=true,mappingLabelsV8=true;
  let mappingStage=null,mappingRows=null,mappingLabels=new Map(),mappingTimer=null,mappingBudget=null;
  const mappingNames=["X","Y","Contact","Tilt yaw","Tilt pitch","Tilt roll","Acceleration","Rotation","Air strike",
    ...Array.from({length:8},(_,i)=>"Pad "+(i+1)),...Array.from({length:25},(_,i)=>"Key "+(i+1)),"Piano sustain",
    "Expression","Volume","Wah / Filter","Pedal sustain","Switch A","Switch B"];
  // Bounded specialized grammar: flat envelope plus fixed-width integer rows.
  // Decoded keys are unique; no generic recursive parser or coercion.
  function parseMapping(data,labels=false){
    if(typeof data!=="string"||data.length>256||/[^\x00-\x7f]/.test(data))return null;
    const ws="[ \\t\\r\\n]*",uint="(?:0|[1-9][0-9]*)";
    const token='"(?:[^"\\\\\\x00-\\x1f]|\\\\(?:["\\\\/bfnrt]|u[0-9a-fA-F]{4}))*"';
    const tuple="\\["+ws+(labels?uint+ws+","+ws+token:Array(5).fill(uint).join(ws+","+ws))+ws+"\\]";
    const rows="\\["+ws+"(?:"+tuple+(labels?"":"(?:"+ws+","+ws+tuple+"){0,7}")+")?"+ws+"\\]";
    const member=new RegExp(ws+"("+token+")"+ws+":"+ws+"("+token+"|"+uint+"|true|false|"+rows+")"+ws,"y");
    const start=/[ \t\r\n]*\{[ \t\r\n]*/y,end=/[ \t\r\n]*\}[ \t\r\n]*$/y,comma=/[ \t\r\n]*,[ \t\r\n]*/y;
    let at=0;const keys=new Set(),out=Object.create(null);
    function take(re){re.lastIndex=at;const m=re.exec(data);if(m)at=re.lastIndex;return m;}
    try{
      if(!take(start))return null;
      let m;
      while((m=take(member))){
        const key=JSON.parse(m[1]),raw=m[2];
        if(keys.has(key)||!(labels?["kind","version","sequence","page","pages","total","rows"]:["kind","version","sequence","page","pages","total","detail","rows"]).includes(key))return null;
        keys.add(key);
        if(["version","sequence","page","pages","total"].includes(key)&&!/^(0|[1-9][0-9]*)$/.test(raw))return null;
        if(key==="rows"&&!raw.startsWith("["))return null;
        out[key]=JSON.parse(raw);
        if(take(end))return at===data.length&&keys.size===(labels?7:8)?out:null;
        if(!take(comma))return null;
      }
    }catch{}
    return null;
  }
  function rowValid(r){
    if(!Array.isArray(r)||r.length!==5||!r.every(Number.isSafeInteger))return false;
    const [signal,kind,channel,number,count]=r;
    if(signal<0||signal>48||kind<0||kind>3||channel<0||channel>15||count<1||count>64)return false;
    if(kind===0&&(number<0||number>127))return false;
    if(kind===1&&(number<0||number>119||[0,6,32,38,64,96,97,98,99,100,101].includes(number)))return false;
    if(kind>=2&&number!==0)return false;
    if(signal>=8&&signal<=41&&kind!==0)return false;
    if([42,46].includes(signal)&&kind!==3)return false;
    if((signal>=3&&signal<=7||signal>=43&&signal<=45)&&kind!==1&&kind!==2)return false;
    if(signal>=47&&kind!==1)return false;
    return true;
  }
  function ordered(a,b){for(let i=0;i<4;i++){if(a[i]!==b[i])return a[i]<b[i];}return false;}
  function coverage(rows,manifest){
    const ids=new Set(rows.map(r=>r[0])),any=(a,b)=>[...ids].some(i=>i>=a&&i<=b);
    const bits=(a,b)=>[...ids].filter(i=>i>=a&&i<=b).reduce((m,i)=>m|(1<<(i-a)),0);
    return manifest.touch===any(0,2)&&manifest.tilt===any(3,5)&&manifest.acceleration===(ids.has(6)||ids.has(8))&&
      manifest.rotation===ids.has(7)&&manifest.airDrums===ids.has(8)&&manifest.drums===bits(9,16)&&
      manifest.piano===bits(17,42)&&manifest.pedals===bits(43,48);
  }
  function targetText(r){return "Ch "+(r[2]+1)+" · "+(["Note "+r[3],"CC "+r[3],"Pitch bend","Sustain (CC64)"][r[1]])+(r[4]>1?" ×"+r[4]:"");}
  function targets(id){return mappingRows?.filter(r=>r[0]===id)||[];}
  function verifiedScale(){
    if(!mappingRows||!caps)return false;
    for(let i=0;i<25;i++)if(has("piano",i)){
      const r=targets(17+i);if(!r.length||!r.every(x=>x[1]===0&&x[3]===48+i))return false;
    }
    return Boolean(caps.piano&33554431);
  }
  function labelFor(id){const label=mappingLabels.get(id);return label?label+" ("+mappingNames[id]+")":mappingNames[id];}
  function decodeLabel(raw){
    if(typeof raw!=="string"||!/^[A-Za-z0-9_-]{1,86}$/.test(raw))return null;
    // Decode canonical base64url without relying on browser atob or permissive UTF-8.
    const alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let bits=0,value=0,bytes=[];
    for(const c of raw){value=(value<<6)|alphabet.indexOf(c);bits+=6;if(bits>=8){bits-=8;bytes.push((value>>bits)&255);}}
    if(bits===6||(bits&&((value&((1<<bits)-1))!==0))||bytes.length<1||bytes.length>64)return null;
    try{
      const label=decodeURIComponent(bytes.map(b=>"%"+b.toString(16).padStart(2,"0")).join(""));
      if(/[\p{Cc}\p{Cf}]/u.test(label)||!/[^\p{White_Space}]/u.test(label))return null;
      return label;
    }catch{return null;}
  }
  function acceptLabels(data){
    const s=mappingStage,p=parseMapping(data,true);
    if(!s||s.phase!=="labels"||!p||p.kind!=="mappingLabels"||p.version!==8||p.sequence!==sequence||p.page!==s.next||
      ![p.sequence,p.page,p.pages,p.total].every(Number.isSafeInteger)||p.total<0||p.total>49||
      p.pages!==Math.max(1,p.total)||p.page<0||p.page>=p.pages||
      p.rows.length!==(p.total===0?0:1)||(s.next!==0&&(p.total!==s.labelTotal||p.pages!==s.labelPages)))return false;
    if(s.next===0){s.labelTotal=p.total;s.labelPages=p.pages;}
    for(const r of p.rows){
      if(!Array.isArray(r)||r.length!==2||!Number.isSafeInteger(r[0])||r[0]<=s.lastLabel||
        !s.rows.some(row=>row[0]===r[0]))return false;
      const label=decodeLabel(r[1]);if(label===null)return false;
      s.labels.set(r[0],label);s.lastLabel=r[0];
    }
    s.next++;clearDeadline();pending=false;pendingKind=null;
    if(s.next===s.labelPages)ready(s.manifest,s.rows,s.labels);else nextMapping();
    return true;
  }
  function renderMapping(){
    get("mappingSection").hidden=!caps;
    get("mappingStatus").textContent=!caps?"":mappingRows?"Shared by the Mac. MIDI output is not confirmed by this display.":"Mapping details hidden by the Mac.";
    get("mappingDetails").textContent=mappingRows?mappingRows.map(r=>labelFor(r[0])+" · "+targetText(r)).join("\n"):"";
    for(let i=0;i<8;i++){
      const r=targets(9+i);get("drum"+i).textContent=labelFor(9+i)+(r.length===1?" · "+targetText(r[0]):r.length>1?" · "+r.length+" targets":"");
    }
  }
  function clearMapping(){
    if(mappingTimer!==null)clearTimeout(mappingTimer);mappingTimer=null;
    if(mappingBudget!==null)clearTimeout(mappingBudget);mappingBudget=null;
    mappingStage=null;mappingRows=null;mappingLabels=new Map();
  }
  function ready(manifest,rows,labels=new Map()){
    clearMapping();mappingRows=rows;mappingLabels=labels;caps=manifest;currentView="play";
    if(!octaveAvailable(0)&&octaveAvailable(1))pianoOctave=1;
    syncControls();renderMapping();status.textContent="Connected. Only mapped controls are available.";
    timer=setInterval(tick,25);tick();
  }
  function nextMapping(){
    const stage=mappingStage,connection=ws;
    if(!stage||!connection)return;
    mappingTimer=setTimeout(()=>{
      mappingTimer=null;
      if(ws!==connection||mappingStage!==stage||pending)return;
      send(stage.phase==="labels"?"mappingLabels":"mapping",{page:stage.next});
    },Math.max(0,50-(performance.now()-lastSend)));
  }
  function acceptMapping(data){
    const s=mappingStage,p=parseMapping(data);
    if(!s||!p||p.kind!=="mapping"||p.version!==8||p.sequence!==sequence||p.page!==s.next||
      ![p.sequence,p.page,p.pages,p.total].every(Number.isSafeInteger)||p.total<0||p.total>64||
      p.pages!==Math.max(1,Math.ceil(p.total/8))||p.page<0||p.page>=p.pages||typeof p.detail!=="boolean"||
      !Array.isArray(p.rows)||p.rows.length!==Math.min(8,p.total-p.page*8)||
      (!p.detail&&(p.total!==0||p.pages!==1))||
      (s.next!==0&&(p.total!==s.total||p.pages!==s.pages||p.detail!==s.detail)))return false;
    if(s.next===0){s.total=p.total;s.pages=p.pages;s.detail=p.detail;}
    for(const r of p.rows){
      if(!rowValid(r)||(s.rows.length&&!ordered(s.rows.at(-1),r)))return false;
      s.multiplicity+=r[4];if(s.multiplicity>64)return false;s.rows.push(r);
    }
    s.next++;
    clearDeadline();pending=false;pendingKind=null;
    if(s.next===s.pages){
      if(s.detail&&(!s.rows.length||!coverage(s.rows,s.manifest)))return false;
      if(s.detail&&mappingLabelsV8){s.phase="labels";s.next=0;s.labels=new Map();s.lastLabel=-1;nextMapping();}
      else ready(s.manifest,s.detail?s.rows:null);
    }else nextMapping();
    return true;
  }
  const workloadMode=get("workloadMode"),workloadStatus=get("workloadStatus");
  const workloadBits={touch:1,tilt:2,acceleration:4,rotation:8,drums:16,piano:32,pedals:64};
  function drumBusy(){return drumDesired!==0||drumSent!==0||drumQueue.length!==0||drumEmergency||pendingKind==="drumPads";}
  function workloadMask(){
    let mask=0;
    if(touchBusy())mask|=1;
    if(mode!=="idle")mask|=2;
    for(const s of streams)if(s.mode!=="idle")mask|=workloadBits[s.kind];
    if(drumEnabled||drumBusy())mask|=16;
    if(pianoEnabled||pianoBusy())mask|=32;
    if(pedalEnabled||pedalBusy())mask|=64;
    return mask;
  }
  function popcount(mask){let n=0;while(mask){mask&=mask-1;n++;}return n;}
  function conservativeCombination(mask){
    const discrete=popcount(mask&113),sensors=popcount(mask&14);
    return discrete===0?sensors<=3:discrete===1&&sensors<=2;
  }
  function workloadAllows(group){
    return !releasingAll&&(experimentalWorkload||conservativeCombination(workloadMask()|workloadBits[group]));
  }
  function requestWorkload(group){
    if(workloadAllows(group)){workloadRefusal="";return true;}
    workloadRefusal="Combination unavailable. Disable and release another control before trying again.";
    syncWorkload();return false;
  }
  function syncWorkload(){
    const mask=workloadMask();
    get("workloadSection").hidden=!caps;
    workloadMode.disabled=!admitted||!caps||mask!==0||pending||releasingAll;
    workloadMode.textContent=experimentalWorkload?"Use conservative combinations":"Enable experimental combinations";
    workloadMode.setAttribute("aria-pressed",String(experimentalWorkload));
    const description=experimentalWorkload?"Experimental combinations. Performance may be interrupted.":"Conservative combinations. No physical latency guarantee.";
    workloadStatus.textContent=(workloadRefusal?workloadRefusal+" ":"")+description+" Enabled, requested or releasing streams: "+popcount(mask)+".";
  }
  const manifestFields=["kind","version","touch","tilt","acceleration","rotation","airDrums","drums","piano","pedals"];
  const has=(group,index)=>Boolean(caps&&(caps[group]&(1<<index)));
  const octaveAvailable=value=>Boolean(caps&&(caps.piano&(8191<<(12*value))));
  // Flat manifest only. Parse decoded key tokens before JSON.parse collapses
  // duplicates; reject nested objects/arrays and trailing content.
  function uniqueManifestKeys(data){
    const start=/[ \t\r\n]*\{[ \t\r\n]*/y,end=/[ \t\r\n]*\}[ \t\r\n]*$/y,comma=/[ \t\r\n]*,[ \t\r\n]*/y;
    const member=/[ \t\r\n]*("(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*")[ \t\r\n]*:[ \t\r\n]*("(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null)[ \t\r\n]*/y;
    let at=0;
    function take(re){re.lastIndex=at;const m=re.exec(data);if(m)at=re.lastIndex;return m;}
    if(!take(start))return false;
    const keys=new Set();
    if(take(end))return at===data.length;
    let m;
    while((m=take(member))){
      const key=JSON.parse(m[1]);
      if(keys.has(key))return false;
      if(["version","drums","piano","pedals"].includes(key)&&!/^(0|[1-9][0-9]*)$/.test(m[2]))return false;
      keys.add(key);
      if(take(end))return at===data.length;
      if(!take(comma))return false;
    }
    return false;
  }
  function parseCapabilities(data){
    if(typeof data!=="string"||data.length>256)return null;
    try{
      if(!uniqueManifestKeys(data))return null;
      const value=JSON.parse(data);
      if(!value||typeof value!=="object"||Array.isArray(value)||Object.keys(value).length!==manifestFields.length||
         !manifestFields.every(k=>Object.prototype.hasOwnProperty.call(value,k))||
         value.kind!=="capabilities"||value.version!==7)return null;
      if(!["touch","tilt","acceleration","rotation","airDrums"].every(k=>typeof value[k]==="boolean"))return null;
      if(![["drums",255],["piano",67108863],["pedals",63]].every(([k,max])=>Number.isInteger(value[k])&&value[k]>=0&&value[k]<=max))return null;
      if(value.airDrums&&!value.acceleration)return null;
      return Object.freeze(value);
    }catch{return null;}
  }
  function syncSections(){
    for(const [id,visible] of [["touchSection",caps?.touch],["drumSection",caps?.drums],["pianoSection",caps?.piano],["pedalSection",caps?.pedals],["tiltSection",caps?.tilt],["inertialSection",caps?.acceleration||caps?.rotation],["accelSection",caps?.acceleration],["rotationSection",caps?.rotation],["airDrumNotice",caps?.airDrums]])get(id).hidden=!visible;
  }
  const drumButtons=Array.from({length:8},(_,i)=>get("drum"+i));
  const drumEnable=get("drumEnable"),drumRelease=get("drumRelease"),drumStatus=get("drumStatus");
  let drumEnabled=false,drumOwners=new Map(),drumQueue=[],drumDesired=0,drumSent=0,lastDrumSend=-Infinity,drumEmergency=false;
  function syncDrums(){
    drumEnable.disabled=!admitted||!caps?.drums;drumEnable.textContent=drumEnabled?"Disable drum pads":"Enable drum pads";
    drumRelease.disabled=!admitted||(!drumDesired&&!drumSent&&!drumQueue.length);
    drumButtons.forEach((b,i)=>{b.hidden=!has("drums",i);b.disabled=!admitted||!drumEnabled||!has("drums",i)||drumEmergency;b.setAttribute("aria-pressed",String(Boolean(drumDesired&(1<<i))));});
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
    drumEmergency=drumSent!==0;syncControls();tick();
  }
  function drumDown(owner,index){
    if(!admitted||!drumEnabled||!has("drums",index)||drumEmergency||drumOwners.has(owner))return;
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
    pianoEnable.disabled=!admitted||!caps?.piano;pianoEnable.textContent=pianoEnabled?"Disable piano":"Enable piano";
    pianoRelease.disabled=!admitted||!pianoBusy();
    octaveDown.disabled=!admitted||!pianoEnabled||pianoOctave===0||!octaveAvailable(0)||pianoBusy();
    octaveUp.disabled=!admitted||!pianoEnabled||pianoOctave===1||!octaveAvailable(1)||pianoBusy();
    octaveLabel.textContent=verifiedScale()?"C"+(3+pianoOctave)+"–C"+(4+pianoOctave):"Keys "+(1+12*pianoOctave)+"–"+(13+12*pianoOctave);
    const scaleAllowed=verifiedScale();pianoScale.disabled=!scaleAllowed;pianoRoot.disabled=!scaleAllowed;
    const scale=scaleDegrees[pianoScale.value]||scaleDegrees.all;
    const root=Number(pianoRoot.value)||0;
    pianoButtons.forEach((b,i)=>{
      const index=i+12*pianoOctave,note=pitchNames[index%12]+(3+Math.floor(index/12));
      b.disabled=!admitted||!pianoEnabled||!has("piano",index)||pianoEmergency;
      const rows=targets(17+index);
      const label=scaleAllowed?note:"K"+(index+1);
      b.textContent=label;b.setAttribute("aria-label",(mappingLabels.has(17+index)?labelFor(17+index)+" · ":"")+label+(rows.length?" · "+rows.map(targetText).join("; "):" · mapping details hidden"));
      b.setAttribute("aria-pressed",String(Boolean(pianoDesired&(1<<index))));
      b.setAttribute("data-scale",String(scaleAllowed&&pianoScale.value!=="all"&&scale.includes((index-root+12)%12)));
    });
    get("pianoBoard").hidden=!Boolean(caps?.piano&33554431);
    pianoPedal.hidden=!has("piano",25);pianoPedal.disabled=!admitted||!pianoEnabled||!has("piano",25)||pianoEmergency;
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
    pianoEmergency=pianoSent!==0;syncControls();tick();
  }
  function pianoDown(owner,index){
    if(!admitted||!pianoEnabled||!has("piano",index)||pianoEmergency||pianoOwners.has(owner))return;
    if(pianoOwners.size>=32){close("Too many piano contacts. Reconnect explicitly.");return;}
    pianoOwners.set(owner,index);pianoChanged();
  }
  function pianoUp(owner){if(pianoOwners.delete(owner))pianoChanged();}
  function sendPiano(mask){send("pianoKeys",{mask});}
  function changeOctave(value){if(!admitted||!pianoEnabled||!octaveAvailable(value)||pianoBusy())return;pianoOctave=value;syncPiano();}
  const pedalEnable=get("pedalEnable"),pedalRelease=get("pedalRelease"),pedalStatus=get("pedalStatus");
  const pedalToggles=Array.from({length:6},(_,i)=>get("pedalToggle"+i));
  const pedalSliders=Array.from({length:3},(_,i)=>get("pedalLevel"+i));
  const pedalOutputs=Array.from({length:3},(_,i)=>get("pedalValue"+i));
  let pedalEnabled=false,pedalMask=0,pedalSentMask=0,pedalPositions=[100,100,0],pedalQueue=[],pedalDirty=false,lastPedalSend=-Infinity,pedalEmergency=false;
  function pedalBusy(){return pedalMask!==0||pedalSentMask!==0||pedalQueue.length!==0||pedalEmergency||pendingKind==="pedalboard";}
  function syncPedals(){
    pedalEnable.disabled=!admitted||!caps?.pedals;pedalEnable.textContent=pedalEnabled?"Disable pedalboard":"Enable pedalboard";
    pedalRelease.disabled=!admitted||!pedalBusy();
    pedalToggles.forEach((b,i)=>{
      const active=Boolean(pedalMask&(1<<i));
      b.disabled=!admitted||!pedalEnabled||!has("pedals",i)||pedalEmergency;
      b.textContent=i<3?(active?"Release":"Activate"):(active?"On":"Off");
      b.setAttribute("aria-pressed",String(active));
    });
    pedalSliders.forEach((b,i)=>{
      b.disabled=!admitted||!pedalEnabled||!has("pedals",i)||pedalEmergency||!(pedalMask&(1<<i));
      b.value=String(pedalPositions[i]);pedalOutputs[i].textContent=pedalPositions[i]+"%";
    });
  }
  function pedalSnapshot(){
    return {mask:pedalMask,levels:Array.from({length:6},(_,i)=>(pedalMask&(1<<i))?(i<3?pedalPositions[i]/100:1):0)};
  }
  function resetPedals(){
    pedalEnabled=false;pedalMask=0;pedalSentMask=0;pedalPositions=[100,100,0];pedalQueue=[];pedalDirty=false;lastPedalSend=-Infinity;pedalEmergency=false;
    pedalStatus.textContent="Off.";syncPedals();
  }
  function pedalToggle(i){
    if(!admitted||!pedalEnabled||!has("pedals",i)||pedalEmergency)return;
    pedalMask^=1<<i;
    if(pedalQueue.length>=8){close("Pedal input backlog. Reconnect explicitly.");return;}
    pedalQueue.push({snapshot:pedalSnapshot(),at:performance.now()});pedalDirty=false;syncPedals();tick();
  }
  function pedalMove(i){
    if(!admitted||!pedalEnabled||!has("pedals",i)||pedalEmergency||!(pedalMask&(1<<i)))return;
    const n=Number(pedalSliders[i].value);
    if(!Number.isFinite(n)||n<0||n>100){close("Invalid pedal level.");return;}
    pedalPositions[i]=Math.round(n);pedalDirty=true;syncPedals();tick();
  }
  function releasePedals(){
    pedalMask=0;pedalQueue=[];pedalDirty=false;pedalEmergency=pedalSentMask!==0;syncControls();tick();
  }
  function sendPedals(snapshot){send("pedalboard",snapshot);}
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
    if(currentView!=="play"||releasingAll||!admitted||!caps?.[s.kind]||s.mode!=="idle"||streams.some(x=>x.mode==="requesting")||mode==="requesting")return;
    if(!window.isSecureContext||typeof window.DeviceMotionEvent==="undefined"){s.status.textContent="DeviceMotion unavailable.";return;}
    if(!requestWorkload(s.kind))return;
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
    pad.setAttribute("aria-disabled",String(!admitted||!caps?.touch||!workloadAllows("touch")));syncSections();syncDrums();syncPiano();syncPedals();syncWorkload();syncNavigation();syncLatency();
    releaseAll.disabled=!admitted||!caps||releasingAll;
    const asking=releasingAll||mode==="requesting"||streams.some(s=>s.mode==="requesting");
    if(releasingAll){drumEnable.disabled=true;pianoEnable.disabled=true;pedalEnable.disabled=true;}
    motionStart.disabled=!admitted||!caps?.tilt||mode!=="idle"||asking;
    for(const s of streams){s.start.disabled=!admitted||!caps?.[s.kind]||s.mode!=="idle"||asking;s.stop.disabled=!admitted||s.mode==="idle"||s.mode==="releasing";}
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
    if(currentView!=="play"||releasingAll||!admitted||!caps?.tilt||mode!=="idle"||streams.some(s=>s.mode==="requesting"))return;
    if(!window.isSecureContext||typeof window.DeviceOrientationEvent==="undefined"){
      motionStatus.textContent="Orientation unavailable in this secure browser.";return;
    }
    if(!requestWorkload("tilt"))return;
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
    const old=ws;ws=null;admitted=false;caps=null;currentView="connection";ackSamples=[];ackAt=null;releasingAll=false;cancelGlobalTimer();clearMapping();renderMapping();experimentalWorkload=false;workloadRefusal="";pending=false;sequence=0;pointer=null;position=null;touchQueue=[];touchSent=false;
    if(paceTimer!==null)clearTimeout(paceTimer);paceTimer=null;clearDeadline();if(timer!==null)clearInterval(timer);timer=null;pendingKind=null;lastTouchSend=-Infinity;lastTiltSend=-Infinity;resetMotion("Motion off.");for(const s of streams)resetInertial(s,"Off.");resetDrums();resetPiano();resetPedals();syncControls();
    if(old){old.onopen=old.onmessage=old.onclose=old.onerror=null;try{old.close();}catch{}}
    dot.hidden=true;pad.setAttribute("aria-disabled","true");connect.disabled=false;disconnect.disabled=true;status.textContent=message;
  }
  function wait(ms){clearDeadline();deadline=setTimeout(()=>close("Connection timed out. Request a new invitation."),ms);}
  function send(kind, axes){
    if(!ws||!admitted||pending||ws.readyState!==WebSocket.OPEN)return;
    if(ws.bufferedAmount>256){close("Backlog. Controls released by host watchdog.");return;}
    const motion=kind==="orientationArm"||kind==="orientation"||kind==="motionRelease";
    const inertial=streams.find(s=>kind===s.kind||kind===s.kind+"Arm"||kind===s.kind+"Release");
    const drum=kind==="drumPads",piano=kind==="pianoKeys",pedals=kind==="pedalboard";
    const frame={version:(kind==="mapping"||kind==="mappingLabels")?8:kind==="capabilities"?7:pedals?6:piano?5:drum?4:inertial?3:motion?2:1,sequence:++sequence,kind};
    if(kind==="mapping"||kind==="mappingLabels"){frame.page=axes.page;}
    else if(pedals){frame.mask=axes.mask;frame.levels=axes.levels;}
    else if(drum||piano){frame.mask=axes.mask;}
    else if(axes){if(motion){frame.alpha=axes.alpha;frame.beta=axes.beta;frame.gamma=axes.gamma;}else{frame.x=axes.x;frame.y=axes.y;if(inertial)frame.z=axes.z;}}
    pending=true;pendingKind=kind;lastSend=performance.now();
    if(drum){lastDrumSend=lastSend;drumSent=axes.mask;}
    if(piano){lastPianoSend=lastSend;pianoSent=axes.mask;}
    if(pedals){lastPedalSend=lastSend;pedalSentMask=axes.mask;}
    if(kind==="touch"){lastTouchSend=lastSend;touchSent=true;}
    if(kind==="release")touchSent=false;
    if(kind==="orientationArm"||kind==="orientation")lastTiltSend=lastSend;
    if(inertial&&kind!==inertial.kind+"Release")inertial.last=lastSend;
    syncControls();wait(220);
    try{ws.send(JSON.stringify(frame));}catch{close("Send failed. Request a new invitation.");}
  }
  function tick(){
    if(!admitted||!caps)return;
    const now=performance.now();syncLatency();
    if(mode==="waiting"&&now-waitingSince>=3000){resetMotion("No valid orientation data. Check permission and device support.");}
    if((mode==="active"||mode==="arming")&&now-sampleAt>=250){close("Orientation stopped. Host releases tilt; reconnect explicitly.");return;}
    for(const s of streams){
      if(s.mode==="waiting"&&now-s.waiting>=3000)resetInertial(s,"No valid sensor data. Check device support.");
      if((s.mode==="arming"||s.mode==="active")&&now-s.at>=250){close(s.kind+" stopped. Reconnect explicitly.");return;}
    }
    if(touchQueue.length&&now-touchQueue[0].at>=150){close("Touch input delayed. Reconnect explicitly.");return;}
    if(drumQueue.length&&now-drumQueue[0].at>=150){close("Drum input delayed. Reconnect explicitly.");return;}
    if(pianoQueue.length&&now-pianoQueue[0].at>=150){close("Piano input delayed. Reconnect explicitly.");return;}
    if(pedalQueue.length&&now-pedalQueue[0].at>=150){close("Pedal input delayed. Reconnect explicitly.");return;}
    if(pending)return;
    if(releasingAll&&finishGlobalRelease())return;
    // Bound sends before dequeue, including releases.
    if(now-lastSend<13){if(paceTimer===null)paceTimer=setTimeout(()=>{paceTimer=null;tick();},13-(now-lastSend));return;}
    // Release takes precedence over new samples; one frame per ACK.
    const releases=[];const due=last=>Number.isFinite(last)?last+300:now;
    if(pedalEmergency)releases.push({due:due(lastPedalSend),run:()=>{pedalEmergency=false;sendPedals({mask:0,levels:[0,0,0,0,0,0]});}});
    if(pianoEmergency)releases.push({due:due(lastPianoSend),run:()=>{pianoEmergency=false;sendPiano(0);}});
    if(drumEmergency)releases.push({due:due(lastDrumSend),run:()=>{drumEmergency=false;sendDrum(0);}});
    if(touchQueue[0]?.kind==="release")releases.push({due:Math.min(due(lastTouchSend),touchQueue[0].at+150),run:sendTouchEdge});
    if(mode==="releasing")releases.push({due:due(lastTiltSend),run:()=>send("motionRelease")});
    for(const s of streams)if(s.mode==="releasing")releases.push({due:due(s.last),run:()=>send(s.kind+"Release")});
    if(releases.length){releases.reduce((a,b)=>a.due<=b.due?a:b).run();return;}
    if(releasingAll){close("Release state incomplete. Mac cleanup not confirmed. Request a new invitation.");return;}
    const ready=[];
    if(pedalQueue.length&&now-lastPedalSend>=25)ready.push({last:lastPedalSend,edge:pedalQueue[0].at,run:()=>sendPedals(pedalQueue.shift().snapshot)});
    else if(!pedalQueue.length&&pedalMask!==0&&now-lastPedalSend>=50)ready.push({last:lastPedalSend,run:()=>{pedalDirty=false;sendPedals(pedalSnapshot());}});
    if(pianoQueue.length&&now-lastPianoSend>=25)ready.push({last:lastPianoSend,edge:pianoQueue[0].at,run:()=>sendPiano(pianoQueue.shift().mask)});
    else if(pianoSent!==0&&!pianoQueue.length&&now-lastPianoSend>=50)ready.push({last:lastPianoSend,run:()=>sendPiano(pianoSent)});
    if(drumQueue.length&&now-lastDrumSend>=25)ready.push({last:lastDrumSend,edge:drumQueue[0].at,run:()=>sendDrum(drumQueue.shift().mask)});
    else if(drumSent!==0&&!drumQueue.length&&now-lastDrumSend>=50)ready.push({last:lastDrumSend,run:()=>sendDrum(drumSent)});
    if(touchQueue.length)ready.push({last:lastTouchSend,edge:touchQueue[0].at,run:sendTouchEdge});
    else if(pointer!==null&&position&&touchSent&&now-lastTouchSend>=50)ready.push({last:lastTouchSend,run:()=>send("touch",position)});
    if(mode==="waiting"&&sample&&now-sampleAt<150)ready.push({last:-Infinity,arm:waitingSince,run:()=>{
      neutral={...sample};sentAt=sampleAt;mode="arming";motionStatus.textContent="Calibrating…";send("orientationArm",sample);
    }});
    if(mode==="active"&&sample&&sampleAt>sentAt&&now-lastTiltSend>=50&&now-sampleAt<150)
      ready.push({last:lastTiltSend,run:()=>{sentAt=sampleAt;send("orientation",sample);}});
    for(const s of streams){
      if(s.mode==="waiting"&&s.sample&&now-s.at<150)ready.push({last:-Infinity,arm:s.waiting,run:()=>{
        s.sent=s.at;s.mode="arming";s.status.textContent="Arming…";send(s.kind+"Arm",s.sample);
      }});
      if(s.mode==="active"&&s.sample&&s.at>s.sent&&now-s.last>=50&&now-s.at<150)
        ready.push({last:s.last,run:()=>{s.sent=s.at;send(s.kind,s.sample);}});
    }
    // One ACK lane: discrete edges by age, then waiting arms, then refresh age.
    // Release targets are scheduling priorities, not extended safety deadlines.
    if(ready.length){const rank=x=>[x.edge!==undefined?0:x.arm!==undefined?1:2,x.edge??x.arm??x.last];ready.reduce((a,b)=>{const x=rank(a),y=rank(b);return x[0]<y[0]||(x[0]===y[0]&&x[1]<=y[1])?a:b;}).run();return;}
    if(!touchBusy()&&pedalSentMask===0&&!pedalQueue.length&&pianoSent===0&&!pianoQueue.length&&drumSent===0&&!drumQueue.length&&mode!=="active"&&mode!=="arming"&&!streams.some(s=>s.mode==="active"||s.mode==="arming")&&now-lastSend>=500)send("heartbeat");
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
        if(e.data!=="admitted"||socket.protocol!=="tihulu-touch-v1"){close("Connection not accepted. Request a new invitation from the Mac. Invitation, mapping or device capacity may be unavailable.");return;}
        clearDeadline();admitted=true;lastSend=performance.now();syncControls();status.textContent="Checking mapped controls…";
        send("capabilities");return;
      }
      if(pending&&pendingKind==="capabilities"){
        const manifest=parseCapabilities(e.data);
        if(!manifest){close("Invalid or unsupported control manifest. Reconnect with a compatible Mac build.");return;}
        clearDeadline();pending=false;pendingKind=null;
        if(!mappingV8){ready(manifest,null);return;}
        mappingStage={manifest,phase:"mapping",next:0,rows:[],multiplicity:0};
        status.textContent="Synchronizing MIDI mappings…";
        mappingBudget=setTimeout(()=>close("Mapping synchronization timed out. Reconnect explicitly."),10000);
        nextMapping();return;
      }
      if(pending&&pendingKind==="mapping"){
        if(!acceptMapping(e.data))close("Invalid mapping response. Reconnect explicitly.");return;
      }
      if(pending&&pendingKind==="mappingLabels"){
        if(!acceptLabels(e.data))close("Invalid label response. Reconnect explicitly.");return;
      }
      if(!pending||!caps||e.data!=="accepted"){close("Unexpected response.");return;}
      recordAck();clearDeadline();pending=false;const kind=pendingKind;pendingKind=null;
      if(kind==="orientationArm"&&mode==="arming"){mode="active";motionStatus.textContent="Tilt active. Move gently; release when finished.";}
      if(kind==="motionRelease")resetMotion("Tilt released.");
      for(const s of streams){
        if(kind===s.kind+"Arm"&&s.mode==="arming"){s.mode="active";s.status.textContent="Active. Release when finished.";}
        if(kind===s.kind+"Release")resetInertial(s,"Released.");
      }
      syncControls();if(!finishGlobalRelease())tick();
    };
    socket.onerror=()=>{key.fill(0);if(ws===socket)close("TLS or connection failed. Do not bypass certificate validation.");};
    socket.onclose=()=>{key.fill(0);if(ws===socket)close("Disconnected. Request a new invitation.");};
  });
  function move(e){
    const rect=pad.getBoundingClientRect();
    if(![rect.width,rect.height,rect.left,rect.top,e.clientX,e.clientY].every(Number.isFinite)||rect.width<=0||rect.height<=0){close("Invalid touch geometry. Reconnect explicitly.");return false;}
    const clamp=v=>Math.max(0,Math.min(1,v));
    position={x:clamp((e.clientX-rect.left)/rect.width),y:1-clamp((e.clientY-rect.top)/rect.height)};
    dot.hidden=false;dot.style.left=(position.x*100)+"%";dot.style.top=((1-position.y)*100)+"%";return true;
  }
  pad.addEventListener("pointerdown",e=>{
    if(currentView!=="play"||releasingAll||!admitted||!caps?.touch||pointer!==null||e.button!==0)return;
    if(!requestWorkload("touch"))return;
    e.preventDefault();pointer=e.pointerId;try{pad.setPointerCapture(pointer);}catch{close("Pointer capture failed.");return;}
    if(!move(e))return;syncControls();queueTouch("touch",{...position});
  });
  pad.addEventListener("pointermove",e=>{if(e.pointerId===pointer){e.preventDefault();move(e);}});
  function lift(e){
    if(e.pointerId!==pointer)return;
    pointer=null;position=null;dot.hidden=true;syncControls();queueTouch("release");
  }
  pad.addEventListener("pointerup",lift);
  // Cancellation is not a completed musical tap: discard unsent edges and
  // let host disconnect/watchdog release already delivered owners.
  for(const event of ["pointercancel","lostpointercapture"])pad.addEventListener(event,e=>{if(e.pointerId===pointer)close("Touch cancelled. Reconnect explicitly.");});
  drumEnable.addEventListener("click",()=>{
    if(currentView!=="play"||releasingAll||!admitted||!caps?.drums)return;
    if(!drumEnabled&&!requestWorkload("drums"))return;
    drumEnabled=!drumEnabled;
    if(!drumEnabled)releaseDrums();
    workloadRefusal="";syncControls();
    drumStatus.textContent=drumEnabled?"Enabled. Use only with the mapped Mac preset.":"Off.";
    syncDrums();
  });
  drumRelease.addEventListener("click",releaseDrums);
  drumButtons.forEach((b,index)=>{
    b.addEventListener("pointerdown",e=>{
      if(!admitted||!drumEnabled||!has("drums",index)||e.button!==0)return;
      e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{close("Drum pointer capture failed.");return;}
      drumDown("p"+e.pointerId,index);
    });
    for(const name of ["pointerup","pointercancel","lostpointercapture"])b.addEventListener(name,e=>drumUp("p"+e.pointerId));
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)drumDown("k"+index,index);}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();drumUp("k"+index);}});
    b.addEventListener("blur",()=>drumUp("k"+index));
  });
  pianoEnable.addEventListener("click",()=>{
    if(currentView!=="play"||releasingAll||!admitted||!caps?.piano)return;
    if(!pianoEnabled&&!requestWorkload("piano"))return;
    pianoEnabled=!pianoEnabled;
    if(!pianoEnabled)releasePiano();
    workloadRefusal="";syncControls();
    pianoStatus.textContent=pianoEnabled?"Enabled. Use only with the mapped Mac preset.":"Off.";syncPiano();
  });
  pianoRelease.addEventListener("click",releasePiano);
  octaveDown.addEventListener("click",()=>changeOctave(0));
  octaveUp.addEventListener("click",()=>changeOctave(1));
  pianoScale.addEventListener("change",syncPiano);pianoRoot.addEventListener("change",syncPiano);
  [...pianoButtons,pianoPedal].forEach((b,i)=>{
    const index=()=>i===13?25:i+12*pianoOctave;
    b.addEventListener("pointerdown",e=>{
      if(!admitted||!pianoEnabled||!has("piano",index())||e.button!==0)return;
      e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{close("Piano pointer capture failed.");return;}
      pianoDown("p"+e.pointerId,index());
    });
    for(const name of ["pointerup","pointercancel","lostpointercapture"])b.addEventListener(name,e=>pianoUp("p"+e.pointerId));
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)pianoDown("k"+i,index());}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();pianoUp("k"+i);}});
    b.addEventListener("blur",()=>pianoUp("k"+i));
  });
  pedalEnable.addEventListener("click",()=>{
    if(currentView!=="play"||releasingAll||!admitted||!caps?.pedals)return;
    if(!pedalEnabled&&!requestWorkload("pedals"))return;
    pedalEnabled=!pedalEnabled;
    if(!pedalEnabled)releasePedals();
    workloadRefusal="";syncControls();
    pedalStatus.textContent=pedalEnabled?"Enabled. Activate individual mapped pedals.":"Off.";syncPedals();
  });
  pedalRelease.addEventListener("click",releasePedals);
  pedalToggles.forEach((b,i)=>b.addEventListener("click",()=>pedalToggle(i)));
  pedalSliders.forEach((b,i)=>b.addEventListener("input",()=>pedalMove(i)));
  workloadMode.addEventListener("click",()=>{
    if(releasingAll||!admitted||!caps||workloadMask()!==0||pending)return;
    experimentalWorkload=!experimentalWorkload;workloadRefusal="";syncControls();
  });
  for(const v of viewNames)get(navId(v)).addEventListener("click",()=>chooseView(v));
  releaseAll.addEventListener("click",releaseMyControls);
  motionStart.addEventListener("click",startMotion);
  motionStop.addEventListener("click",stopMotion);
  for(const s of streams){s.start.addEventListener("click",()=>startInertial(s));s.stop.addEventListener("click",()=>stopInertial(s));}
  function rotated(){if(ws&&(touchBusy()||pedalBusy()||pianoBusy()||drumDesired!==0||drumSent!==0||drumQueue.length||mode!=="idle"||streams.some(s=>s.mode!=="idle")))close("Screen rotated. Reconnect and calibrate again.");}
  window.addEventListener("orientationchange",rotated);
  if(window.screen&&window.screen.orientation&&typeof window.screen.orientation.addEventListener==="function")window.screen.orientation.addEventListener("change",rotated);
  disconnect.addEventListener("click",()=>close("Disconnected. Host releases owned controls."));
  window.addEventListener("blur",()=>{if(ws)close("Window lost focus. Reconnect explicitly.");});
  window.addEventListener("pagehide",()=>{if(ws)close("Page hidden.");});
  document.addEventListener("visibilitychange",()=>{if(document.hidden&&ws)close("Page hidden. Reconnect explicitly.");});
  syncControls();
})();
"""#
}
#endif
