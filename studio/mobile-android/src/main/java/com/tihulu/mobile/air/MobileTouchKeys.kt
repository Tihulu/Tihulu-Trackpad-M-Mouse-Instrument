package com.tihulu.mobile.air

/** Pure bounded snapshot mapping for a future native touch piano.
 * Caller supplies the complete currently owned touches of the active view
 * generation. No historical events, synthetic timestamps or MIDI destinations.
 * Invalid means retire transport; empty is explicit release. */
internal class MobileTouchKeys(authorized:Int) {
    companion object {const val MAX_CONTACTS=10}
    data class Contact(val id:Int,val x:Double)
    init {require(authorized in 1 until (1 shl 25))}
    val keys:List<Int> = (0..24).filter{authorized and (1 shl it)!=0}
    fun output(contacts:List<Contact>):AirOutput? {
        if(contacts.size>MAX_CONTACTS)return null
        val seen=mutableSetOf<Int>()
        var mask=0
        for(c in contacts){
            if(c.id<0||!seen.add(c.id)||!c.x.isFinite()||c.x !in 0.0..1.0)return null
            val column=minOf(keys.lastIndex,(c.x*keys.size).toInt())
            mask=mask or (1 shl keys[column])
        }
        return AirOutput(keys=mask)
    }
}
