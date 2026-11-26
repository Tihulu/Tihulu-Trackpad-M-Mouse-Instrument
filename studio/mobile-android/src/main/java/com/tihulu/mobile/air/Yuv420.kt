package com.tihulu.mobile.air

import java.nio.ByteBuffer

/** Bounded conversion for a full YUV_420_888 CPU frame. Planes may have
 * independent row/pixel strides and interleaved chroma. No native packing. */
object Yuv420 {
    data class Plane(val bytes:ByteBuffer,val rowStride:Int,val pixelStride:Int)
    fun argb(width:Int,height:Int,y:Plane,u:Plane,v:Plane):IntArray? {
        if(width !in 1..4096||height !in 1..4096||width.toLong()*height>4_194_304)return null
        val cw=(width+1)/2;val ch=(height+1)/2
        fun valid(p:Plane,w:Int,h:Int):Boolean {
            val end=(h-1L)*p.rowStride+(w-1L)*p.pixelStride
            return p.pixelStride>0&&p.rowStride.toLong()>(w-1L)*p.pixelStride&&end>=0&&end<p.bytes.remaining()
        }
        if(!valid(y,width,height)||!valid(u,cw,ch)||!valid(v,cw,ch))return null
        fun sample(p:Plane,x:Int,row:Int) = p.bytes.get(p.bytes.position()+row*p.rowStride+x*p.pixelStride).toInt() and 255
        return IntArray(width*height){i->
            val x=i%width;val row=i/width
            val yy=(sample(y,x,row)-16).coerceAtLeast(0);val uu=sample(u,x/2,row/2)-128;val vv=sample(v,x/2,row/2)-128
            val r=((298*yy+409*vv+128) shr 8).coerceIn(0,255)
            val g=((298*yy-100*uu-208*vv+128) shr 8).coerceIn(0,255)
            val b=((298*yy+516*uu+128) shr 8).coerceIn(0,255)
            (255 shl 24) or (r shl 16) or (g shl 8) or b
        }
    }
}

/** Inverse of the explicit clockwise image rotation, in upper-left coordinates. */
object PalmCoordinates {
    fun raw(x:Double,y:Double,clockwise:Int):Point? {
        if(!x.isFinite()||!y.isFinite()||x !in 0.0..1.0||y !in 0.0..1.0)return null
        return when(clockwise) {
            0->Point(x,y);90->Point(y,1-x);180->Point(1-x,1-y);270->Point(1-y,x);else->null
        }
    }
}
