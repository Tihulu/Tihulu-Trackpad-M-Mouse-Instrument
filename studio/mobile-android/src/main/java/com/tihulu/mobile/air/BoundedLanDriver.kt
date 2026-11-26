package com.tihulu.mobile.air

/**
 * Serialized, socket-independent driver for the bounded transport.
 * The caller must close the channel on terminal state, independently
 * poll (including while writes block), and never hold the policy lock
 * during network I/O. All timestamps use one monotonic clock.
 */
internal class BoundedLanDriver(selection:MobileLanSession.Selection,
    private val encoder:BoundedLanFrameWriter=BoundedLanFrameWriter()) {
    companion object { const val SETUP_NS=5_000_000_000L }
    private val policy=MobileLanSession(selection)
    private val slot=LanWriteSlot()
    private var startedAt:Long?=null
    private var clock:Long?=null
    private var invitation:String?=null
    private var upgraded=false
    private var earlyReply:String?=null
    var closed=false;private set
    var message="Not connected";private set
    val phase get()=policy.phase
    val assignment get()=policy.readyManifest
    val writeWaiting get()=!closed&&slot.busy&&!slot.writing

    fun connect(secret:String,now:Long):Boolean {
        if(closed||startedAt!=null||now<0)return false
        val bytes=MobileLanEndpoint.invitationBytes(secret)?:return false
        bytes.fill(0)
        startedAt=now;clock=now;invitation=secret
        message="Authenticating local TLS"
        return true
    }
    private fun check(now:Long):Boolean {
        if(closed||startedAt==null)return false
        if(now<0||clock?.let{now<it}==true){stop("Invalid monotonic clock");return false}
        clock=now
        if(!upgraded&&now-startedAt!!>=SETUP_NS){stop("TLS setup timed out");return false}
        if(slot.expired(now)){stop("Transport write timed out");return false}
        return true
    }
    /** Only the owner of a successfully verified TLS + exact Upgrade
     * channel may call this. The invitation is never in the HTTP request. */
    fun verifiedUpgrade(now:Long) {
        if(!check(now))return
        val secret=invitation
        invitation=null
        if(upgraded||secret==null){stop("Unexpected upgrade");return}
        upgraded=true;message="Checking host admission"
        dispatch(policy.begin(true,"tihulu-touch-v1",secret,now),now)
    }
    private fun enqueue(frame:ByteArray,now:Long) {
        if(!slot.admit(frame,now)){frame.fill(0);stop("Transport backpressure")}
    }
    private fun dispatch(action:MobileLanSession.Action,now:Long) {
        if(closed)return
        try {
            when(action) {
                MobileLanSession.Action.Wait -> if(phase==MobileLanSession.Phase.READY)message="Ready · assigned lane"
                is MobileLanSession.Action.Close -> stop(action.reason)
                is MobileLanSession.Action.Binary -> {
                    try {enqueue(encoder.invitation(action.bytes),now)}
                    finally {action.bytes.fill(0)}
                }
                is MobileLanSession.Action.Text -> {
                    try {enqueue(encoder.text(action.bytes),now)}
                    finally {action.bytes.fill(0)}
                }
            }
        }catch(_:Exception){stop("Transport frame rejected")}
    }
    fun receive(event:BoundedLanFrameReader.Event,now:Long) {
        if(!check(now))return
        if(!upgraded){stop("Unexpected response before upgrade");return}
        when(event) {
            BoundedLanFrameReader.Event.Close -> stop("Host closed")
            is BoundedLanFrameReader.Event.Pong -> Unit
            is BoundedLanFrameReader.Event.Ping -> {
                // No second frame can queue behind a blocked write.
                try {enqueue(encoder.pong(event.payload),now)}
                catch(_:Exception){stop("Invalid control frame")}
            }
            is BoundedLanFrameReader.Event.Text -> {
                if(event.value.length>256||event.value.any{it.code>=128}){stop("Invalid response");return}
                if(slot.busy) {
                    // One bounded response may race a local write return.
                    // Do not acknowledge it, refresh time or advance policy
                    // until the exact write has successfully completed.
                    if(!slot.writing||earlyReply!=null){stop("Unexpected early response");return}
                    earlyReply=event.value
                } else dispatch(policy.receive(event.value,now),now)
            }
        }
    }
    fun poll(now:Long) {
        if(check(now)&&upgraded)dispatch(policy.poll(now),now)
    }
    fun offer(output:AirOutput,observedAt:Long,now:Long,deadlines:Map<Int,Long> = emptyMap()) {
        if(check(now)&&upgraded&&phase==MobileLanSession.Phase.READY)
            dispatch(policy.offer(output,observedAt,now,deadlines),now)
    }
    fun take(now:Long):LanWriteSlot.Lease? {
        if(!check(now))return null
        return slot.take(now)
    }
    fun complete(lease:LanWriteSlot.Lease,now:Long) {
        if(!check(now))return
        if(!slot.complete(lease,now)){stop("Unexpected write completion");return}
        val response=earlyReply
        earlyReply=null
        if(response!=null)dispatch(policy.receive(response,now),now)
    }
    fun projection(mode:AirMode,role:HandRole,orientation:Orientation,mirror:Boolean,
        near:Double,far:Double,allowEstimatedDepth:Boolean):AirProjection? =
        if(closed)null else policy.newProjection(mode,role,orientation,mirror,near,far,allowEstimatedDepth)
    fun stop(reason:String="Stopped explicitly") {
        if(closed)return
        closed=true;invitation=null;earlyReply=null;message=reason
        slot.retire();policy.abort()
    }
}
