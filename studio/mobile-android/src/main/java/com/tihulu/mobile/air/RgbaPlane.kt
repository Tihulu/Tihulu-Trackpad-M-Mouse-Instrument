package com.tihulu.mobile.air

import java.nio.ByteBuffer

/** CameraX RGBA bytes in documented R,G,B,A order. Never depend on native
 * bitmap packing. Support bounded row padding and explicit crop rectangles. */
object RgbaPlane {
    fun toArgb(buffer:ByteBuffer,rowStride:Int,pixelStride:Int,width:Int,height:Int,
        left:Int,top:Int,right:Int,bottom:Int):IntArray? {
        if(width !in 1..4096||height !in 1..4096||pixelStride!=4||rowStride<width*4||
            left<0||top<0||right>width||bottom>height||right<=left||bottom<=top) return null
        val w=right-left;val h=bottom-top
        if(w.toLong()*h>4_194_304L) return null
        val last=(bottom-1L)*rowStride+(right-1L)*4+3
        if(last>=buffer.remaining()) return null
        val bytes=buffer.duplicate()
        val offset=bytes.position()
        val out=IntArray(w*h)
        for(y in 0 until h) for(x in 0 until w) {
            val i=offset+(top+y)*rowStride+(left+x)*4
            val r=bytes.get(i).toInt() and 255
            val g=bytes.get(i+1).toInt() and 255
            val b=bytes.get(i+2).toInt() and 255
            val a=bytes.get(i+3).toInt() and 255
            out[y*w+x]=(a shl 24) or (r shl 16) or (g shl 8) or b
        }
        return out
    }
}
