package com.tihulu.mobile.air

/** Separate UI ownership/liveness contract, NOT camera acquisition.
 * Every event or pulse must come from the current foreground, focused,
 * visible native view owner. The transport independently expires/closes.
 * A missed owner pulse is terminal even when neutral. No live wiring yet. */
internal class MobileTouchLiveLease(authorized:Int,armedAt:Long) {
    data class Snapshot(val output:AirOutput,val ownerAt:Long)
    private val ownership=MobileTouchOwnership(authorized)
    private var last=armedAt
    init {require(armedAt>=0)}
    val retired get()=ownership.retired
    val output get()=ownership.output
    fun retire(){ownership.retire()}
    private fun check(now:Long,ownerActive:Boolean):Boolean {
        if(retired||!ownerActive||now<=last||now-last>=AirSendGate.FRESH_NS){
            retire();return false
        }
        last=now;return true
    }
    fun event(change:MobileTouchOwnership.Change,contacts:List<MobileTouchKeys.Contact>,
              now:Long,ownerActive:Boolean):Snapshot? {
        if(!check(now,ownerActive))return null
        val value=ownership.update(change,contacts)?:return null
        return Snapshot(value,now)
    }
    fun pointerEvent(change:MobileTouchOwnership.Change,all:List<MobileTouchKeys.Contact>,
              changedID:Int?,now:Long,ownerActive:Boolean):Snapshot? {
        if(!check(now,ownerActive))return null
        val value=ownership.pointerTransition(change,all,changedID)?:return null
        return Snapshot(value,now)
    }
    /** Native view owner only, never background watchdog or network. */
    fun pulse(now:Long,ownerActive:Boolean):Snapshot? {
        if(!check(now,ownerActive))return null
        return Snapshot(ownership.output,now)
    }
}
