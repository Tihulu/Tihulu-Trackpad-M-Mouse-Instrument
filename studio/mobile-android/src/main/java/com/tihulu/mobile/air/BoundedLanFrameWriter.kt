package com.tihulu.mobile.air

import java.security.SecureRandom

/**
 * Bounded, unfragmented client frames for the LAN protocol. No general
 * binary or arbitrary MIDI interface: binary is the exact 32-byte invite;
 * text is bounded ASCII policy output; control replies are bounded.
 * Each call uses an independent cryptographic mask. Caller owns the
 * returned frame and must erase it after synchronous write or cancellation.
 */
internal class BoundedLanFrameWriter private constructor(private val maskSource:(ByteArray)->Unit) {
    constructor():this(SecureRandom()::nextBytes)
    companion object {
        internal fun testing(maskSource:(ByteArray)->Unit)=BoundedLanFrameWriter(maskSource)
    }
    fun invitation(payload:ByteArray):ByteArray {
        require(payload.size==32)
        return encode(2,payload)
    }
    fun text(payload:ByteArray):ByteArray {
        require(payload.size in 1..256&&payload.all{it.toInt() in 0..127})
        return encode(1,payload)
    }
    fun pong(payload:ByteArray):ByteArray {
        require(payload.size<=125)
        return encode(10,payload)
    }
    private fun encode(opcode:Int,payload:ByteArray):ByteArray {
        val length=payload.size
        val header=if(length<=125)2 else 4
        val mask=ByteArray(4)
        try {
            maskSource(mask)
            val result=ByteArray(header+4+length)
            result[0]=(128 or opcode).toByte()
            result[1]=(128 or if(length<=125)length else 126).toByte()
            if(header==4) {
                result[2]=(length shr 8).toByte()
                result[3]=length.toByte()
            }
            mask.copyInto(result,header)
            for(i in payload.indices)result[header+4+i]=(payload[i].toInt() xor mask[i%4].toInt()).toByte()
            return result
        }finally{mask.fill(0)}
    }
}
