package com.tihulu.mobile.air

/**
 * Single outbound frame ownership, serialized by the session owner.
 * No queue, retry or replacement. A frame taken by the writer is erased
 * only by that writer; cancellation must not mutate its live buffer.
 * The watchdog can retire the slot without waiting for the writer.
 */
internal class LanWriteSlot {
    companion object {
        // Conservative independent transport budget; does not extend the
        // existing source, pacing, ACK or note deadlines.
        const val WRITE_NS=50_000_000L
        const val MAX_FRAME_BYTES=264
    }
    class Lease internal constructor(internal val bytes:ByteArray,internal val at:Long) {
        internal var started=false
        fun erase(){bytes.fill(0)}
    }
    private var active:Lease?=null
    private var retired=false
    val busy get()=active!=null
    val writing get()=active?.started==true

    /** Takes ownership on success only. The caller erases a rejected frame. */
    fun admit(frame:ByteArray,now:Long):Boolean {
        if(retired||busy||now<0||frame.size !in 6..MAX_FRAME_BYTES)return false
        active=Lease(frame,now)
        return true
    }
    fun expired(now:Long):Boolean=active?.let{now<it.at||now-it.at>=WRITE_NS}?:false
    fun take(now:Long):Lease? {
        val lease=active?:return null
        if(retired||lease.started||expired(now))return null
        lease.started=true
        return lease
    }
    /** Exactly the writer that took the lease may complete it. */
    fun complete(lease:Lease,now:Long):Boolean {
        if(retired||active!==lease||!lease.started||expired(now))return false
        active=null
        return true
    }
    fun retire() {
        retired=true
        val lease=active
        active=null
        if(lease!=null&&!lease.started)lease.erase()
    }
}
