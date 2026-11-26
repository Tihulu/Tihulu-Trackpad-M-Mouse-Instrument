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

    @Test fun cameraReceivesOnlyConfirmedSparseAssignment() {
        val session = MobileLanSession(MobileLanSession.Selection.Keys)
        assertNull(session.readyManifest)
        session.begin(true, "tihulu-touch-v1", token, 0)
        session.receive("admitted", ms(1))
        session.receive(host(1 shl 19), ms(15))
        assertNull(session.readyManifest)
        session.receive("accepted", ms(20))
        assertEquals(1 shl 19, session.readyManifest?.piano)
        session.abort()
        assertNull(session.readyManifest)
    }

    @Test fun pairedProjectionRequiresNeutralAckAndMatchesFamily() {
        val s=MobileLanSession(MobileLanSession.Selection.Keys)
        assertNull(s.newProjection(AirMode.PINCH_KEYS))
        s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1));s.receive(host(1 shl 19),ms(15))
        assertNull(s.newProjection(AirMode.PINCH_KEYS))
        s.receive("accepted",ms(20))
        assertNull(s.newProjection(AirMode.STRINGS))
        assertNull(s.newProjection(AirMode.CHORDS,HandRole.RIGHT))
        assertNull(s.newProjection(AirMode.HORIZONTAL))
        val p=checkNotNull(s.newProjection(AirMode.PINCH_KEYS))
        fun frame(aperture:Double,t:Long)=Frame(listOf(Observation(Hand(.5,.5,aperture),"right",1f)),ms(t))
        p.receive(frame(.5,21),ms(21));p.receive(frame(.5,40),ms(40))
        val out=p.receive(frame(.1,60),ms(60))
        assertEquals(1 shl 19,out.keys)
        assertTrue(packet(s.offer(out,ms(60),ms(60))).contains("\"mask\":524288"))
        s.abort()
        assertNull(s.newProjection(AirMode.PINCH_KEYS))
    }
    @Test fun helperProjectionCannotSelectPianoOrDifferentFamily() {
        val s=MobileLanSession(MobileLanSession.Selection.Helper(2))
        s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1));s.receive(host(0,4),ms(15))
        s.receive("accepted",ms(20))
        assertNull(s.newProjection(AirMode.PINCH_KEYS))
        assertNotNull(s.newProjection(AirMode.HORIZONTAL))
        assertNull(s.newProjection(AirMode.BEAM_HELPER,near=.9,far=.2))
    }
    @Test fun stringDeadlinesReachSessionWatchdog() {
        val s=MobileLanSession(MobileLanSession.Selection.Keys)
        s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1));s.receive(host(7),ms(15));s.receive("accepted",ms(20))
        assertTrue(packet(s.offer(AirOutput(keys=1),ms(30),ms(30),mapOf(0 to ms(100)))).contains("\"mask\":1"))
        s.receive("accepted",ms(40))
        assertTrue(packet(s.poll(ms(100))).contains("\"mask\":0"))
    }

    @Test fun modeTransitionHidesAssignmentAndRejectsNewFamilyUntilNeutralAck() {
        val s=MobileLanSession(MobileLanSession.Selection.Keys)
        s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1));s.receive(host(7),ms(15));s.receive("accepted",ms(20))
        s.offer(AirOutput(keys=1),ms(30),ms(30));s.receive("accepted",ms(40))
        assertTrue(packet(s.pauseForModeChange(ms(45))).contains("\"mask\":0"))
        assertEquals(MobileLanSession.Phase.RECONFIGURING,s.phase)
        assertNull(s.readyManifest);assertNull(s.newProjection(AirMode.STRINGS))
        assertEquals(MobileLanSession.Action.Wait,s.offer(AirOutput(keys=2),ms(46),ms(46)))
        s.receive("accepted",ms(50))
        assertEquals(MobileLanSession.Phase.READY,s.phase)
        assertNotNull(s.newProjection(AirMode.STRINGS))
        assertNull(s.newProjection(AirMode.HORIZONTAL))
        assertEquals(MobileLanSession.Action.Wait,s.offer(AirOutput(keys=2),ms(49),ms(51)))
        assertTrue(packet(s.offer(AirOutput(keys=2),ms(60),ms(60))).contains("\"mask\":2"))
    }
    @Test fun modeTransitionTimeoutCannotRestoreReady() {
        val s=MobileLanSession(MobileLanSession.Selection.Helper(0))
        s.begin(true,"tihulu-touch-v1",token,0);s.receive("admitted",ms(1));s.receive(host(0,1),ms(15));s.receive("accepted",ms(20))
        s.pauseForModeChange(ms(30))
        assertTrue(s.poll(ms(180)) is MobileLanSession.Action.Close)
        assertNull(s.readyManifest)
        assertTrue(s.receive("accepted",ms(181)) is MobileLanSession.Action.Close)
    }
    @Test fun xyzUsesOneGrantedSnapshotAndReleasesAtSourceExpiry() {
        val session = MobileLanSession(MobileLanSession.Selection.XYZ(5))
        session.begin(true, "tihulu-touch-v1", token, 0)
        session.receive("admitted", ms(1))
        assertTrue(packet(session.receive(host(0,7), ms(15))).contains("\"mask\":0"))
        session.receive("accepted", ms(20))
        val axes = mutableListOf<Double?>(0.0, null, 0.7)
        val frame = packet(session.offer(AirOutput(xyz = axes), ms(30), ms(30)))
        assertTrue(frame.contains("\"mask\":5,\"levels\":[0.0,0,0.7,0,0,0]"))
        axes[0] = 1.0
        session.receive("accepted", ms(40))
        assertTrue(packet(session.poll(ms(80))).contains("[0.0,0,0.7,0,0,0]"))
        session.receive("accepted", ms(85))
        assertTrue(packet(session.poll(ms(180))).contains("\"mask\":0"))
    }
    @Test fun xyzRejectsIncompleteGrantAndInvalidOutput() {
        val manifest = checkNotNull(MobileLanCapabilities.parseSingleFamily(host(0,5)))
        assertNull(manifest.xyzLane(7))
        val lane = checkNotNull(manifest.xyzLane(5))
        for (output in listOf(AirOutput(xyz=listOf(1.0,1.0,1.0)), AirOutput(level=0.5),
            AirOutput(xyz=listOf(0.0,null,Double.NaN)), AirOutput(keys=1))) {
            assertThrows(IllegalArgumentException::class.java) { lane.encode(output,1) }
        }
    }
    @Test fun hybridUsesOneAckAndRequiresBothAssignedFamilies() {
        val session=MobileLanSession(MobileLanSession.Selection.Hybrid(5))
        session.begin(true,"tihulu-touch-v1",token,0);session.receive("admitted",ms(1))
        assertNull(MobileLanCapabilities.parseSingleFamily(host(5,7)))
        assertTrue(packet(session.receive(host(5,7),ms(15))).contains("\"kind\":\"xyzHybrid\""))
        session.receive("accepted",ms(20))
        val active=AirOutput(keys=4,xyz=listOf(0.4,null,0.9))
        assertTrue(packet(session.offer(active,ms(30),ms(30))).contains("\"keys\":4"))
        assertTrue(session.offer(active.copy(keys=1),ms(35),ms(35)) is MobileLanSession.Action.Close)
    }
}
