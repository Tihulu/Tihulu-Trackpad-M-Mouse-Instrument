package com.tihulu.mobile.air

import java.io.EOFException
import java.io.IOException
import java.io.InputStream

/**
 * Bounded server-to-client frame reader for the native LAN protocol.
 * Isolated transport candidate, NOT used by the existing OkHttp adapter.
 * A single owner must supply an already TLS-verified, upgraded stream
 * without negotiated extensions and enforce independent read deadlines.
 * Client writes, HTTP upgrade, cancellation and socket ownership are separate.
 */
internal class BoundedLanFrameReader(private val input:InputStream) {
    sealed interface Event {
        data class Text(val value:String):Event
        data class Ping(val payload:ByteArray):Event
        data class Pong(val payload:ByteArray):Event
        data object Close:Event
    }
    companion object {
        const val MAX_TEXT_BYTES=256
        const val MAX_FRAGMENTS=16
    }
    private var terminal=false
    private val message=ByteArray(MAX_TEXT_BYTES)
    private var used=0
    private var fragments=0
    private fun reject():Nothing {
        terminal=true
        throw IOException("Invalid or oversized LAN WebSocket frame")
    }
    private fun octet():Int {
        val value=input.read()
        if(value<0)throw EOFException("LAN stream ended")
        return value
    }
    private fun readPayload(target:ByteArray,offset:Int,length:Int) {
        var cursor=offset
        val end=offset+length
        while(cursor<end) {
            val count=input.read(target,cursor,end-cursor)
            if(count<=0)throw EOFException("Incomplete LAN frame")
            cursor+=count
        }
    }
    /** Returns control frames separately, preserving any bounded text
     * assembly across them. Close and every parse/read failure are terminal.
     * Never allocate a buffer using a peer-supplied unvalidated length. */
    fun next():Event {
        if(terminal)throw IOException("LAN reader is closed")
        return try {
            while(true) {
                val first=octet();val second=octet()
                val final=(first and 128)!=0
                val opcode=first and 15
                if((first and 112)!=0||(second and 128)!=0)reject() // no RSV or masked server frames
                if(opcode !in setOf(0,1,8,9,10))reject() // binary/reserved prohibited
                val indicator=second and 127
                val control=opcode>=8
                if(control&&(!final||indicator>125))reject()
                // 64-bit lengths can never fit this protocol. Reject at
                // the two-byte header rather than consuming any payload.
                if(indicator==127)reject()
                val length=if(indicator==126) {
                    val n=(octet() shl 8) or octet()
                    if(n<126)reject()
                    n
                } else indicator
                if(control) {
                    val payload=ByteArray(length) // already <=125
                    readPayload(payload,0,length)
                    when(opcode) {
                        8 -> {
                            if(length==1)reject()
                            if(length>=2) {
                                val code=((payload[0].toInt() and 255) shl 8) or (payload[1].toInt() and 255)
                                if(code !in 1000..4999||code in setOf(1004,1005,1006,1015)||code in 1016..2999)reject()
                                try {
                                    Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(payload,2,length-2))
                                }catch(_:java.nio.charset.CharacterCodingException){reject()}
                            }
                            terminal=true;message.fill(0);used=0;fragments=0
                            return Event.Close
                        }
                        9 -> return Event.Ping(payload)
                        10 -> return Event.Pong(payload)
                    }
                }
                if(opcode==1&&fragments!=0||opcode==0&&fragments==0)reject()
                if(fragments>=MAX_FRAGMENTS||length>MAX_TEXT_BYTES-used)reject()
                readPayload(message,used,length)
                // The host protocol intentionally uses ASCII only.
                for(i in used until used+length)if(message[i].toInt() !in 0..127)reject()
                used+=length;fragments++
                if(final) {
                    val text=message.copyOf(used).toString(Charsets.US_ASCII)
                    message.fill(0);used=0;fragments=0
                    return Event.Text(text)
                }
            }
            @Suppress("UNREACHABLE_CODE")
            reject()
        } catch(error:IOException) {
            terminal=true;message.fill(0);used=0;fragments=0
            throw error
        }
    }
}
