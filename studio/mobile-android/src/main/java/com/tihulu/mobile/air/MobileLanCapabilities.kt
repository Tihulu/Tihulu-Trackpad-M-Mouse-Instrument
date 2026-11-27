package com.tihulu.mobile.air

/** First native proof accepts only one supported family. This is parsing,
 * not authentication or admission. Host must authorize every frame. */
object MobileLanCapabilities {
    class Manifest internal constructor(val piano:Int,val pedals:Int) {
        fun hybridLane(mask:Int):AirWireLane.XYZ? =
            if(piano>0 && pedals in 1..7 && mask in 1..7 && (mask and pedals)==mask) AirWireLane.XYZ(mask,pedals,piano) else null
        fun xyzLane(mask: Int): AirWireLane.XYZ? =
            if (piano == 0 && mask in 1..7 && (mask and pedals) == mask) AirWireLane.XYZ(mask, pedals) else null
        fun keysLane():AirWireLane.Keys?=if(piano>0&&pedals==0)AirWireLane.Keys(piano) else null
        /** The independent touch piano must never adopt a Hybrid lane. */
        fun touchPianoMask():Int? = piano.takeIf { keysLane()!=null }
        fun helperLane(index:Int):AirWireLane.Helper?=if(piano==0&&index in 0..2&&(pedals and (1 shl index))!=0)AirWireLane.Helper(index,pedals) else null
    }
    fun parseSingleFamily(input:String):Manifest? = parse(input,false)
    internal fun parse(input:String,hybrid:Boolean):Manifest? {
        if(input.length>256||input.any {it.code>=128})return null
        val text=input.trim(' ','\t','\r','\n')
        if(!text.startsWith("{")||!text.endsWith("}"))return null
        val fields=mutableMapOf<String,String>()
        val keys=setOf("kind","version","touch","tilt","acceleration","rotation","airDrums","drums","piano","pedals")
        for(member in text.substring(1,text.length-1).split(',')){
            val pair=member.split(':')
            if(pair.size!=2)return null
            val key=pair[0].trim(' ','\t','\r','\n');val value=pair[1].trim(' ','\t','\r','\n')
            if(key.length<2||key.first()!='"'||key.last()!='"')return null
            val name=key.substring(1,key.length-1)
            if(name !in keys||fields.put(name,value)!=null)return null
        }
        if(fields.keys!=keys||fields["kind"]!="\"capabilities\""||fields["version"]!="7"||
            listOf("touch","tilt","acceleration","rotation","airDrums").any {fields[it]!="false"}||fields["drums"]!="0")return null
        fun integer(name:String,max:Int):Int? {
            val s=fields[name]?:return null
            if(s.isEmpty()||s.any {it !in '0'..'9'})return null
            val v=s.toIntOrNull()?:return null
            return v.takeIf {it.toString()==s&&it in 0..max}
        }
        val piano=integer("piano",(1 shl 25)-1)?:return null;val pedals=integer("pedals",63)?:return null
        if(hybrid){
            if(piano==0 || pedals !in 1..7)return null
        }else if(!(piano>0&&pedals==0||piano==0&&(pedals and 7)!=0))return null
        return Manifest(piano,pedals)
    }
}
