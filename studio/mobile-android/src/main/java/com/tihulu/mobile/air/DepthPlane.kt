package com.tihulu.mobile.air

import java.nio.ByteBuffer
import kotlin.math.abs

/** Pure, stride-aware sampling. Input coordinates are already aligned to
 * the depth plane; raw RGB coordinates must not be passed directly. */
class DepthPlane(private val bytes:ByteBuffer,val width:Int,val height:Int,
    private val rowStride:Int,private val pixelStride:Int,private val sampleBytes:Int) {
    fun read(x:Int,y:Int):Int? {
        if(width !in 1..8192||height !in 1..8192||sampleBytes !in 1..2||
            pixelStride<sampleBytes||rowStride.toLong()<(width-1L)*pixelStride+sampleBytes||
            x !in 0 until width||y !in 0 until height) return null
        val i=y.toLong()*rowStride+x.toLong()*pixelStride
        if(i<0||i+sampleBytes>bytes.remaining())return null
        val p=bytes.position()+i.toInt()
        val low=bytes.get(p).toInt() and 255
        return if(sampleBytes==1)low else low or ((bytes.get(p+1).toInt() and 255) shl 8)
    }
}
object DepthNeighborhood {
    private fun consensus(values:List<Double>):Double? {
        if(values.size<5)return null
        val sorted=values.sorted();val median=sorted[sorted.size/2]
        val cluster=sorted.filter {abs(it-median)<=maxOf(.03,median*.08)}
        return if(cluster.size>=5)cluster[cluster.size/2] else null
    }
    private fun interior(depth:DepthPlane,x:Int,y:Int)=x>0&&y>0&&x<depth.width-1&&y<depth.height-1
    fun camera2(depth:DepthPlane,x:Int,y:Int):Double? {
        if(!interior(depth,x,y))return null
        val samples=ArrayList<Int>(9)
        for(row in y-1..y+1)for(col in x-1..x+1)samples.add(depth.read(col,row)?:return null)
        return DepthPolicy.palmDepth(samples)
    }
    fun arCore(depth:DepthPlane,confidence:DepthPlane,x:Int,y:Int):Double? {
        if(!interior(depth,x,y)||confidence.width!=depth.width||confidence.height!=depth.height)return null
        val values=ArrayList<Double>(9)
        for(row in y-1..y+1)for(col in x-1..x+1) {
            val mm=depth.read(col,row)?:return null
            val c=confidence.read(col,row)?:return null
            if(mm>0&&c>=192)values.add(mm/1000.0)
        }
        return consensus(values)
    }
}
