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
<body><h1>TIHULU Remote</h1><p>Local touch controller · Experimental</p>
<label for="secret">One-time invitation (64 hexadecimal characters)</label>
<input id="secret" type="password" maxlength="64" autocomplete="off" autocapitalize="off" spellcheck="false">
<button id="connect">Connect</button><button id="disconnect" disabled>Disconnect / release</button>
<p id="status" role="status" aria-live="polite">Not connected.</p>
<div id="pad" aria-label="XY touch surface" aria-disabled="true"><span>Touch and move</span><div id="dot" hidden></div></div>
<p><small>X and Y control the mapped instrument. Lift to release. One contact only. No motion, microphone or camera access. The host decides whether MIDI is enabled.</small></p>
<script src="/control.js" defer></script></body></html>
"""#
    private static let script = #"""
"use strict";
(() => {
  const get = id => document.getElementById(id);
  const pad=get("pad"), dot=get("dot"), secret=get("secret"), connect=get("connect"), disconnect=get("disconnect"), status=get("status");
  let ws=null, admitted=false, pending=false, sequence=0, pointer=null, position=null, releaseDue=false, timer=null, deadline=null, lastSend=0;
  function clearDeadline(){if(deadline!==null)clearTimeout(deadline);deadline=null;}
  function close(message){
    const old=ws;ws=null;admitted=false;pending=false;sequence=0;pointer=null;position=null;releaseDue=false;
    clearDeadline();if(timer!==null)clearInterval(timer);timer=null;
    if(old){old.onopen=old.onmessage=old.onclose=old.onerror=null;try{old.close();}catch{}}
    dot.hidden=true;pad.setAttribute("aria-disabled","true");connect.disabled=false;disconnect.disabled=true;status.textContent=message;
  }
  function wait(ms){clearDeadline();deadline=setTimeout(()=>close("Connection timed out. Request a new invitation."),ms);}
  function send(kind, axes){
    if(!ws||!admitted||pending||ws.readyState!==WebSocket.OPEN)return;
    if(ws.bufferedAmount>256){close("Backlog. Controls released by host watchdog.");return;}
    const frame={version:1,sequence:++sequence,kind};
    if(axes){frame.x=axes.x;frame.y=axes.y;}
    pending=true;lastSend=performance.now();wait(220);
    try{ws.send(JSON.stringify(frame));}catch{close("Send failed. Request a new invitation.");}
  }
  function tick(){
    if(!admitted||pending)return;
    if(releaseDue){releaseDue=false;send("release");}
    else if(pointer!==null&&position){if(performance.now()-lastSend>=50)send("touch",position);}
    else if(performance.now()-lastSend>=500)send("heartbeat");
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
        clearDeadline();admitted=true;lastSend=performance.now();pad.setAttribute("aria-disabled","false");status.textContent="Connected. Touch to play.";
        timer=setInterval(tick,25);tick();return;
      }
      if(!pending||e.data!=="accepted"){close("Unexpected response.");return;}
      clearDeadline();pending=false;if(releaseDue)tick();
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
    if(!admitted||pointer!==null||e.button!==0)return;
    e.preventDefault();pointer=e.pointerId;try{pad.setPointerCapture(pointer);}catch{close("Pointer capture failed.");return;}
    move(e);if(!pending&&!releaseDue)send("touch",position);
  });
  pad.addEventListener("pointermove",e=>{if(e.pointerId===pointer){e.preventDefault();move(e);}});
  function lift(e){
    if(e.pointerId!==pointer)return;
    pointer=null;position=null;dot.hidden=true;releaseDue=true;tick();
  }
  for(const event of ["pointerup","pointercancel","lostpointercapture"])pad.addEventListener(event,lift);
  disconnect.addEventListener("click",()=>close("Disconnected. Host releases owned controls."));
  window.addEventListener("blur",()=>{if(ws)close("Window lost focus. Reconnect explicitly.");});
  window.addEventListener("pagehide",()=>{if(ws)close("Page hidden.");});
  document.addEventListener("visibilitychange",()=>{if(document.hidden&&ws)close("Page hidden. Reconnect explicitly.");});
})();
"""#
}
#endif
