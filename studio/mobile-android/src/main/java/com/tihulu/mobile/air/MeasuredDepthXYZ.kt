package com.tihulu.mobile.air

import kotlin.math.abs

/** A single isolated depth return (hand or object). No RGB registration or
 * object classification is assumed. Camera2 range is measured in metres. */
data class MeasuredXYZ(val x:Double, val y:Double, val metres:Double, val confidence:Double)

data class XYZVolume(val left:Double=0.0, val right:Double=1.0, val bottom:Double=0.0,
                     val top:Double=1.0, val near:Double=.25, val far:Double=.85) {
    val valid get() = left in 0.0..1.0 && right in 0.0..1.0 && right-left >= .05 &&
        bottom in 0.0..1.0 && top in 0.0..1.0 && top-bottom >= .05 &&
        near in .1..3.0 && far in .1..3.0 && far-near >= .1
    fun axes(p:MeasuredXYZ,mask:Int):List<Double?>? {
        if(!valid || mask !in 1..7 || p.x !in left..right || p.y !in bottom..top ||
            p.metres !in near..far || p.confidence !in .65..1.0)return null
        return listOf((p.x-left)/(right-left),(p.y-bottom)/(top-bottom),(p.metres-near)/(far-near))
            .mapIndexed { i,value -> value.takeIf { mask and (1 shl i) != 0 } }
    }
}

object MeasuredDepthXYZ {
    /** Sample a bounded grid. Reject a broad background, multiple objects, or
     * a target without a coherent measured return near the component centre. */
    fun read(plane:DepthPlane, volume:XYZVolume, clockwise:Int):MeasuredXYZ? {
        if(!volume.valid || clockwise !in listOf(0,90,180,270)) return null
        val width=minOf(40,plane.width-2)
        val height=minOf(32,plane.height-2)
        if(width<5 || height<5) return null
        fun px(col:Int)=1+col*(plane.width-3)/(width-1)
        fun py(row:Int)=1+row*(plane.height-3)/(height-1)
        val samples=DoubleArray(width*height)
        for(row in 0 until height)for(col in 0 until width){
            val raw=plane.read(px(col),py(row))?:return null
            val d=DepthPolicy.decode(raw)
            if(d!=null && d in volume.near..volume.far)samples[row*width+col]=d
        }
        val visited=BooleanArray(samples.size)
        val queue=IntArray(samples.size)
        var target:MeasuredXYZ?=null
        for(seed in samples.indices){
            if(visited[seed] || samples[seed]==0.0)continue
            queue[0]=seed; visited[seed]=true
            var head=0; var tail=1; var sumX=0; var sumY=0
            while(head<tail){
                val i=queue[head++]; val col=i%width; val row=i/width
                sumX+=col;sumY+=row
                fun add(next:Int) {
                    if(!visited[next] && samples[next]!=0.0 &&
                        abs(samples[i]-samples[next])<=maxOf(.04,samples[i]*.10)){
                        visited[next]=true;queue[tail++]=next
                    }
                }
                if(col>0)add(i-1)
                if(col+1<width)add(i+1)
                if(row>0)add(i-width)
                if(row+1<height)add(i+width)
            }
            if(tail<4)continue
            if(target!=null || tail>samples.size/3)return null
            val cx=sumX.toDouble()/tail;val cy=sumY.toDouble()/tail
            var nearest=seed;var best=Double.POSITIVE_INFINITY
            for(j in 0 until tail){
                val i=queue[j]; val dx=i%width-cx; val dy=i/width-cy; val distance=dx*dx+dy*dy
                if(distance<best){nearest=i;best=distance}
            }
            val x=px(nearest%width); val y=py(nearest/width)
            val metres=DepthNeighborhood.camera2(plane,x,y)?:return null
            val raw=plane.read(x,y)?:return null
            if(metres !in volume.near..volume.far || abs(metres-samples[nearest])>maxOf(.03,metres*.08))return null
            val confidence=raw ushr 13
            val u=x.toDouble()/(plane.width-1); val v=y.toDouble()/(plane.height-1)
            val (right,up)=when(clockwise){
                0->u to 1-v
                90->1-v to 1-u
                180->1-u to v
                else->v to u
            }
            target=MeasuredXYZ(right,up,metres,if(confidence==0)1.0 else (confidence-1)/7.0)
        }
        return target
    }
}

class MeasuredXYZTracking(private val volume:XYZVolume,private val mask:Int) {
    private var candidate:Long?=null
    private var watermark=-1L
    private var clock=-1L
    fun observe(point:MeasuredXYZ?, at:Long, now:Long):AirOutput {
        val fresh=at>watermark && now>=clock && at>=0 && at<=now && now-at<AirSendGate.FRESH_NS
        clock=maxOf(clock,now)
        val axes=point?.let { volume.axes(it,mask) }
        if(!fresh || axes==null){candidate=null;watermark=maxOf(watermark,clock);return AirOutput()}
        val last=candidate
        // Mirror Swift: a delayed drain cannot extend an expired acquisition
        // with a buffered measurement captured before its expiry.
        if(last!=null && now-last>=AirSendGate.FRESH_NS){
            if(at-last<AirSendGate.FRESH_NS){
                candidate=null;watermark=maxOf(watermark,clock);return AirOutput()
            }
            watermark=at;candidate=at;return AirOutput()
        }
        watermark=at;candidate=at
        return if(last!=null && at-last<AirSendGate.FRESH_NS)AirOutput(xyz=axes) else AirOutput()
    }
    /** Expire on silence and fence previously captured measurements. */
    fun expire(now:Long):Boolean {
        val last=candidate
        val invalid=now<0 || now<clock
        clock=maxOf(clock,now)
        if(last==null)return false
        if(!invalid && now-last<AirSendGate.FRESH_NS)return false
        candidate=null;watermark=maxOf(watermark,clock)
        return true
    }
}

internal class MeasuredXYZKeys(mask:Int, private val axis:Int) {
    private val keys=(0..24).filter { mask and (1 shl it)!=0 }
    private var zone:Int?=null
    init { require(mask in 1 until (1 shl 25) && axis in 0..2) }
    fun output(levels: List<Double?>?):AirOutput {
        val value=levels?.getOrNull(axis)
        if(value==null || value !in 0.0..1.0){zone=null;return AirOutput()}
        val position=value*keys.size
        val previous=zone
        val selected=if(previous!=null && position>=previous-.12 && position<previous+1.12)previous
            else minOf(keys.lastIndex,position.toInt())
        zone=selected
        return AirOutput(keys=1 shl keys[selected])
    }
}
