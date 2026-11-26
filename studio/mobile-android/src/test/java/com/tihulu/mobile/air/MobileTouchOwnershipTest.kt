package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class MobileTouchOwnershipTest {
    private fun c(id:Int,x:Double)=MobileTouchKeys.Contact(id,x)
    private val began=MobileTouchOwnership.Change.BEGAN
    private val moved=MobileTouchOwnership.Change.MOVED
    private val ended=MobileTouchOwnership.Change.ENDED
    @Test fun noMoveBeforeDownOrRearmAfterCancel() {
        val p=MobileTouchOwnership(3)
        assertNull(p.update(moved,listOf(c(0,0.0))))
        assertTrue(p.retired);assertEquals(0,p.output.keys)
        assertNull(p.update(began,listOf(c(0,0.0))))
        val fresh=MobileTouchOwnership(3)
        assertEquals(1,fresh.update(began,listOf(c(0,0.0)))?.keys)
        assertNull(fresh.update(MobileTouchOwnership.Change.CANCELLED,emptyList()))
        assertTrue(fresh.retired);assertEquals(0,fresh.output.keys)
    }
    @Test fun tracksSharedNotesAndCompleteTransitions() {
        val p=MobileTouchOwnership(5)
        assertEquals(1,p.update(began,listOf(c(0,0.0)))?.keys)
        assertEquals(1,p.update(began,listOf(c(0,0.0),c(1,.1)))?.keys)
        assertEquals(5,p.update(moved,listOf(c(0,0.0),c(1,1.0)))?.keys)
        assertEquals(4,p.update(ended,listOf(c(1,1.0)))?.keys)
        assertEquals(0,p.update(ended,emptyList())?.keys)
        assertFalse(p.retired)
        assertEquals(4,p.update(began,listOf(c(0,1.0)))?.keys)
    }
    @Test fun rejectsDroppedInventedOrInvalidPointer() {
        for(change in listOf(moved,began,ended)){
            val p=MobileTouchOwnership(3)
            p.update(began,listOf(c(1,0.0)))
            assertNull(p.update(change,listOf(c(2,1.0))))
            assertTrue(p.retired);assertEquals(0,p.output.keys)
        }
        val p=MobileTouchOwnership(3)
        p.update(began,listOf(c(1,0.0)))
        assertNull(p.update(moved,listOf(c(1,1.1))))
        assertEquals(0,p.output.keys)
    }
    @Test fun explicitRetirementIdempotent() {
        val p=MobileTouchOwnership(3)
        p.update(began,listOf(c(1,0.0)))
        assertEquals(0,p.retire().keys)
        assertEquals(0,p.retire().keys)
        assertNull(p.update(ended,emptyList()))
    }
}
