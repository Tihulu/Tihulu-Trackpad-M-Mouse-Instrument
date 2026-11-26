#if os(iOS)
@preconcurrency import Foundation
@preconcurrency import UIKit
import NoSpeakerCore

/// Experimental, single-use LAN adapter. Not attached to the sensor preview.
/// Ordinary URLSession TLS trust is mandatory; no trust challenge override.
/// All mutable state is confined to one serial queue. Caller must stop on
/// lifecycle loss and must supply observation timestamps in this clock domain.
public final class MobileLANSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public struct Status: Sendable {
        public let phase:MobileLANSession.Phase
        public let message:String
    }
    private let endpoint:MobileLANEndpoint
    private let queue=DispatchQueue(label:"com.tihulu.mobile.lan",qos:.userInitiated)
    private var policy:MobileLANSession
    private var session:URLSession?
    private var socket:URLSessionWebSocketTask?
    private var timer:DispatchSourceTimer?
    private var lifecycle:NSObjectProtocol?
    private var token:String?
    private var startAt:Int64?
    private var opened=false
    private var sending=false
    private var terminal=false
    private var message="Not connected"
    public init(endpoint:MobileLANEndpoint,selection:MobileLANSession.Selection) {
        self.endpoint=endpoint;policy=MobileLANSession(selection:selection)
        super.init()
    }
    public static var nowNS:Int64 {
        Int64(clamping:DispatchTime.now().uptimeNanoseconds)
    }
    public func status()->Status {
        queue.sync {Status(phase:policy.phase,message:message)}
    }
    private func request()->URLRequest {
        // The endpoint parser has already validated the canonical numeric URL.
        var r=URLRequest(url:URL(string:endpoint.socketURL)!)
        r.setValue(endpoint.origin,forHTTPHeaderField:"Origin")
        r.setValue(endpoint.subprotocol,forHTTPHeaderField:"Sec-WebSocket-Protocol")
        return r
    }
    /// Explicit user action only. Invitation is retained in memory until
    /// the TLS upgrade callback, never included in URL or persistent storage.
    public func connect(invitation:String)->Bool {
        queue.sync {
            guard !terminal,startAt==nil,MobileLANEndpoint.invitationBytes(invitation) != nil else{return false}
            token=invitation;startAt=Self.nowNS;message="Authenticating local TLS"
            let config=URLSessionConfiguration.ephemeral
            config.httpCookieStorage=nil;config.urlCache=nil;config.urlCredentialStorage=nil
            config.httpShouldSetCookies=false;config.waitsForConnectivity=false
            config.timeoutIntervalForRequest=5
            let delegates=OperationQueue();delegates.maxConcurrentOperationCount=1
            let session=URLSession(configuration:config,delegate:self,delegateQueue:delegates)
            self.session=session
            let task=session.webSocketTask(with:request())
            task.maximumMessageSize=RemoteTouchFrame.maximumBytes
            socket=task
            lifecycle=NotificationCenter.default.addObserver(forName:UIApplication.willResignActiveNotification,object:nil,queue:nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.finish("App inactive") }
            }
            let timer=DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now() + .milliseconds(25),repeating:.milliseconds(25))
            timer.setEventHandler { [weak self] in self?.watchdog() }
            self.timer=timer;timer.resume()
            task.resume()
            return true
        }
    }
    public func offer(_ output:MobileAirOutput,observedAt:Int64) {
        queue.sync {if !terminal && opened {dispatch(policy.offer(output,observedAt:observedAt,now:Self.nowNS))}}
    }
    public func stop(){queue.sync {finish("Stopped explicitly")}}
    private func watchdog(){
        guard !terminal else{return}
        let now=Self.nowNS
        if opened {dispatch(policy.poll(now:now))}
        else if let startAt,now-startAt>=5_000_000_000 {finish("TLS setup timed out")}
    }
    private func current(_ task:URLSessionWebSocketTask)->Bool {!terminal && socket === task}
    private func dispatch(_ action:MobileLANSession.Action){
        guard !terminal,let task=socket else{return}
        switch action {
        case .wait:if policy.phase == .ready {message="Ready · assigned lane"}
        case .close(let reason):finish(reason)
        case .binary(let bytes):send(.data(bytes),task:task)
        case .text(let bytes):
            guard let text=String(data:bytes,encoding:.utf8) else{finish("Invalid text");return}
            send(.string(text),task:task)
        }
    }
    private func send(_ payload:URLSessionWebSocketTask.Message,task:URLSessionWebSocketTask){
        guard current(task),!sending else{finish("Send backpressure");return}
        sending=true
        task.send(payload) { [weak self,weak task] error in
            guard let self,let task else{return}
            let failed=error != nil
            self.queue.async { [weak self] in
                guard let self,self.current(task) else{return}
                self.sending=false
                if failed {self.finish("Transport send failed")}
            }
        }
    }
    private func read(_ task:URLSessionWebSocketTask){
        guard current(task) else{return}
        task.receive { [weak self,weak task] result in
            guard let self,let task else{return}
            self.queue.async { [weak self] in
                guard let self,self.current(task) else{return}
                switch result {
                case .success(.string(let text)):
                    self.dispatch(self.policy.receive(text:text,now:Self.nowNS))
                    self.read(task)
                default:self.finish("Unexpected or failed WebSocket response")
                }
            }
        }
    }
    private func finish(_ reason:String){
        guard !terminal else{return}
        terminal=true;token=nil;message=reason;_=policy.abort()
        timer?.cancel();timer=nil
        if let lifecycle {NotificationCenter.default.removeObserver(lifecycle);self.lifecycle=nil}
        let old=socket;socket=nil
        // Abort immediately; host cleanup is authoritative.
        old?.cancel()
        session?.invalidateAndCancel();session=nil
    }
    public func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didOpenWithProtocol proto:String?){
        queue.async { [weak self] in
            guard let self,self.current(webSocketTask) else{webSocketTask.cancel();return}
            let invitation=self.token;self.token=nil
            guard !self.opened,let invitation,proto==self.endpoint.subprotocol,
                  webSocketTask.currentRequest?.url==URL(string:self.endpoint.socketURL),
                  let startAt=self.startAt,Self.nowNS-startAt<5_000_000_000 else{self.finish("TLS or WebSocket negotiation refused");return}
            self.opened=true;self.message="Checking host admission"
            // didOpen only follows URLSession's default TLS validation.
            self.dispatch(self.policy.begin(trustedTLS:true,subprotocol:self.endpoint.subprotocol,invitation:invitation,now:Self.nowNS))
            self.read(webSocketTask)
        }
    }
    public func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didCloseWith closeCode:URLSessionWebSocketTask.CloseCode,reason:Data?){
        queue.async { [weak self] in if let self,self.current(webSocketTask){self.finish("Host closed")} }
    }
    public func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){
        queue.async { [weak self] in if let self,self.socket === task {self.finish("Connection ended")} }
    }
    public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping @Sendable (URLRequest?)->Void){
        completionHandler(nil)
        queue.async { [weak self] in if let self,self.socket === task {self.finish("Redirect refused")} }
    }
}
#endif
