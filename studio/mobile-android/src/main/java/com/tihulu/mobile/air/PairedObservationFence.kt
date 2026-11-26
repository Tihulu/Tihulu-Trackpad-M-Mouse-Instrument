package com.tihulu.mobile.air

/**
 * UI capture generation fence. The transport still independently enforces
 * all source/ACK deadlines. No synthetic observation timestamps or replay
 * of an ARCore latest-reading snapshot as a new camera frame.
 */
internal class PairedObservationFence(private val startedAt:Long) {
    enum class Verdict { SEND, DUPLICATE, RETIRE }
    private var last:Long?=null
    private var closed=false
    fun observe(observedAt:Long,now:Long,latestReading:Boolean=false):Verdict {
        if(closed)return Verdict.RETIRE
        if(startedAt<0||observedAt<startedAt||now<observedAt||now-observedAt>=AirSendGate.FRESH_NS||
            last?.let{observedAt<it}==true){
            closed=true;return Verdict.RETIRE
        }
        if(last==observedAt) {
            if(latestReading)return Verdict.DUPLICATE
            closed=true;return Verdict.RETIRE
        }
        last=observedAt
        return Verdict.SEND
    }
    fun retire(){closed=true}
}
