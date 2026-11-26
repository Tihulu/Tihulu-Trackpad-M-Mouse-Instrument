package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test

class AirWireLaneTest {
    @Test fun pianoSnapshotAndNeutral() {
        val lane=AirWireLane.Keys(145)
        assertEquals("""{"kind":"pianoKeys","version":5,"sequence":1,"mask":145}""",lane.encode(AirOutput(keys=145),1).decodeToString())
        assertEquals("""{"kind":"pianoKeys","version":5,"sequence":2,"mask":0}""",lane.encode(AirOutput(),2).decodeToString())
    }
    @Test fun activeZeroIsDifferentFromRelease() {
        val lane=AirWireLane.Helper(2,4)
        assertEquals("""{"kind":"pedalboard","version":6,"sequence":3,"mask":4,"levels":[0,0,0,0,0,0]}""",lane.encode(AirOutput(level=0.0),3).decodeToString())
        assertEquals("""{"kind":"pedalboard","version":6,"sequence":4,"mask":0,"levels":[0,0,0,0,0,0]}""",lane.encode(AirOutput(),4).decodeToString())
    }
    @Test fun rejectsUnauthorizedAndNonfiniteValues() {
        fun rejected(f:()->Unit) {try {f();fail("invalid snapshot accepted")}catch(_:IllegalArgumentException){}}
        rejected {AirWireLane.Keys(145).encode(AirOutput(keys=2),1)}
        rejected {AirWireLane.Keys(145).encode(AirOutput(keys=1,level=0.0),1)}
        rejected {AirWireLane.Keys(145).encode(AirOutput(),0)}
        rejected {AirWireLane.Keys(145).encode(AirOutput(),9_007_199_254_740_992L)}
        rejected {AirWireLane.Helper(3,8)}
        rejected {AirWireLane.Helper(2,1)}
        rejected {AirWireLane.Helper(2,4).encode(AirOutput(level=Double.NaN),1)}
        rejected {AirWireLane.Helper(2,4).encode(AirOutput(level=1.01),1)}
        rejected {AirWireLane.Helper(2,4).encode(AirOutput(keys=1),1)}
    }

@Test fun canonicalInactiveTokensAcrossAllThreeHelperLanes() {
    for(i in 0..2) {
        val lane=AirWireLane.Helper(i,7)
        val expected=(0..5).joinToString(",") { if(it==i) "0.25" else "0" }
        assertTrue(lane.encode(AirOutput(level=.25),1).decodeToString().contains("\"levels\":[$expected]"))
        assertTrue(lane.encode(AirOutput(level=-0.0),2).decodeToString().contains("\"levels\":[0,0,0,0,0,0]"))
    }
}
}
