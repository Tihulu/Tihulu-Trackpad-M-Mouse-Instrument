package com.tihulu.mobile.air
import java.util.concurrent.atomic.AtomicReference

/** Process-local ownership between the diagnostic RGB and ARCore sources.
 * Never releases someone else's camera lease. */
object MobileCaptureLease {
    private val owner=AtomicReference<Any?>(null)
    fun acquire(token:Any):Boolean=owner.compareAndSet(null,token)
    fun release(token:Any):Boolean=owner.compareAndSet(token,null)
}
