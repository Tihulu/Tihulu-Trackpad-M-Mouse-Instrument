package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class PairedObservationFenceTest {
    private fun ms(v:Long)=v*1_000_000L
    @Test fun onlyFreshPostStartFramesPass() {
        val f=PairedObservationFence(ms(10))
        assertEquals(PairedObservationFence.Verdict.SEND,f.observe(ms(10),ms(11)))
        assertEquals(PairedObservationFence.Verdict.SEND,f.observe(ms(12),ms(13)))
        assertEquals(PairedObservationFence.Verdict.RETIRE,f.observe(ms(9),ms(14)))
        assertEquals(PairedObservationFence.Verdict.RETIRE,f.observe(ms(15),ms(15)))
    }
    @Test fun depthSnapshotMayRepeatButCannotRefreshItsAge() {
        val f=PairedObservationFence(0)
        assertEquals(PairedObservationFence.Verdict.SEND,f.observe(ms(1),ms(2),true))
        assertEquals(PairedObservationFence.Verdict.DUPLICATE,f.observe(ms(1),ms(100),true))
        assertEquals(PairedObservationFence.Verdict.RETIRE,f.observe(ms(1),ms(151),true))
    }
    @Test fun staleFutureAndOldRgbFramesFailClosed() {
        for((at,now) in listOf(ms(9) to ms(10),ms(11) to ms(10),ms(10) to ms(160))) {
            val f=PairedObservationFence(ms(10))
            assertEquals(PairedObservationFence.Verdict.RETIRE,f.observe(at,now))
        }
        val f=PairedObservationFence(0)
        f.observe(1,2)
        assertEquals(PairedObservationFence.Verdict.RETIRE,f.observe(1,3))
    }
    @Test fun retiredGenerationCannotRearm() {
        val f=PairedObservationFence(0)
        f.retire()
        assertEquals(PairedObservationFence.Verdict.RETIRE,f.observe(1,2))
    }
}
