package com.tihulu.mobile.air

import kotlin.math.hypot
import kotlin.math.min

object FingerGeometry {
    fun count(chains:List<Triple<Point,Point,Point>>):Int? {
        if (chains.size!=5) return null
        var count=0
        for ((a,b,c) in chains) {
            if (!a.valid || !b.valid || !c.valid) return null
            val ax=a.x-b.x; val ay=a.y-b.y; val bx=c.x-b.x;val by=c.y-b.y
            val length=hypot(ax,ay)*hypot(bx,by)
            if (length<=0.00001) return null
            val cosine=(ax*bx+ay*by)/length
            if (cosine<=-.78) count++ else if (cosine<-.35) return null
        }
        return count
    }
}
enum class AirMode { PINCH_KEYS, CHORDS, STRINGS, HORIZONTAL, VERTICAL, APERTURE, SPEED,
    PINCH_HELPER, TOGGLE_HELPER, BEAM_KEYS, BEAM_HELPER }
enum class HandRole { SINGLE, LEFT, RIGHT }
enum class Orientation { UP, CLOCKWISE, DOWN, COUNTERCLOCKWISE }
data class AirOutput(val keys:Int=0,val level:Double?=null)
data class AlignedDepth(val meters:Double,val provenance:DepthProvenance,
    val rgbNs:Long,val depthNs:Long,val role:HandRole)

/** Local diagnostics; output is logical only. No socket or MIDI ownership.
 * Sensor receipt clock is monotonic; raw hardware synchronization is separate.
 * A consumer must call expire independently even if no camera callback occurs. */
