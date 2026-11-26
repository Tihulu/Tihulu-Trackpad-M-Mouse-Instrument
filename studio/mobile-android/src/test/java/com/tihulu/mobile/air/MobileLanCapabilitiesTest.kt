package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test
class MobileLanCapabilitiesTest {
    private fun manifest(piano:String="0",pedals:String="0",touch:String="false",drums:String="0")=
        """{"kind":"capabilities","version":7,"touch":$touch,"tilt":false,"acceleration":false,"rotation":false,"airDrums":false,"drums":$drums,"piano":$piano,"pedals":$pedals}"""
    @Test fun onlyAssignedNativeLane() {
        val p=MobileLanCapabilities.parseSingleFamily(manifest(piano="145"))!!
        assertNull(p.helperLane(0));assertTrue(p.keysLane()!!.encode(AirOutput(keys=145),1).decodeToString().contains("\"mask\":145"))
        val h=MobileLanCapabilities.parseSingleFamily(manifest(pedals="4"))!!
        assertNull(h.keysLane());assertNull(h.helperLane(0));assertNull(h.helperLane(3))
        assertTrue(h.helperLane(2)!!.encode(AirOutput(level=.5),1).decodeToString().contains("\"mask\":4"))
    }
    @Test fun unsupportedAndNoncanonicalFieldsRejected(){
        for(s in listOf(manifest(),manifest("1","1"),manifest("1",touch="true"),manifest("1",drums="1"),manifest("33554432"),manifest(pedals="64"),manifest(pedals="8"),manifest("1.0"),manifest("-0"),manifest("01"),manifest("true"),manifest("1e0"),manifest("1",touch="0")))assertNull(s,MobileLanCapabilities.parseSingleFamily(s))
    }
    @Test fun duplicatesAndUnknownFieldsRejected(){
        val s=manifest("1")
        for(bad in listOf(s.replace("\"piano\":1","\"piano\":1,\"piano\":2"),s.replace("\"piano\":1","\"piano\":1,\"extra\":2"),s.replace("\"piano\"","\"\\u0070iano\""),s+"{}"))assertNull(bad,MobileLanCapabilities.parseSingleFamily(bad))
    }
}
