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
    @Test fun modeSwitchRequiresNewPostStartObservationAndRetiresOldGeneration() {
        val old=PairedObservationFence(ms(10))
        assertEquals(PairedObservationFence.Verdict.SEND,old.observe(ms(20),ms(21)))
        old.retire()
        assertEquals(PairedObservationFence.Verdict.RETIRE,old.observe(ms(30),ms(31)))

        // This fence is created only after the UI observes neutral ACK and starts a new capture.
        val changed=PairedObservationFence(ms(40))
        assertEquals(PairedObservationFence.Verdict.RETIRE,changed.observe(ms(39),ms(41)))
        assertEquals(PairedObservationFence.Verdict.RETIRE,changed.observe(ms(42),ms(43)))

        val restarted=PairedObservationFence(ms(50))
        assertEquals(PairedObservationFence.Verdict.SEND,restarted.observe(ms(50),ms(51)))
        assertEquals(PairedObservationFence.Verdict.DUPLICATE,restarted.observe(ms(50),ms(199),true))
        assertEquals(PairedObservationFence.Verdict.RETIRE,restarted.observe(ms(50),ms(200),true))
    }
}
