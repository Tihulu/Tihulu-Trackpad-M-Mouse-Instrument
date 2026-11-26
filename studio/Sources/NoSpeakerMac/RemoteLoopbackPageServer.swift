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
<body><h1>TIHULU Remote</h1><p>Local MIDI performance controller · Experimental</p>
<div id="remoteBar"><nav aria-label="Controller views"><button id="navPlay" aria-pressed="false" disabled>Play</button><button id="navSetup" aria-pressed="false" disabled>Setup</button><button id="navConnection" aria-pressed="true">Connection</button></nav><button id="releaseAll" disabled>Release my controls</button><button id="disconnect" disabled>Disconnect / release</button><p id="navStatus" role="status"></p><p id="playWorkloadStatus" role="status"></p><p id="status" role="status" aria-live="polite">Not connected.</p><small id="ackLatency">Mac ACK round trip: no sample.</small></div>
<section id="connectionView"><label for="secret">One-time invitation (64 hexadecimal characters)</label>
<input id="secret" type="password" maxlength="64" autocomplete="off" autocapitalize="off" spellcheck="false">
<button id="connect">Connect</button><p>Use the matching trusted TLS certificate and a new invitation for each connection. ACK round trip includes Mac processing; it is not audio or MIDI latency.</p></section>
<div id="setupView" hidden>
<section id="mappingSection" hidden><h2>Mapped MIDI destinations</h2><p id="mappingStatus" role="status"></p><pre id="mappingDetails" style="white-space:pre-wrap;overflow-wrap:anywhere"></pre></section>
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
<div id="playView" hidden><section id="playModeSection" data-wide="true"><label for="playMode">Instrument / controller mode</label><select id="playMode" disabled aria-describedby="playModeStatus"></select><p id="playModeStatus" role="status"></p><small>Switch surfaces here. Only modes assigned on the Mac are available. Pitch bend requires a mapped XY axis or pedal slider. Switching releases previous controls before showing the new surface.</small></section><section id="customSection" hidden data-wide="true" aria-labelledby="customTitle"><h2 id="customTitle">My performance panel</h2>
<p>Enable the mapped control families separately. Existing workload limits still apply.</p>
<button id="customDrumEnable" type="button" disabled>Enable drum pads</button><button id="customPedalEnable" type="button" disabled>Enable pedalboard</button>
<button id="customDrumRelease" type="button" disabled>Release all drum pads</button><button id="customPedalRelease" type="button" disabled>Release all pedals</button>
<div id="customGrid"></div></section><section id="touchSection" hidden><div id="pad" aria-label="XY touch surface" aria-disabled="true"><span>Touch and move</span><div id="dot" hidden></div></div>
<p><small>X and Y control the mapped instrument. Lift to release. One contact only.</small></p></section>
<section id="drumSection" hidden aria-labelledby="drum-title"><h2 id="drum-title">Drum Pads</h2>
<p>Only pads mapped for this paired device are available. Pad numbers identify controls, not assumed MIDI notes. Actual destinations are listed in Setup when shared.</p>
<button id="drumEnable" disabled>Enable drum pads</button><button id="drumRelease" disabled>Release all pads</button>
<p id="drumStatus" role="status">Off.</p><div id="drumGrid"><button id="drum0" type="button" aria-pressed="false" disabled>1 · Kick</button><button id="drum1" type="button" aria-pressed="false" disabled>2 · Snare</button><button id="drum2" type="button" aria-pressed="false" disabled>3 · Closed Hi-Hat</button><button id="drum3" type="button" aria-pressed="false" disabled>4 · Open Hi-Hat</button><button id="drum4" type="button" aria-pressed="false" disabled>5 · Low Tom</button><button id="drum5" type="button" aria-pressed="false" disabled>6 · High Tom</button><button id="drum6" type="button" aria-pressed="false" disabled>7 · Crash</button><button id="drum7" type="button" aria-pressed="false" disabled>8 · Ride</button></div>
<small>Multiple fingers supported. Hold a pad to sustain its note; lift to release. Fixed host velocity, no pressure sensing. Release all clears pending hits.</small>
<div id="airStickSection" hidden><h3>Air stick</h3><label for="airStickPad">Assigned strike pad</label><select id="airStickPad"></select><button id="airStickStart" type="button" disabled>Enable air stick</button><button id="airStickStop" type="button" disabled>Stop air stick</button><p id="airStickStatus" role="status">Off.</p><small>Gravity-free motion triggers a mapped pad at fixed velocity. Hold securely, use small movements and never hit a surface.</small></div></section>
<section id="pianoSection" hidden aria-labelledby="piano-title"><h2 id="piano-title">Piano</h2>
<p>Only keys and sustain mapped for this paired device are available. Key positions identify logical controls. Scale hints are available only for a verified default pitch mapping.</p>
<button id="pianoEnable" disabled>Enable piano</button><button id="pianoRelease" disabled>Release keys &amp; pedal</button>
<p id="pianoStatus" role="status">Off.</p>
<button id="octaveDown" disabled>Octave −</button><span id="octaveLabel">C3–C4</span><button id="octaveUp" disabled>Octave +</button>
<label for="pianoScale">Scale guide (visual only)</label><select id="pianoScale"><option value="all">Chromatic</option><option value="major">Major</option><option value="minor">Natural minor</option><option value="pentatonic">Major pentatonic</option></select>
<label for="pianoRoot">Root note</label><select id="pianoRoot"><option value="0">C</option><option value="1">C♯</option><option value="2">D</option><option value="3">D♯</option><option value="4">E</option><option value="5">F</option><option value="6">F♯</option><option value="7">G</option><option value="8">G♯</option><option value="9">A</option><option value="10">A♯</option><option value="11">B</option></select>
<button id="pianoStrips" aria-pressed="false" disabled>Note strips</button>
<small id="pianoStripHint" hidden>Slide between assigned notes or hold multiple fingers. Lift to release; leaving the surface releases that finger. Discrete notes only, no independent pitch bend. Change layouts when all notes and pedal are released.</small>
<div id="pianoBoard" aria-label="Piano keyboard"><button id="piano0" class="whiteKey" type="button" style="left:0%;width:12.5%" aria-pressed="false" disabled></button><button id="piano2" class="whiteKey" type="button" style="left:12.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano4" class="whiteKey" type="button" style="left:25%;width:12.5%" aria-pressed="false" disabled></button><button id="piano5" class="whiteKey" type="button" style="left:37.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano7" class="whiteKey" type="button" style="left:50%;width:12.5%" aria-pressed="false" disabled></button><button id="piano9" class="whiteKey" type="button" style="left:62.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano11" class="whiteKey" type="button" style="left:75%;width:12.5%" aria-pressed="false" disabled></button><button id="piano12" class="whiteKey" type="button" style="left:87.5%;width:12.5%" aria-pressed="false" disabled></button><button id="piano1" class="blackKey" type="button" style="left:8.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano3" class="blackKey" type="button" style="left:21.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano6" class="blackKey" type="button" style="left:46.1%;width:7.8%" aria-pressed="false" disabled></button><button id="piano8" class="blackKey" type="button" style="left:58.6%;width:7.8%" aria-pressed="false" disabled></button><button id="piano10" class="blackKey" type="button" style="left:71.1%;width:7.8%" aria-pressed="false" disabled></button></div>
<button id="pianoSustain" type="button" aria-pressed="false" disabled>Sustain (hold)</button>
<small id="pianoManualHint">Hold multiple keys or the pedal. Lift to release. Octave changes are available only after all piano messages are acknowledged. Scale guide does not alter MIDI routing.</small>
<div id="phraseSection" hidden><h3 id="phraseTitle">Chord pads</h3>
<div id="chordGrid"><button id="chord0" type="button" disabled></button><button id="chord1" type="button" disabled></button><button id="chord2" type="button" disabled></button><button id="chord3" type="button" disabled></button></div>
<div id="phraseTransport" hidden><label for="phraseTempo">Tempo</label><select id="phraseTempo"><option value="60">60 BPM</option><option value="90">90 BPM</option><option value="120" selected>120 BPM</option><option value="150">150 BPM</option></select><label id="arpLabel" for="arpChoice">Arpeggio chord</label><select id="arpChoice"></select><div id="sequenceSteps"><label for="phraseStep0">Step 1</label><select id="phraseStep0"></select><label for="phraseStep1">Step 2</label><select id="phraseStep1"></select><label for="phraseStep2">Step 3</label><select id="phraseStep2"></select><label for="phraseStep3">Step 4</label><select id="phraseStep3"></select><label for="phraseStep4">Step 5</label><select id="phraseStep4"></select><label for="phraseStep5">Step 6</label><select id="phraseStep5"></select><label for="phraseStep6">Step 7</label><select id="phraseStep6"></select><label for="phraseStep7">Step 8</label><select id="phraseStep7"></select></div><button id="phraseStart" type="button" disabled>Start loop</button><button id="phraseStop" type="button" disabled>Stop loop</button></div>
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
    const pedals=Boolean(caps)&&modeAllows("pedals")&&customActive.some(id=>id[0]==="p");
    for(const id of customActive)customNode(id).hidden=!modeAllows(id[0]==="d"?"drums":"pedals")||!customMapped(id);
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
    ["tilt","Tilt / orientation",["tilt"]],
    ["gyro","Gyro / rotation",["rotation"]],
    ["accel","Acceleration / Air Drums",["acceleration"]],
    ["motion","All assigned motion sensors",["tilt","rotation","acceleration"]]
  ];
  function modeAvailable(id){
    const entry=playModes.find(p=>p[0]===id);
    return Boolean(caps&&entry&&(["chord","arp","seq"].includes(id)?Boolean(caps.piano&33554431):id==="all"||entry[2].some(kind=>Boolean(caps[kind]))));
  }
  function modeAllows(kind){
    return playMode==="all"||Boolean(playModes.find(p=>p[0]===playMode)?.[2].includes(kind));
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
      if(modeAvailable(pendingPlayMode))playMode=pendingPlayMode;
      pendingPlayMode=null;
    }
    drumStatus.textContent=pianoStatus.textContent=pedalStatus.textContent="Off.";
    status.textContent="My controls released locally; required Mac acknowledgments received. MIDI/audio output not confirmed. Enable controls again to play.";
    syncControls();return true;
  }
  function releaseMyControls(){
    if(!admitted||!caps||releasingAll)return;
    releasingAll=true;const now=performance.now();
    // Cancel unsent onsets; retain the state of every already sent owner.
    pointer=null;position=null;dot.hidden=true;touchQueue=touchSent?[{kind:"release",at:now}]:[];
    resetStick();drumEnabled=false;drumOwners.clear();drumDesired=0;drumQueue=[];drumEmergency=drumSent!==0;
    resetPhrase();pianoEnabled=false;pianoOwners.clear();pianoDesired=0;pianoQueue=[];pianoEmergency=pianoSent!==0;
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
    const originalPedals=indices(6).some(i=>has("pedals",i)&&!customActive.includes("p"+i));
    for(const [id,visible] of [["touchSection",caps?.touch&&modeAllows("touch")],["drumSection",originalDrums&&modeAllows("drums")],["pianoSection",caps?.piano&&modeAllows("piano")],["pedalSection",originalPedals&&modeAllows("pedals")],["tiltSection",caps?.tilt&&modeAllows("tilt")],["inertialSection",(caps?.acceleration&&modeAllows("acceleration"))||(caps?.rotation&&modeAllows("rotation"))],["accelSection",caps?.acceleration&&modeAllows("acceleration")],["rotationSection",caps?.rotation&&modeAllows("rotation")],["airDrumNotice",caps?.airDrums&&modeAllows("acceleration")]])get(id).hidden=!visible;
  }
  const drumButtons=Array.from({length:8},(_,i)=>get("drum"+i));
  const drumEnable=get("drumEnable"),drumRelease=get("drumRelease"),drumStatus=get("drumStatus");
  let drumEnabled=false,drumOwners=new Map(),drumQueue=[],drumDesired=0,drumSent=0,lastDrumSend=-Infinity,drumEmergency=false;
  let stickState="idle",stickEpoch=0,stickPad=0,stickKey="",stickAt=0,stickReady=false,stickPulseAt=null,stickLast=-Infinity;
  function syncStick(){
    const select=get("airStickPad"),key=String(caps?.drums??0);
    if(key!==stickKey){
      select.replaceChildren(...Array.from({length:8},(_,i)=>i).filter(i=>has("drums",i)).map(i=>{
        const o=document.createElement("option");o.value=String(i);o.textContent=labelFor(9+i);return o;
      }));
      stickPad=Array.from({length:8},(_,i)=>i).find(i=>has("drums",i))??0;select.value=String(stickPad);stickKey=key;
    }
    get("airStickSection").hidden=playMode!=="stick";
    select.disabled=stickState!=="idle"||!admitted||!caps?.drums;
    get("airStickStart").disabled=playMode!=="stick"||!admitted||!caps?.drums||releasingAll||stickState!=="idle"||drumBusy();
    get("airStickStop").disabled=stickState==="idle";
  }
  function resetStick(message="Off."){
    stickEpoch++;stickState="idle";stickReady=false;stickPulseAt=null;stickLast=-Infinity;
    get("airStickStatus").textContent=message;syncInertialListener();
  }
  async function startStick(){
    if(playMode!=="stick"||currentView!=="play"||!admitted||releasingAll||stickState!=="idle"||drumBusy()||!has("drums",stickPad))return;
    if(!window.isSecureContext||typeof window.DeviceMotionEvent==="undefined"){get("airStickStatus").textContent="DeviceMotion unavailable.";return;}
    if(!requestWorkload("drums"))return;
    const epoch=++stickEpoch;stickState="requesting";drumEnabled=true;syncControls();
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
    if(now-stickLast<150||pending||drumBusy()||releasingAll)return;
    stickLast=now;stickPulseAt=now;drumDown("air-stick",stickPad);
  }
  function stopStick(){resetStick();drumEnabled=false;releaseDrums();}
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
  function drumUp(owner){if(drumOwners.delete(owner))drumChanged();}
  function sendDrum(mask){send("drumPads",{mask});}
  const pianoButtons=Array.from({length:13},(_,i)=>get("piano"+i));
  const pianoPedal=get("pianoSustain"),pianoEnable=get("pianoEnable"),pianoRelease=get("pianoRelease"),pianoStatus=get("pianoStatus");
  const octaveDown=get("octaveDown"),octaveUp=get("octaveUp"),octaveLabel=get("octaveLabel"),pianoScale=get("pianoScale"),pianoRoot=get("pianoRoot");
  const pitchNames=["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"];
  const scaleDegrees={all:[0,1,2,3,4,5,6,7,8,9,10,11],major:[0,2,4,5,7,9,11],minor:[0,2,3,5,7,8,10],pentatonic:[0,2,4,7,9]};
  const pianoBoard=get("pianoBoard"),pianoStrips=get("pianoStrips"),pianoStripHint=get("pianoStripHint");
  let strips=false;
  let pianoEnabled=false,pianoOctave=0,pianoOwners=new Map(),pianoQueue=[],pianoDesired=0,pianoSent=0,lastPianoSend=-Infinity,pianoEmergency=false;
  function pianoBusy(){return phraseRun!==null||pianoDesired!==0||pianoSent!==0||pianoQueue.length!==0||pianoEmergency||pendingKind==="pianoKeys";}
  const chordShapes=[[0,4,7],[2,5,9],[5,9,12],[7,11,14]];
  const phraseModes=["chord","arp","seq"];
  const chordOwners=new Map();
  let phraseMask=0,phraseRun=null,phraseOptionsKey="";
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
    get("pianoBoard").hidden=special||!Boolean(caps?.piano&33554431);
    get("pianoManualHint").hidden=special;
    get("pianoStrips").hidden=special;
    for(const id of ["octaveDown","octaveUp","octaveLabel","pianoScale","pianoRoot","pianoSustain"])if(special)get(id).hidden=true;
    else if(id!=="pianoSustain")get(id).hidden=false;
    get("phraseTitle").textContent=playMode==="chord"?"Chord pads":playMode==="arp"?"Arpeggiator":"8-step sequencer";
    get("chordGrid").hidden=playMode!=="chord";
    get("phraseTransport").hidden=playMode==="chord";
    get("arpChoice").hidden=get("arpLabel").hidden=playMode!=="arp";
    get("sequenceSteps").hidden=playMode!=="seq";
    for(let i=0;i<4;i++){
      const b=get("chord"+i);b.textContent=chordLabel(i);b.disabled=playMode!=="chord"||!pianoEnabled||!admitted||releasingAll||!chordAvailable(i);
      b.setAttribute("aria-pressed",String([...chordOwners.values()].includes(i)));
    }
    for(const id of ["phraseTempo","arpChoice",...Array.from({length:8},(_,i)=>"phraseStep"+i)])get(id).disabled=playing;
    get("phraseStart").disabled=!pianoEnabled||!admitted||releasingAll||pianoBusy()||!["arp","seq"].includes(playMode);
    get("phraseStop").disabled=!playing;
  }
  function resetPhrase(message="Off."){phraseRun=null;phraseMask=0;chordOwners.clear();get("phraseStatus").textContent=message;}
  function chordDown(owner,i){
    if(currentView!=="play"||playMode!=="chord"||!admitted||!pianoEnabled||releasingAll||pianoEmergency||!chordAvailable(i)||chordOwners.has(owner))return;
    if(chordOwners.size>=16){close("Too many chord contacts.");return;}
    chordOwners.set(owner,i);pianoChanged();
  }
  function chordUp(owner){if(chordOwners.delete(owner))pianoChanged();}
  function startPhrase(){
    if(currentView!=="play"||!["arp","seq"].includes(playMode)||!pianoEnabled||!admitted||releasingAll||pianoBusy())return;
    const bpm=Number(get("phraseTempo").value);
    if(![60,90,120,150].includes(bpm))return;
    const selection=get("arpChoice").value,index=Number(selection);
    const pattern=playMode==="arp"?(selection!==""&&chordAvailable(index)?[...chordShapes[index]]:[]):
      Array.from({length:8},(_,i)=>Number(get("phraseStep"+i).value));
    if(!pattern.length||!pattern.some(i=>i>=0)||!pattern.every(i=>Number.isInteger(i)&&(i===-1||(i<25&&has("piano",i)))))return;
    phraseRun={pattern,index:0,on:false,next:performance.now(),period:30000/bpm};
    get("phraseStatus").textContent="Playing · local browser clock.";syncControls();tick();
  }
  function advancePhrase(now){
    const run=phraseRun;if(!run||now<run.next)return true;
    if(now-run.next>=150){close("Sequencer delayed. Reconnect explicitly.");return false;}
    if(pending||pianoQueue.length||pianoEmergency)return true;
    if(!pianoEnabled||releasingAll||!admitted||!["arp","seq"].includes(playMode)){releasePiano();return false;}
    if(!run.on){
      const i=run.pattern[run.index];phraseMask=i<0?0:1<<i;
      run.on=true;run.next=now+run.period*0.5;
    }else{
      phraseMask=0;run.on=false;run.index=(run.index+1)%run.pattern.length;run.next=now+run.period*0.5;
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
    pianoStrips.disabled=!admitted||!Boolean(caps?.piano&33554431)||pianoBusy()||releasingAll;
    pianoStrips.setAttribute("aria-pressed",String(strips));
    pianoStrips.textContent=strips?"Piano layout":"Note strips";
    pianoStripHint.hidden=!strips;
    pianoBoard.setAttribute("data-strips",String(strips));
    pianoBoard.setAttribute("aria-label",strips?"Assigned note strips":"Piano keyboard");
    const scale=scaleDegrees[pianoScale.value]||scaleDegrees.all;
    const root=Number(pianoRoot.value)||0;
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
      b.setAttribute("data-scale",String(scaleAllowed&&pianoScale.value!=="all"&&scale.includes((index-root+12)%12)));
    });
    get("pianoBoard").hidden=!Boolean(caps?.piano&33554431);
    pianoPedal.hidden=!has("piano",25);pianoPedal.disabled=!admitted||!pianoEnabled||!has("piano",25)||pianoEmergency;
    pianoPedal.setAttribute("aria-pressed",String(Boolean(pianoDesired&(1<<25))));syncPhrase();
  }
  function resetPiano(){resetPhrase();strips=false;pianoEnabled=false;pianoOctave=0;pianoOwners.clear();pianoQueue=[];pianoDesired=0;pianoSent=0;lastPianoSend=-Infinity;pianoEmergency=false;pianoStatus.textContent="Off.";syncPiano();}
  function pianoChanged(runTick=true){
    let mask=phraseMask;for(const index of pianoOwners.values())mask|=1<<index;
    for(const index of chordOwners.values())mask|=chordMask(index);
    if(mask===pianoDesired)return;
    pianoDesired=mask;
    if(pianoQueue.length>=8){close("Piano input backlog. Reconnect explicitly.");return;}
    pianoQueue.push({mask,at:performance.now()});syncPiano();if(runTick)tick();
  }
  function releasePiano(){
    resetPhrase();pianoOwners.clear();pianoDesired=0;pianoQueue=[];
    pianoEmergency=pianoSent!==0;syncControls();tick();
  }
  function pianoDown(owner,index){
    if(specialPiano()||!admitted||!pianoEnabled||!has("piano",index)||pianoEmergency||pianoOwners.has(owner))return;
    if(pianoOwners.size>=32){close("Too many piano contacts. Reconnect explicitly.");return;}
    pianoOwners.set(owner,index);pianoChanged();
  }
  function pianoUp(owner){if(pianoOwners.delete(owner))pianoChanged();}
  function moveStrip(e){
    const owner="p"+e.pointerId;
    if(!strips||!admitted||!pianoEnabled||pianoEmergency||!pianoOwners.has(owner)||pianoOwners.get(owner)===25)return;
    e.preventDefault();
    const r=pianoBoard.getBoundingClientRect();
    if(![r.left,r.top,r.width,r.height,e.clientX,e.clientY].every(Number.isFinite)||r.width<=0||r.height<=0){
      close("Invalid note surface geometry. Reconnect explicitly.");return;
    }
    if(e.clientX<r.left||e.clientX>r.left+r.width||e.clientY<r.top||e.clientY>r.top+r.height){
      pianoUp(owner);return;
    }
    // Compact only the host-authorized notes. DOM order and geometry agree.
    const zones=Array.from({length:13},(_,i)=>i+12*pianoOctave).filter(i=>has("piano",i));
    if(!zones.length){pianoUp(owner);return;}
    const gap=3, width=(r.width-gap*(zones.length-1))/zones.length;
    if(width<=0){close("Note surface too narrow. Reconnect explicitly.");return;}
    const slot=Math.min(zones.length-1,Math.floor((e.clientX-r.left)/(width+gap)));
    const index=zones[slot];
    if(index!==pianoOwners.get(owner)){pianoOwners.set(owner,index);pianoChanged();}
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
    pedalEnable.disabled=!admitted||!caps?.pedals||!modeAllows("pedals");pedalEnable.textContent=pedalEnabled?"Disable pedalboard":"Enable pedalboard";
    pedalRelease.disabled=!admitted||!pedalBusy();
    pedalToggles.forEach((b,i)=>{
      const active=Boolean(pedalMask&(1<<i));
      get("pedalCell"+i).hidden=!has("pedals",i);
      b.disabled=!admitted||!pedalEnabled||!has("pedals",i)||pedalEmergency;
      const hold=isHoldPedal(i);
      const alias=localAlias("p"+i);
      b.textContent=(alias?alias+" · ":groupNeutralHandshake&&mappingLabels.has(43+i)?mappingLabels.get(43+i)+" · ":"")+(hold?(active?"Held":"Hold to activate"):i<3?(active?"Release":"Activate"):(active?"On":"Off"));
      b.setAttribute("data-hold",String(hold));
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
    pedalEnabled=false;pedalHoldOwners.clear();pedalMask=0;pedalSentMask=0;pedalPositions=[...details.sliderDefaults];pedalQueue=[];pedalDirty=false;lastPedalSend=-Infinity;pedalEmergency=false;
    pedalStatus.textContent="Off.";syncPedals();
  }
  function pedalAdmitted(i){
    return currentView==="play"&&!releasingAll&&admitted&&pedalEnabled&&has("pedals",i)&&!pedalEmergency;
  }
  function pedalSet(i,active){
    const next=active?pedalMask|(1<<i):pedalMask&~(1<<i);
    if(next===pedalMask)return;
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
  function pedalMove(i){
    if(!pedalAdmitted(i)||!(pedalMask&(1<<i)))return;
    const n=Number(pedalSliders[i].value);
    if(!Number.isFinite(n)||n<0||n>100){close("Invalid pedal level.");return;}
    pedalPositions[i]=Math.round(n);pedalDirty=true;syncPedals();tick();
  }
  function releasePedals(){
    pedalHoldOwners.clear();pedalMask=0;pedalQueue=[];pedalDirty=false;pedalEmergency=pedalSentMask!==0;syncControls();tick();
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
    pad.setAttribute("aria-disabled",String(!admitted||!caps?.touch||!workloadAllows("touch")));syncSections();syncDrums();syncPiano();syncPedals();syncCustom();syncWorkload();syncNavigation();syncPlayMode();syncLatency();syncLayout();
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
    const old=ws;ws=null;admitted=false;caps=null;groupReady=null;currentView="connection";ackSamples=[];playMode="all";pendingPlayMode=null;releasingAll=false;cancelGlobalTimer();clearMapping();renderMapping();experimentalWorkload=false;workloadRefusal="";pending=false;sequence=0;pointer=null;position=null;touchQueue=[];touchSent=false;
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
      if(groupReady){
        if(!pending||e.data!=="accepted"){close("Group neutral handshake rejected.");return;}
        const armed=groupReady;
        clearDeadline();pending=false;pendingKind=null;
        if(armed.queue.length){send(...armed.queue.shift());return;}
        groupReady=null;
        finishReady(armed.manifest,armed.rows,armed.labels);return;
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
  get("phraseStart").addEventListener("click",startPhrase);
  get("phraseStop").addEventListener("click",releasePiano);
  for(let i=0;i<4;i++){
    const b=get("chord"+i);
    b.addEventListener("pointerdown",e=>{if(e.button!==0||b.disabled)return;e.preventDefault();try{b.setPointerCapture(e.pointerId);}catch{close("Chord pointer capture failed.");return;}chordDown("c"+i+":"+e.pointerId,i);});
    for(const event of ["pointerup","pointercancel","lostpointercapture"])b.addEventListener(event,e=>chordUp("c"+i+":"+e.pointerId));
    b.addEventListener("keydown",e=>{if((e.key===" "||e.key==="Enter")&&!e.repeat){e.preventDefault();chordDown("k"+i,i);}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();chordUp("k"+i);}});
    b.addEventListener("blur",()=>chordUp("k"+i));
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
    for(const name of ["pointercancel","lostpointercapture"])b.addEventListener(name,e=>{
      if(strips&&pianoOwners.has("p"+e.pointerId)){close("Note contact cancelled. Reconnect explicitly.");return;}
      pianoUp("p"+e.pointerId);
    });
    b.addEventListener("keydown",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();if(!e.repeat)pianoDown("k"+i,index());}});
    b.addEventListener("keyup",e=>{if(e.key===" "||e.key==="Enter"){e.preventDefault();pianoUp("k"+i);}});
    b.addEventListener("blur",()=>pianoUp("k"+i));
  });
  function togglePedals(){
    if(currentView!=="play"||releasingAll||!admitted||!caps?.pedals)return;
    if(!pedalEnabled&&!requestWorkload("pedals"))return;
    pedalEnabled=!pedalEnabled;
    if(!pedalEnabled)releasePedals();
    workloadRefusal="";syncControls();
    pedalStatus.textContent=pedalEnabled?"Enabled. Activate individual mapped pedals.":"Off.";syncPedals();
  }
  pedalEnable.addEventListener("click",togglePedals);
  get("customPedalEnable").addEventListener("click",()=>{if(customActive.some(id=>id[0]==="p"))togglePedals();});
  pedalRelease.addEventListener("click",releasePedals);
  get("customPedalRelease").addEventListener("click",()=>{
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
    for(const event of ["pointerup","pointercancel","lostpointercapture"])b.addEventListener(event,e=>pedalHoldUp(i,"p"+e.pointerId));
    b.addEventListener("keydown",e=>{
      if(isHoldPedal(i)&&(e.key===" "||e.key==="Enter")){
        e.preventDefault();if(!e.repeat)pedalHoldDown(i,"k"+i);
      }
    });
    b.addEventListener("keyup",e=>{
      if(isHoldPedal(i)&&(e.key===" "||e.key==="Enter")){e.preventDefault();pedalHoldUp(i,"k"+i);}
    });
    b.addEventListener("blur",()=>pedalHoldUp(i,"k"+i));
  });
  pedalSliders.forEach((b,i)=>b.addEventListener("input",()=>pedalMove(i)));
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
  get("airStickPad").addEventListener("change",()=>{const i=Number(get("airStickPad").value);if(stickState==="idle"&&Number.isInteger(i)&&has("drums",i))stickPad=i;else get("airStickPad").value=String(stickPad);});
  get("airStickStart").addEventListener("click",startStick);
  get("airStickStop").addEventListener("click",stopStick);
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
  applyLayout();syncControls();
})();
"""#
}
#endif