class AirProjection(private val mode:AirMode, private val authorized:Int,
    private val role:HandRole=HandRole.SINGLE, private val orientation:Orientation=Orientation.UP,
    private val mirror:Boolean=false, private val near:Double=.25,private val far:Double=.85,
    private val allowEstimatedDepth:Boolean=false) {
    private val keyList=(0..24).filter {(authorized and (1 shl it))!=0}
    private val shapes=listOf(listOf(0,4,7),listOf(2,5,9),listOf(4,7,11),listOf(5,9,12),listOf(7,11,14))
    private val helper=mode in setOf(AirMode.HORIZONTAL,AirMode.VERTICAL,AirMode.APERTURE,AirMode.SPEED,AirMode.PINCH_HELPER,AirMode.TOGGLE_HELPER,AirMode.BEAM_HELPER)
    private val beam=mode==AirMode.BEAM_HELPER||mode==AirMode.BEAM_KEYS
    init {
        require(authorized in 0 until (1 shl 25) && (helper||keyList.isNotEmpty()))
        require(mode!=AirMode.CHORDS||role!=HandRole.SINGLE)
        require(mode!=AirMode.STRINGS||keyList.size>=3)
        require(mode!=AirMode.CHORDS||shapes.any { shape->shape.all {it in keyList} })
        require(near.isFinite()&&far.isFinite()&&near>=.1&&far<=3&&far-near>=.1)
    }
    private var last:Long?=null
    private var lastAcquisition:Long?=null
    private var tracked=0
    private var prior:Hand?=null
    private var armed=false
    private var pinched=false
    private var latched=false
    private var held:Int?=null
    private var chordArmed=false
    private var chord:Int?=null
    private var pendingChord:Int?=null
    private var pendingAt=0L
    private var beamZone:Int?=null
    private val ringing=mutableMapOf<Int,Long>()
    private val stringSides=IntArray(3)
    /** Immutable snapshot of the independently expiring string pulses. */
    val stringDeadlines: Map<Int,Long> get() = ringing.toMap()
    private fun ringingOutput()=AirOutput(keys=ringing.keys.fold(0){m,k->m or (1 shl k)})
    private fun reset() {
        tracked=0;prior=null;armed=false;pinched=false;latched=false;held=null
        chordArmed=false;chord=null;pendingChord=null;beamZone=null;ringing.clear();stringSides.fill(0)
    }
    fun expire(now:Long):AirOutput? {
        val t=last ?: return AirOutput()
        if (now<t||now-t>=150_000_000L) {reset();return AirOutput()}
        if(mode==AirMode.STRINGS && ringing.entries.removeAll {now>=it.value}) return ringingOutput()
        return null
    }
    private fun hand(frame:Frame,role:HandRole):Observation? {
        val candidates=when(role) {
            HandRole.SINGLE -> frame.hands
            HandRole.LEFT -> frame.hands.filter {it.side=="left"&&it.score.isFinite()&&it.score>=.75f}
            HandRole.RIGHT -> frame.hands.filter {it.side=="right"&&it.score.isFinite()&&it.score>=.75f}
        }
        return candidates.singleOrNull()?.takeIf { val h=it.hand
            listOf(h.x,h.y,h.aperture).all {v->v.isFinite()&&v in 0.0..1.0}
        }
    }
    private fun transform(h:Hand):Hand {
        val (x,y)=when(orientation) {
            Orientation.UP -> h.x to h.y
            Orientation.CLOCKWISE -> h.y to 1-h.x
            Orientation.DOWN -> 1-h.x to 1-h.y
            Orientation.COUNTERCLOCKWISE -> 1-h.y to h.x
        }
        return Hand(if(mirror) 1-x else x,y,h.aperture)
    }
    fun receive(frame:Frame,now:Long,depth:AlignedDepth?=null):AirOutput {
        val t=frame.timeNs;val old=last
        val acquisition=frame.acquisitionNs;val previousAcquisition=lastAcquisition
        if(t<0||now<t||now-t>=150_000_000L||(old!=null&&t<=old)||acquisition<0||
            (previousAcquisition!=null&&acquisition<=previousAcquisition)) {reset();return AirOutput()}
        lastAcquisition=acquisition
        if(old!=null&&t-old>=150_000_000L) reset()
        last=t
        val observation=hand(frame,role) ?: run {reset();return AirOutput()}
        val selected=if(mode==AirMode.CHORDS) hand(frame,if(role==HandRole.LEFT)HandRole.RIGHT else HandRole.LEFT) else null
        if(mode==AirMode.CHORDS && (selected?.fingers ?: -1) !in 0..5) {reset();return AirOutput()}
        val measured=if(beam) depth?.takeIf {
            it.role==role&&it.rgbNs==frame.acquisitionNs&&DepthPolicy.sameAcquisition(it.rgbNs,it.depthNs)&&
            it.meters.isFinite()&&it.meters in near..far&&
            (it.provenance==DepthProvenance.CAMERA2_DEPTH16||
             (allowEstimatedDepth&&it.provenance==DepthProvenance.ARCORE_ESTIMATED_OR_FUSED))
        }?.meters else null
        if(beam&&measured==null) {reset();return AirOutput()}
        val h=transform(observation.hand)
        tracked=min(2,tracked+1)
        if(tracked<2) return AirOutput()
        val previous=prior;prior=h
        if(mode==AirMode.CHORDS) {
            val count=selected!!.fingers!!
            if(count==0) {chordArmed=true;chord=null;pendingChord=null;armed=false;pinched=false;held=null}
            else if(chordArmed&&count!=chord) {
                if(pendingChord!=count) {pendingChord=count;pendingAt=t;held=null}
                if(t-pendingAt>=120_000_000L) {chord=count;pendingChord=null}
            } else if(count==chord) pendingChord=null
        }
        if(h.aperture>=.35) {armed=true;pinched=false;held=null}
        val edge=armed&&!pinched&&h.aperture<=.18
        if(edge) {pinched=true;latched=!latched}
        return when(mode) {
            AirMode.HORIZONTAL -> AirOutput(level=h.x)
            AirMode.VERTICAL -> AirOutput(level=h.y)
            AirMode.APERTURE -> AirOutput(level=h.aperture)
            AirMode.SPEED -> AirOutput(level=if(previous==null||old==null)0.0 else
                (hypot(h.x-previous.x,h.y-previous.y)/maxOf(.001,(t-old)/1e9)/5).coerceIn(0.0,1.0))
            AirMode.PINCH_HELPER -> AirOutput(level=if(pinched)1.0 else 0.0)
            AirMode.TOGGLE_HELPER -> AirOutput(level=if(latched)1.0 else 0.0)
            AirMode.PINCH_KEYS -> {
                if(edge) held=keyList[min(keyList.lastIndex,(h.x*keyList.size).toInt())]
                AirOutput(keys=held?.let {1 shl it}?:0)
            }
            AirMode.CHORDS -> {
                if(chord!=selected!!.fingers) held=null
                if(edge&&chord!=null&&chord==selected.fingers) held=chord
                val mask=held?.let {slot->shapes[slot-1].fold(0){m,k->m or (1 shl k)}}?:0
                AirOutput(keys=if((mask and authorized)==mask)mask else 0)
            }
            AirMode.STRINGS -> {
                ringing.entries.removeAll {now>=it.value}
                for(i in 0..2) {
                    val center=(i+1)/4.0
                    val side=if(h.x<center-.025)-1 else if(h.x>center+.025)1 else 0
                    if(side==0) continue
                    if(stringSides[i]!=0&&stringSides[i]!=side&&previous!=null&&now-t<120_000_000L)
                        ringing[keyList[i]]=t+120_000_000L
                    stringSides[i]=side
                }
                ringingOutput()
            }
            AirMode.BEAM_HELPER -> AirOutput(level=((far-measured!!)/(far-near)).coerceIn(0.0,1.0))
            AirMode.BEAM_KEYS -> {
                val count=min(8,keyList.size)
                val position=((far-measured!!)/(far-near)).coerceIn(0.0,1.0)*count
                val current=beamZone
                val next=if(current!=null&&position>=current-.15&&position<current+1+.15)current
                    else min(count-1,position.toInt())
                beamZone=next;AirOutput(keys=1 shl keyList[next])
            }
        }
    }
}
