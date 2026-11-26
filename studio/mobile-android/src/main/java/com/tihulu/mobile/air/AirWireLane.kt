package com.tihulu.mobile.air

/** Existing v5 piano and v6 pedalboard wire shapes, matching Swift
 * MobileAirWireLane. The caller owns authentication, lane exclusivity,
 * neutral handshake, sequence allocation, ACK pacing and watchdogs.
 * No destinations, camera timestamps or arbitrary MIDI are accepted. */
sealed class AirWireLane {
    abstract fun encode(output:AirOutput,sequence:Long):ByteArray
    protected fun packet(sequence:Long,version:Int,kind:String,fields:String):ByteArray {
        require(sequence in 1L..9_007_199_254_740_991L)
        return """{"kind":"$kind","version":$version,"sequence":$sequence,$fields}"""
            .toByteArray(Charsets.US_ASCII).also {require(it.size<=256)}
    }
    class Keys(private val authorized:Int):AirWireLane() {
        init {require(authorized in 1 until (1 shl 25))}
        override fun encode(output:AirOutput,sequence:Long):ByteArray {
            require(output.keys in 0 until (1 shl 25) && (output.keys and authorized)==output.keys && output.level==null && output.xyz==null)
            return packet(sequence,5,"pianoKeys","\"mask\":${output.keys}")
        }
    }
    class Helper(private val index:Int,private val authorized:Int):AirWireLane() {
        init {require(index in 0..2 && authorized in 1..63 && (authorized and (1 shl index))!=0)}
        override fun encode(output:AirOutput,sequence:Long):ByteArray {
            require(output.keys==0 && output.xyz==null && (output.level?.let {it.isFinite()&&it in 0.0..1.0}?:true))
            // Inactive lanes must use the canonical integer token 0, not 0.0.
            val levels=(0..5).map {i->if(i==index && output.level!=null && output.level!=0.0) output.level.toString() else "0"}
            val mask=if(output.level==null)0 else 1 shl index
            return packet(sequence,6,"pedalboard","\"mask\":$mask,\"levels\":[${levels.joinToString(",")}]")
        }
    }
    class XYZ(private val mask: Int, authorized: Int): AirWireLane() {
        init { require(mask in 1..7 && authorized in 1..63 && (mask and authorized) == mask) }
        override fun encode(output: AirOutput, sequence: Long): ByteArray {
            require(output.keys == 0 && output.level == null)
            val levels = MutableList(6) { "0" }
            var active = 0
            output.xyz?.let { axes ->
                require(axes.size == 3)
                axes.forEachIndexed { i, value ->
                    if (value != null) {
                        require(value.isFinite() && value in 0.0..1.0)
                        active = active or (1 shl i)
                        levels[i] = value.toString()
                    }
                }
                require(active == mask)
            }
            return packet(sequence, 6, "pedalboard", """"mask":$active,"levels":[${levels.joinToString(",")}]""")
        }
    }
}
