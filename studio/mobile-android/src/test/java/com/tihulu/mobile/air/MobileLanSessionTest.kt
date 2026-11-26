package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test
class MobileLanSessionTest {
    private val token="ab".repeat(32)
    private fun ms(n:Long)=n*1_000_000L
    private fun host(piano:Int=1,pedals:Int=0)="""{"kind":"capabilities","version":7,"touch":false,"tilt":false,"acceleration":false,"rotation":false,"airDrums":false,"drums":0,"piano":$piano,"pedals":$pedals}"""
    private fun packet(a:MobileLanSession.Action)=(a as MobileLanSession.Action.Text).bytes.decodeToString()
    @Test fun fullHandshakeAndFreshAttack(){
        val s=MobileLanSession(MobileLanSession.Selection.Keys)
        assertArrayEquals(ByteArray(32){0xab.toByte()},(s.begin(true,"tihulu-touch-v1",token,0) as MobileLanSession.Action.Binary).bytes)
        assertTrue(packet(s.receive("admitted",ms(10))).contains("\"sequence\":1"))
        assertEquals(MobileLanSession.Action.Wait,s.receive(host(),ms(11)))
        val neutral=packet(s.poll(ms(23)));assertTrue(neutral.contains("\"mask\":0"));assertTrue(neutral.contains("\"sequence\":2"))
        assertEquals(MobileLanSession.Action.Wait,s.offer(AirOutput(keys=1),ms(24),ms(24)))
        assertEquals(MobileLanSession.Action.Wait,s.receive("accepted",ms(40)))
        assertEquals(MobileLanSession.Phase.READY,s.phase)
        assertEquals(MobileLanSession.Action.Wait,s.offer(AirOutput(keys=1),ms(39),ms(41)))
        val attack=packet(s.offer(AirOutput(keys=1),ms(42),ms(42)));assertTrue(attack.contains("\"sequence\":3"));assertTrue(attack.contains("\"mask\":1"))
    }
    @Test fun noTrustOrWrongProtocol(){
        for((trust,proto) in listOf(false to "tihulu-touch-v1",true to "other")){
            val s=MobileLanSession(MobileLanSession.Selection.Keys)
            assertTrue(s.begin(trust,proto,token,0) is MobileLanSession.Action.Close)
            assertEquals(MobileLanSession.Phase.CLOSED,s.phase)
        }
    }
    @Test fun unassignedFamilyAndAdmissionTimeout(){
        val s=MobileLanSession(MobileLanSession.Selection.Helper(0));s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1))
        assertEquals(MobileLanSession.Action.Close("Unassigned lane"),s.receive(host(0,4),ms(2)))
        val t=MobileLanSession(MobileLanSession.Selection.Keys);t.begin(true,"tihulu-touch-v1",token,0)
        assertEquals(MobileLanSession.Action.Close("Negotiation timeout"),t.receive("admitted",ms(3000)))
    }
    @Test fun neutralTimeoutIsTerminal(){
        val s=MobileLanSession(MobileLanSession.Selection.Keys);s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1));s.receive(host(),ms(14))
        assertEquals(MobileLanSession.Action.Close("ACK timeout"),s.receive("accepted",ms(234)))
        assertEquals(MobileLanSession.Phase.CLOSED,s.phase)
        assertEquals(MobileLanSession.Action.Close("Already closed"),s.poll(ms(235)))
    }

    @Test fun lateActiveAckCannotEraseSourceExpiry(){
        val s=MobileLanSession(MobileLanSession.Selection.Keys)
        s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1));s.receive(host(),ms(14));s.receive("accepted",ms(30))
        s.offer(AirOutput(keys=1),ms(31),ms(31))
        assertEquals(MobileLanSession.Action.Close("Source expired while active ACK outstanding"),s.receive("accepted",ms(181)))
    }
}
