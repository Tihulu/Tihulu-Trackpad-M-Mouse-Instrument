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
    private var stringDeadlines:Map<Int,Long> = emptyMap()
    private var lastInput:Long?=null
    private var releaseDebtAt:Long?=null
    private var neutralFence=false
    private var neutralConfirmedAt:Long?=null
    private var releaseSourceAt:Long?=null
    private var releaseStringDeadline:Long?=null
    private fun close(reason:String):Action.Close {
        closed=true;admitted=false;pendingAt=null;sample=null;stringDeadlines=emptyMap();releaseDebtAt=null;releaseSourceAt=null;releaseStringDeadline=null
        return Action.Close(reason)
    }
    private fun check(now:Long):Action.Close? {
        if(closed)return Action.Close("Already closed")
        if(now<0||clock?.let {now<it}==true)return close("Invalid monotonic clock")
        clock=now
        if(pendingAt?.let {now-it>=ACK_NS}==true)return close("ACK timeout")
        if(releaseDebtAt?.let {now-it>=FRESH_NS}==true)return close("Release overdue")
        if(sent!=AirOutput()&&pendingAt!=null&&!pendingNeutral&&releaseSourceAt?.let{now-it>=FRESH_NS}==true)
            return close("Source expired while active ACK outstanding")
        if(sent.keys!=0&&releaseStringDeadline?.let{now>=it}==true&&
            (pendingAt!=null||lastSend?.let{now-it<PACE_NS}==true))
            return close("String release deadline blocked")
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
        if(sampledAt?.let {now-it>=FRESH_NS}==true&&sent!=AirOutput()&&!pendingNeutral)
            return close("Source expired while active ACK outstanding")
        if(expireStrings(now)&&!pendingNeutral)return close("String expired while active ACK outstanding")
        pendingAt=null
        if(pendingNeutral) {
            admitted=true;neutralFence=false;releaseDebtAt=null;neutralConfirmedAt=now
            releaseSourceAt=null;releaseStringDeadline=null
            // Do not reuse a gesture observed before release ACK.
            sample=null;sampledAt=null;stringDeadlines=emptyMap()
        }
        pendingNeutral=false
        return poll(now)
    }
    /** Observation time is local monotonic time, not a remote timestamp.
     * No attack queue: changed non-neutral note masks during ACK wait fail
     * closed rather than replaying old attacks. Continuous levels coalesce.
     * Neutral has priority and blocks new attacks until its ACK. */
    fun offer(output:AirOutput,observedAt:Long,now:Long,deadlines:Map<Int,Long> = emptyMap()):Action {
        check(now)?.let {return it}
        if(!started)return close("Not started")
        if(observedAt<0||observedAt>now||now-observedAt>=FRESH_NS||
            lastInput?.let {observedAt<=it}==true)return close("Stale or replayed observation")
        lastInput=observedAt
        try {lane.encode(output,1)}catch(_:IllegalArgumentException){return close("Invalid logical snapshot")}
        if(deadlines.isNotEmpty() && (output.xyz!=null || output.level!=null || deadlines.keys.any {it !in 0..24} ||
            deadlines.keys.fold(0){mask,key->mask or (1 shl key)}!=output.keys ||
            deadlines.values.any {it<=observedAt||it-observedAt>120_000_000L}))return close("Invalid string expiry")
        if(!admitted)return Action.Wait
        // A fresh arrival cannot erase a source gap that already expired.
        if(sampledAt?.let {now-it>=FRESH_NS}==true&&sent!=AirOutput()&&pendingAt!=null)
            return close("Source expired while active ACK outstanding")
        if(expireStrings(now)) {
            if(pendingAt!=null)return close("String expired while active ACK outstanding")
            if(lastSend?.let {now-it<PACE_NS}==true)return close("String release blocked by send pacing")
            // Do not replace an expired transmitted pulse with a new attack before releasing it.
            return poll(now)
        }
        expireSample(now)
        if(neutralFence||neutralConfirmedAt?.let {observedAt<=it}!=false)return poll(now)
        if(output==AirOutput()) {
            val hadActive=sent!=AirOutput()
            rememberReleaseDeadlines()
            sample=null;sampledAt=null;stringDeadlines=emptyMap()
            if(hadActive) {neutralFence=true;releaseDebtAt=observedAt}
            return poll(now)
        }
        val previous=sample
        if(previous!=null&&previous.keys!=output.keys&&previous.keys!=0&&output.keys!=0&&
            (pendingAt!=null||lastSend?.let {now-it<PACE_NS}==true))
            return close("Discrete edge cannot be delivered on time")
        sample = if (output.xyz == null) output else output.copy(xyz = output.xyz.toList())
        sampledAt=observedAt;stringDeadlines=deadlines.toMap()
        return poll(now)
    }
    private fun rememberReleaseDeadlines() {
        if(sent==AirOutput())return
        sampledAt?.let {at->releaseSourceAt=minOf(releaseSourceAt?:at,at)}
        val stringAt=stringDeadlines.filterKeys{sent.keys and (1 shl it)!=0}.values.minOrNull()
        if(stringAt!=null)releaseStringDeadline=minOf(releaseStringDeadline?:stringAt,stringAt)
    }
    /** Expire pulses independently of the sensor UI and ACK callbacks. */
    private fun expireStrings(now:Long):Boolean {
        val value=sample ?: return false
        val expired=stringDeadlines.filterValues {it<=now}
        if(expired.isEmpty())return false
        val mask=expired.keys.fold(0){m,key->m or (1 shl key)}
        stringDeadlines=stringDeadlines.filterKeys {it !in expired}
        val remaining=value.keys and mask.inv()
        sample=if(remaining==0)null else AirOutput(keys=remaining)
        if(remaining==0&&sent.keys!=0&&!neutralFence){
            neutralFence=true;releaseDebtAt=expired.values.minOrNull()
        }
        return (sent.keys and mask)!=0
    }
    private fun expireSample(now:Long) {
        val at=sampledAt ?: return
        if(now-at>=FRESH_NS) {
            sample=null;sampledAt=null;stringDeadlines=emptyMap()
            if(sent!=AirOutput()&&!neutralFence){neutralFence=true;releaseDebtAt=at+FRESH_NS}
        }
    }
    fun poll(now:Long):Action {
        check(now)?.let {return it}
        if(!started||!admitted)return Action.Wait
        val expiredActive=sampledAt?.let {now-it>=FRESH_NS}==true&&sent!=AirOutput()
        if(expireStrings(now)) {
            if(pendingAt!=null)return close("String expired while active ACK outstanding")
            if(lastSend?.let {now-it<PACE_NS}==true)return close("String release blocked by send pacing")
        }
        expireSample(now)
        check(now)?.let {return it}
        if(expiredActive&&pendingAt!=null)return close("Source expired while active ACK outstanding")
        if(pendingAt!=null)return Action.Wait
        val elapsed=lastSend?.let {now-it}?:Long.MAX_VALUE
        if(elapsed<PACE_NS)return Action.Wait
        if(neutralFence)return send(AirOutput(),now)
        val value=sample
        if(value!=null&&(value!=sent||elapsed>=REFRESH_NS))return send(value,now)
        if(sent==AirOutput()&&elapsed>=IDLE_NS)return send(AirOutput(),now,heartbeat=true)
        return Action.Wait
    }
    /** Explicit mode-change fence, not a fabricated sensor observation.
     * The caller stops the old capture generation before invoking this.
     * Preserve any earlier release debt and refuse to hide active string
     * expiry behind a pending ACK or pace limit. */
    internal val neutralReady:Boolean get()=started&&admitted&&!closed&&
        pendingAt==null&&!neutralFence&&sent==AirOutput()&&sample==null
    internal fun requestNeutral(now:Long):Action {
        check(now)?.let{return it}
        if(!started||!admitted)return close("Neutral transition before admission")
        val at=sampledAt
        if(at!=null&&now-at>=FRESH_NS&&sent!=AirOutput()&&pendingAt!=null&&!pendingNeutral)
            return close("Source expired while active ACK outstanding")
        val activeStrings=stringDeadlines.keys.any {sent.keys and (1 shl it)!=0}
        if(activeStrings&&!pendingNeutral&&(pendingAt!=null||lastSend?.let{now-it<PACE_NS}==true))
            return close("Mode change cannot delay string release")
        // Existing release debt is never moved forward. If the source
        // already expired, the earlier expiry is the release origin.
        val debt=minOf(releaseDebtAt?:now,now,
            if(at!=null&&now-at>=FRESH_NS)at+FRESH_NS else now)
        rememberReleaseDeadlines()
        sample=null;sampledAt=null;stringDeadlines=emptyMap()
        neutralFence=true;releaseDebtAt=debt
        return poll(now)
    }
    /** Caller must close transport immediately, not send stale release. */
    fun abort():Action.Close=close("Stopped explicitly")
}
