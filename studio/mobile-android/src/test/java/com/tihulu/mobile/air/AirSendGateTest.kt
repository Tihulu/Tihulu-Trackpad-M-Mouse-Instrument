package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test
class AirSendGateTest {
    private fun ms(n:Long)=n*1_000_000L
    private fun send(a:AirSendGate.Action)= (a as AirSendGate.Action.Send).bytes.decodeToString()
    @Test fun neutralAckRequiredAndNoPreAckAttack() {
        val g=AirSendGate(AirWireLane.Keys(3),8)
        assertTrue(send(g.begin(0)).contains("\"sequence\":9"))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=1),ms(1),ms(1)))
        assertEquals(AirSendGate.Action.Wait,g.acknowledge("accepted",ms(20)))
        assertTrue(send(g.offer(AirOutput(keys=1),ms(21),ms(21))).contains("\"mask\":1"))
    }
    @Test fun releasePriorityAndFreshObservationAfterAck() {
        val g=AirSendGate(AirWireLane.Keys(3),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(keys=1),ms(21),ms(21))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(),ms(30),ms(30)))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=2),ms(31),ms(31)))
        assertTrue(send(g.acknowledge("accepted",ms(40))).contains("\"mask\":0"))
        assertEquals(AirSendGate.Action.Wait,g.acknowledge("accepted",ms(60)))
        assertTrue(send(g.offer(AirOutput(keys=2),ms(61),ms(61))).contains("\"mask\":2"))
    }
    @Test fun expiredActiveSourceClosesWithPendingAck() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20));g.offer(AirOutput(keys=1),ms(21),ms(21))
        assertTrue(g.poll(ms(171)) is AirSendGate.Action.Close)
        assertTrue(g.acknowledge("accepted",ms(172)) is AirSendGate.Action.Close)
    }
    @Test fun acknowledgedSourceExpirySendsNeutral() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20));g.offer(AirOutput(keys=1),ms(21),ms(21))
        g.acknowledge("accepted",ms(40))
        assertTrue(send(g.poll(ms(171))).contains("\"mask\":0"))
    }
    @Test fun rejectsReplayUnexpectedAckAndBackwardsClock() {
        val g=AirSendGate(AirWireLane.Helper(0,1),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(level=0.0),ms(21),ms(21))
        assertTrue(g.offer(AirOutput(level=.5),ms(21),ms(22)) is AirSendGate.Action.Close)
        val h=AirSendGate(AirWireLane.Keys(1),0)
        h.begin(0);assertTrue(h.acknowledge("other",ms(1)) is AirSendGate.Action.Close)
        val i=AirSendGate(AirWireLane.Keys(1),0)
        i.begin(ms(10));assertTrue(i.poll(ms(9)) is AirSendGate.Action.Close)
    }
    @Test fun heartbeatOnlyWhileNeutralAndExactAckDeadline() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        assertTrue(send(g.poll(ms(1000))).contains("\"kind\":\"heartbeat\""))
        assertTrue(g.poll(ms(1220)) is AirSendGate.Action.Close)
    }

    @Test fun observationCapturedBeforeNeutralAckCannotAttackAfterAck() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=1),ms(19),ms(21)))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=1),ms(20),ms(22)))
        assertTrue(send(g.offer(AirOutput(keys=1),ms(23),ms(23))).contains("\"mask\":1"))
        g.acknowledge("accepted",ms(30))
        g.offer(AirOutput(),ms(40),ms(40))
        g.acknowledge("accepted",ms(50))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=1),ms(49),ms(51)))
        assertTrue(send(g.offer(AirOutput(keys=1),ms(54),ms(54))).contains("\"mask\":1"))
    }
    @Test fun releaseDebtDeadlineCannotBeExtendedByNewSamples() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20));g.offer(AirOutput(keys=1),ms(21),ms(21))
        g.offer(AirOutput(),ms(30),ms(30))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=1),ms(179),ms(179)))
        assertTrue(g.poll(ms(180)) is AirSendGate.Action.Close)
    }

    @Test fun freshArrivalCannotBridgeExpiredSourceGap() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20));g.offer(AirOutput(keys=1),ms(21),ms(21))
        g.acknowledge("accepted",ms(40))
        assertTrue(send(g.offer(AirOutput(keys=1),ms(180),ms(180))).contains("\"mask\":0"))
        g.acknowledge("accepted",ms(190))
        assertTrue(send(g.offer(AirOutput(keys=1),ms(195),ms(195))).contains("\"mask\":1"))
    }
    @Test fun expiredSourcePendingAckCannotBeRefreshedByArrival() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20));g.offer(AirOutput(keys=1),ms(21),ms(21))
        assertTrue(g.offer(AirOutput(keys=1),ms(180),ms(180)) is AirSendGate.Action.Close)
    }
    @Test fun delayedNeutralUsesObservationDeadline() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20));g.offer(AirOutput(keys=1),ms(21),ms(21))
        g.offer(AirOutput(),ms(30),ms(100))
        assertTrue(g.poll(ms(180)) is AirSendGate.Action.Close)
    }

    @Test fun stringExpiresBeforeSourceWithoutNewFrames() {
        val g=AirSendGate(AirWireLane.Keys(3),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(keys=3),ms(21),ms(21),mapOf(0 to ms(100),1 to ms(141)))
        g.acknowledge("accepted",ms(30))
        assertTrue(send(g.poll(ms(100))).contains("\"mask\":2"))
        g.acknowledge("accepted",ms(110))
        assertTrue(send(g.poll(ms(141))).contains("\"mask\":0"))
    }
    @Test fun stringExpiryDuringPendingAckClosesEvenWithFreshSource() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(keys=1),ms(21),ms(21),mapOf(0 to ms(100)))
        assertTrue(g.acknowledge("accepted",ms(100)) is AirSendGate.Action.Close)
    }
    @Test fun expiredUnsentStringCannotBePlayed() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=1),ms(21),ms(100),mapOf(0 to ms(100))))
    }
    @Test fun invalidPartialOrExtendedStringDeadlineRejected() {
        for(d in listOf(mapOf(0 to ms(100)),mapOf(0 to ms(142),1 to ms(100)),mapOf(0 to ms(100),25 to ms(100)))) {
            val g=AirSendGate(AirWireLane.Keys(3),0)
            g.begin(0);g.acknowledge("accepted",ms(20))
            assertTrue(g.offer(AirOutput(keys=3),ms(21),ms(21),d) is AirSendGate.Action.Close)
        }
    }
    @Test fun newObservationCannotMaskExpiredTransmittedString() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(keys=1),ms(21),ms(21),mapOf(0 to ms(100)))
        g.acknowledge("accepted",ms(30))
        assertTrue(send(g.offer(AirOutput(keys=1),ms(100),ms(100),mapOf(0 to ms(220)))).contains("\"mask\":0"))
    }

    @Test fun stringReleaseCannotBeHiddenByPacing() {
        val g=AirSendGate(AirWireLane.Keys(3),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(keys=3),ms(21),ms(21),mapOf(0 to ms(31),1 to ms(100)))
        g.acknowledge("accepted",ms(25))
        assertTrue(g.poll(ms(31)) is AirSendGate.Action.Close)
    }

    @Test fun explicitNeutralModeFenceClearsOldSampleAndRequiresFreshAck() {
        val g=AirSendGate(AirWireLane.Keys(3),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(keys=1),ms(21),ms(21));g.acknowledge("accepted",ms(30))
        assertTrue(send(g.requestNeutral(ms(35))).contains("\"mask\":0"))
        assertFalse(g.neutralReady)
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=2),ms(36),ms(36)))
        g.acknowledge("accepted",ms(40))
        assertTrue(g.neutralReady)
        assertEquals(AirSendGate.Action.Wait,g.offer(AirOutput(keys=2),ms(39),ms(41)))
        assertTrue(send(g.offer(AirOutput(keys=2),ms(49),ms(49))).contains("\"mask\":2"))
    }
    @Test fun explicitNeutralWaitsForOrdinaryPendingAckWithoutReplayingAttack() {
        val g=AirSendGate(AirWireLane.Keys(3),0)
        g.begin(0);g.acknowledge("accepted",ms(20));g.offer(AirOutput(keys=1),ms(21),ms(21))
        assertEquals(AirSendGate.Action.Wait,g.requestNeutral(ms(22)))
        assertTrue(send(g.acknowledge("accepted",ms(35))).contains("\"mask\":0"))
        g.acknowledge("accepted",ms(36));assertTrue(g.neutralReady)
    }
    @Test fun transitionCannotDelayActiveStringOrExistingReleaseDebt() {
        val g=AirSendGate(AirWireLane.Keys(1),0)
        g.begin(0);g.acknowledge("accepted",ms(20))
        g.offer(AirOutput(keys=1),ms(21),ms(21),mapOf(0 to ms(100)))
        assertTrue(g.requestNeutral(ms(22)) is AirSendGate.Action.Close)
        val h=AirSendGate(AirWireLane.Keys(1),0)
        h.begin(0);h.acknowledge("accepted",ms(20));h.offer(AirOutput(keys=1),ms(21),ms(21))
        h.offer(AirOutput(),ms(30),ms(30));h.requestNeutral(ms(100))
        assertTrue(h.poll(ms(180)) is AirSendGate.Action.Close)
    }
}
