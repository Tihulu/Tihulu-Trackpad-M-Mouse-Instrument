package com.tihulu.mobile.air

/** Single-use protocol policy, no socket or certificate implementation.
 * Serialize calls, dispatch immediately and poll independently. Only the
 * authenticated current connection can supply begin/receive events. */
class MobileLanSession(private val selection:Selection) {
    sealed interface Selection { data object Keys:Selection; data class Helper(val index:Int):Selection; data class XYZ(val mask:Int):Selection; data class Hybrid(val mask:Int):Selection }
    enum class Phase { IDLE, ADMISSION, CAPABILITIES, NEUTRAL_DELAY, NEUTRAL_ACK, READY, RECONFIGURING, CLOSED }
    sealed interface Action {
        data object Wait:Action
        data class Binary(val bytes:ByteArray):Action
        data class Text(val bytes:ByteArray):Action
        data class Close(val reason:String):Action
    }
    var phase=Phase.IDLE;private set
    private var clock:Long?=null
    private var pendingAt:Long?=null
    private var capabilitiesSentAt:Long?=null
    private var gate:AirSendGate?=null
    private var lane:AirWireLane?=null
    private var manifest: MobileLanCapabilities.Manifest? = null
    val readyManifest: MobileLanCapabilities.Manifest?
        get() = if (phase == Phase.READY) manifest else null
    private fun close(reason:String):Action.Close {phase=Phase.CLOSED;gate=null;lane=null;manifest=null;pendingAt=null;return Action.Close(reason)}
    private fun check(now:Long):Action.Close? {
        if(phase==Phase.CLOSED)return Action.Close("Already closed")
        if(now<0||clock?.let{now<it}==true)return close("Invalid monotonic clock")
        clock=now
        val limit=if(phase==Phase.ADMISSION)3_000_000_000L else AirSendGate.ACK_NS
        if(pendingAt?.let{now-it>=limit}==true)return close("Negotiation timeout")
        return null
    }
    fun begin(trustedTLS:Boolean,subprotocol:String,invitation:String,now:Long):Action {
        check(now)?.let{return it}
        if(phase!=Phase.IDLE||!trustedTLS||subprotocol!="tihulu-touch-v1")return close("Untrusted or invalid connection")
        val bytes=MobileLanEndpoint.invitationBytes(invitation)?:return close("Untrusted or invalid connection")
        phase=Phase.ADMISSION;pendingAt=now
        return Action.Binary(bytes)
    }
    private fun translate(a:AirSendGate.Action):Action=when(a){
        AirSendGate.Action.Wait->Action.Wait
        is AirSendGate.Action.Send->Action.Text(a.bytes)
        is AirSendGate.Action.Close->close(a.reason)
    }
    fun receive(text:String,now:Long):Action {
        check(now)?.let{return it}
        if(text.length>256||text.any{it.code>=128})return close("Invalid response")
        return when(phase){
            Phase.ADMISSION->{
                if(text!="admitted")return close("Admission refused")
                phase=Phase.CAPABILITIES;pendingAt=now;capabilitiesSentAt=now
                Action.Text("""{"kind":"capabilities","version":7,"sequence":1}""".toByteArray(Charsets.US_ASCII))
            }
            Phase.CAPABILITIES->{
                val manifest=MobileLanCapabilities.parse(text,selection is Selection.Hybrid)?:return close("Unsupported manifest")
                lane = when (val selected = selection) {
                    Selection.Keys -> manifest.keysLane()
                    is Selection.Helper -> manifest.helperLane(selected.index)
                    is Selection.Hybrid -> manifest.hybridLane(selected.mask)
                    is Selection.XYZ -> manifest.xyzLane(selected.mask)
                }
                if(lane==null)return close("Unassigned lane")
                this.manifest = manifest
                pendingAt=null;phase=Phase.NEUTRAL_DELAY;poll(now)
            }
            Phase.NEUTRAL_ACK,Phase.READY,Phase.RECONFIGURING->{
                val sender=gate?:return close("Missing sender")
                val initial=phase==Phase.NEUTRAL_ACK
                val result=sender.acknowledge(text,now)
                if(initial&&result==AirSendGate.Action.Wait)phase=Phase.READY
                if(phase==Phase.RECONFIGURING&&sender.neutralReady)phase=Phase.READY
                translate(result)
            }
            else->close("Unexpected response")
        }
    }
    fun poll(now:Long):Action {
        check(now)?.let{return it}
        if(phase==Phase.NEUTRAL_DELAY){
            val at=capabilitiesSentAt?:return close("Missing negotiation")
            if(now-at>=AirSendGate.ACK_NS)return close("Neutral setup overdue")
            if(now-at<AirSendGate.PACE_NS)return Action.Wait
            val sender=AirSendGate(lane?:return close("Missing lane"),1)
            gate=sender;phase=Phase.NEUTRAL_ACK
            return translate(sender.begin(now))
        }
        if(phase==Phase.NEUTRAL_ACK||phase==Phase.READY||phase==Phase.RECONFIGURING){
            val sender=gate?:return close("Missing sender")
            val result=sender.poll(now)
            if(phase==Phase.RECONFIGURING&&sender.neutralReady)phase=Phase.READY
            return translate(result)
        }
        return Action.Wait
    }
    fun offer(output:AirOutput,observedAt:Long,now:Long,stringDeadlines:Map<Int,Long> = emptyMap()):Action {
        check(now)?.let{return it}
        if(phase!=Phase.READY)return poll(now)
        return translate(gate?.offer(output,observedAt,now,stringDeadlines)?:return close("Missing sender"))
    }
    /** A mode change retains exactly the existing lane, not a new host
     * assignment. The caller must retire old camera callbacks first. */
    internal fun pauseForModeChange(now:Long):Action {
        check(now)?.let{return it}
        if(phase!=Phase.READY)return close("Mode change requires ready session")
        phase=Phase.RECONFIGURING
        return translate(gate?.requestNeutral(now)?:return close("Missing sender"))
    }
    /** A paired projection may be constructed only after neutral ACK.
     * It uses the confirmed mask, never the diagnostic full keyboard. */
    fun newProjection(mode:AirMode,role:HandRole=HandRole.SINGLE,
                      orientation:Orientation=Orientation.UP,mirror:Boolean=false,
                      near:Double=.25,far:Double=.85,allowEstimatedDepth:Boolean=false):AirProjection? {
        val assigned=readyManifest?:return null
        val authorized=when(val selected=selection) {
            is Selection.XYZ, is Selection.Hybrid -> return null
            Selection.Keys -> if(!mode.isHelper&&assigned.keysLane()!=null)assigned.piano else return null
            is Selection.Helper -> if(mode.isHelper&&assigned.helperLane(selected.index)!=null)0 else return null
        }
        return try { AirProjection(mode,authorized,role,orientation,mirror,near,far,allowEstimatedDepth) }
        catch(_:IllegalArgumentException){null}
    }
    fun abort():Action=close("Stopped explicitly")
}
