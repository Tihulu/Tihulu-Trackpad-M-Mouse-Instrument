package com.tihulu.mobile.air

/** Native input validation only. Does not establish TLS or pairing. */
class MobileLanEndpoint private constructor(val host:String) {
    val socketUrl get()="wss://$host:9443/"
    val origin get()="https://$host:9444"
    val subprotocol get()="tihulu-touch-v1"
    companion object {
        fun parse(pageAddress:String):MobileLanEndpoint? {
            if(pageAddress.length>64||!pageAddress.startsWith("https://")||!pageAddress.endsWith(":9444/"))return null
            val host=pageAddress.substring(8,pageAddress.length-6)
            val parts=host.split('.')
            if(parts.size!=4)return null
            val octets=parts.map {
                if(it.isEmpty()||it.length>3||it.any {c->c !in '0'..'9'})return null
                val n=it.toIntOrNull()?:return null
                if(n !in 0..255||n.toString()!=it)return null
                n
            }
            if(!(octets[0]==10||octets[0]==172&&octets[1] in 16..31||octets[0]==192&&octets[1]==168))return null
            return MobileLanEndpoint(host)
        }
        /** Caller must not persist/log token, and only send after TLS and
         * subprotocol verification. No whitespace or Unicode aliases. */
        fun invitationBytes(token:String):ByteArray? {
            if(token.length!=64)return null
            fun nibble(c:Char):Int=when(c){in '0'..'9'->c-'0';in 'a'..'f'->c-'a'+10;in 'A'..'F'->c-'A'+10;else->-1}
            val bytes=ByteArray(32)
            for(i in bytes.indices){
                val high=nibble(token[i*2]);val low=nibble(token[i*2+1])
                if(high<0||low<0){bytes.fill(0);return null}
                bytes[i]=(high*16+low).toByte()
            }
            return bytes
        }
    }
}
