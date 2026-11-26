package com.tihulu.mobile.air

import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale

/** Single-use bounded HTTP upgrade candidate. Caller must first establish
 * normally verified TLS to this exact endpoint, then enforce absolute
 * handshake/read/write deadlines. No network or MIDI is opened here. */
internal class BoundedLanUpgrade private constructor(private val endpoint:MobileLanEndpoint,
    private val key:String) {
    companion object {
        const val MAX_HEADER_BYTES=4096
        const val MAX_HEADERS=32
        private const val GUID="258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        private val NAME=Regex("[!#$%&'*+.^_|~0-9A-Za-z-]+")
        fun create(endpoint:MobileLanEndpoint):BoundedLanUpgrade {
            val nonce=ByteArray(16)
            SecureRandom().nextBytes(nonce)
            return fromNonce(endpoint,nonce)
        }
        internal fun fromNonce(endpoint:MobileLanEndpoint,nonce:ByteArray):BoundedLanUpgrade {
            require(nonce.size==16)
            return BoundedLanUpgrade(endpoint,Base64.getEncoder().encodeToString(nonce))
        }
    }
    private var requested=false
    private var consumed=false
    fun request():ByteArray {
        check(!requested&&!consumed)
        requested=true
        return listOf("GET / HTTP/1.1","Host: "+endpoint.host+":9443",
            "Origin: "+endpoint.origin,"Connection: Upgrade","Upgrade: websocket",
            "Sec-WebSocket-Version: 13","Sec-WebSocket-Key: "+key,
            "Sec-WebSocket-Protocol: "+endpoint.subprotocol,"","")
            .joinToString("\r\n").toByteArray(Charsets.US_ASCII)
    }
    private fun reject():Nothing=throw IOException("LAN WebSocket upgrade rejected")

    /** Consume only through CRLF CRLF, leaving frame bytes untouched.
     * No retries on a consumed response, even when rejected. */
    fun accept(input:InputStream) {
        check(requested&&!consumed)
        consumed=true
        var remaining=MAX_HEADER_BYTES
        fun readByte():Int {
            if(remaining<=0)reject()
            val value=input.read()
            if(value<0)throw EOFException("Incomplete LAN upgrade")
            remaining--
            return value
        }
        fun line():String {
            val out=StringBuilder()
            while(true) {
                val value=readByte()
                if(value==13) {
                    if(readByte()!=10)reject()
                    return out.toString()
                }
                if(value!=9&&value !in 32..126)reject()
                out.append(value.toChar())
            }
        }
        val status=line()
        if(status!="HTTP/1.1 101"&&!status.startsWith("HTTP/1.1 101 "))reject()
        if(status.any {it.code !in 32..126})reject()
        val headers=mutableMapOf<String,String>()
        while(true) {
            val raw=line()
            if(raw.isEmpty())break
            if(headers.size>=MAX_HEADERS)reject()
            val colon=raw.indexOf(':')
            if(colon<=0)reject()
            val name=raw.substring(0,colon)
            if(!NAME.matches(name))reject()
            if(headers.put(name.lowercase(Locale.ROOT),raw.substring(colon+1).trim(' ','\t'))!=null)reject()
        }
        if(headers.keys.any {it in setOf("sec-websocket-extensions","content-length","transfer-encoding")})reject()
        if(!headers["upgrade"].equals("websocket",ignoreCase=true))reject()
        val connection=headers["connection"]?.split(',')?.map {it.trim(' ','\t').lowercase(Locale.ROOT)}?:reject()
        if(connection.any {it.isEmpty()}||connection.count {it=="upgrade"}!=1||"close" in connection)reject()
        if(headers["sec-websocket-protocol"]!=endpoint.subprotocol)reject()
        val expected=Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1")
            .digest((key+GUID).toByteArray(Charsets.US_ASCII)))
        if(headers["sec-websocket-accept"]!=expected)reject()
    }
}
