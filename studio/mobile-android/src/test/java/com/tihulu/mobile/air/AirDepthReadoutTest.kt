package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class AirDepthReadoutTest {
    @Test fun missingOrExpiredObservationDoesNotClaimActiveDepth() {
        assertEquals("ARCore · no fresh observation · controls released",
            AirDepthReadout.describe(AirDepthReadout.RUNNING, null, AirOutput()))
        assertEquals("ARCore · no fresh observation · controls released",
            AirDepthReadout.describe(AirDepthReadout.RUNNING, null, AirOutput(keys = 1)))
    }
    @Test fun neutralAndActiveZeroAreDifferent() {
        assertEquals("ARCore · acquiring or outside range · controls released",
            AirDepthReadout.describe(AirDepthReadout.RUNNING, 10, AirOutput()))
        assertEquals(AirDepthReadout.RUNNING + " · projected output",
            AirDepthReadout.describe(AirDepthReadout.RUNNING, 10, AirOutput(level = 0.0)))
        assertEquals(AirDepthReadout.RUNNING + " · projected output",
            AirDepthReadout.describe(AirDepthReadout.RUNNING, 10, AirOutput(keys = 1)))
    }
    @Test fun errorsAndStartupRemainVisible() {
        for (status in listOf("Starting ARCore", "Stopped", "ARCore processing failed"))
            assertEquals(status, AirDepthReadout.describe(status, null, AirOutput()))
    }
}
