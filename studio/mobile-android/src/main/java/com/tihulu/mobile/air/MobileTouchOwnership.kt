package com.tihulu.mobile.air

/** Single explicitly armed touch owner; invalid or cancelled snapshots
 * retire this owner. A fresh UI generation requires explicit rearm. */
internal class MobileTouchOwnership(authorized:Int) {
    enum class Change { BEGAN, MOVED, ENDED, CANCELLED }
    private val mapper=MobileTouchKeys(authorized)
    val keys get()=mapper.keys
    private var active:Set<Int> = emptySet()
    val activeIDs:Set<Int> get()=active.toSet()
    var retired=false;private set
    var output=AirOutput();private set
    fun retire():AirOutput {
        retired=true;active=emptySet();output=AirOutput()
        return output
    }
    /** Android MotionEvent supplies the complete pre-release pointer set.
     * Verify the actual changed pointer as well as post-event ownership. */
    fun pointerTransition(change:Change,all:List<MobileTouchKeys.Contact>,changedID:Int?=null):AirOutput? {
        if(retired)return null
        if(change==Change.CANCELLED){retire();return null}
        if(mapper.output(all)==null){retire();return null}
        val ids=all.map{it.id}.toSet()
        val valid=when(change){
            Change.BEGAN->changedID!=null&&changedID !in active&&ids==active+changedID
            Change.MOVED->changedID==null&&ids==active
            Change.ENDED->changedID!=null&&changedID in active&&ids==active
            Change.CANCELLED->false
        }
        if(!valid){retire();return null}
        return update(change,if(change==Change.ENDED)all.filter{it.id!=changedID} else all)
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
