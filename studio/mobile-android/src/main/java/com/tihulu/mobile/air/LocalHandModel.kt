package com.tihulu.mobile.air
import java.io.InputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest

/** Explicitly user-selected local model. Hash is identification, not trust.
 * No persistence, auto download or automatic capture. */
class LocalHandModel private constructor(private val bytes:ByteArray,val sha256:String) {
    fun directBuffer():ByteBuffer=ByteBuffer.allocateDirect(bytes.size).apply {put(bytes);rewind()}
    companion object {
        const val MAX_BYTES=16*1024*1024
        fun read(input:InputStream,limit:Int=MAX_BYTES):LocalHandModel {
            require(limit in 1..MAX_BYTES)
            val out=ByteArrayOutputStream();val chunk=ByteArray(8192)
            while(true) {
                val n=input.read(chunk)
                if(n<0)break
                require(n>0&&n<=limit-out.size()) {"Model exceeds limit or stream stalled"}
                out.write(chunk,0,n)
            }
            require(out.size()>0) {"Empty model"}
            val bytes=out.toByteArray()
            val hash=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {"%02x".format(it.toInt() and 255)}
            return LocalHandModel(bytes,hash)
        }
    }
}
