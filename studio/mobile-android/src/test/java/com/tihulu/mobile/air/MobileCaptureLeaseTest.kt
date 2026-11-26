package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test
class MobileCaptureLeaseTest {
    @Test fun exclusiveOwnershipCannotBeReleasedByOtherSource(){
        val a=Any();val b=Any()
        assertTrue(MobileCaptureLease.acquire(a))
        try {
            assertFalse(MobileCaptureLease.acquire(b));assertFalse(MobileCaptureLease.release(b))
            assertFalse(MobileCaptureLease.acquire(b))
        }finally{MobileCaptureLease.release(a)}
        assertTrue(MobileCaptureLease.acquire(b));assertTrue(MobileCaptureLease.release(b))
    }
}
