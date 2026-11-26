package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class MobileTouchKeysTest {
    private fun c(id:Int,x:Double)=MobileTouchKeys.Contact(id,x)
    @Test fun onlySparseAssignedKeysAtEdgesAndCenter() {
        val p=MobileTouchKeys((1 shl 2) or (1 shl 10) or (1 shl 24))
        assertEquals(listOf(2,10,24),p.keys)
        assertEquals(1 shl 2,p.output(listOf(c(1,0.0)))?.keys)
        assertEquals(1 shl 10,p.output(listOf(c(1,0.5)))?.keys)
        assertEquals(1 shl 24,p.output(listOf(c(1,1.0)))?.keys)
    }
    @Test fun aggregateAndReleaseOnlyUnownedKeys() {
        val p=MobileTouchKeys(5)
        assertEquals(5,p.output(listOf(c(1,0.0),c(2,0.2),c(3,1.0)))?.keys)
        assertEquals(5,p.output(listOf(c(2,0.2),c(3,1.0)))?.keys)
        assertEquals(4,p.output(listOf(c(3,1.0)))?.keys)
        assertEquals(0,p.output(emptyList())?.keys)
    }
    @Test fun rejectsInvalidSnapshotsAndBoundaries() {
        val p=MobileTouchKeys(1)
        for(x in listOf(Double.NaN,Double.POSITIVE_INFINITY,-0.01,1.01))assertNull(p.output(listOf(c(0,x))))
        assertNull(p.output(listOf(c(-1,0.0))))
        assertNull(p.output(listOf(c(1,0.0),c(1,1.0))))
        assertNull(p.output((0..10).map{c(it,0.0)}))
        assertEquals(1,p.output((0 until 10).map{c(it,0.0)})?.keys)
        assertTrue(runCatching{MobileTouchKeys(0)}.isFailure)
        assertTrue(runCatching{MobileTouchKeys(1 shl 25)}.isFailure)
    }
}
