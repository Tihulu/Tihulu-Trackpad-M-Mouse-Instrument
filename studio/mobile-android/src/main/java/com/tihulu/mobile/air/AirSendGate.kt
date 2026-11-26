package com.tihulu.mobile.air

/**
 * Single exclusive lane, single-use diagnostic sender policy. A future
 * authenticated transport must already have negotiated all group-neutral
 * families and transferred exclusive sequence/lane ownership, and must
 * dispatch Send synchronously or close. ACK is the exact current socket
 * response "accepted"; never forward responses from an old connection.
 * The transport must independently poll and actually close on Close.
 * No sockets, no MIDI, no implicit retry or reconnection.
 */
class AirSendGate(private val lane:AirWireLane,initialSequence:Long) {
    sealed interface Action {
        data object Wait:Action
        data class Send(val bytes:ByteArray):Action
        data class Close(val reason:String):Action
    }
    init {require(initialSequence in 0 until MAX_SEQUENCE)}
    companion object {
        const val MAX_SEQUENCE=9_007_199_254_740_991L
        const val ACK_NS=220_000_000L
        const val FRESH_NS=150_000_000L
        const val PACE_NS=13_000_000L
        const val REFRESH_NS=50_000_000L
        const val IDLE_NS=1_000_000_000L
    }
    private var sequence=initialSequence
    private var started=false
    private var admitted=false
    private var closed=false
    private var clock:Long?=null
    private var lastSend:Long?=null
    private var pendingAt:Long?=null
    private var pendingNeutral=false
    private var sent=AirOutput()
    private var sample:AirOutput?=null
    private var sampledAt:Long?=null
    private var lastInput:Long?=null
    private var releaseDebtAt:Long?=null
    private var neutralFence=false
    private var neutralConfirmedAt:Long?=null
    private fun close(reason:String):Action.Close {
        closed=true;admitted=false;pendingAt=null;sample=null;releaseDebtAt=null
        return Action.Close(reason)
    }
    private fun check(now:Long):Action.Close? {
        if(closed)return Action.Close("Already closed")
        if(now<0||clock?.let {now<it}==true)return close("Invalid monotonic clock")
        clock=now
        if(pendingAt?.let {now-it>=ACK_NS}==true)return close("ACK timeout")
        if(releaseDebtAt?.let {now-it>=FRESH_NS}==true)return close("Release overdue")
        return null
    }
    private fun send(value:AirOutput,now:Long,heartbeat:Boolean=false):Action {
        if(sequence>=MAX_SEQUENCE)return close("Sequence exhausted")
        val next=sequence+1
        val bytes=try {
            if(heartbeat) """{"kind":"heartbeat","version":1,"sequence":$next}""".toByteArray(Charsets.US_ASCII)
            else lane.encode(value,next)
        }catch(_:IllegalArgumentException){return close("Invalid logical snapshot")}
        sequence=next;pendingAt=now;lastSend=now
        pendingNeutral=!heartbeat&&value==AirOutput()
        if(!heartbeat)sent=value
        return Action.Send(bytes)
    }
    fun begin(now:Long):Action {
        check(now)?.let {return it}
        if(started)return close("Duplicate start")
        started=true
        return send(AirOutput(),now)
    }
    fun acknowledge(response:String,now:Long):Action {
        check(now)?.let {return it}
        if(!started||pendingAt==null||response!="accepted")return close("Unexpected ACK")
        pendingAt=null
        if(pendingNeutral) {
            admitted=true;neutralFence=false;releaseDebtAt=null;neutralConfirmedAt=now
            // Do not reuse a gesture observed before release ACK.
            sample=null;sampledAt=null
        }
        pendingNeutral=false
        return poll(now)
    }
    /** Observation time is local monotonic time, not a remote timestamp.
     * No attack queue: changed non-neutral note masks during ACK wait fail
     * closed rather than replaying old attacks. Continuous levels coalesce.
     * Neutral has priority and blocks new attacks until its ACK. */
    fun offer(output:AirOutput,observedAt:Long,now:Long):Action {
        check(now)?.let {return it}
        if(!started)return close("Not started")
        if(observedAt<0||observedAt>now||now-observedAt>=FRESH_NS||
            lastInput?.let {observedAt<=it}==true)return close("Stale or replayed observation")
        lastInput=observedAt
        try {lane.encode(output,1)}catch(_:IllegalArgumentException){return close("Invalid logical snapshot")}
        if(!admitted||neutralFence||neutralConfirmedAt?.let {observedAt<=it}!=false)return Action.Wait
        if(output==AirOutput()) {
            val hadActive=sent!=AirOutput()
            sample=null;sampledAt=null
            if(hadActive) {neutralFence=true;releaseDebtAt=now}
            return poll(now)
        }
        val previous=sample
        if(previous!=null&&previous.keys!=output.keys&&previous.keys!=0&&output.keys!=0&&
            (pendingAt!=null||lastSend?.let {now-it<PACE_NS}==true))
            return close("Discrete edge cannot be delivered on time")
        sample=output;sampledAt=observedAt
        return poll(now)
    }
    fun poll(now:Long):Action {
        check(now)?.let {return it}
        if(!started||!admitted)return Action.Wait
        val fresh=sampledAt?.let {now-it<FRESH_NS}==true
        if(!fresh&&sample!=null) {
            sample=null;sampledAt=null
            if(sent!=AirOutput()&&!neutralFence){neutralFence=true;releaseDebtAt=now}
        }
        // At the source deadline, do not wait another ACK window with active debt.
        if(neutralFence&&pendingAt!=null&&sent!=AirOutput()&&lastInput?.let {now-it>=FRESH_NS}==true)
            return close("Source expired while active ACK outstanding")
        if(pendingAt!=null)return Action.Wait
        val elapsed=lastSend?.let {now-it}?:Long.MAX_VALUE
        if(elapsed<PACE_NS)return Action.Wait
        if(neutralFence)return send(AirOutput(),now)
        val value=sample
        if(value!=null&&(value!=sent||elapsed>=REFRESH_NS))return send(value,now)
        if(sent==AirOutput()&&elapsed>=IDLE_NS)return send(AirOutput(),now,heartbeat=true)
        return Action.Wait
    }
    /** Caller must close transport immediately, not send stale release. */
    fun abort():Action.Close=close("Stopped explicitly")
}
