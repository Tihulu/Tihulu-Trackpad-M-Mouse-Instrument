package com.tihulu.mobile.air

import android.os.SystemClock
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.net.Proxy
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Opt-in native LAN adapter prototype, not wired to the RGB/ARCore preview.
 * A single instance owns a single socket and sender policy. All state and
 * sends are serialized; the independent watchdog does not rely on sensor UI.
 * Uses ordinary TLS chain and hostname verification, optionally anchored
 * to an explicitly fingerprint-verified private root for this exact host.
 * No redirect, proxy, retry, global trust change or credential in URL.
 * Caller must explicitly stop on lifecycle/permission loss. The current
 * diagnostic APK intentionally has no INTERNET permission.
 */
class MobileLanSocket(private val endpoint:MobileLanEndpoint, selection:MobileLanSession.Selection,
                      privateRoot:MobileLanTrust?=null) {
    init { require(privateRoot==null||privateRoot.host==endpoint.host) }
    private val policy=MobileLanSession(selection)
    private val lock=Any()
    private val scheduler=Executors.newSingleThreadScheduledExecutor {r->Thread(r,"TIHULU-LAN-watchdog").apply{isDaemon=true}}
    private val client=OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY).followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).connectTimeout(5,TimeUnit.SECONDS)
        .apply { privateRoot?.configure(this) }
        .build()
    private var socket:WebSocket?=null
    private var token:String?=null
    private var startAt:Long?=null
    private var opened=false
    private var terminal=false
    private var message="Not connected"
    data class Status(val phase:MobileLanSession.Phase,val message:String,val assignment:MobileLanCapabilities.Manifest?)
    fun status():Status=synchronized(lock){Status(policy.phase,message,policy.readyManifest)}
    companion object {
        fun nowNs():Long=SystemClock.elapsedRealtimeNanos()
        internal fun request(endpoint:MobileLanEndpoint):Request=Request.Builder()
            .url(endpoint.socketUrl).header("Origin",endpoint.origin)
            .header("Sec-WebSocket-Protocol",endpoint.subprotocol).build()
    }
    fun connect(invitation:String):Boolean=synchronized(lock){
        if(terminal||startAt!=null)return@synchronized false
        val validated=MobileLanEndpoint.invitationBytes(invitation)?:return@synchronized false
        validated.fill(0)
        token=invitation;startAt=nowNs();message="Authenticating local TLS"
        try{
            socket=client.newWebSocket(request(endpoint),listener)
            scheduler.scheduleAtFixedRate({synchronized(lock){watchdog()}},25,25,TimeUnit.MILLISECONDS)
            true
        }catch(_:Exception){finish("Connection setup failed");false}
    }
    /** observedAt must use nowNs()'s elapsed-realtime clock; never wall time.
     * Calls during negotiation cannot buffer gestures. */
    fun offer(output:AirOutput,observedAt:Long,stringDeadlines:Map<Int,Long> = emptyMap())=synchronized(lock){
        if(!terminal&&opened)dispatch(policy.offer(output,observedAt,nowNs(),stringDeadlines))
    }
    /** Camera owner must discard the returned projection when the session ends.
     * A later offer still passes the independent current-session gate. */
    fun newProjection(mode:AirMode,role:HandRole=HandRole.SINGLE,
                      orientation:Orientation=Orientation.UP,mirror:Boolean=false,
                      near:Double=.25,far:Double=.85,allowEstimatedDepth:Boolean=false):AirProjection?=synchronized(lock) {
        if(terminal)null else policy.newProjection(mode,role,orientation,mirror,near,far,allowEstimatedDepth)
    }
    fun stop()=synchronized(lock){finish("Stopped explicitly")}
    private fun watchdog(){
        if(terminal)return
        val now=nowNs()
        if(!opened){
            if(startAt?.let{now-it>=5_000_000_000L}==true)finish("TLS setup timed out")
        }else dispatch(policy.poll(now))
    }
    private fun dispatch(action:MobileLanSession.Action){
        if(terminal)return
        val ws=socket?:run{finish("Socket missing");return}
        try{
            when(action){
                MobileLanSession.Action.Wait->{if(policy.phase==MobileLanSession.Phase.READY)message="Ready · assigned lane"}
                is MobileLanSession.Action.Close->finish(action.reason)
                is MobileLanSession.Action.Binary->{
                    val accepted=ws.queueSize()==0L&&ws.send(action.bytes.toByteString())
                    action.bytes.fill(0)
                    if(!accepted)finish("Binary send failed or backpressured")
                }
                is MobileLanSession.Action.Text->{
                    if(ws.queueSize()!=0L||!ws.send(action.bytes.decodeToString()))finish("Text send failed or backpressured")
                }
            }
        }catch(_:Exception){finish("Transport send failed")}
    }
    private fun finish(reason:String){
        if(terminal)return
        terminal=true;token=null;message=reason;policy.abort()
        val old=socket;socket=null
        // Cancel rather than leave queued attacks ahead of a graceful close.
        old?.cancel();scheduler.shutdownNow()
        client.dispatcher.cancelAll();client.connectionPool.evictAll()
    }
    private fun current(ws:WebSocket)=!terminal&&socket===ws
    private val listener=object:WebSocketListener(){
        override fun onOpen(webSocket:WebSocket,response:Response)=synchronized(lock){
            if(!current(webSocket)){webSocket.cancel();return@synchronized}
            val secret=token;token=null
            val protocol=response.headers.values("Sec-WebSocket-Protocol")
            val expected=request(endpoint).url
            // Ordinary OkHttp TLS validation has already occurred. Never
            // accept a redirected authority or ambiguous protocol selection.
            if(opened||secret==null||response.handshake==null||response.request.url!=expected||
                protocol!=listOf(endpoint.subprotocol)||
                startAt?.let{nowNs()-it>=5_000_000_000L}!=false){
                finish("TLS or WebSocket negotiation refused");return@synchronized
            }
            opened=true;message="Checking host admission"
            dispatch(policy.begin(true,protocol.single(),secret,nowNs()))
        }
        override fun onMessage(webSocket:WebSocket,text:String)=synchronized(lock){
            if(current(webSocket)){if(!opened)finish("Unexpected response")else dispatch(policy.receive(text,nowNs()))}
        }
        override fun onMessage(webSocket:WebSocket,bytes:ByteString)=synchronized(lock){
            if(current(webSocket))finish("Unexpected binary response")
        }
        override fun onClosing(webSocket:WebSocket,code:Int,reason:String)=synchronized(lock){
            if(current(webSocket))finish("Host closing")
        }
        override fun onClosed(webSocket:WebSocket,code:Int,reason:String)=synchronized(lock){
            if(current(webSocket))finish("Host closed")
        }
        override fun onFailure(webSocket:WebSocket,t:Throwable,response:Response?)=synchronized(lock){
            if(current(webSocket))finish("TLS or connection failed")
        }
    }
}
