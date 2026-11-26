package com.tihulu.mobile.air

/** Single explicitly armed touch owner; invalid or cancelled snapshots
 * retire this owner. A fresh UI generation requires explicit rearm. */
internal class MobileTouchOwnership(authorized:Int) {
    enum class Change { BEGAN, MOVED, ENDED, CANCELLED }
    private val mapper=MobileTouchKeys(authorized)
    val keys get()=mapper.keys
    private var active:Set<Int> = emptySet()
    var retired=false;private set
    var output=AirOutput();private set
    fun retire():AirOutput {
        retired=true;active=emptySet();output=AirOutput()
        return output
    }
    fun update(change:Change,contacts:List<MobileTouchKeys.Contact>):AirOutput? {
        if(retired)return null
        if(change==Change.CANCELLED){retire();return null}
        val next=mapper.output(contacts)?:run{retire();return null}
        val ids=contacts.map{it.id}.toSet()
        val valid=when(change){
            Change.BEGAN->ids.size>active.size&&ids.containsAll(active)
            Change.MOVED->active.isNotEmpty()&&ids==active
            Change.ENDED->ids.size<active.size&&active.containsAll(ids)
            Change.CANCELLED->false
        }
        if(!valid){retire();return null}
        active=ids;output=next
        return next
    }
}
