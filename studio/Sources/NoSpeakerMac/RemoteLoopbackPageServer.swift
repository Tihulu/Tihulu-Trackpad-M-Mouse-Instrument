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
    public let groupNeutralHandshake: Bool
    private var attemptStart = 0.0
    private var attempts = 0
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false

    public init(identity: SecIdentity, endpoint: RemoteEndpoint = .loopback, groupNeutralHandshake:Bool = false) throws {
        self.endpoint = endpoint
        self.groupNeutralHandshake = groupNeutralHandshake
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
            case .script: self.respond(id, content: Self.script.replacingOccurrences(of: "__REMOTE_ORIGIN__", with: self.endpoint.origin).replacingOccurrences(of: "__REMOTE_SOCKET__", with: self.endpoint.socketURL).replacingOccurrences(of: "__GROUP_NEUTRAL__", with: self.groupNeutralHandshake ? "enabled" : "disabled"), type: "text/javascript; charset=utf-8")
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
            "Permissions-Policy: camera=(self), microphone=(), geolocation=()",
            "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src wss://\(endpoint.socketAuthority); media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
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
#pad:focus-visible{outline:3px solid #e5a33b;outline-offset:3px}#pad[aria-disabled=true]{opacity:.45}#dot{position:absolute;width:22px;height:22px;background:#e34f4f;border:2px solid white;border-radius:50%;transform:translate(-50%,-50%);pointer-events:none}#dot[hidden]{display:none}
#releaseAll{min-height:44px;border-color:#e5a33b}#status{min-height:2.8em}small{color:#bdbdbd}
#drumGrid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px}#drumGrid button{margin:0;min-height:80px;padding:8px;touch-action:none;user-select:none;overflow-wrap:anywhere}#drumGrid button[aria-pressed=true]{background:#286b50;border-color:#79c9a5} @media(max-width:420px){#drumGrid{grid-template-columns:repeat(2,minmax(0,1fr))}}
#kitBoard{container-type:size;position:relative;height:clamp(250px,48vh,430px);border:1px solid #777;border-radius:12px;background:radial-gradient(#454545 1px,transparent 1px) 0 0/16px 16px;overflow:hidden}
#kitBoard button{position:absolute;margin:0;transform:translate(-50%,-50%);width:clamp(44px,18%,100px);max-width:min(24cqw,30cqh);box-sizing:border-box;aspect-ratio:1;border-radius:50%;padding:3px;touch-action:none;font-size:clamp(10px,2.4vw,14px);background:#303947;border:2px solid #8e9bad;overflow-wrap:anywhere}
#kitBoard button[data-cymbal=true]{background:#66512a;border-color:#d9b65c}
#kitBoard button[data-selected=true]{outline:3px solid #79c9a5;outline-offset:2px;z-index:2}#kitBoard button:focus-visible{outline:3px solid #e5a33b;outline-offset:2px;z-index:3}
#kitBoard button[data-hit=true]{background:#286b50;border-color:#79c9a5}
#kitEditor label{display:block}#kitEditor button{min-height:44px}
#pianoBoard{position:relative;height:clamp(145px,30vh,240px);touch-action:none;user-select:none}
#pianoBoard button{position:absolute;margin:0;border-radius:0 0 6px 6px;padding:0 0 8px;display:flex;align-items:flex-end;justify-content:center;touch-action:none;user-select:none;font-size:12px}
#pianoBoard .whiteKey{top:0;height:100%;background:#f1f1f1;color:#252525;border-color:#555;z-index:1}
#pianoBoard .blackKey{top:0;height:60%;background:#222;color:white;border-color:#666;z-index:2}
#pianoBoard button[data-arp-selected=true]{box-shadow:inset 0 -8px #6ba9ed}
#pianoTools{display:flex;gap:6px;flex-wrap:wrap;align-items:center}#pianoTools button{min-height:44px}
#pedalSection[data-synth=true] output[data-dial]{display:grid;place-items:center;position:relative;margin:8px auto;width:68px;height:68px;border-radius:50%;border:5px solid #607b96;background:#292f38;touch-action:none;user-select:none;font-size:11px}
 #pedalSection[data-compact=true] output[data-dial]{width:48px;height:48px;border-width:3px;margin:4px auto}
#pedalSection[data-compact=true] input[type=range]{height:22px}
#synthChoiceGrid{display:flex;flex-wrap:wrap;gap:4px}#synthChoiceGrid button{margin:2px;min-height:40px}
#pedalSection[data-synth=true] output[data-dial]::before{content:"";position:absolute;inset:5px;border-top:3px solid #9bc9fa;border-radius:50%;transform:rotate(var(--dial-angle,0deg));pointer-events:none}
#pianoBoard button[data-scale=true]{border-bottom:7px solid #79a8d2}
#pianoBoard button[aria-pressed=true],#pianoSustain[aria-pressed=true]{background:#286b50;color:white;border-color:#79c9a5}
#pianoBoard[data-strips=true]{display:flex;gap:3px;height:clamp(180px,40vh,340px)}
#pianoBoard[data-strips=true] button{position:static;flex:1 1 0;min-width:0;width:auto!important;height:100%;border-radius:8px;background:#27394a;color:white;font-size:clamp(10px,2vw,16px);padding:0 0 12px}
#pianoBoard[data-strips=true] button[aria-pressed=true]{background:#286b50;border-color:#79c9a5}
#pianoBoard button:focus-visible{outline:3px solid #e5a33b;outline-offset:-4px}
#pedalGrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
#pedalGrid section{border:1px solid #777;border-radius:10px;padding:8px;min-width:0}
#pedalGrid button{width:100%;margin:4px 0;padding:8px;overflow-wrap:anywhere}
#pedalGrid input[type=range]{padding:8px 0;accent-color:#79c9a5}
#pedalGrid button[data-hold=true]{touch-action:none;user-select:none}
#pedalGrid button[aria-pressed=true]{background:#286b50;border-color:#79c9a5}
@media(max-width:420px){#pedalGrid{grid-template-columns:repeat(2,minmax(0,1fr))}}
#playView>section[data-wide=true]{grid-column:1/-1}
@media(min-width:800px){#playView>section[data-wide=false]{grid-column:span 1}}
#touchSection[data-size=compact] #pad,#pianoSection[data-size=compact] #pianoBoard{height:clamp(130px,28vh,220px)}
#touchSection[data-size=large] #pad,#pianoSection[data-size=large] #pianoBoard{height:clamp(220px,55vh,430px)}
#drumSection[data-size=compact] #drumGrid button{min-height:56px}
#drumSection[data-size=large] #drumGrid button{min-height:110px}
#pedalSection[data-size=compact] #pedalGrid button{min-height:44px}
#pedalSection[data-size=large] #pedalGrid button{min-height:76px}
#drumGrid[data-columns="2"],#pedalGrid[data-columns="2"]{grid-template-columns:repeat(2,minmax(0,1fr))}
#drumGrid[data-columns="3"],#pedalGrid[data-columns="3"]{grid-template-columns:repeat(3,minmax(0,1fr))}
#drumGrid[data-columns="4"],#pedalGrid[data-columns="4"]{grid-template-columns:repeat(4,minmax(0,1fr))}
@media(max-width:360px){#drumGrid[data-columns="4"],#pedalGrid[data-columns="4"]{grid-template-columns:repeat(2,minmax(0,1fr))}}
#layoutSection select,#playMode{max-width:100%;font:inherit;padding:10px;background:#252525;color:inherit}#playModeSection{grid-column:1/-1;order:-2}#playMode{width:100%;min-height:44px}
#layoutSection button{min-height:44px}
#layoutDragList{display:grid;gap:4px;max-width:460px}
#layoutDragList button{margin:0;text-align:left;touch-action:none;user-select:none}
#customGrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}
#customGrid[data-columns="1"]{grid-template-columns:minmax(0,1fr)}
#customGrid[data-columns="3"]{grid-template-columns:repeat(3,minmax(0,1fr))}
@media(max-width:360px){#customGrid[data-columns="3"]{grid-template-columns:repeat(2,minmax(0,1fr))}}
#customGrid>button{margin:0;min-height:76px;touch-action:none;user-select:none;overflow-wrap:anywhere}
#customGrid section{border:1px solid #777;border-radius:10px;padding:8px;min-width:0}
#customGrid section button{width:100%;margin:4px 0;overflow-wrap:anywhere}
#customGrid input[type=range]{width:100%;accent-color:#79c9a5}
#playView input[type=range][data-vertical=true]{writing-mode:vertical-lr;direction:rtl;height:145px;width:44px;display:block;margin:8px auto;padding:0;touch-action:none}
#customGrid button[data-hold=true]{touch-action:none;user-select:none}
#customGrid button[aria-pressed=true]{background:#286b50;border-color:#79c9a5}
#layoutDragList button[data-target=true]{border-color:#e5a33b;background:#4c3820}
</style></head>
<body><h1>TIHULU Remote</h1><p>Local MIDI performance controller · No app installation required · Experimental</p>
<div id="remoteBar"><nav aria-label="Controller views"><button id="navPlay" aria-pressed="false" disabled>Play</button><button id="navSetup" aria-pressed="false" disabled>Setup</button><button id="navConnection" aria-pressed="true">Connection</button></nav><button id="releaseAll" disabled>Release my controls</button><button id="disconnect" disabled>Disconnect / release</button><p id="navStatus" role="status"></p><p id="playWorkloadStatus" role="status"></p><p id="status" role="status" aria-live="polite">Not connected.</p><small id="ackLatency">Mac ACK round trip: no sample.</small></div>
<section id="connectionView"><label for="secret">One-time invitation (64 hexadecimal characters)</label>
<input id="secret" type="password" maxlength="64" autocomplete="off" autocapitalize="off" spellcheck="false">
<button id="connect">Connect</button><p>Use the matching trusted TLS certificate and a new invitation for each connection. ACK round trip includes Mac processing; it is not audio or MIDI latency.</p><div id="webCameraConnectionHost"><details id="webCameraPanel"><summary id="webCameraSummary">Browser camera check (optional)</summary><p id="webCameraDescription">Local camera preview only. No hand recognition, depth or MIDI output in this check. Stop before pairing. Nothing is recorded or sent to the Mac.</p><label for="webCameraFacing">Camera direction</label><select id="webCameraFacing"><option value="environment">Rear</option><option value="user">Front</option></select><label for="webCameraDevice">Available camera</label><select id="webCameraDevice"><option value="">Default for direction</option></select><button id="webCameraStart" type="button">Start camera check</button><button id="webCameraStop" type="button" disabled>Stop camera</button><video id="webCameraVideo" muted playsinline autoplay hidden style="width:100%;max-width:480px;border-radius:12px"></video><label for="webCameraZoom">Device zoom</label><input id="webCameraZoom" type="range" disabled><p id="webCameraStatus" role="status">Camera off.</p><small>Camera access requires a trusted HTTPS connection. Lens and zoom availability are browser/device dependent. Native LiDAR/ToF APIs are not available in this preview.</small></details></div></section>
<div id="setupView" hidden>
<section id="mappingSection" hidden><h2>Mapped MIDI destinations</h2><p id="mappingStatus" role="status"></p><p id="responseModeStatus"></p><pre id="mappingDetails" style="white-space:pre-wrap;overflow-wrap:anywhere"></pre></section>
<section id="workloadSection" hidden aria-labelledby="workloadTitle"><h2 id="workloadTitle">Performance combinations</h2>
<p id="workloadStatus" role="status" aria-live="polite">Conservative combinations. No physical latency guarantee.</p>
<button id="workloadMode" type="button" aria-pressed="false" disabled>Enable experimental combinations</button>
<small>Conservative mode allows one touch, drum, piano or pedal surface plus up to two motion streams, or all three motion streams alone. Experimental mode permits additional mapped combinations but may interrupt performance; the same safety limits apply. Change mode only when all controls are disabled and released.</small></section>
<section id="layoutSection" hidden aria-labelledby="layoutTitle"><h2 id="layoutTitle">My performance layout</h2>
<p>Arrange the mapped panels on this browser. Layout does not change Mac mappings or enable any controls.</p>
<p><small>Drag a panel handle to another row to reorder, or use the move buttons below.</small></p>
<div id="layoutDragList" aria-label="Panel reorder handles"></div>
<label for="layoutPanel">Panel</label><select id="layoutPanel"></select>
<button id="layoutUp" type="button">Move earlier</button><button id="layoutDown" type="button">Move later</button>
<button id="layoutWide" type="button" aria-pressed="false">Full width on tablet</button>
<label for="layoutSize">Playing surface size</label><select id="layoutSize"><option value="normal">Normal</option><option value="compact">Compact</option><option value="large">Large</option></select>
<label for="panelSize">Selected panel size</label><select id="panelSize"><option value="inherit">Use overall size</option><option value="compact">Compact</option><option value="normal">Normal</option><option value="large">Large</option></select>
<label for="panelColumns">Selected grid columns</label><select id="panelColumns"><option value="auto">Automatic</option><option value="2">2 columns</option><option value="3">3 columns</option><option value="4">4 columns</option></select>
<fieldset id="customEditor"><legend>Custom performance panel</legend>
<p>Combine up to eight mapped pads and pedal controls. Controls move from their original panels; Mac mappings do not change.</p>
<label for="customColumns">Custom panel columns</label><select id="customColumns"><option value="1">1 column</option><option value="2">2 columns</option><option value="3">3 columns</option></select>
<label for="customAddChoice">Available control</label><select id="customAddChoice"></select><button id="customAdd" type="button">Add to custom panel</button>
<label for="customChoice">Custom panel control</label><select id="customChoice"></select><button id="customUp" type="button">Move earlier</button><button id="customDown" type="button">Move later</button><button id="customRemove" type="button">Return to original panel</button>
<label for="customAlias">Local control label</label><input id="customAlias" type="text" maxlength="32" autocomplete="off"><button id="customAliasApply" type="button">Apply label</button><button id="customAliasClear" type="button">Use Mac label</button><small>Only changes the name displayed on this browser, not the MIDI mapping.</small></fieldset>
<fieldset id="gridOrderEditor" hidden><legend>Individual mapped controls</legend>
<label for="gridControl">Control</label><select id="gridControl"></select>
<button id="gridControlUp" type="button">Move control earlier</button><button id="gridControlDown" type="button">Move control later</button>
<small>Control identities and Mac assignments stay unchanged.</small></fieldset>
<fieldset id="sliderEditor" hidden><legend>Slider configuration</legend>
<label for="sliderChoice">Mapped slider</label><select id="sliderChoice"></select>
<label for="sliderDirection">Orientation</label><select id="sliderDirection"><option value="horizontal">Horizontal</option><option value="vertical">Vertical</option></select>
<label for="sliderDefault">Initial level (%)</label><input id="sliderDefault" type="number" min="0" max="100" step="1" inputmode="numeric" value="100">
<button id="sliderApply" type="button">Apply slider settings</button>
<small>Initial level is sent only after explicit pedal activation.</small></fieldset>
<fieldset id="pedalBehavior"><legend>Pedal switch behavior</legend><label for="pedalMode3">Sustain</label><select id="pedalMode3"><option value="toggle">Toggle</option><option value="hold">Hold</option></select>
<label for="pedalMode4">Switch A</label><select id="pedalMode4"><option value="toggle">Toggle</option><option value="hold">Hold</option></select>
<label for="pedalMode5">Switch B</label><select id="pedalMode5"><option value="toggle">Toggle</option><option value="hold">Hold</option></select>
<small>Changes how the button sends its active state. The Mac still defines its MIDI assignment and behavior.</small></fieldset>
<button id="layoutSave" type="button">Save on this browser</button><button id="layoutReset" type="button">Reset layout</button>
<p id="layoutStatus" role="status"></p><small>Only presentation preferences are stored locally. Release and disable controls before editing. No invitation, mapping or device name is stored.</small></section></div>
<div id="playView" hidden><section id="playModeSection" data-wide="true"><label for="playMode">Instrument / controller mode</label><select id="playMode" disabled aria-describedby="playModeStatus"></select><p id="playModeStatus" role="status"></p><small>Switch surfaces here. Only modes assigned on the Mac are available. Pitch bend requires a mapped XY axis or pedal slider. Switching releases previous controls before showing the new surface.</small></section><section id="webCameraPlayHost" hidden data-wide="true"><h2>Camera motion helper (experimental)</h2><p>Keep the device stationary. Image change controls a mapped continuous pedal. Not hand recognition or depth. Stop to change lens or zoom.</p><label for="webCameraTarget">Assigned helper</label><select id="webCameraTarget"></select><label for="webCameraExtra1">Additional helper 1 (optional)</label><select id="webCameraExtra1"></select><label for="webCameraExtraMetric1">Additional control 1</label><select id="webCameraExtraMetric1"><option value="x">Motion X</option><option value="y">Motion Y</option><option value="amount">Motion amount</option></select><label for="webCameraExtraInvert1"><input id="webCameraExtraInvert1" type="checkbox" style="width:auto"> Invert additional control 1</label><label for="webCameraExtraGain1">Additional control 1 gain</label><select id="webCameraExtraGain1"><option value="1">100%</option><option value="0.5">50%</option><option value="1.5">150%</option><option value="2">200%</option></select><label for="webCameraExtra2">Additional helper 2 (optional)</label><select id="webCameraExtra2"></select><label for="webCameraExtraMetric2">Additional control 2</label><select id="webCameraExtraMetric2"><option value="y">Motion Y</option><option value="x">Motion X</option><option value="amount">Motion amount</option></select><label for="webCameraExtraInvert2"><input id="webCameraExtraInvert2" type="checkbox" style="width:auto"> Invert additional control 2</label><label for="webCameraExtraGain2">Additional control 2 gain</label><select id="webCameraExtraGain2"><option value="1">100%</option><option value="0.5">50%</option><option value="1.5">150%</option><option value="2">200%</option></select><label for="webCameraMetric">Motion control</label><select id="webCameraMetric"><option value="amount">Motion amount</option><option value="x">Motion position X</option><option value="y">Motion position Y (up)</option></select><label for="webCameraGain">Primary control gain</label><select id="webCameraGain"><option value="1">100%</option><option value="0.5">50%</option><option value="1.5">150%</option><option value="2">200%</option></select><label for="webCameraSensitivity">Sensitivity</label><select id="webCameraSensitivity"><option value="normal">Normal</option><option value="fine">Sensitive</option><option value="low">Low</option></select><label for="webCameraRegion">Detection region</label><select id="webCameraRegion"><option value="full">Full frame</option><option value="center">Center</option><option value="left">Left half</option><option value="right">Right half</option></select><label for="webCameraDesiredZoom">Performance zoom factor (optional)</label><input id="webCameraDesiredZoom" type="number" min="0.1" step="any" inputmode="decimal" placeholder="Device default"><small>Applied and verified before performance starts; unsupported values are rejected.</small><label for="webCameraCalibration">Startup calibration</label><select id="webCameraCalibration"><option value="quiet">Require quiet frame baseline</option><option value="direct">Direct (experimental)</option></select><label><input id="webCameraLight" type="checkbox" style="width:auto"> Reduce uniform lighting changes</label><label><input id="webCameraInvert" type="checkbox" style="width:auto"> Invert active output</label><button id="webCameraSave" type="button">Save sensor settings locally</button><button id="webCameraLoad" type="button">Load saved sensor settings</button><button id="webCameraReset" type="button">Reset sensor settings</button><p id="webCameraProfileStatus" role="status"></p><small>Stores calibration and display preferences only; not camera IDs, MIDI assignments or invitations. Load never starts capture.</small><p id="webCameraMotionStatus" role="status">Off.</p></section><section id="customSection" hidden data-wide="true" aria-labelledby="customTitle"><h2 id="customTitle">My performance panel</h2>
<p>Enable the mapped control families separately. Existing workload limits still apply.</p>
<button id="customDrumEnable" type="button" disabled>Enable drum pads</button><button id="customPedalEnable" type="button" disabled>Enable pedalboard</button>
<button id="customDrumRelease" type="button" disabled>Release all drum pads</button><button id="customPedalRelease" type="button" disabled>Release all pedals</button>
<div id="customGrid"></div></section><section id="touchSection" hidden><div id="pad" role="button" tabindex="-1" aria-label="XY touch surface" aria-describedby="xyHelp xyInputStatus" aria-disabled="true" aria-pressed="false"><span>Touch and move</span><div id="dot" hidden></div></div>
<p><small id="xyHelp">X and Y control the mapped instrument. Lift to release. Keyboard: hold Space or Enter, use arrow keys to move, release the held key or press Escape to stop. Release XY retires the current source contact; the Mac release policy still applies. One contact only.</small></p><button id="xyClutch" type="button" disabled>Release XY / re-arm</button><p id="xyInputStatus" role="status">XY idle.</p></section>
<section id="drumSection" hidden aria-labelledby="drum-title"><h2 id="drum-title">Drum Pads</h2>
<p>Only pads mapped for this paired device are available. Pad numbers identify controls, not assumed MIDI notes. Actual destinations are listed in Setup when shared.</p>
<button id="drumEnable" disabled>Enable drum pads</button><button id="drumRelease" disabled>Release all pads</button>
<p id="drumStatus" role="status">Off.</p><div id="drumGrid"><button id="drum0" type="button" aria-pressed="false" disabled>1 · Kick</button><button id="drum1" type="button" aria-pressed="false" disabled>2 · Snare</button><button id="drum2" type="button" aria-pressed="false" disabled>3 · Closed Hi-Hat</button><button id="drum3" type="button" aria-pressed="false" disabled>4 · Open Hi-Hat</button><button id="drum4" type="button" aria-pressed="false" disabled>5 · Low Tom</button><button id="drum5" type="button" aria-pressed="false" disabled>6 · High Tom</button><button id="drum6" type="button" aria-pressed="false" disabled>7 · Crash</button><button id="drum7" type="button" aria-pressed="false" disabled>8 · Ride</button></div>
<small>Multiple fingers supported. Hold a pad to sustain its note; lift to release. Fixed host velocity, no pressure sensing. Release all clears pending hits.</small>
<div id="airStickSection" hidden><h3>Air stick · Drum kit</h3><div id="kitBoard" aria-label="Editable assigned drum kit"></div>
<button id="kitEdit" type="button" aria-pressed="false">Edit kit layout</button><div id="kitEditor" hidden>
<label for="kitPart">Kit element</label><select id="kitPart"></select><button id="kitAdd" type="button">Add to layout</button><button id="kitRemove" type="button">Remove from layout</button>
<label for="kitX">Horizontal position</label><input id="kitX" type="range" min="12" max="88" step="1">
<label for="kitY">Vertical position</label><input id="kitY" type="range" min="15" max="85" step="1">
<label for="kitSize">Element size</label><input id="kitSize" type="range" min="12" max="24" step="1">
<button id="kitSave" type="button">Save layout on this browser</button><button id="kitReset" type="button">Reset kit</button><p id="kitStatus" role="status"></p>
<small>Drag a visible element or adjust its position and size. Add/remove changes presentation only; the Mac owns MIDI assignments. Only assigned pads can be added.</small></div>
<label for="airStickPad">Assigned strike pad</label><select id="airStickPad"></select><button id="airStickStart" type="button" disabled>Enable air stick</button><button id="airStickStop" type="button" disabled>Stop air stick</button><p id="airStickStatus" role="status">Off.</p><small>Select a mapped pad between strikes, then hold still before striking it. Gravity-free motion triggers the selected pad at fixed velocity. Hold securely, use small movements and never hit a surface.</small></div></section>
<section id="pianoSection" hidden aria-labelledby="piano-title"><h2 id="piano-title">Piano</h2>
<p>Only keys and sustain mapped for this paired device are available. Key positions identify logical controls. Scale hints are available only for a verified default pitch mapping.</p>
<div id="pianoTools"><button id="pianoArp" type="button" aria-pressed="false" disabled>Arp</button><button id="pianoChord" type="button" aria-pressed="false" disabled>Chord</button><button id="pianoSynth" type="button" aria-pressed="false" disabled>Show synth controls</button><button id="synthCompact" type="button" aria-pressed="false" hidden>Compact knobs</button></div><div id="synthChoices" hidden><small>Visible controls (edit while pedals are off)</small><div id="synthChoiceGrid"></div></div>
<button id="pianoEnable" disabled>Enable piano</button><button id="pianoRelease" disabled>Release keys &amp; pedal</button>
<p id="pianoStatus" role="status">Off.</p>
<button id="octaveDown" disabled>Octave −</button><span id="octaveLabel">C3–C4</span><button id="octaveUp" disabled>Octave +</button>
<label for="pianoScale">Scale guide (visual 12-TET only)</label><select id="pianoScale"><option value="all">Chromatic</option><option value="major">Major</option><option value="minor">Natural Minor</option><option value="harmonicMinor">Harmonic Minor</option><option value="melodicMinor">Melodic Minor (ascending)</option><option value="dorian">Dorian</option><option value="phrygian">Phrygian</option><option value="lydian">Lydian</option><option value="mixolydian">Mixolydian</option><option value="locrian">Locrian</option><option value="pentatonic">Major Pentatonic</option><option value="minorPentatonic">Minor Pentatonic</option><option value="blues">Blues</option><option value="hicaz">Hicaz-inspired (12-TET)</option><option value="nihavend">Nihavend-inspired (12-TET)</option><option value="kurdi">Kurdi-inspired (12-TET)</option><option value="hicazkar">Hicazkar-inspired (12-TET)</option></select><small id="scaleGuideStatus"></small>
<label for="pianoRoot">Root note</label><select id="pianoRoot"><option value="0">C</option><option value="1">C♯</option><option value="2">D</option><option value="3">D♯</option><option value="4">E</option><option value="5">F</option><option value="6">F♯</option><option value="7">G</option><option value="8">G♯</option><option value="9">A</option><option value="10">A♯</option><option value="11">B</option></select>
<button id="pianoStrips" aria-pressed="false" disabled>Note strips</button>
<small id="pianoStripHint" hidden>Slide between assigned notes or hold multiple fingers. Lift to release; leaving the surface releases that finger. Discrete notes only, no independent pitch bend. Change layouts when all notes and pedal are released.</small>
<div id="pianoBoard" aria-label="Piano keyboard"><button id="piano0" class="whiteKey" type="button" style="left:0%;width:12.5%" aria-pressed="false" disabled></button><button id="piano2" class="whiteKey" type="button" style="left:12.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano4" class="whiteKey" type="button" style="left:25%;width:12.5%" aria-pressed="false" disabled></button><button id="piano5" class="whiteKey" type="button" style="left:37.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano7" class="whiteKey" type="button" style="left:50%;width:12.5%" aria-pressed="false" disabled></button><button id="piano9" class="whiteKey" type="button" style="left:62.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano11" class="whiteKey" type="button" style="left:75%;width:12.5%" aria-pressed="false" disabled></button><button id="piano12" class="whiteKey" type="button" style="left:87.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano1" class="blackKey" type="button" style="left:8.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano3" class="blackKey" type="button" style="left:21.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano6" class="blackKey" type="button" style="left:46.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano8" class="blackKey" type="button" style="left:58.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano10" class="blackKey" type="button" style="left:71.1%;width:7.8%" aria-pressed="false" disabled></button></div>
<button id="pianoSustain" type="button" aria-pressed="false" disabled>Sustain (hold)</button>
<small id="pianoManualHint">Hold or slide across multiple keys. Lift to release. Sustain is independent. Octave changes are available only after all piano messages are acknowledged. Scale guide does not alter MIDI routing.</small>
<div id="phraseSection" hidden><h3 id="phraseTitle">Chord pads</h3>
<div id="chordGrid"><button id="chord0" type="button" disabled></button><button id="chord1" type="button" disabled></button><button id="chord2" type="button" disabled></button><button id="chord3" type="button" disabled></button></div>
<div id="phraseTransport" hidden><label for="phraseTempo">Tempo</label><select id="phraseTempo"><option value="60">60 BPM</option><option value="90">90 BPM</option><option value="120" selected>120 BPM</option><option value="150">150 BPM</option></select><label id="arpLabel" for="arpChoice">Arpeggio chord</label><select id="arpChoice"></select><div id="arpKeyboardTools" hidden><button id="arpClear" type="button">Clear selected notes</button><label for="arpDirection">Direction</label><select id="arpDirection"><option value="up">Up</option><option value="down">Down</option><option value="bounce">Up / down</option></select><label for="arpRate">Rate</label><select id="arpRate"><option value="8">1/8</option><option value="4">1/4</option><option value="16">1/16</option><option value="12">1/8 triplet</option></select><label for="arpSwing">Swing</label><select id="arpSwing"><option value="50">Straight (50%)</option><option value="55">55%</option><option value="60">60%</option></select><p id="arpSelected" role="status"></p></div><div id="sequenceSteps"><label for="phraseStep0">Step 1</label><select id="phraseStep0"></select><label for="phraseStep1">Step 2</label><select id="phraseStep1"></select><label for="phraseStep2">Step 3</label><select id="phraseStep2"></select><label for="phraseStep3">Step 4</label><select id="phraseStep3"></select><label for="phraseStep4">Step 5</label><select id="phraseStep4"></select><label for="phraseStep5">Step 6</label><select id="phraseStep5"></select><label for="phraseStep6">Step 7</label><select id="phraseStep6"></select><label for="phraseStep7">Step 8</label><select id="phraseStep7"></select></div><button id="phraseStart" type="button" disabled>Start loop</button><button id="phraseStop" type="button" disabled>Stop loop</button></div>
<p id="phraseStatus" role="status">Off.</p><small>Only mapped logical keys are used. Actual pitch depends on Mac mapping. Browser clock, no DAW synchronization; delayed playback stops instead of replaying old notes.</small></div></section>
<section id="pedalSection" hidden aria-labelledby="pedal-title"><h2 id="pedal-title">Pedalboard</h2>
<p>Only pedals mapped for this paired device are available. These are MIDI controls, not audio effects. Labels identify logical controls; actual destinations depend on the Mac mapping.</p>
<button id="pedalEnable" disabled>Enable pedalboard</button><button id="pedalRelease" disabled>Release all pedals</button>
<p id="pedalStatus" role="status">Off.</p>
<div id="pedalGrid"><section id="pedalCell0"><label for="pedalLevel0">Expression</label><button id="pedalToggle0" type="button" aria-pressed="false" disabled>Activate</button><input id="pedalLevel0" type="range" min="0" max="100" step="1" value="100" disabled><output id="pedalValue0" for="pedalLevel0">100%</output></section><section id="pedalCell1"><label for="pedalLevel1">Volume</label><button id="pedalToggle1" type="button" aria-pressed="false" disabled>Activate</button><input id="pedalLevel1" type="range" min="0" max="100" step="1" value="100" disabled><output id="pedalValue1" for="pedalLevel1">100%</output></section><section id="pedalCell2"><label for="pedalLevel2">Wah / Filter</label><button id="pedalToggle2" type="button" aria-pressed="false" disabled>Activate</button><input id="pedalLevel2" type="range" min="0" max="100" step="1" value="0" disabled><output id="pedalValue2" for="pedalLevel2">0%</output></section><section id="pedalCell3"><p>Sustain</p><button id="pedalToggle3" type="button" aria-pressed="false" disabled>Off</button></section><section id="pedalCell4"><p>Switch A</p><button id="pedalToggle4" type="button" aria-pressed="false" disabled>Off</button></section><section id="pedalCell5"><p>Switch B</p><button id="pedalToggle5" type="button" aria-pressed="false" disabled>Off</button></section></div>
<small>Each control is explicitly activated; sliders retain their position until released. Sustain and FX switches use the Hold or Toggle behavior selected in Setup. Release sends the Mac-defined neutral or restores another owner's value. For motion-controlled wah, map tilt pitch to CC74 on the Mac and use Pocket Wah below instead of activating the manual wah slider. If both are mapped, existing host priority rules apply.</small></section>
<section id="tiltSection" hidden aria-labelledby="tilt-title"><h2 id="tilt-title">Pocket Wah / Tilt</h2>
<p>First map a phone or tablet tilt axis on the Mac. Hold the phone comfortably, nearly upright or flat but away from extreme angles, then enable and calibrate. Touch and tilt can be used together. Release either control independently.</p>
<button id="motionStart" disabled>Enable &amp; calibrate tilt</button><button id="motionStop" disabled>Release tilt</button>
<label for="tiltMeter">Relative pitch (before Mac mapping)</label><meter id="tiltMeter" min="0" max="1" value="0.5" style="width:100%;height:24px"></meter>
<p id="motionStatus" role="status">Motion off.</p><small>Motion is opt-in, sent only to the paired Mac. No microphone, camera or storage. Calibrate here for source orientation, not the current MIDI value. The Mac owns response mode; release and enable again for a new source reference.</small></section>
<section id="inertialSection" hidden aria-labelledby="inertial-title"><h2 id="inertial-title">Motion dynamics</h2>
<p>Map acceleration magnitude or rotation magnitude on the Mac first. Each control is optional and separately released. Gravity-free acceleration is required; missing readings are not simulated.</p>
<div id="accelSection" hidden><label for="accelMeter">Acceleration · 0–20 m/s²</label><meter id="accelMeter" min="0" max="1" value="0" style="width:100%;height:24px"></meter>
<button id="accelStart" disabled>Enable acceleration</button><button id="accelStop" disabled>Release acceleration</button><p id="accelStatus" role="status">Off.</p></div>
<div id="rotationSection" hidden><label for="rotationMeter">Rotation speed · 0–360°/s</label><meter id="rotationMeter" min="0" max="1" value="0" style="width:100%;height:24px"></meter>
<button id="rotationStart" disabled>Enable rotation</button><button id="rotationStop" disabled>Release rotation</button><p id="rotationStatus" role="status">Off.</p></div>
<p id="airDrumNotice" hidden>Air Drums is mapped: enabling acceleration can trigger notes. Use gentle controlled movements.</p><small>Live meters are before Mac mapping. Rotation speed is not angle or displacement. The Mac owns response mode; release and enable again to start a new source session. Use only the sensors your instrument maps. If the Mac instrument maps Air Drums, enabling acceleration also enables motion-triggered notes. Hold your device securely; use small controlled motions. Never strike a surface with it.</small></section>
</div><script src="/control.js" defer></script></body></html>
"""#
    private static let script = #"""
"use strict";
(() => {
  const get = id => document.getElementById(id);
  const pad=get("pad"), dot=get("dot"), secret=get("secret"), connect=get("connect"), disconnect=get("disconnect"), status=get("status");
  let ws=null, admitted=false, pending=false, sequence=0, pointer=null, position=null, timer=null, deadline=null, lastSend=0;
  const cameraPanel=get("webCameraPanel"),cameraFacing=get("webCameraFacing"),cameraDevice=get("webCameraDevice"),cameraStart=get("webCameraStart"),cameraStop=get("webCameraStop"),cameraVideo=get("webCameraVideo"),cameraZoom=get("webCameraZoom"),cameraStatus=get("webCameraStatus");
  let cameraStream=null,cameraEpoch=0,cameraPending=false,cameraInFlight=false,cameraZoomPending=false,cameraDevices=[],cameraZoomRange=null;
  const cameraTarget=get("webCameraTarget"),cameraMotionStatus=get("webCameraMotionStatus");
  const cameraMetric=get("webCameraMetric"),cameraSensitivity=get("webCameraSensitivity"),cameraRegion=get("webCameraRegion"),cameraLight=get("webCameraLight"),cameraInvert=get("webCameraInvert"),cameraCalibration=get("webCameraCalibration"),cameraDesiredZoom=get("webCameraDesiredZoom");
  const cameraExtra=[get("webCameraExtra1"),get("webCameraExtra2")],cameraExtraMetric=[get("webCameraExtraMetric1"),get("webCameraExtraMetric2")];
  const cameraGains=[get("webCameraGain"),get("webCameraExtraGain1"),get("webCameraExtraGain2")],cameraExtraInvert=[get("webCameraExtraInvert1"),get("webCameraExtraInvert2")];
  const cameraSave=get("webCameraSave"),cameraLoad=get("webCameraLoad"),cameraReset=get("webCameraReset"),cameraProfileStatus=get("webCameraProfileStatus");
  const cameraProfileKey="tihulu.remote.camera-settings.v1";
  let cameraConfig=null,cameraBaseline=0,cameraArmed=false,cameraSetupTimer=null,cameraGeometry=null,cameraTrackSettings=null;
  function clearCameraSetupTimer(){if(cameraSetupTimer!==null)clearTimeout(cameraSetupTimer);cameraSetupTimer=null;}
  let cameraHelper=false,cameraHost="connection",cameraTargetKey="",cameraLane=-1,cameraFrameId=null,cameraContext=null,cameraPrior=null,cameraAt=null,cameraStartedAt=0,cameraMediaTime=-Infinity,cameraQuiet=0,cameraReleaseAt=null;
  const cameraMedia=()=>window.isSecureContext===true&&typeof navigator!=="undefined"&&navigator.mediaDevices&&typeof navigator.mediaDevices.getUserMedia==="function"?navigator.mediaDevices:null;
  const cameraMode=()=>Boolean(ws&&admitted&&caps&&(caps.pedals&7)&&currentView==="play"&&playMode==="camera");
  const canEditCameraProfile=()=>cameraMode()&&!cameraHelper&&!cameraInFlight&&!cameraStream&&!releasingAll&&workloadMask()===0;
  const validCameraGain=v=>typeof v==="number"&&[.5,1,1.5,2].includes(v);
  function validCameraProfile(p){return p&&typeof p==="object"&&!Array.isArray(p)&&((p.version===1&&Object.keys(p).sort().join(",")==="calibration,facing,invert,light,metric,region,sensitivity,version,zoom")||(p.version===2&&Object.keys(p).sort().join(",")==="calibration,extraInvert,extraMetric,facing,gains,invert,light,metric,region,sensitivity,version,zoom"&&Array.isArray(p.gains)&&p.gains.length===3&&p.gains.every(validCameraGain)&&Array.isArray(p.extraInvert)&&p.extraInvert.length===2&&p.extraInvert.every(v=>typeof v==="boolean")&&Array.isArray(p.extraMetric)&&p.extraMetric.length===2&&p.extraMetric.every(v=>["amount","x","y"].includes(v))))&&["quiet","direct"].includes(p.calibration)&&["user","environment"].includes(p.facing)&&typeof p.invert==="boolean"&&typeof p.light==="boolean"&&["amount","x","y"].includes(p.metric)&&["full","center","left","right"].includes(p.region)&&["normal","fine","low"].includes(p.sensitivity)&&(p.zoom===null||typeof p.zoom==="number"&&Number.isFinite(p.zoom)&&p.zoom>0&&p.zoom<=100);}
  function applyCameraProfile(p){cameraCalibration.value=p.calibration;cameraFacing.value=p.facing;cameraDevice.value="";cameraInvert.checked=p.invert;cameraLight.checked=p.light;cameraMetric.value=p.metric;cameraRegion.value=p.region;cameraSensitivity.value=p.sensitivity;cameraDesiredZoom.value=p.zoom===null?"":String(p.zoom);cameraGains.forEach((el,i)=>el.value=String(p.version===2?p.gains[i]:1));cameraExtraInvert.forEach((el,i)=>el.checked=p.version===2?p.extraInvert[i]:false);cameraExtraMetric.forEach((el,i)=>el.value=p.version===2?p.extraMetric[i]:i===0?"x":"y");}
  cameraSave.addEventListener("click",()=>{if(!canEditCameraProfile())return;
    const raw=cameraDesiredZoom.value.trim(),p={version:2,gains:cameraGains.map(el=>Number(el.value||"1")),extraInvert:cameraExtraInvert.map(el=>el.checked===true),extraMetric:cameraExtraMetric.map((el,i)=>el.value||(i===0?"x":"y")),calibration:cameraCalibration.value||"quiet",facing:cameraFacing.value||"environment",invert:cameraInvert.checked===true,light:cameraLight.checked===true,metric:cameraMetric.value||"amount",region:cameraRegion.value||"full",sensitivity:cameraSensitivity.value||"normal",zoom:raw===""?null:Number(raw)};
    if(!validCameraProfile(p)){cameraProfileStatus.textContent="Invalid sensor settings.";return;}
    try{window.localStorage.setItem(cameraProfileKey,JSON.stringify(p));cameraProfileStatus.textContent="Sensor settings saved on this browser.";}catch{cameraProfileStatus.textContent="Local storage unavailable.";}
  });
  cameraLoad.addEventListener("click",()=>{if(!canEditCameraProfile())return;
    try{const raw=window.localStorage.getItem(cameraProfileKey);if(typeof raw!=="string"||raw.length>1024)throw Error();const p=JSON.parse(raw);if(!validCameraProfile(p))throw Error();applyCameraProfile(p);cameraProfileStatus.textContent="Settings loaded. Review and start explicitly.";}catch{cameraProfileStatus.textContent="No valid saved sensor settings.";}
  });
  cameraReset.addEventListener("click",()=>{if(!canEditCameraProfile())return;
    applyCameraProfile({version:1,calibration:"quiet",facing:"environment",invert:false,light:false,metric:"amount",region:"full",sensitivity:"normal",zoom:null});
    try{window.localStorage.removeItem(cameraProfileKey);cameraProfileStatus.textContent="Sensor settings reset.";}catch{cameraProfileStatus.textContent="Reset for this page only; storage unavailable.";}
  });
  function syncCamera(){
    const helper=cameraMode(),host=helper?"play":"connection";
    if(host!==cameraHost){get(helper?"webCameraPlayHost":"webCameraConnectionHost").appendChild(cameraPanel);cameraHost=host;}
    get("webCameraPlayHost").hidden=!helper;
    textIfChanged("webCameraSummary",helper?"Camera source and controls":"Browser camera check (optional)");
    textIfChanged("webCameraStart",helper?"Start motion helper":"Start camera check");
    textIfChanged("webCameraDescription",helper?"Local video is analyzed for image motion. Only the assigned helper level is sent to the Mac. No recording, hand recognition or depth. Camera calibration is not MIDI feedback; the Mac owns the response mode.":"Local camera preview only. No hand recognition, depth or MIDI output in this check. Stop before pairing. Nothing is recorded or sent to the Mac.");
    const targetKey=String(caps?.pedals??0);
    if(targetKey!==cameraTargetKey){cameraTarget.replaceChildren(...Array.from({length:3},(_,i)=>i).filter(i=>has("pedals",i)).map(i=>{const o=document.createElement("option");o.value=String(i);o.textContent=["Expression","Volume","Wah / filter"][i];return o;}));cameraTarget.value=String(Array.from({length:3},(_,i)=>i).find(i=>has("pedals",i))??0);for(const extra of cameraExtra){const off=document.createElement("option");off.value="";off.textContent="Off";extra.replaceChildren(off,...Array.from({length:3},(_,i)=>i).filter(i=>has("pedals",i)).map(i=>{const o=document.createElement("option");o.value=String(i);o.textContent=["Expression","Volume","Wah / filter"][i];return o;}));extra.value="";}cameraTargetKey=targetKey;}
    for(const control of [cameraTarget,...cameraExtra,...cameraExtraMetric,...cameraGains,...cameraExtraInvert,cameraMetric,cameraSensitivity,cameraRegion,cameraLight,cameraInvert,cameraCalibration,cameraDesiredZoom])control.disabled=cameraHelper||cameraInFlight||!helper;
    for(const b of [cameraSave,cameraLoad,cameraReset])b.disabled=!canEditCameraProfile();
    cameraStart.disabled=(!!ws&&!helper)||!cameraMedia()||cameraInFlight||!!cameraStream||document.hidden||(helper&&(releasingAll||pending||workloadMask()!==0||typeof cameraVideo.requestVideoFrameCallback!=="function"));
    if(!cameraMedia()&&!cameraStream&&!cameraPending)cameraStatus.textContent="Camera unavailable in this browser or insecure context. Touch controls remain separate.";
    cameraStop.disabled=!cameraPending&&!cameraStream;
    cameraFacing.disabled=(!!ws&&!helper)||cameraInFlight||!!cameraStream;
    cameraDevice.disabled=cameraFacing.disabled||cameraDevices.length===0;
    cameraZoom.disabled=!!ws||!cameraStream||!cameraZoomRange||cameraZoomPending;
  }
  function disposeCamera(stream){if(stream)for(const track of stream.getTracks()){try{track.stop();}catch{}}}
  function stopCamera(message="Camera off."){
    clearCameraSetupTimer();
    if(cameraFrameId!==null){try{cameraVideo.cancelVideoFrameCallback?.(cameraFrameId);}catch{}}cameraFrameId=null;
    cameraHelper=false;cameraLane=-1;cameraConfig=null;cameraBaseline=0;cameraArmed=false;cameraGeometry=null;cameraTrackSettings=null;cameraContext=null;cameraPrior=null;cameraAt=null;cameraMediaTime=-Infinity;cameraQuiet=0;cameraMotionStatus.textContent="Off.";
    cameraEpoch++;cameraPending=false;cameraZoomPending=false;cameraZoomRange=null;
    const previous=cameraStream;cameraStream=null;
    cameraVideo.srcObject=null;cameraVideo.hidden=true;disposeCamera(previous);
    cameraStatus.textContent=message;syncCamera();
  }
  function showCameraChoices(devices){
    cameraDevices=devices.filter(d=>d.kind==="videoinput"&&typeof d.deviceId==="string"&&d.deviceId.length>0).slice(0,32);
    cameraDevice.replaceChildren();
    const defaultOption=document.createElement("option");defaultOption.value="";defaultOption.textContent="Default for direction";cameraDevice.appendChild(defaultOption);
    cameraDevices.forEach((d,i)=>{const o=document.createElement("option");o.value=d.deviceId;o.textContent=(typeof d.label==="string"&&d.label?d.label:"Camera "+(i+1)).slice(0,120);cameraDevice.appendChild(o);});
    cameraDevice.value="";
  }
  cameraFacing.addEventListener("change",()=>{cameraDevice.value="";});
  function stopCameraExplicit(message){if(cameraHelper&&admitted){releaseMyControls();cameraStatus.textContent=message;}else stopCamera(message);}
  cameraPanel.addEventListener("toggle",()=>{if(cameraPanel.open===false&&(cameraStream||cameraPending))stopCameraExplicit("Camera panel closed.");});
  cameraStart.addEventListener("click",async()=>{
    const media=cameraMedia();
    const helper=cameraMode();
    if(!media||(ws&&!helper)||cameraInFlight||cameraStream||document.hidden)return;
    if(helper&&(releasingAll||pending||workloadMask()!==0||typeof cameraVideo.requestVideoFrameCallback!=="function"))return;
    const facing=cameraFacing.value||"environment",id=cameraDevice.value;
    if(!["user","environment"].includes(facing)||id&&!cameraDevices.some(d=>d.deviceId===id))return;
    if(helper){const lane=Number(cameraTarget.value);if(!Number.isInteger(lane)||lane<0||lane>2||!has("pedals",lane))return;
      const metric=cameraMetric.value||"amount",sensitivity=cameraSensitivity.value||"normal",region=cameraRegion.value||"full",calibration=cameraCalibration.value||"quiet";
      if(!["amount","x","y"].includes(metric)||!["normal","fine","low"].includes(sensitivity)||!["full","center","left","right"].includes(region)||!["quiet","direct"].includes(calibration))return;
      const gain=i=>{const v=cameraGains[i].value||"1";return ["0.5","1","1.5","2"].includes(v)?Number(v):null;};
      if(gain(0)===null)return;
      const assignments=[{lane,metric,gain:gain(0),invert:cameraInvert.checked===true}];
      for(let i=0;i<cameraExtra.length;i++){const raw=cameraExtra[i].value;if(raw==="")continue;const extra=Number(raw),kind=cameraExtraMetric[i].value|| (i===0?"x":"y");
        if(!/^[0-2]$/.test(raw)||!has("pedals",extra)||assignments.some(a=>a.lane===extra)||!["amount","x","y"].includes(kind)){cameraMotionStatus.textContent="Choose distinct assigned helpers.";return;}const g=gain(i+1);if(g===null)return;assignments.push({lane:extra,metric:kind,gain:g,invert:cameraExtraInvert[i].checked===true});}
      const requested=cameraDesiredZoom.value.trim(),desiredZoom=requested===""?null:Number(requested);
      if(desiredZoom!==null&&(!Number.isFinite(desiredZoom)||desiredZoom<=0))return;
      cameraConfig={metric,assignments,mask:assignments.reduce((m,a)=>m|(1<<a.lane),0),sensitivity,region,light:cameraLight.checked===true,invert:cameraInvert.checked===true,calibration,desiredZoom};cameraArmed=calibration==="direct";cameraHelper=true;cameraLane=lane;pedalEnabled=true;}
    const epoch=++cameraEpoch;cameraPending=true;cameraInFlight=true;cameraStatus.textContent="Requesting local camera…";syncCamera();
    let stream=null;
    try{
      stream=await media.getUserMedia({audio:false,video:{...(id?{deviceId:{exact:id}}:{facingMode:{exact:facing}}),width:{ideal:640},height:{ideal:480}}});
      if(epoch!==cameraEpoch||(helper?!cameraMode():!!ws)||document.hidden){disposeCamera(stream);return;}
      const tracks=stream.getVideoTracks();
      if(tracks.length!==1||stream.getTracks().length!==1||tracks[0].readyState==="ended")throw Error("Invalid camera stream");
      const track=tracks[0];cameraStream=stream;cameraVideo.srcObject=stream;cameraVideo.hidden=false;
      track.addEventListener("ended",()=>{if(epoch===cameraEpoch){if(cameraHelper)close("Camera ended. Reconnect explicitly.");else stopCamera("Camera ended. Start explicitly again.");}});
      track.addEventListener("mute",()=>{if(epoch===cameraEpoch){if(cameraHelper)close("Camera muted. Reconnect explicitly.");else stopCamera("Camera muted. Start explicitly again.");}});
      if(track.muted===true)throw Error("Camera muted");
      const zoom=typeof track.getCapabilities==="function"?track.getCapabilities().zoom:null;
      if(zoom&&Number.isFinite(zoom.min)&&Number.isFinite(zoom.max)&&zoom.min>0&&zoom.max>zoom.min){
        cameraZoomRange={min:zoom.min,max:zoom.max,step:Number.isFinite(zoom.step)&&zoom.step>0?zoom.step:0.1};
        cameraZoom.min=String(zoom.min);cameraZoom.max=String(zoom.max);cameraZoom.step=String(cameraZoomRange.step);
        const current=typeof track.getSettings==="function"?track.getSettings().zoom:null;
        cameraZoom.value=String(Number.isFinite(current)?Math.max(zoom.min,Math.min(zoom.max,current)):Math.max(zoom.min,Math.min(zoom.max,1)));
      }
      if(helper&&cameraConfig?.desiredZoom!==null){
        const requested=cameraConfig.desiredZoom;
        if(!cameraZoomRange||requested<cameraZoomRange.min||requested>cameraZoomRange.max||typeof track.applyConstraints!=="function")throw Error("Requested zoom unavailable");
        cameraSetupTimer=setTimeout(()=>{if(epoch===cameraEpoch)stopCameraExplicit("Camera zoom setup timed out. Stop and restart explicitly.");},3000);
        await track.applyConstraints({advanced:[{zoom:requested}]});
        if(epoch===cameraEpoch)clearCameraSetupTimer();
        if(epoch!==cameraEpoch||!cameraMode()||cameraStream!==stream||document.hidden)return;
        const actual=track.getSettings?.().zoom;
        if(!Number.isFinite(actual)||actual<cameraZoomRange.min||actual>cameraZoomRange.max||Math.abs(actual-requested)>0.001)throw Error("Requested zoom not confirmed");
        cameraZoom.value=String(actual);
      }
      const settings=track.getSettings?.()??{};
      if(helper)cameraTrackSettings={zoom:Number.isFinite(settings.zoom)?settings.zoom:null,deviceId:typeof settings.deviceId==="string"?settings.deviceId:null,facingMode:typeof settings.facingMode==="string"?settings.facingMode:null};
      cameraPending=false;const actualFacing=settings.facingMode;
      cameraStatus.textContent="Camera active locally"+(actualFacing==="user"?" · front":actualFacing==="environment"?" · rear":" · direction not reported")+(helper?". Motion helper · zoom locked while armed.":". Stop before pairing.");syncCamera();
      if(helper){const canvas=document.createElement("canvas");canvas.width=16;canvas.height=12;cameraContext=canvas.getContext("2d",{willReadFrequently:true});if(!cameraContext)throw Error("Canvas unavailable");cameraStartedAt=performance.now();cameraMotionStatus.textContent="Waiting for local video frames…";cameraFrameId=cameraVideo.requestVideoFrameCallback((now,meta)=>cameraFrame(epoch,now,meta));}
      if(typeof media.enumerateDevices==="function"){
        // Inventory is best effort and must never hold the capture request fence.
        Promise.resolve().then(()=>media.enumerateDevices()).then(devices=>{if(epoch===cameraEpoch&&cameraStream===stream){showCameraChoices(devices);syncCamera();}}).catch(()=>{});
      }
    }catch{if(epoch===cameraEpoch&&helper){if(cameraStream!==stream)disposeCamera(stream);stopCameraExplicit("Camera or requested zoom unavailable. Check browser permission, HTTPS and zoom range.");}else if(epoch===cameraEpoch&&cameraStream===stream)stopCamera("Camera denied or unavailable. Check browser permission and HTTPS.");else{disposeCamera(stream);if(epoch===cameraEpoch)stopCamera("Camera denied or unavailable. Check browser permission and HTTPS.");}}
    finally{cameraInFlight=false;syncCamera();}
  });
  cameraStop.addEventListener("click",()=>stopCameraExplicit("Camera off."));
  function cameraFrame(epoch,callbackTime,metadata){
    if(epoch!==cameraEpoch||!cameraHelper||!cameraMode()||!cameraStream)return;
    const track=cameraStream.getVideoTracks()[0];
    if(!track||track.readyState==="ended"||track.muted===true){close("Camera unavailable. Reconnect explicitly.");return;}
    cameraFrameId=null;
    const now=performance.now(),mediaTime=metadata?.mediaTime;
    if((cameraAt!==null&&now-cameraAt>=150)||(cameraAt===null&&now-cameraStartedAt>=3000)){close("Camera frames stopped. Reconnect explicitly.");return;}
    try{
      if(!Number.isFinite(callbackTime)||callbackTime>now||now-callbackTime>=150||!Number.isFinite(mediaTime)||mediaTime<0||mediaTime<cameraMediaTime)throw Error("Invalid video timing");
      if(metadata.captureTime!==undefined&&(!Number.isFinite(metadata.captureTime)||metadata.captureTime<0||metadata.captureTime>now||now-metadata.captureTime>=150))throw Error("Stale capture timestamp");
      const width=metadata.width,height=metadata.height;
      if(width!==undefined||height!==undefined){
        if(!Number.isInteger(width)||!Number.isInteger(height)||width<=0||height<=0||width>8192||height>8192)throw Error("Invalid frame geometry");
        if(cameraGeometry&&(cameraGeometry[0]!==width||cameraGeometry[1]!==height))throw Error("Camera geometry changed");
        cameraGeometry=[width,height];
      }
      const settings=track.getSettings?.()??{},locked=cameraTrackSettings;
      if(locked&&((locked.zoom!==null&&(!Number.isFinite(settings.zoom)||Math.abs(settings.zoom-locked.zoom)>.001))||(locked.deviceId!==null&&settings.deviceId!==locked.deviceId)||(locked.facingMode!==null&&settings.facingMode!==locked.facingMode)))throw Error("Camera settings changed");
      if(mediaTime>cameraMediaTime){
        cameraContext.drawImage(cameraVideo,0,0,16,12);
        const bytes=cameraContext.getImageData(0,0,16,12).data;
        if(bytes.length!==768)throw Error("Invalid video frame");
        const gray=Array.from({length:192},(_,i)=>(bytes[i*4]*.299+bytes[i*4+1]*.587+bytes[i*4+2]*.114));
        if(!gray.every(Number.isFinite))throw Error("Invalid pixel");
        const previous=cameraPrior;
        cameraPrior=gray;cameraMediaTime=mediaTime;cameraAt=now;
        if(previous){
          // Motion centroid, not hand/pose recognition. Neutral is independent of inversion.
          const cfg=cameraConfig;if(!cfg)throw Error("Missing camera configuration");
          const diffs=gray.map((v,i)=>v-previous[i]);
          const shift=cfg.light?diffs.reduce((a,b)=>a+b,0)/192:0;
          let total=0,weightedX=0,weightedY=0,count=0;
          for(let i=0;i<192;i++){const x=i%16,y=Math.floor(i/16);
            if(cfg.region==="center"&&(x<4||x>=12||y<3||y>=9)||cfg.region==="left"&&x>=8||cfg.region==="right"&&x<8)continue;
            const weight=Math.abs(diffs[i]-shift)/255;total+=weight;weightedX+=weight*(x+.5)/16;weightedY+=weight*(1-(y+.5)/12);count++;
          }
          const amount=total/count,threshold=cfg.sensitivity==="fine"?.012:cfg.sensitivity==="low"?.05:.025;
          const span=cfg.sensitivity==="fine"?.10:cfg.sensitivity==="low"?.35:.20;
          const strength=Math.round(Math.max(0,Math.min(1,(amount-threshold)/span))*100);
          if(!cameraArmed){
            cameraBaseline=strength===0?Math.min(3,cameraBaseline+1):0;
            cameraArmed=cameraBaseline>=3;
            cameraMotionStatus.textContent=cameraArmed?"Calibrated · move to control":"Keep camera and scene still · "+cameraBaseline+"/3";
            tick();
            if(epoch===cameraEpoch&&cameraHelper)cameraFrameId=cameraVideo.requestVideoFrameCallback((t,m)=>cameraFrame(epoch,t,m));
            return;
          }
          const active=strength>0;
          const valueFor=a=>{if(!active)return 0;const raw=a.metric==="x"?weightedX/total*100:a.metric==="y"?weightedY/total*100:strength;const v=Math.round(Math.max(0,Math.min(100,raw*a.gain)));return a.invert?100-v:v;};
          if(performance.now()-now>=150){close("Camera analysis overdue. Reconnect explicitly.");return;}
          if(active){cameraQuiet=0;
            if(cameraReleaseAt===null&&!pedalMask&&!pedalBusy()){
              for(const a of cfg.assignments)pedalPositions[a.lane]=valueFor(a);
              pedalMask=cfg.mask;pedalQueue.push({snapshot:pedalSnapshot(),at:now});pedalDirty=false;syncPedals();tick();
            }else if(pedalMask===cfg.mask){
              for(const a of cfg.assignments)pedalPositions[a.lane]=valueFor(a);
              // Continuous camera values may coalesce, but never extend the original onset deadline.
              if(pedalSentMask===0&&pedalQueue.length===1&&pedalQueue[0].snapshot.mask===cfg.mask)pedalQueue[0].snapshot=pedalSnapshot();
              else pedalDirty=true;
            }
          }else if(++cameraQuiet>=1&&pedalMask){
            if(pedalSentMask===0&&pendingKind!=="pedalboard"){pedalMask=0;pedalQueue=[];pedalDirty=false;}
            else if(cameraQuiet>=2){cameraReleaseAt=now;releasePedals();}
          }
          cameraMotionStatus.textContent=cfg.assignments.map(a=>["Expression","Volume","Wah / filter"][a.lane]+": "+valueFor(a)+"%").join(" · ")+" · "+(pedalMask?"helper active":"neutral");
          tick();
        }
      }
      if(epoch===cameraEpoch&&cameraHelper)cameraFrameId=cameraVideo.requestVideoFrameCallback((t,m)=>cameraFrame(epoch,t,m));
    }catch{close("Camera processing unavailable. Reconnect explicitly.");}
  }

  cameraZoom.addEventListener("change",async()=>{
    if(!cameraStream||!cameraZoomRange||cameraZoomPending||ws)return;
    const value=Number(cameraZoom.value),range=cameraZoomRange,epoch=cameraEpoch,track=cameraStream.getVideoTracks()[0];
    if(!Number.isFinite(value)||value<range.min||value>range.max||typeof track.applyConstraints!=="function")return;
    cameraZoomPending=true;syncCamera();
    try{
      await track.applyConstraints({advanced:[{zoom:value}]});
      if(epoch!==cameraEpoch)return;
      const actual=track.getSettings?.().zoom;
      if(Number.isFinite(actual)&&actual>=range.min&&actual<=range.max){cameraZoom.value=String(actual);cameraStatus.textContent="Camera active locally · "+actual.toFixed(2)+"×";}
      else {cameraZoomRange=null;cameraStatus.textContent="Camera active locally · zoom could not be verified.";}
    }catch{if(epoch===cameraEpoch){cameraZoomRange=null;cameraStatus.textContent="Camera active locally · zoom unavailable.";}}
    finally{if(epoch===cameraEpoch){cameraZoomPending=false;syncCamera();}}
  });
  const motionStart=get("motionStart"), motionStop=get("motionStop"), meter=get("tiltMeter"), motionStatus=get("motionStatus");
  let mode="idle", sample=null, neutral=null, sampleAt=0, sentAt=-1, permissionEpoch=0, waitingSince=0, pendingKind=null;
  let lastTouchSend=-Infinity,lastTiltSend=-Infinity;
  let touchQueue=[],touchSent=false,paceTimer=null,xyClutchPending=false;
  function touchBusy(){return pointer!==null||touchQueue.length!==0||touchSent||pendingKind==="touch"||pendingKind==="release";}
  function queueTouch(kind,axes){
    if(touchQueue.length>=8){close("Touch input backlog. Reconnect explicitly.");return;}
    touchQueue.push({kind,axes,at:performance.now()});syncControls();tick();
  }
  function sendTouchEdge(){const edge=touchQueue.shift();send(edge.kind,edge.axes);}
  let caps=null,experimentalWorkload=false,workloadRefusal="";
  const groupNeutralHandshake="__GROUP_NEUTRAL__"==="enabled";
  let groupReady=null;
  let releasingAll=false,releaseAllTimer=null;
  let currentView="connection",ackSamples=[];
  let playMode="all",pendingPlayMode=null,modeOptionsKey="";
  const viewNames=["play","setup","connection"];
  const navId=v=>"nav"+v[0].toUpperCase()+v.slice(1);
  function navigationBusy(){return releasingAll||pending||workloadMask()!==0;}
  const panelIDs=["touchSection","drumSection","pianoSection","pedalSection","tiltSection","inertialSection"];
  const panelNames=["XY touch","Drum pads","Piano","Pedalboard","Tilt","Motion dynamics"];
  const layoutKey="tihulu.remote.presentation.v1";
  const defaultLayout=()=>({version:1,order:[...panelIDs],wide:["pianoSection","pedalSection"],size:"normal"});
  function validLayout(value){
    if(!value||typeof value!=="object"||Array.isArray(value)||
       Object.keys(value).sort().join(",")!=="order,size,version,wide"||value.version!==1)return false;
    return Array.isArray(value.order)&&value.order.length===panelIDs.length&&
      new Set(value.order).size===panelIDs.length&&value.order.every(id=>panelIDs.includes(id))&&
      Array.isArray(value.wide)&&value.wide.length<=panelIDs.length&&new Set(value.wide).size===value.wide.length&&
      value.wide.every(id=>panelIDs.includes(id))&&["normal","compact","large"].includes(value.size);
  }
  function loadLayout(){
    try{const raw=window.localStorage?.getItem(layoutKey);
      if(typeof raw==="string"&&raw.length<=1024){const data=JSON.parse(raw);if(validLayout(data))return data;}
    }catch{}
    return defaultLayout();
  }
  // The additional preferences are independent of the v1 panel layout.
  // Existing saved layouts require no migration or rewriting.
  const detailKey="tihulu.remote.panel-details.v1";
  const sizedPanels=["touchSection","drumSection","pianoSection","pedalSection"];
  const gridPanels=["drumSection","pedalSection"];
  const indices=n=>Array.from({length:n},(_,i)=>i);
  const customIDs=[...indices(8).map(i=>"d"+i),...indices(6).map(i=>"p"+i)];
  const defaultDetails=()=>({version:1,sizes:{},columns:{},holds:[],drumOrder:indices(8),pedalOrder:indices(6),custom:[],customColumns:"2",customAliases:{},sliderDefaults:[100,100,0],vertical:[]});
  function validOrder(order,n){
    return Array.isArray(order)&&order.length===n&&new Set(order).size===n&&order.every(i=>Number.isInteger(i)&&i>=0&&i<n);
  }
  function validAlias(v){
    return typeof v==="string"&&v.length>=1&&v.length<=32&&v.trim()===v&&
      !/[\p{Cc}\p{Cf}]/u.test(v)&&/[^\p{White_Space}]/u.test(v);
  }
  function validDetails(d){
    const record=v=>v&&typeof v==="object"&&!Array.isArray(v);
    return record(d)&&Object.keys(d).every(k=>["columns","sizes","version","holds","drumOrder","pedalOrder","custom","customColumns","customAliases","sliderDefaults","vertical"].includes(k))&&d.version===1&&
      (d.sliderDefaults===undefined||(Array.isArray(d.sliderDefaults)&&d.sliderDefaults.length===3&&d.sliderDefaults.every(v=>Number.isInteger(v)&&v>=0&&v<=100)))&&
      (d.vertical===undefined||(Array.isArray(d.vertical)&&d.vertical.length<=3&&new Set(d.vertical).size===d.vertical.length&&d.vertical.every(i=>[0,1,2].includes(i))))&&
      (d.customColumns===undefined||["1","2","3"].includes(d.customColumns))&&
      (d.customAliases===undefined||(record(d.customAliases)&&Object.keys(d.customAliases).length<=8&&
        Array.isArray(d.custom)&&Object.entries(d.customAliases).every(([id,v])=>customIDs.includes(id)&&d.custom.includes(id)&&validAlias(v))))&&
      (d.custom===undefined||(Array.isArray(d.custom)&&d.custom.length<=8&&new Set(d.custom).size===d.custom.length&&d.custom.every(id=>customIDs.includes(id))))&&
      (d.drumOrder===undefined||validOrder(d.drumOrder,8))&&(d.pedalOrder===undefined||validOrder(d.pedalOrder,6))&&
      (d.holds===undefined||(Array.isArray(d.holds)&&d.holds.length<=3&&new Set(d.holds).size===d.holds.length&&d.holds.every(i=>[3,4,5].includes(i))))&&
      record(d.sizes)&&Object.entries(d.sizes).every(([k,v])=>sizedPanels.includes(k)&&["compact","normal","large"].includes(v))&&
      record(d.columns)&&Object.entries(d.columns).every(([k,v])=>gridPanels.includes(k)&&["2","3","4"].includes(v));
  }
  function loadDetails(){
    try{const raw=window.localStorage?.getItem(detailKey);
      if(typeof raw==="string"&&raw.length<=4096){const d=JSON.parse(raw);if(validDetails(d))return {...defaultDetails(),...d};}
    }catch{}
    return defaultDetails();
  }
  let details=loadDetails();
  let layout=loadLayout(),layoutMessage="",layoutOptionsKey="",layoutSyncKey="";
  let layoutDrag=null,layoutHandles=[],layoutHandleEpoch=0,gridOptionsKey="",customOptionsKey="",customActive=[],sliderOptionsKey="",sliderValueKey="",aliasInputKey="";
  function availablePanels(){
    if(!caps)return [];
    const available=[caps.touch,Boolean(caps.drums),Boolean(caps.piano),Boolean(caps.pedals),caps.tilt,caps.acceleration||caps.rotation];
    return layout.order.filter(id=>available[panelIDs.indexOf(id)]);
  }
  // A heartbeat has no musical ownership. Keep idle editing usable even
  // when the existing liveness ACK is outstanding; never change scheduling.
  function canEditLayout(){
    return admitted&&caps&&currentView==="setup"&&!releasingAll&&
      workloadMask()===0&&(!pending||pendingKind==="heartbeat");
  }
  function applyLayout(){
    const play=get("playView");
    // Keep visual and keyboard/screen-reader navigation order consistent.
    // Only called at initialization or an admitted idle editor action.
    customActive=details.custom.filter(customMapped);
    if(customActive.length)play.appendChild(get("customSection"));
    for(const [index,id] of layout.order.entries()){
      const element=get(id);
      element.style.order=String(index);
      element.setAttribute("data-wide",String(layout.wide.includes(id)));
      element.setAttribute("data-size",details.sizes[id]??layout.size);
      play.appendChild(element);
    }
    play.setAttribute("data-size",layout.size);
    get("drumGrid").setAttribute("data-columns",details.columns.drumSection??"auto");
    get("pedalGrid").setAttribute("data-columns",details.columns.pedalSection??"auto");
    for(const i of details.drumOrder)get("drumGrid").appendChild(get("drum"+i));
    for(const i of details.pedalOrder)get("pedalGrid").appendChild(get("pedalCell"+i));
    get("customGrid").setAttribute("data-columns",details.customColumns);
    for(const id of customActive)get("customGrid").appendChild(customNode(id));
    get("customSection").style.order=customActive.length?"-1":"6";
    if(!customActive.length)play.appendChild(get("customSection"));
    for(const i of [0,1,2]){
      const vertical=details.vertical.includes(i),slider=get("pedalLevel"+i);
      slider.setAttribute("data-vertical",String(vertical));
      slider.setAttribute("aria-orientation",vertical?"vertical":"horizontal");
    }
    syncSections();syncPedals();syncCustom();renderMapping();
  }
  function clearLayoutDrag(){
    layoutDrag=null;
    for(const h of layoutHandles)h.button.setAttribute("data-target","false");
  }
  function dragTarget(y){
    if(!Number.isFinite(y)||!layoutHandles.length)return null;
    // The handles are a small fixed list; no host-provided geometry.
    for(const h of layoutHandles){
      const rect=h.button.getBoundingClientRect();
      if(!Number.isFinite(rect.top)||!Number.isFinite(rect.height)||rect.height<=0)return null;
      if(y<=rect.top+rect.height/2)return h.id;
    }
    return layoutHandles.at(-1).id;
  }
  function rebuildLayoutHandles(available){
    clearLayoutDrag();
    const epoch=++layoutHandleEpoch;
    const currentHandle=()=>epoch===layoutHandleEpoch;
    layoutHandles=available.map(id=>{
      const button=document.createElement("button");
      button.type="button";button.textContent="↕ "+panelNames[panelIDs.indexOf(id)];
      button.setAttribute("aria-label","Reorder "+panelNames[panelIDs.indexOf(id)]);
      button.addEventListener("click",()=>{
        if(!currentHandle()||!canEditLayout())return;
        get("layoutPanel").value=id;syncLayout();
      });
      button.addEventListener("pointerdown",e=>{
        if(!currentHandle()||!canEditLayout()||layoutDrag||e.button!==0||!Number.isFinite(e.clientY))return;
        e.preventDefault();
        try{button.setPointerCapture(e.pointerId);}catch{return;}
        layoutDrag={id,pointer:e.pointerId,connection:ws,startY:e.clientY,target:id};
        button.setAttribute("data-target","true");
      });
      button.addEventListener("pointermove",e=>{
        if(!currentHandle()||layoutDrag?.pointer!==e.pointerId||layoutDrag.id!==id)return;
        if(!canEditLayout()||layoutDrag.connection!==ws){clearLayoutDrag();return;}
        e.preventDefault();
        layoutDrag.target=dragTarget(e.clientY)??id;
        for(const h of layoutHandles)h.button.setAttribute("data-target",String(h.id===layoutDrag.target));
      });
      button.addEventListener("pointerup",e=>{
        const drag=layoutDrag;
        if(!currentHandle()||drag?.pointer!==e.pointerId||drag.id!==id)return;
        clearLayoutDrag();
        if(!canEditLayout()||drag.connection!==ws||!Number.isFinite(e.clientY))return;
        if(Math.abs(e.clientY-drag.startY)<8){get("layoutPanel").value=id;syncLayout();return;}
        const target=dragTarget(e.clientY);
        if(target)movePanelTo(id,target);
      });
      for(const event of ["pointercancel","lostpointercapture"])button.addEventListener(event,e=>{
        if(currentHandle()&&layoutDrag?.pointer===e.pointerId&&layoutDrag.id===id)clearLayoutDrag();
      });
      return {id,button};
    });
    get("layoutDragList").replaceChildren(...layoutHandles.map(h=>h.button));
  }
  function movePanelTo(id,target){
    if(!canEditLayout())return;
    const available=availablePanels(),from=available.indexOf(id),to=available.indexOf(target);
    if(from<0||to<0||from===to)return;
    clearLayoutDrag();
    available.splice(from,1);available.splice(to,0,id);
    // Dormant panels retain their saved positions.
    let next=0;const visible=new Set(available);
    layout.order=layout.order.map(p=>visible.has(p)?available[next++]:p);
    get("layoutPanel").value=id;
    layoutMessage="Layout changed. Save to retain it.";applyLayout();syncLayout();
  }
  function customMapped(id){
    return customIDs.includes(id)&&has(id[0]==="d"?"drums":"pedals",Number(id[1]));
  }
  function customNode(id){return get((id[0]==="d"?"drum":"pedalCell")+id[1]);}
  function customLabel(id){return labelFor((id[0]==="d"?9:43)+Number(id[1]));}
  function localAlias(id){return customActive.includes(id)?(details.customAliases[id]??""):"";}
  function customEditorLabel(id){const original=customLabel(id);return details.customAliases[id]?details.customAliases[id]+" · "+original:original;}
  function syncCustom(){
    const drums=Boolean(caps)&&playMode!=="stick"&&modeAllows("drums")&&customActive.some(id=>id[0]==="d");
    const pedals=Boolean(caps)&&modeAllows("pedals")&&customActive.some(id=>id[0]==="p"&&synthVisible(Number(id[1])));
    for(const id of customActive)customNode(id).hidden=!modeAllows(id[0]==="d"?"drums":"pedals")||!customMapped(id)||(id[0]==="p"&&!synthVisible(Number(id[1])));
    get("customSection").hidden=!drums&&!pedals;
    for(const [id,visible,enabled,label] of [["customDrumEnable",drums,drumEnabled,"drum pads"],["customPedalEnable",pedals,pedalEnabled,"pedalboard"]]){
      const b=get(id);b.hidden=!visible;b.disabled=!visible||!admitted||releasingAll;
      const title=(enabled?"Disable ":"Enable ")+label;
      if(b.textContent!==title)b.textContent=title;
    }
    for(const [id,visible,enabled] of [["customDrumRelease",drums,drumEnabled],["customPedalRelease",pedals,pedalEnabled]]){
      const b=get(id);b.hidden=!visible;b.disabled=!visible||!admitted||releasingAll||!enabled||currentView!=="play";
    }
  }
  function syncCustomEditor(editable){
    const columns=get("customColumns");columns.disabled=!editable;columns.value=details.customColumns;
    const available=customIDs.filter(id=>customMapped(id)&&!details.custom.includes(id));
    const chosen=details.custom;
    const chosenLabel=id=>customMapped(id)?customEditorLabel(id):((id[0]==="d"?"Pad ":"Pedal ")+(Number(id[1])+1)+" (not mapped)");
    const key=JSON.stringify([available,chosen,available.map(customLabel),chosen.map(chosenLabel)]);
    if(key!==customOptionsKey){
      for(const [id,ids] of [["customAddChoice",available],["customChoice",chosen]]){
        const control=get(id),before=control.value;
        control.replaceChildren(...ids.map(value=>{
          const option=document.createElement("option");option.value=value;option.textContent=id==="customChoice"?chosenLabel(value):customLabel(value);return option;
        }));
        control.value=ids.includes(before)?before:(ids[0]??"");
      }
      customOptionsKey=key;
    }
    const index=chosen.indexOf(get("customChoice").value),canAdd=editable&&details.custom.length<8&&available.includes(get("customAddChoice").value);
    get("customAddChoice").disabled=!editable||!available.length||details.custom.length>=8;
    get("customChoice").disabled=!editable||index<0;
    get("customAdd").disabled=!canAdd;
    get("customRemove").disabled=!editable||index<0;
    get("customUp").disabled=!editable||index<=0;
    get("customDown").disabled=!editable||index<0||index===chosen.length-1;
    const alias=get("customAlias"),selected=chosen[index],aliasKey=JSON.stringify([selected,details.customAliases[selected]??""]);
    if(aliasInputKey!==aliasKey){aliasInputKey=aliasKey;alias.value=details.customAliases[selected]??"";}
    alias.disabled=get("customAliasApply").disabled=!editable||index<0;
    get("customAliasClear").disabled=!editable||index<0||!details.customAliases[selected];
  }
  function changeCustomAlias(clear){
    const id=get("customChoice").value,input=get("customAlias"),value=input.value.trim();
    if(!canEditLayout()||!details.custom.includes(id))return;
    if(!clear&&!validAlias(value)){layoutMessage="Use 1–32 printable characters for the local label.";syncLayout();return;}
    if(clear)delete details.customAliases[id];else details.customAliases[id]=value;
    aliasInputKey="";clearLayoutDrag();layoutMessage="Local label changed. Save to retain it.";applyLayout();syncLayout();
  }
  function changeCustomColumns(){
    const control=get("customColumns"),value=control.value;
    if(!canEditLayout()||!["1","2","3"].includes(value)){control.value=details.customColumns;return;}
    details.customColumns=value;clearLayoutDrag();layoutMessage="Custom panel changed. Save to retain it.";applyLayout();syncLayout();
  }
  function changeCustom(action){
    if(!canEditLayout())return;
    const id=get(action==="add"?"customAddChoice":"customChoice").value;
    if(!customIDs.includes(id))return;
    const chosen=details.custom,index=chosen.indexOf(id);
    if(action==="add"){
      if(!customMapped(id)||details.custom.includes(id)||details.custom.length>=8)return;
      details.custom.push(id);
    }else if(action==="remove"){
      if(index<0)return;details.custom=details.custom.filter(x=>x!==id);delete details.customAliases[id];
    }else if(action==="up"||action==="down"){
      const next=index+(action==="up"?-1:1);
      if(index<0||next<0||next>=chosen.length)return;
      [chosen[index],chosen[next]]=[chosen[next],chosen[index]];
    }else{return;}
    clearLayoutDrag();layoutMessage="Custom panel changed. Save to retain it.";applyLayout();syncLayout();
  }
  function syncSliderEditor(editable){
    const available=[0,1,2].filter(i=>has("pedals",i)),choice=get("sliderChoice");
    get("sliderEditor").hidden=!available.length;
    const key=JSON.stringify([available,available.map(i=>labelFor(43+i))]);
    if(key!==sliderOptionsKey){
      const old=choice.value;
      choice.replaceChildren(...available.map(i=>{
        const option=document.createElement("option");option.value=String(i);option.textContent=labelFor(43+i);return option;
      }));
      choice.value=available.map(String).includes(old)?old:(available.length?String(available[0]):"");
      sliderOptionsKey=key;
    }
    const index=available.map(String).indexOf(choice.value),i=index<0?null:available[index];
    const allowed=editable&&i!==null;
    choice.disabled=!allowed;
    get("sliderDirection").disabled=get("sliderDefault").disabled=get("sliderApply").disabled=!allowed;
    // Keep an in-progress numeric edit intact across idle heartbeat ACKs.
    const valueKey=JSON.stringify([i,i===null?null:details.sliderDefaults[i],i!==null&&details.vertical.includes(i)]);
    if(valueKey!==sliderValueKey){
      get("sliderDefault").value=i===null?"":String(details.sliderDefaults[i]);
      get("sliderDirection").value=i!==null&&details.vertical.includes(i)?"vertical":"horizontal";
      sliderValueKey=valueKey;
    }
  }
  function applySliderSettings(){
    if(!canEditLayout())return;
    const raw=get("sliderChoice").value,i=Number(raw),levelRaw=get("sliderDefault").value,
      level=Number(levelRaw),direction=get("sliderDirection").value;
    if(!["0","1","2"].includes(raw)||!has("pedals",i)||
       !/^(0|[1-9][0-9]{0,2})$/.test(levelRaw)||!Number.isInteger(level)||level>100||
       !["horizontal","vertical"].includes(direction))return;
    clearLayoutDrag();details.sliderDefaults[i]=level;pedalPositions[i]=level;
    details.vertical=details.vertical.filter(v=>v!==i);
    if(direction==="vertical")details.vertical.push(i);
    layoutMessage="Slider settings changed. Save to retain them.";applyLayout();syncLayout();
  }
  function gridChoice(){
    const panel=get("layoutPanel").value;
    if(panel==="drumSection"&&caps?.drums)return {kind:"drums",order:"drumOrder",label:9};
    if(panel==="pedalSection"&&caps?.pedals)return {kind:"pedals",order:"pedalOrder",label:43};
    return null;
  }
  function visibleGrid(choice){return choice?details[choice.order].filter(i=>has(choice.kind,i)&&!customActive.includes((choice.kind==="drums"?"d":"p")+i)):[];}
  function syncGridEditor(editable){
    const choice=gridChoice(),available=visibleGrid(choice),control=get("gridControl");
    get("gridOrderEditor").hidden=!choice;
    const key=choice?JSON.stringify([choice.kind,available,available.map(i=>labelFor(choice.label+i))]):"";
    if(key!==gridOptionsKey){
      const before=control.value;
      control.replaceChildren(...available.map(i=>{
        const option=document.createElement("option");
        option.value=String(i);option.textContent=labelFor(choice.label+i);return option;
      }));
      control.value=available.map(String).includes(before)?before:(available.length?String(available[0]):"");
      gridOptionsKey=key;
    }
    const index=available.map(String).indexOf(control.value);
    control.disabled=!editable||index<0;
    get("gridControlUp").disabled=!editable||index<=0;
    get("gridControlDown").disabled=!editable||index<0||index===available.length-1;
  }
  function moveGridControl(delta){
    if(!canEditLayout())return;
    const choice=gridChoice(),available=visibleGrid(choice);
    const index=available.map(String).indexOf(get("gridControl").value);
    if(!choice||index<0||index+delta<0||index+delta>=available.length)return;
    clearLayoutDrag();
    [available[index],available[index+delta]]=[available[index+delta],available[index]];
    const mapped=new Set(available);let offset=0;
    details[choice.order]=details[choice.order].map(i=>mapped.has(i)?available[offset++]:i);
    layoutMessage="Control order changed. Save to retain it.";applyLayout();syncLayout();
  }
  function syncLayout(){
    const visible=Boolean(caps)&&currentView==="setup";
    get("layoutSection").hidden=!visible;
    // The play/ACK hot path must not rebuild editor options or write
    // layout attributes on every performance sample.
    if(!visible){
      if(layoutDrag)clearLayoutDrag();
      layoutSyncKey="";
      // On disconnection retire detached handlers as well as drag state.
      if(!caps&&layoutHandles.length){
        layoutHandleEpoch++;layoutHandles=[];layoutOptionsKey="";
        get("layoutDragList").replaceChildren();
        get("layoutPanel").replaceChildren();
      }
      if(!caps&&gridOptionsKey){gridOptionsKey="";get("gridControl").replaceChildren();}
      if(!caps&&customOptionsKey){customOptionsKey="";aliasInputKey="";get("customAlias").value="";get("customAddChoice").replaceChildren();get("customChoice").replaceChildren();}
      if(!caps&&sliderOptionsKey){sliderOptionsKey="";sliderValueKey="";get("sliderChoice").replaceChildren();}
      return;
    }
    const panel=get("layoutPanel"),available=availablePanels(),key=available.join(",");
    if(key!==layoutOptionsKey){
      const previous=panel.value;
      // Known fixed identifiers/labels only; no host text enters markup.
      panel.replaceChildren(...available.map(id=>{
        const option=document.createElement("option");
        option.value=id;option.textContent=panelNames[panelIDs.indexOf(id)];return option;
      }));
      panel.value=available.includes(previous)?previous:(available[0]||"");
      layoutOptionsKey=key;
      rebuildLayoutHandles(available);
    }
    const editable=Boolean(canEditLayout()),selected=panel.value,index=available.indexOf(selected);
    if(!editable&&layoutDrag)clearLayoutDrag();
    syncGridEditor(editable);syncCustomEditor(editable);syncSliderEditor(editable);
    const stateKey=JSON.stringify([editable,key,selected,layout.wide,layout.size,details,layoutMessage]);
    if(stateKey===layoutSyncKey)return;
    layoutSyncKey=stateKey;
    panel.disabled=!editable||available.length===0;
    for(const h of layoutHandles)h.button.disabled=!editable;
    get("layoutUp").disabled=!editable||index<=0;
    get("layoutDown").disabled=!editable||index<0||index===available.length-1;
    get("layoutWide").disabled=!editable||index<0;
    get("layoutWide").setAttribute("aria-pressed",String(layout.wide.includes(selected)));
    get("layoutSize").value=layout.size;get("layoutSize").disabled=!editable;
    get("panelSize").value=details.sizes[selected]??"inherit";
    get("panelSize").disabled=!editable||!sizedPanels.includes(selected)||index<0;
    get("panelColumns").value=details.columns[selected]??"auto";
    get("panelColumns").disabled=!editable||!gridPanels.includes(selected)||index<0;
    get("pedalBehavior").hidden=!Boolean(caps?.pedals&56);
    for(const i of [3,4,5]){
      const control=get("pedalMode"+i);
      control.value=details.holds.includes(i)?"hold":"toggle";
      control.disabled=!editable||!has("pedals",i);
    }
    get("layoutSave").disabled=get("layoutReset").disabled=!editable;
    textIfChanged("layoutStatus",!editable&&caps?"Release and disable controls to edit.":layoutMessage);
  }
  function changePanelOrder(delta){
    if(!canEditLayout())return;
    const available=availablePanels(),id=get("layoutPanel").value,index=available.indexOf(id);
    if(index<0||index+delta<0||index+delta>=available.length)return;
    movePanelTo(id,available[index+delta]);
  }
  function changePanelWidth(){
    if(!canEditLayout())return;
    const id=get("layoutPanel").value;if(!availablePanels().includes(id))return;
    clearLayoutDrag();
    layout.wide=layout.wide.includes(id)?layout.wide.filter(x=>x!==id):[...layout.wide,id];
    layoutMessage="Layout changed. Save to retain it.";applyLayout();syncLayout();
  }
  function changeLayoutSize(){
    if(!canEditLayout()||!["normal","compact","large"].includes(get("layoutSize").value)){syncLayout();return;}
    clearLayoutDrag();
    layout.size=get("layoutSize").value;
    layoutMessage="Layout changed. Save to retain it.";applyLayout();syncLayout();
  }
  function changePanelDetail(kind){
    const id=get("layoutPanel").value;
    if(!canEditLayout()||!availablePanels().includes(id))return;
    const sizing=kind==="sizes",control=get(sizing?"panelSize":"panelColumns"),value=control.value;
    if(!(sizing?sizedPanels:gridPanels).includes(id))return;
    const choices=sizing?["inherit","compact","normal","large"]:["auto","2","3","4"];
    if(!choices.includes(value))return;
    clearLayoutDrag();
    if(value===choices[0])delete details[kind][id];else details[kind][id]=value;
    layoutMessage="Layout changed. Save to retain it.";applyLayout();syncLayout();
  }
  function changePedalBehavior(i){
    if(!canEditLayout()||![3,4,5].includes(i)||!has("pedals",i))return;
    const value=get("pedalMode"+i).value;
    if(!["hold","toggle"].includes(value))return;
    clearLayoutDrag();
    details.holds=details.holds.filter(x=>x!==i);
    if(value==="hold")details.holds.push(i);
    layoutMessage="Pedal behavior changed. Save to retain it.";applyLayout();syncLayout();
  }
  function saveLayout(){
    if(!canEditLayout()||!validLayout(layout)||!validDetails(details))return;
    try{
      window.localStorage.setItem(layoutKey,JSON.stringify(layout));
      window.localStorage.setItem(detailKey,JSON.stringify(details));
      layoutMessage="Saved on this browser.";
    }catch{layoutMessage="Storage unavailable or incomplete. Current layout remains in this page.";}
    syncLayout();
  }
  function resetLayout(){
    if(!canEditLayout())return;
    clearLayoutDrag();
    layout=defaultLayout();details=defaultDetails();pedalPositions=[...details.sliderDefaults];sliderValueKey="";aliasInputKey="";
    try{window.localStorage.removeItem(layoutKey);window.localStorage.removeItem(detailKey);layoutMessage="Default layout restored.";}
    catch{layoutMessage="Default layout restored for this page; saved data could not be removed.";}
    applyLayout();syncLayout();
  }
  const playModes=[
    ["all","All assigned controls",[]],
    ["xy","XY / pitch bend (as mapped)",["touch"]],
    ["piano","Piano / note strips",["piano"]],
    ["chord","Chord pads",["piano"]],
    ["arp","Arpeggiator",["piano"]],
    ["seq","Step sequencer",["piano"]],
    ["drums","Drum pads",["drums"]],
    ["stick","Air stick (motion to drum pad)",["drums"]],
    ["pedals","Pedals / effects",["pedals"]],
    ["camera","Camera motion helper (experimental)",[]],
    ["tilt","Tilt / orientation",["tilt"]],
    ["gyro","Gyro / rotation",["rotation"]],
    ["accel","Acceleration / Air Drums",["acceleration"]],
    ["motion","All assigned motion sensors",["tilt","rotation","acceleration"]]
  ];
  function modeAvailable(id){
    const entry=playModes.find(p=>p[0]===id);
    return Boolean(caps&&entry&&(id==="chord"?chordShapes.some((_,i)=>chordAvailable(i)):["arp","seq"].includes(id)?Boolean(caps.piano&33554431):id==="camera"?Boolean(caps.pedals&7):id==="all"||entry[2].some(kind=>Boolean(caps[kind]))));
  }
  function modeAllows(kind){
    return playMode==="all"||(kind==="pedals"&&synthOpen&&["piano","arp","chord","seq"].includes(playMode))||Boolean(playModes.find(p=>p[0]===playMode)?.[2].includes(kind));
  }
  function syncPlayMode(){
    const select=get("playMode");
    const key=JSON.stringify(playModes.map(p=>[p[0],modeAvailable(p[0])]));
    if(key!==modeOptionsKey){
      select.replaceChildren(...playModes.map(([id,label])=>{
        const option=document.createElement("option");option.value=id;
        const available=modeAvailable(id);
        option.disabled=!available;option.textContent=label+(available?"":" — not assigned");
        return option;
      }));
      modeOptionsKey=key;
    }
    select.value=pendingPlayMode??playMode;
    select.disabled=!admitted||!caps||currentView!=="play"||releasingAll;
    textIfChanged("playModeStatus",pendingPlayMode!==null?"Releasing previous controls; waiting for Mac acknowledgments…":
      "Select an assigned mode. Enable notes, pedals or sensors explicitly when needed.");
  }
  function choosePlayMode(){
    const id=get("playMode").value;
    if(currentView!=="play"||!admitted||!caps||releasingAll||!modeAvailable(id)||id===playMode){
      syncPlayMode();return;
    }
    // Global release already cancels unsent onsets, waits for ACKs and
    // closes on timeout. Never open a second lane or arm automatically.
    pendingPlayMode=id;
    releaseMyControls();
  }
  function syncNavigation(){
    for(const v of viewNames){
      get(v+"View").hidden=currentView!==v;
      const b=get(navId(v));b.setAttribute("aria-pressed",String(currentView===v));
      b.disabled=v!==currentView&&(!caps||navigationBusy());
    }
    textIfChanged("navStatus",caps&&navigationBusy()?"Release and disable controls before changing views.":"");
  }
  function chooseView(v){
    if(!viewNames.includes(v)||v===currentView||!caps||navigationBusy())return;
    currentView=v;syncControls();
  }
  function textIfChanged(id,value){const el=get(id);if(el.textContent!==value)el.textContent=value;}
  function syncLatency(){
    const now=performance.now();
    ackSamples=ackSamples.filter(x=>now-x.at<2000);
    const values=ackSamples.map(x=>x.elapsed).sort((a,b)=>a-b),n=values.length;
    const median=n?(values[Math.floor((n-1)/2)]+values[Math.floor(n/2)])/2:null;
    textIfChanged("ackLatency",median!==null?"Mac ACK round trip (recent median): "+Math.round(median)+" ms. Not MIDI/audio latency.":"Mac ACK round trip: no recent sample.");
  }
  function recordAck(){
    const now=performance.now(),elapsed=now-lastSend;
    if(Number.isFinite(elapsed)&&elapsed>=0&&elapsed<=220){ackSamples.push({elapsed,at:now});if(ackSamples.length>8)ackSamples.shift();}
    syncLatency();
  }
  const releaseAll=get("releaseAll");
  function cancelGlobalTimer(){if(releaseAllTimer!==null)clearTimeout(releaseAllTimer);releaseAllTimer=null;}
  function finishGlobalRelease(){
    if(!releasingAll||pending||workloadMask()!==0)return false;
    cancelGlobalTimer();releasingAll=false;
    if(pendingPlayMode!==null){
      if(modeAvailable(pendingPlayMode)){playMode=pendingPlayMode;synthOpen=false;dialDrags.clear();arpSelected.clear();}
      pendingPlayMode=null;
    }
    drumStatus.textContent=pianoStatus.textContent=pedalStatus.textContent="Off.";
    status.textContent="My controls released locally; required Mac acknowledgments received. MIDI/audio output not confirmed. Enable controls again to play.";
    syncControls();return true;
  }
  function releaseMyControls(){
    if(!admitted||!caps||releasingAll)return;
    releasingAll=true;const now=performance.now();
    if(cameraHelper){if(pedalSentMask!==0||pendingKind==="pedalboard")cameraReleaseAt??=now;stopCamera("Camera stopped; releasing controls.");}
    // Cancel unsent onsets; retain the state of every already sent owner.
    pointer=null;position=null;dot.hidden=true;touchQueue=touchSent?[{kind:"release",at:now}]:[];
    resetStick();drumEnabled=false;drumOwners.clear();drumDesired=0;drumQueue=[];drumEmergency=drumSent!==0;
    resetPhrase();pianoEnabled=false;pianoOwners.clear();pianoVisited.clear();pianoDesired=0;pianoQueue=[];pianoEmergency=pianoSent!==0;
    pedalEnabled=false;pedalHoldOwners.clear();pedalMask=0;pedalQueue=[];pedalDirty=false;pedalEmergency=pedalSentMask!==0;
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
  function groupLabelAvailable(id,manifest){
    if(!Number.isSafeInteger(id))return false;
    if(id>=0&&id<=2)return manifest.touch;
    if(id>=9&&id<=16)return Boolean(manifest.drums&(1<<(id-9)));
    if(id>=17&&id<=42)return Boolean(manifest.piano&(1<<(id-17)));
    if(id>=43&&id<=48)return Boolean(manifest.pedals&(1<<(id-43)));
    return false;
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
        !(groupNeutralHandshake&&!s.detail?groupLabelAvailable(r[0],s.manifest):s.rows.some(row=>row[0]===r[0])))return false;
      const label=decodeLabel(r[1]);if(label===null)return false;
      s.labels.set(r[0],label);s.lastLabel=r[0];
    }
    s.next++;clearDeadline();pending=false;pendingKind=null;
    if(s.next===s.labelPages)ready(s.manifest,s.detail?s.rows:null,s.labels);else nextMapping();
    return true;
  }
  function renderMapping(){
    get("mappingSection").hidden=!caps;
    get("mappingStatus").textContent=!caps?"":mappingRows?"Shared by the Mac. MIDI output is not confirmed by this display.":groupNeutralHandshake&&mappingLabels.size?"Custom control labels shared. MIDI addresses remain hidden.":"Mapping details hidden by the Mac.";
    textIfChanged("responseModeStatus",caps?"Absolute / Relative response and starting reference are configured on the Mac. This connection does not report the applied mode or current instrument value. Source readings and acknowledgments are not Logic feedback.":"");
    get("mappingDetails").textContent=mappingRows?mappingRows.map(r=>labelFor(r[0])+" · "+targetText(r)).join("\n"):groupNeutralHandshake?[...mappingLabels.keys()].map(labelFor).join("\n"):"";
    for(let i=0;i<8;i++){
      const r=targets(9+i),alias=localAlias("d"+i),original=labelFor(9+i);
      const button=get("drum"+i);
      button.textContent=(alias||original)+(r.length===1?" · "+targetText(r[0]):r.length>1?" · "+r.length+" targets":"");
      button.setAttribute("aria-label",alias?alias+" · "+original:button.textContent);
    }
  }
  function clearMapping(){
    if(mappingTimer!==null)clearTimeout(mappingTimer);mappingTimer=null;
    if(mappingBudget!==null)clearTimeout(mappingBudget);mappingBudget=null;
    mappingStage=null;mappingRows=null;mappingLabels=new Map();
  }
  function ready(manifest,rows,labels=new Map()){
    clearMapping();
    if(groupNeutralHandshake){
      const queue=[];
      if(manifest.touch)queue.push(["release"]);
      if(manifest.drums)queue.push(["drumPads",{mask:0}]);
      if(manifest.piano)queue.push(["pianoKeys",{mask:0}]);
      if(manifest.pedals)queue.push(["pedalboard",{mask:0,levels:[0,0,0,0,0,0]}]);
      if(queue.length<1||queue.length>4||manifest.tilt||manifest.acceleration||manifest.rotation||manifest.airDrums){close("Unsupported group surface.");return;}
      groupReady={manifest,rows,labels,queue};
      status.textContent="Arming neutral group controls…";
      send(...queue.shift());
      return;
    }
    finishReady(manifest,rows,labels);
  }
  function finishReady(manifest,rows,labels){
    mappingRows=rows;mappingLabels=labels;caps=manifest;currentView="play";
    if(!octaveAvailable(0)&&octaveAvailable(1))pianoOctave=1;
    applyLayout();syncControls();renderMapping();status.textContent="Connected. Only mapped controls are available.";
    timer=setInterval(tick,25);tick();
  }
  function nextMapping(){
    const stage=mappingStage,connection=ws;
    if(!stage||!connection)return;
    mappingTimer=setTimeout(()=>{
      mappingTimer=null;
      if(ws!==connection||mappingStage!==stage||pending)return;
      send(stage.phase==="labels"?"mappingLabels":"mapping",{page:stage.next});
    },50); // Wait after the preceding ACK, not merely after its send.
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
      if(groupNeutralHandshake&&s.detail)return false; // group ports cannot be represented by legacy channel-only rows
      if(s.detail&&(!s.rows.length||!coverage(s.rows,s.manifest)))return false;
      if((s.detail||groupNeutralHandshake)&&mappingLabelsV8){s.phase="labels";s.next=0;s.labels=new Map();s.lastLabel=-1;nextMapping();}
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
    const requested=workloadMask()|workloadBits[group];
    return !releasingAll&&modeAllows(group)&&(!groupNeutralHandshake||popcount(requested)<=2)&&
      (experimentalWorkload||conservativeCombination(requested));
  }
  function requestWorkload(group){
    if(workloadAllows(group)){workloadRefusal="";return true;}
    workloadRefusal="Combination unavailable. Disable and release another control before trying again.";
    syncWorkload();return false;
  }
  function syncWorkload(){
    const mask=workloadMask();
    get("workloadSection").hidden=!caps;
    workloadMode.disabled=currentView!=="setup"||!admitted||!caps||mask!==0||pending||releasingAll;
    workloadMode.textContent=experimentalWorkload?"Use conservative combinations":"Enable experimental combinations";
    workloadMode.setAttribute("aria-pressed",String(experimentalWorkload));
    const description=experimentalWorkload?"Experimental combinations. Performance may be interrupted.":"Conservative combinations. No physical latency guarantee.";
    const summary=(workloadRefusal?workloadRefusal+" ":"")+description+" Enabled, requested or releasing streams: "+popcount(mask)+".";
    if(workloadStatus.textContent!==summary)workloadStatus.textContent=summary;
    textIfChanged("playWorkloadStatus",caps?summary:"");
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
    // The custom panel owns the existing DOM nodes, not duplicated MIDI
    // controls. Suppress an original panel only when every mapped control
    // has moved; restoring any one control immediately restores its panel.
    const originalDrums=playMode==="stick"&&Boolean(caps?.drums)||indices(8).some(i=>has("drums",i)&&!customActive.includes("d"+i));
    const originalPedals=indices(6).some(i=>has("pedals",i)&&synthVisible(i)&&!customActive.includes("p"+i));
    for(const [id,visible] of [["touchSection",caps?.touch&&modeAllows("touch")],["drumSection",originalDrums&&modeAllows("drums")],["pianoSection",caps?.piano&&modeAllows("piano")],["pedalSection",originalPedals&&modeAllows("pedals")],["tiltSection",caps?.tilt&&modeAllows("tilt")],["inertialSection",(caps?.acceleration&&modeAllows("acceleration"))||(caps?.rotation&&modeAllows("rotation"))],["accelSection",caps?.acceleration&&modeAllows("acceleration")],["rotationSection",caps?.rotation&&modeAllows("rotation")],["airDrumNotice",caps?.airDrums&&modeAllows("acceleration")]])get(id).hidden=!visible;
  }
  const drumButtons=Array.from({length:8},(_,i)=>get("drum"+i));
  const drumEnable=get("drumEnable"),drumRelease=get("drumRelease"),drumStatus=get("drumStatus");
  let drumEnabled=false,drumOwners=new Map(),drumQueue=[],drumDesired=0,drumSent=0,lastDrumSend=-Infinity,drumEmergency=false;
  let stickState="idle",stickEpoch=0,stickPad=0,stickKey="",stickAt=0,stickReady=false,stickPulseAt=null,stickLast=-Infinity;
  const kitKey="tihulu.remote.drum-kit.v1";
  const kitNames=["Kick","Snare","Closed hi-hat","Open hi-hat","Low tom","High tom","Crash","Ride"];
  const kitDefault=()=>[[50,78],[25,53],[16,24],[84,50],[63,43],[39,35],[38,15],[77,15]].map(([x,y])=>({x,y,size:18,visible:true}));
  function within(value, min, max) {
    return Number.isInteger(value) && value >= min && value <= max;
  }
  function loadKit() {
    try {
      const raw = window.localStorage?.getItem(kitKey);
      if (typeof raw === "string" && raw.length < 1024) {
        const saved = JSON.parse(raw);
        if (Array.isArray(saved) && saved.length === 8 && saved.every(part =>
          part && Object.keys(part).every(key => ["x","y","size","visible"].includes(key)) &&
          typeof part.visible === "boolean" && within(part.x,12,88) && within(part.y,15,85) &&
          (part.size === undefined || within(part.size,12,24)))) {
          return saved.map(part => ({...part, size: part.size ?? 18}));
        }
      }
    } catch {}
    return kitDefault();
  }
  let kit=loadKit(),kitEditing=false,kitPart=0,kitOptionsKey="",kitDrag=null;
  const kitNodes=kitNames.map((name,i)=>{
    const b=document.createElement("button");b.type="button";b.textContent=name;b.setAttribute("data-cymbal",String([2,3,6,7].includes(i)));
    get("kitBoard").appendChild(b);
    b.addEventListener("click",()=>{
      if(!has("drums",i)||!kit[i].visible)return;
      if(kitEditing&&kitIdle()){kitPart=i;syncStick();}
      else chooseStrikePad(i);
    });
    b.addEventListener("pointerdown",e=>{
      if(kitDrag||!kitEditing||!kitIdle()||!has("drums",i)||!kit[i].visible||e.button!==0)return;
      e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{return;}
      kitPart=i;kitDrag={id:e.pointerId,i};syncStick();
    });
    b.addEventListener("pointermove",e=>{
      if(!kitEditing||!kitIdle()||kitDrag?.id!==e.pointerId||kitDrag.i!==i)return;
      const r=get("kitBoard").getBoundingClientRect();
      if(![r.left,r.top,r.width,r.height,e.clientX,e.clientY].every(Number.isFinite)||r.width<=0||r.height<=0)return;
      kit[i].x=Math.round(Math.max(12,Math.min(88,100*(e.clientX-r.left)/r.width)));
      kit[i].y=Math.round(Math.max(15,Math.min(85,100*(e.clientY-r.top)/r.height)));syncStick();
    });
    for(const event of ["pointerup","pointercancel","lostpointercapture"])b.addEventListener(event,e=>{if(kitDrag?.id===e.pointerId&&kitDrag.i===i)kitDrag=null;});
    return b;
  });
  function kitIdle(){return currentView==="play"&&playMode==="stick"&&admitted&&stickState==="idle"&&!releasingAll&&!drumBusy();}
  function canChooseStrikePad(){
    return currentView==="play"&&playMode==="stick"&&admitted&&!releasingAll&&
      stickState!=="requesting"&&stickPulseAt===null&&!drumBusy();
  }
  function visibleStrikePad(index){return within(index,0,7)&&has("drums",index)&&kit[index].visible;}
  function chooseStrikePad(index){
    if(canChooseStrikePad()&&visibleStrikePad(index)&&index!==stickPad){
      stickPad=index;
      if(stickState!=="idle"){
        stickReady=false;
        get("airStickStatus").textContent="New pad selected. Hold still before the next strike.";
      }
    }
    get("airStickPad").value=stickPad<0?"":String(stickPad);
    syncKit();
  }
  function syncKit(){
    const key=String(caps?.drums??0),idle=kitIdle();
    if(key!==kitOptionsKey){
      const assigned=kitNames.map((_,i)=>i).filter(i=>has("drums",i));
      get("kitPart").replaceChildren(...assigned.map(i=>{const o=document.createElement("option");o.value=String(i);o.textContent=kitNames[i]+" · "+labelFor(9+i);return o;}));
      kitPart=assigned[0]??0;kitOptionsKey=key;
    }
    if(!idle){kitEditing=false;kitDrag=null;}
    get("kitEdit").disabled=!idle;get("kitEdit").setAttribute("aria-pressed",String(kitEditing));
    get("kitEditor").hidden=!kitEditing;get("kitPart").value=String(kitPart);
    for(const id of ["kitPart","kitX","kitY","kitSize","kitAdd","kitRemove","kitSave","kitReset"])get(id).disabled=!kitEditing||!idle;
    get("kitAdd").disabled||=kit[kitPart].visible;get("kitRemove").disabled||=!kit[kitPart].visible;
    get("kitX").value=String(kit[kitPart].x);get("kitY").value=String(kit[kitPart].y);
    get("kitSize").value=String(kit[kitPart].size);
    kitNodes.forEach((b,i)=>{
      b.hidden=!has("drums",i)||!kit[i].visible;b.disabled=!canChooseStrikePad();
      b.style.left=kit[i].x+"%";b.style.top=kit[i].y+"%";
      b.style.width="clamp(44px, "+kit[i].size+"%, "+Math.round(100*kit[i].size/18)+"px)";
      const selected=i===(kitEditing?kitPart:stickPad);
      b.setAttribute("data-selected",String(selected));b.setAttribute("aria-pressed",String(selected));
      b.setAttribute("data-hit",String(Boolean(drumDesired&(1<<i))));
      b.textContent=mappingLabels.get(9+i)||kitNames[i];b.setAttribute("aria-label",b.textContent+" · "+labelFor(9+i));
    });
  }
  function editKit(action){
    if(!kitIdle()||!kitEditing)return;
    if(action==="reset"){kit=kitDefault();}
    else if(action==="save"){try{window.localStorage.setItem(kitKey,JSON.stringify(kit));get("kitStatus").textContent="Layout saved. No assignments stored.";}catch{get("kitStatus").textContent="Storage unavailable.";}}
    else if(has("drums",kitPart)){
      if(action==="add"||action==="remove")kit[kitPart].visible=action==="add";
      else if(action==="size"){
        const size=Number(get("kitSize").value);
        if(within(size,12,24))kit[kitPart].size=size;
      }else if(action==="x"||action==="y"){
        const n=Number(get(action==="x"?"kitX":"kitY").value),lo=action==="x"?12:15,hi=action==="x"?88:85;
        if(Number.isInteger(n)&&n>=lo&&n<=hi)kit[kitPart][action]=n;
      }
    }
    syncStick();
  }
  function syncStick(){
    const select=get("airStickPad"),assigned=Array.from({length:8},(_,i)=>i).filter(visibleStrikePad),key=assigned.join(",");
    if(key!==stickKey){
      select.replaceChildren(...assigned.map(i=>{
        const o=document.createElement("option");o.value=String(i);o.textContent=labelFor(9+i);return o;
      }));
      if(!visibleStrikePad(stickPad))stickPad=assigned[0]??-1;
      select.value=stickPad<0?"":String(stickPad);stickKey=key;
    }
    get("airStickSection").hidden=playMode!=="stick";
    select.disabled=!canChooseStrikePad()||!assigned.length;
    get("airStickStart").disabled=playMode!=="stick"||!admitted||!visibleStrikePad(stickPad)||releasingAll||stickState!=="idle"||drumBusy();
    get("airStickStop").disabled=stickState==="idle";syncKit();
  }
  function resetStick(message="Off."){
    stickEpoch++;stickState="idle";stickReady=false;stickPulseAt=null;stickLast=-Infinity;
    get("airStickStatus").textContent=message;syncInertialListener();
  }
  async function startStick(){
    if(playMode!=="stick"||currentView!=="play"||!admitted||releasingAll||stickState!=="idle"||drumBusy()||!visibleStrikePad(stickPad))return;
    if(!window.isSecureContext||typeof window.DeviceMotionEvent==="undefined"){get("airStickStatus").textContent="DeviceMotion unavailable.";return;}
    if(!requestWorkload("drums"))return;
    kitEditing=false;kitDrag=null;const epoch=++stickEpoch;stickState="requesting";drumEnabled=true;syncControls();
    get("airStickStatus").textContent="Waiting for motion permission…";
    try{
      const api=window.DeviceMotionEvent;
      if(typeof api.requestPermission==="function"&&await api.requestPermission()!=="granted"){
        if(epoch===stickEpoch){resetStick("Motion permission denied.");drumEnabled=false;syncControls();}return;
      }
    }catch{if(epoch===stickEpoch){resetStick("Motion permission unavailable.");drumEnabled=false;syncControls();}return;}
    if(epoch!==stickEpoch||!admitted||stickState!=="requesting"||playMode!=="stick")return;
    stickState="waiting";stickAt=performance.now();stickReady=false;syncInertialListener();syncControls();
    get("airStickStatus").textContent="Hold still to arm.";
  }
  function stickMotion(e){
    if(stickState!=="waiting"&&stickState!=="active")return;
    const v=e.acceleration,axes=v?[v.x,v.y,v.z]:[];
    if(axes.length!==3||!axes.every(x=>Number.isFinite(x)&&Math.abs(x)<=100)){
      if(stickState==="active")close("Air stick sensor invalid. Reconnect explicitly.");return;
    }
    const now=performance.now(),magnitude=Math.hypot(...axes);
    stickAt=now;
    if(magnitude<=3){stickReady=true;stickState="active";get("airStickStatus").textContent="Ready · make a small controlled strike.";return;}
    if(stickState!=="active"||!stickReady||magnitude<8)return;
    stickReady=false;
    if(now-stickLast<150||pending||drumBusy()||releasingAll||!visibleStrikePad(stickPad))return;
    stickLast=now;stickPulseAt=now;drumDown("air-stick",stickPad);
  }
  function stopStick(){if(playMode!=="stick"||stickState==="idle")return;resetStick();drumEnabled=false;releaseDrums();}
  function syncDrums(){
    drumEnable.disabled=!admitted||!caps?.drums||!modeAllows("drums");drumEnable.textContent=drumEnabled?"Disable drum pads":"Enable drum pads";
    drumRelease.disabled=!admitted||(!drumDesired&&!drumSent&&!drumQueue.length);
    drumButtons.forEach((b,i)=>{b.hidden=playMode==="stick"||!has("drums",i);b.disabled=playMode==="stick"||!admitted||!drumEnabled||!has("drums",i)||drumEmergency;b.setAttribute("aria-pressed",String(Boolean(drumDesired&(1<<i))));});
    drumEnable.hidden=playMode==="stick";syncStick();
  }
  function resetDrums(){resetStick();drumEnabled=false;drumOwners.clear();drumQueue=[];drumDesired=0;drumSent=0;lastDrumSend=-Infinity;drumEmergency=false;drumStatus.textContent="Off.";syncDrums();}
  function drumChanged(){
    let mask=0;for(const index of drumOwners.values())mask|=1<<index;
    if(mask===drumDesired)return;
    drumDesired=mask;
    if(drumQueue.length>=8){close("Drum input backlog. Reconnect explicitly.");return;}
    drumQueue.push({mask,at:performance.now()});syncDrums();tick();
  }
  function releaseDrums(){
    if(stickState!=="idle"){resetStick();drumEnabled=false;}
    drumOwners.clear();drumDesired=0;drumQueue=[];
    drumEmergency=drumSent!==0;syncControls();tick();
  }
  function drumDown(owner,index){
    if(!admitted||!drumEnabled||!has("drums",index)||drumEmergency||drumOwners.has(owner)||(playMode==="stick")!==(owner==="air-stick"))return;
    if(drumOwners.size>=16){close("Too many drum contacts. Reconnect explicitly.");return;}
    drumOwners.set(owner,index);drumChanged();
  }
  // A cancelled contact must not replay a rising edge queued behind another ACK.
  // Delivered notes keep normal scoped release; close only on ambiguous queued attacks.
  function queuedAttack(sent,queue,bits,readMask){
    for(const edge of queue){const next=readMask(edge);if((next&~sent&bits)!==0)return true;sent=next;}
    return false;
  }
  function drumUp(owner){if(drumOwners.delete(owner))drumChanged();}
  function cancelDrum(owner){
    const index=drumOwners.get(owner);
    if(index!==undefined&&queuedAttack(drumSent,drumQueue,1<<index,e=>e.mask)){
      close("Queued drum contact cancelled. Reconnect explicitly.");return;
    }
    drumUp(owner);
  }
  function sendDrum(mask){send("drumPads",{mask});}
  const pianoButtons=Array.from({length:13},(_,i)=>get("piano"+i));
  const pianoPedal=get("pianoSustain"),pianoEnable=get("pianoEnable"),pianoRelease=get("pianoRelease"),pianoStatus=get("pianoStatus");
  const octaveDown=get("octaveDown"),octaveUp=get("octaveUp"),octaveLabel=get("octaveLabel"),pianoScale=get("pianoScale"),pianoRoot=get("pianoRoot");
  const pitchNames=["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"];
  // Visual 12-TET guide mirrors ChordScale intervals; legacy browser IDs retained.
  const scaleDegrees={"all":[0,1,2,3,4,5,6,7,8,9,10,11],"major":[0,2,4,5,7,9,11],"minor":[0,2,3,5,7,8,10],"harmonicMinor":[0,2,3,5,7,8,11],"melodicMinor":[0,2,3,5,7,9,11],"dorian":[0,2,3,5,7,9,10],"phrygian":[0,1,3,5,7,8,10],"lydian":[0,2,4,6,7,9,11],"mixolydian":[0,2,4,5,7,9,10],"locrian":[0,1,3,5,6,8,10],"pentatonic":[0,2,4,7,9],"minorPentatonic":[0,3,5,7,10],"blues":[0,3,5,6,7,10],"hicaz":[0,1,4,5,7,9,10],"nihavend":[0,2,3,5,7,8,10],"kurdi":[0,1,3,5,7,8,10],"hicazkar":[0,1,4,5,7,8,11]};
  const pianoBoard=get("pianoBoard"),pianoStrips=get("pianoStrips"),pianoStripHint=get("pianoStripHint");
  let strips=false;
  let pianoEnabled=false,pianoOctave=0,pianoOwners=new Map(),pianoQueue=[],pianoDesired=0,pianoSent=0,lastPianoSend=-Infinity,pianoEmergency=false;
  function pianoBusy(){return phraseRun!==null||pianoDesired!==0||pianoSent!==0||pianoQueue.length!==0||pianoEmergency||pendingKind==="pianoKeys";}
  const chordShapes=[[0,4,7],[2,5,9],[5,9,12],[7,11,14]];
  const phraseModes=["chord","arp","seq"];
  const chordOwners=new Map();
  let phraseMask=0,phraseRun=null,phraseOptionsKey="",synthOpen=false;
  const arpSelected=new Set(),arpContacts=new Set();
  let synthCompact=false,synthHidden=new Set();
  const dialDrags=new Map();
  const synthChoiceButtons=Array.from({length:6},(_,i)=>{const b=document.createElement("button");b.type="button";get("synthChoiceGrid").appendChild(b);b.addEventListener("click",()=>{if(!synthOpen||!admitted||releasingAll||pedalEnabled||pedalBusy()||!has("pedals",i))return;if(synthHidden.has(i))synthHidden.delete(i);else synthHidden.add(i);syncControls();});return b;});
  const synthVisible=i=>!synthOpen||!synthHidden.has(i);
  function choosePianoTool(id){if(currentView!=="play"||!admitted||releasingAll||!modeAvailable(id))return;get("playMode").value=id;choosePlayMode();}
  function toggleSynth(){if(currentView!=="play"||!admitted||releasingAll||!["piano","arp","chord","seq"].includes(playMode)||!caps?.pedals)return;dialDrags.clear();if(synthOpen){synthOpen=false;pedalEnabled=false;releasePedals();}else{synthOpen=true;syncControls();}}
  const specialPiano=()=>phraseModes.includes(playMode);
  const chordAvailable=i=>chordShapes[i]?.every(k=>has("piano",k));
  const chordMask=i=>chordShapes[i].reduce((m,k)=>m|(1<<k),0);
  const chordLabel=i=>chordShapes[i].map(k=>labelFor(17+k)).join(" + ");
  function syncPhrase(){
    const special=specialPiano(),playing=phraseRun!==null,key=String(caps?.piano??0);
    if(key!==phraseOptionsKey){
      const options=[-1,...Array.from({length:25},(_,i)=>i).filter(i=>has("piano",i))];
      for(let i=0;i<8;i++){
        const el=get("phraseStep"+i);
        el.replaceChildren(...options.map(k=>{const o=document.createElement("option");o.value=String(k);o.textContent=k<0?"Rest":labelFor(17+k);return o;}));
        el.value="-1";
      }
      const available=chordShapes.map((_,i)=>i).filter(chordAvailable);
      get("arpChoice").replaceChildren(...available.map(i=>{const o=document.createElement("option");o.value=String(i);o.textContent=chordLabel(i);return o;}));
      get("arpChoice").value=available.length?String(available[0]):"";
      phraseOptionsKey=key;
    }
    get("phraseSection").hidden=!special;
    get("pianoBoard").hidden=(special&&playMode!=="arp")||!Boolean(caps?.piano&33554431);
    get("pianoArp").disabled=!admitted||!modeAvailable("arp")||releasingAll;get("pianoArp").setAttribute("aria-pressed",String(playMode==="arp"));
    get("pianoChord").disabled=!admitted||!modeAvailable("chord")||releasingAll;get("pianoChord").setAttribute("aria-pressed",String(playMode==="chord"));
    get("pianoSynth").hidden=!["piano","arp","chord","seq"].includes(playMode)||!caps?.pedals;get("pianoSynth").disabled=!admitted||releasingAll;
    get("pianoSynth").setAttribute("aria-pressed",String(synthOpen));get("pianoSynth").textContent=synthOpen?"Hide synth controls":"Show synth controls";
    get("synthCompact").hidden=!synthOpen;get("synthCompact").setAttribute("aria-pressed",String(synthCompact));get("synthChoices").hidden=!synthOpen;
    synthChoiceButtons.forEach((b,i)=>{b.hidden=!has("pedals",i);b.disabled=!synthOpen||pedalEnabled||pedalBusy()||releasingAll;b.textContent=labelFor(43+i)+(synthVisible(i)?" · shown":" · hidden");b.setAttribute("aria-pressed",String(synthVisible(i)));});
    get("pianoManualHint").hidden=special;
    get("pianoStrips").hidden=special;
    for(const id of ["octaveDown","octaveUp","octaveLabel","pianoScale","pianoRoot","pianoSustain"])if(special&&playMode!=="arp")get(id).hidden=true;
    else if(id!=="pianoSustain")get(id).hidden=false;
    get("phraseTitle").textContent=playMode==="chord"?"Chord pads":playMode==="arp"?"Arpeggiator":"8-step sequencer";
    get("chordGrid").hidden=playMode!=="chord";
    get("phraseTransport").hidden=playMode==="chord";
    get("arpChoice").hidden=get("arpLabel").hidden=playMode!=="arp";
    get("sequenceSteps").hidden=playMode!=="seq";
    get("arpKeyboardTools").hidden=playMode!=="arp";get("arpClear").disabled=playing;get("arpDirection").disabled=playing;get("arpRate").disabled=playing;get("arpSwing").disabled=playing;
    get("arpSelected").textContent=arpSelected.size?"Selected keys: "+[...arpSelected].sort((a,b)=>a-b).map(k=>labelFor(17+k)).join(", "):"Tap keys to select a custom arpeggio, or use the chord menu.";
    for(let i=0;i<4;i++){
      const b=get("chord"+i);b.textContent=chordLabel(i);b.disabled=playMode!=="chord"||!pianoEnabled||!admitted||releasingAll||!chordAvailable(i);
      b.setAttribute("aria-pressed",String([...chordOwners.values()].includes(i)));
    }
    for(const id of ["phraseTempo","arpChoice",...Array.from({length:8},(_,i)=>"phraseStep"+i)])get(id).disabled=playing;
    const phraseMode=["arp","seq"].includes(playMode),candidate=phraseMode?phraseCandidate():null;
    get("phraseStart").disabled=!pianoEnabled||!admitted||releasingAll||pianoBusy()||!candidate?.pattern;
    get("phraseStart").setAttribute("aria-describedby","phraseStatus");
    if(phraseMode&&!playing)textIfChanged("phraseStatus",!pianoEnabled?"Enable this instrument before starting.":releasingAll||pianoBusy()?"Release controls and wait for Mac acknowledgment.":candidate?.reason||"Ready. Start to play the selected pattern.");
    get("phraseStop").disabled=!playing;
  }
  function resetPhrase(message="Off."){phraseRun=null;phraseMask=0;chordOwners.clear();arpContacts.clear();get("phraseStatus").textContent=message;}
  function chordDown(owner,i){
    if(currentView!=="play"||playMode!=="chord"||!admitted||!pianoEnabled||releasingAll||pianoEmergency||!chordAvailable(i)||chordOwners.has(owner))return;
    if(chordOwners.size>=16){close("Too many chord contacts.");return;}
    chordOwners.set(owner,i);pianoChanged();
  }
  function chordUp(owner){if(chordOwners.delete(owner))pianoChanged();}
  function cancelChord(owner){
    const i=chordOwners.get(owner);
    if(i!==undefined&&queuedAttack(pianoSent,pianoQueue,chordMask(i),e=>e.mask)){
      close("Queued chord contact cancelled. Reconnect explicitly.");return;
    }
    chordUp(owner);
  }
  function phraseCandidate(){
    const bpm=Number(get("phraseTempo").value);
    if(![60,90,120,150].includes(bpm))return {reason:"Choose a supported tempo."};
    const selection=get("arpChoice").value,index=Number(selection);
    let pattern=playMode==="arp"?(arpSelected.size?[...arpSelected].sort((a,b)=>a-b):selection!==""&&chordAvailable(index)?[...chordShapes[index]]:[]):
      Array.from({length:8},(_,i)=>{const v=get("phraseStep"+i).value;return v===""?NaN:Number(v);});
    const direction=get("arpDirection").value,rate=get("arpRate").value||"8";
    if(playMode==="arp"){
      if(!["","up","down","bounce"].includes(direction)||!["4","8","12","16"].includes(rate))return {reason:"Choose a supported arpeggio direction and rate."};
      if(direction==="down")pattern.reverse();if(direction==="bounce"&&pattern.length>2)pattern=pattern.concat(pattern.slice(1,-1).reverse());
    }
    if(!pattern.length||!pattern.some(i=>i>=0))return {reason:playMode==="seq"?"Choose at least one mapped note; an all-rest pattern cannot start.":"Choose mapped notes or an available chord."};
    if(!pattern.every(i=>Number.isInteger(i)&&(i===-1||(i>=0&&i<25&&has("piano",i)))))return {reason:"The pattern contains an unavailable note."};
    const swing=playMode==="arp"?Number(get("arpSwing").value||"50"):50;
    if(![50,55,60].includes(swing))return {reason:"Choose a supported swing value."};
    return {pattern,swing,period:240000/(bpm*(playMode==="arp"?Number(rate):8))};
  }
  function startPhrase(){
    if(currentView!=="play"||!["arp","seq"].includes(playMode)||!pianoEnabled||!admitted||releasingAll||pianoBusy())return;
    const candidate=phraseCandidate();
    if(!candidate.pattern){syncPhrase();return;}
    phraseRun={...candidate,index:0,on:false,longStep:true,next:performance.now()};
    get("phraseStatus").textContent="Playing · local browser clock.";syncControls();tick();
  }
  function advancePhrase(now){
    const run=phraseRun;if(!run||now<run.next)return true;
    if(now-run.next>=150){close("Sequencer delayed. Reconnect explicitly.");return false;}
    if(pending||pianoQueue.length||pianoEmergency)return true;
    if(!pianoEnabled||releasingAll||!admitted||!["arp","seq"].includes(playMode)){releasePiano();return false;}
    // Alternate by elapsed steps, including across an odd-length pattern wrap.
    const halfStep=run.period*(run.longStep?run.swing:100-run.swing)/100;
    const scheduled=run.next+halfStep;
    // Absorb timer jitter without bunching edges after a delayed acknowledgment.
    run.next=scheduled-now>=25?scheduled:now+halfStep;
    if(!run.on){
      const i=run.pattern[run.index];phraseMask=i<0?0:1<<i;
      run.on=true;
    }else{
      phraseMask=0;run.on=false;run.index=(run.index+1)%run.pattern.length;run.longStep=!run.longStep;
    }
    pianoChanged(false);return Boolean(admitted);
  }
  function syncPiano(){
    pianoEnable.disabled=!admitted||!caps?.piano||!modeAllows("piano");pianoEnable.textContent=(pianoEnabled?"Disable ":"Enable ")+({chord:"chord pads",arp:"arpeggiator",seq:"sequencer"}[playMode]||"piano");
    pianoRelease.disabled=!admitted||!pianoBusy();
    octaveDown.disabled=!admitted||!pianoEnabled||pianoOctave===0||!octaveAvailable(0)||pianoBusy();
    octaveUp.disabled=!admitted||!pianoEnabled||pianoOctave===1||!octaveAvailable(1)||pianoBusy();
    octaveLabel.textContent=verifiedScale()?"C"+(3+pianoOctave)+"–C"+(4+pianoOctave):"Keys "+(1+12*pianoOctave)+"–"+(13+12*pianoOctave);
    const scaleAllowed=verifiedScale();pianoScale.disabled=!scaleAllowed;pianoRoot.disabled=!scaleAllowed;
    textIfChanged("scaleGuideStatus",scaleAllowed?"Visual guide only. Does not change MIDI, tuning or makam performance.":"Scale guide unavailable: the Mac has not shared a verified standard note mapping.");
    pianoStrips.disabled=!admitted||!Boolean(caps?.piano&33554431)||pianoBusy()||releasingAll;
    pianoStrips.setAttribute("aria-pressed",String(strips));
    pianoStrips.textContent=strips?"Piano layout":"Note strips";
    pianoStripHint.hidden=!strips;
    pianoBoard.setAttribute("data-strips",String(strips));
    pianoBoard.setAttribute("aria-label",strips?"Assigned note strips":"Piano keyboard");
    const root=Number(pianoRoot.value);
    const guideValid=Object.hasOwn(scaleDegrees,pianoScale.value)&&pianoScale.value!=="all"&&
      Number.isInteger(root)&&root>=0&&root<12&&pianoRoot.value===String(root);
    const scale=guideValid?scaleDegrees[pianoScale.value]:[];
    pianoButtons.forEach((b,i)=>{
      const index=i+12*pianoOctave,note=pitchNames[index%12]+(3+Math.floor(index/12));
      b.disabled=!admitted||!pianoEnabled||!has("piano",index)||pianoEmergency;
      const rows=targets(17+index);
      const singleNote=rows.length===1&&rows[0][1]===0?rows[0][3]:null;
      const actual=singleNote===null?null:pitchNames[singleNote%12]+(Math.floor(singleNote/12)-1);
      const label=groupNeutralHandshake&&mappingLabels.has(17+index)?mappingLabels.get(17+index):strips?(mappingLabels.get(17+index)||actual||"K"+(index+1)):(scaleAllowed?note:"K"+(index+1));
      b.hidden=strips&&!has("piano",index);
      b.style.order=String(i);
      b.textContent=label;b.setAttribute("aria-label",(mappingLabels.has(17+index)?labelFor(17+index)+" · ":"")+label+(rows.length?" · "+rows.map(targetText).join("; "):" · mapping details hidden"));
      b.setAttribute("aria-pressed",String(Boolean(pianoDesired&(1<<index))));
      b.setAttribute("data-arp-selected",String(playMode==="arp"&&arpSelected.has(index)));if(playMode==="arp"&&phraseRun)b.disabled=true;
      b.setAttribute("data-scale",String(scaleAllowed&&has("piano",index)&&guideValid&&scale.includes((index-root+12)%12)));
    });
    get("pianoBoard").hidden=!Boolean(caps?.piano&33554431);
    pianoPedal.hidden=!has("piano",25);pianoPedal.disabled=!admitted||!pianoEnabled||!has("piano",25)||pianoEmergency;
    pianoPedal.setAttribute("aria-pressed",String(Boolean(pianoDesired&(1<<25))));syncPhrase();
  }
  function resetPiano(){resetPhrase();arpSelected.clear();synthOpen=false;dialDrags.clear();synthHidden.clear();strips=false;pianoEnabled=false;pianoOctave=0;pianoOwners.clear();pianoVisited.clear();pianoQueue=[];pianoDesired=0;pianoSent=0;lastPianoSend=-Infinity;pianoEmergency=false;pianoStatus.textContent="Off.";syncPiano();}
  function pianoChanged(runTick=true){
    let mask=phraseMask;for(const index of pianoOwners.values())mask|=1<<index;
    for(const index of chordOwners.values())mask|=chordMask(index);
    if(mask===pianoDesired)return;
    pianoDesired=mask;
    if(pianoQueue.length>=8){close("Piano input backlog. Reconnect explicitly.");return;}
    pianoQueue.push({mask,at:performance.now()});syncPiano();if(runTick)tick();
  }
  function releasePiano(){
    resetPhrase();pianoOwners.clear();pianoVisited.clear();pianoDesired=0;pianoQueue=[];
    pianoEmergency=pianoSent!==0;syncControls();tick();
  }
  function pianoDown(owner,index){
    if(!admitted||!pianoEnabled||!has("piano",index)||pianoEmergency||releasingAll||pianoOwners.has(owner))return;
    if(playMode==="arp"&&index!==25){if(phraseRun||arpContacts.has(owner)||arpContacts.size>=32)return;arpContacts.add(owner);if(arpSelected.has(index))arpSelected.delete(index);else arpSelected.add(index);syncPiano();return;}
    if(specialPiano()&&!(playMode==="arp"&&index===25))return;
    if(pianoOwners.size>=32){close("Too many piano contacts. Reconnect explicitly.");return;}
    pianoOwners.set(owner,index);
    if(owner.startsWith("p"))pianoVisited.set(owner,1<<index);
    pianoChanged();
  }
  const pianoVisited=new Map();
  function pianoUp(owner){arpContacts.delete(owner);pianoVisited.delete(owner);if(pianoOwners.delete(owner))pianoChanged();}
  function cancelPiano(owner){
    const index=pianoOwners.get(owner);
    if(index!==undefined&&(strips&&owner.startsWith("p")||queuedAttack(pianoSent,pianoQueue,pianoVisited.get(owner)??(1<<index),e=>e.mask))){
      close("Note contact cancelled. Reconnect explicitly.");return;
    }
    pianoUp(owner);
  }
  function moveStrip(e){
    const owner="p"+e.pointerId;
    if(!admitted||!pianoEnabled||pianoEmergency||releasingAll||!pianoOwners.has(owner)||pianoOwners.get(owner)===25)return;
    e.preventDefault();
    const r=pianoBoard.getBoundingClientRect();
    if(![r.left,r.top,r.width,r.height,e.clientX,e.clientY].every(Number.isFinite)||r.width<=0||r.height<=0){
      close("Invalid note surface geometry. Reconnect explicitly.");return;
    }
    if(e.clientX<r.left||e.clientX>r.left+r.width||e.clientY<r.top||e.clientY>r.top+r.height){
      // Leaving the board is not a completed tap if a visited attack is queued.
      if(strips){
        const visited=pianoVisited.get(owner)??(1<<pianoOwners.get(owner));
        if(queuedAttack(pianoSent,pianoQueue,visited,edge=>edge.mask)){
          close("Note strip left with queued attack. Reconnect explicitly.");return;
        }
        pianoUp(owner);
      }else cancelPiano(owner);
      return;
    }
    if(!strips){
      // Hit actual rendered geometry because pointer capture keeps events on the
      // original key. Black keys take precedence, including unmapped black keys.
      const order=[1,3,6,8,10,0,2,4,5,7,9,11,12];
      let hit=null;
      for(const i of order){
        const b=pianoButtons[i],k=b.getBoundingClientRect();
        if(![k.left,k.top,k.width,k.height].every(Number.isFinite)||k.width<=0||k.height<=0){
          close("Invalid piano key geometry. Reconnect explicitly.");return;
        }
        if(e.clientX>=k.left&&e.clientX<k.left+k.width&&e.clientY>=k.top&&e.clientY<k.top+k.height){hit=i;break;}
      }
      if(hit===null||!has("piano",hit+12*pianoOctave)){cancelPiano(owner);return;}
      slideTo(owner,hit+12*pianoOctave);return;
    }
    // Compact only the host-authorized notes. DOM order and geometry agree.
    const zones=Array.from({length:13},(_,i)=>i+12*pianoOctave).filter(i=>has("piano",i));
    if(!zones.length){pianoUp(owner);return;}
    const gap=3, width=(r.width-gap*(zones.length-1))/zones.length;
    if(width<=0){close("Note surface too narrow. Reconnect explicitly.");return;}
    const slot=Math.min(zones.length-1,Math.floor((e.clientX-r.left)/(width+gap)));
    const index=zones[slot];
    slideTo(owner,index);
  }
  function slideTo(owner,index){
    if(index===pianoOwners.get(owner))return;
    pianoVisited.set(owner,(pianoVisited.get(owner)??0)|(1<<index));
    pianoOwners.set(owner,index);pianoChanged();
  }
  function sendPiano(mask){send("pianoKeys",{mask});}
  function changeOctave(value){if(!admitted||!pianoEnabled||!octaveAvailable(value)||pianoBusy())return;pianoOctave=value;syncPiano();}
  const pedalEnable=get("pedalEnable"),pedalRelease=get("pedalRelease"),pedalStatus=get("pedalStatus");
  const pedalToggles=Array.from({length:6},(_,i)=>get("pedalToggle"+i));
  const pedalSliders=Array.from({length:3},(_,i)=>get("pedalLevel"+i));
  const pedalOutputs=Array.from({length:3},(_,i)=>get("pedalValue"+i));
  const pedalHoldOwners=new Map();
  const isHoldPedal=i=>details.holds.includes(i);
  let pedalEnabled=false,pedalMask=0,pedalSentMask=0,pedalPositions=[...details.sliderDefaults],pedalQueue=[],pedalDirty=false,lastPedalSend=-Infinity,pedalEmergency=false;
  function pedalBusy(){return pedalMask!==0||pedalSentMask!==0||pedalQueue.length!==0||pedalEmergency||pendingKind==="pedalboard";}
  function syncPedals(){
    get("pedalSection").setAttribute("data-synth",String(synthOpen));get("pedalSection").setAttribute("data-compact",String(synthCompact));
    pedalEnable.disabled=!admitted||!caps?.pedals||!modeAllows("pedals");pedalEnable.textContent=pedalEnabled?"Disable pedalboard":"Enable pedalboard";
    pedalRelease.disabled=!admitted||!pedalBusy();
    pedalToggles.forEach((b,i)=>{
      const active=Boolean(pedalMask&(1<<i));
      get("pedalCell"+i).hidden=!has("pedals",i)||!synthVisible(i);
      b.disabled=!admitted||!pedalEnabled||!has("pedals",i)||pedalEmergency;
      const hold=isHoldPedal(i);
      const alias=localAlias("p"+i);
      b.textContent=(alias?alias+" · ":groupNeutralHandshake&&mappingLabels.has(43+i)?mappingLabels.get(43+i)+" · ":"")+(hold?(active?"Held":"Hold to activate"):i<3?(active?"Release":"Activate"):(active?"On":"Off"));
      const action=hold?(active?"Held":"Hold to activate"):i<3?(active?"Release":"Activate"):(active?"On":"Off");
      b.setAttribute("aria-label",(alias||labelFor(43+i))+" · "+action);
      b.setAttribute("data-hold",String(hold));
      b.setAttribute("aria-pressed",String(active));
    });
    pedalSliders.forEach((b,i)=>{
      b.disabled=!admitted||!pedalEnabled||!has("pedals",i)||pedalEmergency||!(pedalMask&(1<<i));
      b.value=String(pedalPositions[i]);pedalOutputs[i].textContent=pedalPositions[i]+"%";
      pedalOutputs[i].setAttribute("data-dial","true");pedalOutputs[i].style.setProperty?.("--dial-angle",(pedalPositions[i]*2.7-135)+"deg");
    });
  }
  function pedalSnapshot(){
    return {mask:pedalMask,levels:Array.from({length:6},(_,i)=>(pedalMask&(1<<i))?(i<3?pedalPositions[i]/100:1):0)};
  }
  function resetPedals(){
    pedalEnabled=false;pedalHoldOwners.clear();pedalMask=0;pedalSentMask=0;pedalPositions=[...details.sliderDefaults];pedalQueue=[];pedalDirty=false;lastPedalSend=-Infinity;pedalEmergency=false;
    pedalStatus.textContent="Off.";syncPedals();
  }
  function pedalAdmitted(i){
    return currentView==="play"&&!releasingAll&&admitted&&pedalEnabled&&!cameraHelper&&modeAllows("pedals")&&has("pedals",i)&&synthVisible(i)&&!pedalEmergency;
  }
  function pedalSet(i,active){
    const next=active?pedalMask|(1<<i):pedalMask&~(1<<i);
    if(next===pedalMask)return;
    if(!active)dialDrags.delete(i);
    pedalMask=next;
    if(pedalQueue.length>=8){close("Pedal input backlog. Reconnect explicitly.");return;}
    pedalQueue.push({snapshot:pedalSnapshot(),at:performance.now()});pedalDirty=false;syncPedals();tick();
  }
  function pedalToggle(i){
    if(!pedalAdmitted(i)||isHoldPedal(i))return;
    pedalSet(i,!(pedalMask&(1<<i)));
  }
  function pedalHoldDown(i,owner){
    if(!pedalAdmitted(i)||!isHoldPedal(i)||pedalHoldOwners.has(owner))return;
    if(pedalHoldOwners.size>=16){close("Too many pedal contacts. Reconnect explicitly.");return;}
    pedalHoldOwners.set(owner,i);pedalSet(i,true);
  }
  function pedalHoldUp(i,owner){
    if(pedalHoldOwners.get(owner)!==i)return;
    pedalHoldOwners.delete(owner);
    if(![...pedalHoldOwners.values()].includes(i))pedalSet(i,false);
  }
  function cancelHeldPedal(i,owner){
    if(pedalHoldOwners.get(owner)===i&&queuedAttack(pedalSentMask,pedalQueue,1<<i,edge=>edge.snapshot.mask)){
      close("Queued pedal contact cancelled. Reconnect explicitly.");return;
    }
    pedalHoldUp(i,owner);
  }
  function pedalMove(i){
    if(!pedalAdmitted(i)||!(pedalMask&(1<<i)))return;
    const n=Number(pedalSliders[i].value);
    if(!Number.isFinite(n)||n<0||n>100){close("Invalid pedal level.");return;}
    pedalPositions[i]=Math.round(n);pedalDirty=true;syncPedals();tick();
  }
  function releasePedals(){
    dialDrags.clear();pedalHoldOwners.clear();pedalMask=0;pedalQueue=[];pedalDirty=false;pedalEmergency=pedalSentMask!==0;syncControls();tick();
  }
  function sendPedals(snapshot){send("pedalboard",snapshot);}
  function inertialState(kind,prefix,limit,scale){return {kind,start:get(prefix+"Start"),stop:get(prefix+"Stop"),meter:get(prefix+"Meter"),status:get(prefix+"Status"),limit,scale,mode:"idle",epoch:0,sample:null,at:0,sent:-1,last:-Infinity,waiting:0};}
  const streams=[inertialState("acceleration","accel",100,20),inertialState("rotation","rotation",2000,360)];
  const capturing=s=>["waiting","arming","active"].includes(s.mode);
  function syncInertialListener(){
    window.removeEventListener("devicemotion",deviceMotion);
    if(streams.some(capturing)||stickState==="waiting"||stickState==="active")window.addEventListener("devicemotion",deviceMotion);
  }
  function resetInertial(s,message){
    s.epoch++;s.mode="idle";s.sample=null;s.at=0;s.sent=-1;s.last=-Infinity;s.meter.value=0;s.status.textContent=message;
    syncInertialListener();syncControls();
  }
  function deviceMotion(e){
    stickMotion(e);
    if(!admitted)return;
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
    syncCamera();
    if(xyClutchPending&&!touchBusy())xyClutchPending=false;
    const xyAvailable=currentView==="play"&&admitted&&caps?.touch&&workloadAllows("touch")&&!xyClutchPending;
    get("xyClutch").disabled=!admitted||currentView!=="play"||!caps?.touch||!modeAllows("touch")||releasingAll||xyClutchPending||!touchBusy();
    textIfChanged("xyInputStatus",xyClutchPending?"Waiting for XY release acknowledgment.":pointer!==null?"XY source contact active.":touchBusy()?"XY edges awaiting acknowledgment.":"XY idle. A new contact starts a new source gesture.");
    pad.setAttribute("aria-disabled",String(!xyAvailable));pad.setAttribute("tabindex",xyAvailable?"0":"-1");
    pad.setAttribute("aria-pressed",String(pointer!==null));syncSections();syncDrums();syncPiano();syncPedals();syncCustom();syncWorkload();syncNavigation();syncPlayMode();syncLatency();syncLayout();
    releaseAll.disabled=!admitted||!caps||releasingAll;
    const asking=releasingAll||mode==="requesting"||streams.some(s=>s.mode==="requesting");
    if(releasingAll){drumEnable.disabled=true;pianoEnable.disabled=true;pedalEnable.disabled=true;}
    motionStart.disabled=!admitted||!caps?.tilt||!modeAllows("tilt")||mode!=="idle"||asking;
    for(const s of streams){s.start.disabled=!admitted||!caps?.[s.kind]||!modeAllows(s.kind)||s.mode!=="idle"||asking;s.stop.disabled=!admitted||s.mode==="idle"||s.mode==="releasing";}
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
    cameraReleaseAt=null;stopCamera("Camera off.");
    const old=ws;ws=null;admitted=false;caps=null;groupReady=null;currentView="connection";ackSamples=[];playMode="all";pendingPlayMode=null;releasingAll=false;cancelGlobalTimer();clearMapping();renderMapping();experimentalWorkload=false;workloadRefusal="";pending=false;sequence=0;pointer=null;position=null;touchQueue=[];touchSent=false;xyClutchPending=false;
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
    if(cameraReleaseAt!==null){if(now-cameraReleaseAt>=150){close("Camera helper release overdue. Reconnect explicitly.");return;}if(!pedalBusy()&&pedalMask===0)cameraReleaseAt=null;}
    if(cameraHelper&&cameraStream&&!cameraPending&&((cameraAt!==null&&now-cameraAt>=150)||(cameraAt===null&&now-cameraStartedAt>=3000))){close("Camera frames stopped. Reconnect explicitly.");return;}
    if(stickState==="waiting"&&now-stickAt>=3000){resetStick("No valid motion data.");drumEnabled=false;syncControls();}
    if(stickState==="active"&&now-stickAt>=250){close("Air stick motion stopped. Reconnect explicitly.");return;}
    if(stickPulseAt!==null&&now-stickPulseAt>=80){
      if(now-stickPulseAt>=150){close("Air stick pulse delayed. Reconnect explicitly.");return;}
      stickPulseAt=null;drumOwners.delete("air-stick");drumDesired=0;drumQueue=[];drumEmergency=drumSent!==0;syncControls();
    }
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
    if(!advancePhrase(now))return;
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
    else if(!pedalQueue.length&&pedalMask!==0&&now-lastPedalSend>=50&&(!cameraHelper||cameraQuiet===0))ready.push({last:lastPedalSend,run:()=>{pedalDirty=false;sendPedals(pedalSnapshot());}});
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
    stopCamera("Camera off · pairing.");
    const value=secret.value.trim();secret.value="";
    if(!/^[0-9a-fA-F]{64}$/.test(value)){status.textContent="Enter a valid invitation.";return;}
    const key=new Uint8Array(32);for(let i=0;i<32;i++)key[i]=parseInt(value.slice(i*2,i*2+2),16);
    if(location.origin!=="__REMOTE_ORIGIN__"){key.fill(0);close("Wrong origin. Open the local HTTPS page from the Mac app.");return;}
    let socket;
    try{socket=new WebSocket("__REMOTE_SOCKET__","tihulu-touch-v1");}catch{key.fill(0);close("Connection unavailable.");return;}
    ws=socket;syncCamera();connect.disabled=true;disconnect.disabled=false;status.textContent="Connecting…";wait(5000);
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
      if(groupReady){
        if(!pending||e.data!=="accepted"){close("Group neutral handshake rejected.");return;}
        const armed=groupReady;
        clearDeadline();pending=false;pendingKind=null;
        if(armed.queue.length){send(...armed.queue.shift());return;}
        groupReady=null;
        finishReady(armed.manifest,armed.rows,armed.labels);return;
      }
      if(!pending||!caps||e.data!=="accepted"){close("Unexpected response.");return;}
      if(cameraReleaseAt!==null&&performance.now()-cameraReleaseAt>=150){close("Camera helper release ACK overdue. Reconnect explicitly.");return;}
      if(cameraHelper&&cameraAt!==null&&performance.now()-cameraAt>=150){close("Camera frames stopped. Reconnect explicitly.");return;}
      recordAck();clearDeadline();pending=false;const kind=pendingKind;pendingKind=null;
      if(kind==="pedalboard"&&cameraReleaseAt!==null&&pedalSentMask===0&&pedalMask===0&&!pedalEmergency&&!pedalQueue.length)cameraReleaseAt=null;
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
    setXY(clamp((e.clientX-rect.left)/rect.width),1-clamp((e.clientY-rect.top)/rect.height));return true;
  }
  function setXY(x,y){
    position={x,y};dot.hidden=false;dot.style.left=(x*100)+"%";dot.style.top=((1-y)*100)+"%";
  }
  pad.addEventListener("pointerdown",e=>{
    if(currentView!=="play"||releasingAll||xyClutchPending||!admitted||!caps?.touch||pointer!==null||e.button!==0)return;
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
  // Explicit scoped release cancels unsent onsets. A sent contact still needs
  // the existing host release ACK. This is not a hold-last/recenter command.
  function releaseXY(){
    if(!admitted||currentView!=="play"||!caps?.touch||!modeAllows("touch")||releasingAll||xyClutchPending||!touchBusy())return;
    // A clutch press must not renew the age of an already queued release.
    const releaseAt=touchQueue.find(edge=>edge.kind==="release")?.at??performance.now();
    xyClutchPending=true;pointer=null;position=null;dot.hidden=true;
    touchQueue=touchSent?[{kind:"release",at:releaseAt}]:[];
    syncControls();tick();
  }
  get("xyClutch").addEventListener("click",releaseXY);
  const xyKeyOwner=key=>"keyboard:"+key;
  const isXYKeyOwner=()=>typeof pointer==="string"&&pointer.startsWith("keyboard:");
  pad.addEventListener("keydown",e=>{
    if(e.key==="Escape"&&isXYKeyOwner()){e.preventDefault();releaseXY();return;}
    if(e.key===" "||e.key==="Enter"){
      if(currentView!=="play"||releasingAll||xyClutchPending||!admitted||!caps?.touch||!workloadAllows("touch"))return;
      e.preventDefault();
      if(e.repeat||pointer!==null||!requestWorkload("touch"))return;
      pointer=xyKeyOwner(e.key);setXY(.5,.5);syncControls();queueTouch("touch",{...position});return;
    }
    const directions={ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowDown:[0,-1],ArrowUp:[0,1]};
    if(!Object.hasOwn(directions,e.key)||!isXYKeyOwner()||!position)return;
    e.preventDefault();const [dx,dy]=directions[e.key],clamp=v=>Math.max(0,Math.min(1,Math.round(v*20)/20));
    setXY(clamp(position.x+dx*.05),clamp(position.y+dy*.05));
  });
  pad.addEventListener("keyup",e=>{
    if(pointer!==xyKeyOwner(e.key))return;
    e.preventDefault();lift({pointerId:pointer});
  });
  pad.addEventListener("blur",e=>{
    if(!isXYKeyOwner())return;
    if(e.relatedTarget===get("xyClutch")){releaseXY();return;}
    close("Keyboard touch cancelled. Reconnect explicitly.");
  });
  // Cancellation is not a completed musical tap: discard unsent edges and
  // let host disconnect/watchdog release already delivered owners.
  for(const event of ["pointercancel","lostpointercapture"])pad.addEventListener(event,e=>{if(e.pointerId===pointer)close("Touch cancelled. Reconnect explicitly.");});
  function toggleDrums(){
    if(currentView!=="play"||releasingAll||!admitted||!caps?.drums||playMode==="stick")return;
    if(!drumEnabled&&!requestWorkload("drums"))return;
    drumEnabled=!drumEnabled;
    if(!drumEnabled)releaseDrums();
    workloadRefusal="";syncControls();
    drumStatus.textContent=drumEnabled?"Enabled. Use only with the mapped Mac preset.":"Off.";
    syncDrums();
  }
  drumEnable.addEventListener("click",toggleDrums);
  get("customDrumEnable").addEventListener("click",()=>{if(customActive.some(id=>id[0]==="d"))toggleDrums();});
  drumRelease.addEventListener("click",releaseDrums);
  get("customDrumRelease").addEventListener("click",()=>{
    if(currentView==="play"&&admitted&&!releasingAll&&drumEnabled&&customActive.some(id=>id[0]==="d"))releaseDrums();
  });
  drumButtons.forEach((b,index)=>{
    b.addEventListener("pointerdown",e=>{
      if(!admitted||!drumEnabled||!has("drums",index)||e.button!==0)return;
      e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{close("Drum pointer capture failed.");return;}
      drumDown("p"+e.pointerId,index);
    });
    b.addEventListener("pointerup",e=>drumUp("p"+e.pointerId));
    for(const name of ["pointercancel","lostpointercapture"])b.addEventListener(name,e=>cancelDrum("p"+e.pointerId));
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)drumDown("k"+index,index);}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();drumUp("k"+index);}});
    b.addEventListener("blur",()=>cancelDrum("k"+index));
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
  get("pianoArp").addEventListener("click",()=>choosePianoTool(playMode==="arp"?"piano":"arp"));
  get("pianoChord").addEventListener("click",()=>choosePianoTool(playMode==="chord"?"piano":"chord"));
  get("pianoSynth").addEventListener("click",toggleSynth);
  get("synthCompact").addEventListener("click",()=>{if(synthOpen&&admitted&&!releasingAll){synthCompact=!synthCompact;syncControls();}});
  get("arpClear").addEventListener("click",()=>{if(playMode==="arp"&&!phraseRun&&!releasingAll){arpSelected.clear();syncPiano();}});
  for(const id of ["phraseTempo","arpChoice","arpDirection","arpRate","arpSwing",...Array.from({length:8},(_,i)=>"phraseStep"+i)])get(id).addEventListener("change",syncPhrase);
  get("phraseStart").addEventListener("click",startPhrase);
  get("phraseStop").addEventListener("click",releasePiano);
  for(let i=0;i<4;i++){
    const b=get("chord"+i);
    b.addEventListener("pointerdown",e=>{if(e.button!==0||b.disabled)return;e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{close("Chord pointer capture failed.");return;}chordDown("c"+i+":"+e.pointerId,i);});
    b.addEventListener("pointerup",e=>chordUp("c"+i+":"+e.pointerId));
    for(const event of ["pointercancel","lostpointercapture"])b.addEventListener(event,e=>cancelChord("c"+i+":"+e.pointerId));
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)chordDown("k"+i,i);}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();chordUp("k"+i);}});
    b.addEventListener("blur",()=>cancelChord("k"+i));
  }
  pianoStrips.addEventListener("click",()=>{
    if(currentView!=="play"||!admitted||releasingAll||pianoBusy()||!Boolean(caps?.piano&33554431))return;
    strips=!strips;syncPiano();
  });
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
    if(i!==13)b.addEventListener("pointermove",moveStrip);
    b.addEventListener("pointerup",e=>pianoUp("p"+e.pointerId));
    for(const name of ["pointercancel","lostpointercapture"])b.addEventListener(name,e=>cancelPiano("p"+e.pointerId));
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)pianoDown("k"+i,index());}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();pianoUp("k"+i);}});
    b.addEventListener("blur",()=>cancelPiano("k"+i));
  });
  function togglePedals(){
    if(currentView!=="play"||releasingAll||!admitted||!caps?.pedals||cameraHelper||!modeAllows("pedals"))return;
    if(!pedalEnabled&&!requestWorkload("pedals"))return;
    pedalEnabled=!pedalEnabled;
    if(!pedalEnabled)releasePedals();
    workloadRefusal="";syncControls();
    pedalStatus.textContent=pedalEnabled?"Enabled. Activate individual mapped pedals.":"Off.";syncPedals();
  }
  pedalEnable.addEventListener("click",togglePedals);
  get("customPedalEnable").addEventListener("click",()=>{if(customActive.some(id=>id[0]==="p"))togglePedals();});
  pedalRelease.addEventListener("click",()=>{if(!cameraHelper&&modeAllows("pedals"))releasePedals();});
  get("customPedalRelease").addEventListener("click",()=>{
    if(cameraHelper||!modeAllows("pedals"))return;
    if(currentView==="play"&&admitted&&!releasingAll&&pedalEnabled&&customActive.some(id=>id[0]==="p"))releasePedals();
  });
  pedalToggles.forEach((b,i)=>{
    b.addEventListener("click",()=>pedalToggle(i));
    b.addEventListener("pointerdown",e=>{
      if(!pedalAdmitted(i)||!isHoldPedal(i)||e.button!==0)return;
      e.preventDefault();
      try{b.setPointerCapture(e.pointerId);}catch{close("Pedal pointer capture failed.");return;}
      pedalHoldDown(i,"p"+e.pointerId);
    });
    b.addEventListener("pointerup",e=>pedalHoldUp(i,"p"+e.pointerId));
    for(const event of ["pointercancel","lostpointercapture"])b.addEventListener(event,e=>cancelHeldPedal(i,"p"+e.pointerId));
    b.addEventListener("keydown",e=>{
      if(isHoldPedal(i)&&(e.key===" "||e.key==="Enter")){
        e.preventDefault();if(!e.repeat)pedalHoldDown(i,"k"+i);
      }
    });
    b.addEventListener("keyup",e=>{
      if(isHoldPedal(i)&&(e.key===" "||e.key==="Enter")){e.preventDefault();pedalHoldUp(i,"k"+i);}
    });
    b.addEventListener("blur",()=>cancelHeldPedal(i,"k"+i));
  });
  pedalSliders.forEach((b,i)=>b.addEventListener("input",()=>pedalMove(i)));
  pedalOutputs.forEach((dial,i)=>{
    dial.addEventListener("pointerdown",e=>{
      if(dialDrags.has(i)||!synthOpen||!pedalAdmitted(i)||!(pedalMask&(1<<i))||
         e.button!==0||!Number.isFinite(e.clientY))return;
      e.preventDefault();
      try{dial.setPointerCapture(e.pointerId);}catch{return;}
      dialDrags.set(i,{id:e.pointerId,y:e.clientY,value:pedalPositions[i]});
    });
    dial.addEventListener("pointermove",e=>{
      const drag=dialDrags.get(i);
      if(!drag||drag.id!==e.pointerId||!synthOpen||!pedalAdmitted(i)||
         !(pedalMask&(1<<i))||!Number.isFinite(e.clientY))return;
      pedalSliders[i].value=String(Math.round(Math.max(0,Math.min(100,drag.value+drag.y-e.clientY))));
      pedalMove(i);
    });
    for(const event of ["pointerup","pointercancel","lostpointercapture"])dial.addEventListener(event,e=>{
      if(dialDrags.get(i)?.id===e.pointerId)dialDrags.delete(i);
    });
  });
  workloadMode.addEventListener("click",()=>{
    if(currentView!=="setup"||releasingAll||!admitted||!caps||workloadMask()!==0||pending)return;
    experimentalWorkload=!experimentalWorkload;workloadRefusal="";syncControls();
  });
  get("layoutPanel").addEventListener("change",syncLayout);
  get("layoutUp").addEventListener("click",()=>changePanelOrder(-1));
  get("layoutDown").addEventListener("click",()=>changePanelOrder(1));
  get("layoutWide").addEventListener("click",changePanelWidth);
  get("layoutSize").addEventListener("change",changeLayoutSize);
  get("panelSize").addEventListener("change",()=>changePanelDetail("sizes"));
  get("panelColumns").addEventListener("change",()=>changePanelDetail("columns"));
  get("customColumns").addEventListener("change",changeCustomColumns);
  get("customAliasApply").addEventListener("click",()=>changeCustomAlias(false));
  get("customAliasClear").addEventListener("click",()=>changeCustomAlias(true));
  get("gridControl").addEventListener("change",()=>syncGridEditor(Boolean(canEditLayout())));
  for(const [id,action] of [["customAdd","add"],["customRemove","remove"],["customUp","up"],["customDown","down"]])get(id).addEventListener("click",()=>changeCustom(action));
  for(const id of ["customAddChoice","customChoice"])get(id).addEventListener("change",()=>syncCustomEditor(Boolean(canEditLayout())));
  get("sliderChoice").addEventListener("change",()=>{sliderValueKey="";syncSliderEditor(Boolean(canEditLayout()));});
  get("sliderApply").addEventListener("click",applySliderSettings);
  get("gridControlUp").addEventListener("click",()=>moveGridControl(-1));
  get("gridControlDown").addEventListener("click",()=>moveGridControl(1));
  for(const i of [3,4,5])get("pedalMode"+i).addEventListener("change",()=>changePedalBehavior(i));
  get("layoutSave").addEventListener("click",saveLayout);
  get("layoutReset").addEventListener("click",resetLayout);
  for(const v of viewNames)get(navId(v)).addEventListener("click",()=>chooseView(v));
  get("playMode").addEventListener("change",choosePlayMode);
  get("airStickPad").addEventListener("change",()=>{const i=Number(get("airStickPad").value);chooseStrikePad(get("airStickPad").value===String(i)?i:-1);});
  get("kitEdit").addEventListener("click",()=>{if(kitIdle()){kitEditing=!kitEditing;kitDrag=null;syncStick();}});
  get("kitPart").addEventListener("change",()=>{const i=Number(get("kitPart").value);if(kitIdle()&&kitEditing&&get("kitPart").value===String(i)&&within(i,0,7)&&has("drums",i))kitPart=i;syncStick();});
  for(const [id,action] of [["kitAdd","add"],["kitRemove","remove"],["kitSave","save"],["kitReset","reset"]])get(id).addEventListener("click",()=>editKit(action));
  get("kitSize").addEventListener("input",()=>editKit("size"));
  get("kitX").addEventListener("input",()=>editKit("x"));get("kitY").addEventListener("input",()=>editKit("y"));
  get("airStickStart").addEventListener("click",startStick);
  get("airStickStop").addEventListener("click",stopStick);
  releaseAll.addEventListener("click",releaseMyControls);
  motionStart.addEventListener("click",startMotion);
  motionStop.addEventListener("click",stopMotion);
  for(const s of streams){s.start.addEventListener("click",()=>startInertial(s));s.stop.addEventListener("click",()=>stopInertial(s));}
  function rotated(){if(ws&&(cameraHelper||stickState!=="idle"||touchBusy()||pedalBusy()||pianoBusy()||drumDesired!==0||drumSent!==0||drumQueue.length||mode!=="idle"||streams.some(s=>s.mode!=="idle")))close("Screen rotated. Reconnect and calibrate again.");}
  window.addEventListener("orientationchange",rotated);
  if(window.screen&&window.screen.orientation&&typeof window.screen.orientation.addEventListener==="function")window.screen.orientation.addEventListener("change",rotated);
  disconnect.addEventListener("click",()=>close("Disconnected. Host releases owned controls."));
  window.addEventListener("blur",()=>{if(ws)close("Window lost focus. Reconnect explicitly.");else if(cameraStream)stopCamera("Camera stopped: window lost focus.");});
  window.addEventListener("pagehide",()=>{if(ws)close("Page hidden.");else stopCamera("Page hidden.");});
  document.addEventListener("visibilitychange",()=>{if(document.hidden){if(ws)close("Page hidden. Reconnect explicitly.");else stopCamera("Page hidden.");}else syncCamera();});
  applyLayout();syncControls();
})();
"""#
}
#endif
