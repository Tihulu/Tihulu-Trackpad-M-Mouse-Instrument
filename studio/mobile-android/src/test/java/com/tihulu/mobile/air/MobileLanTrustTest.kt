package com.tihulu.mobile.air

import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64

// Public, disposable test certificates only. Their private keys are not stored.
class MobileLanTrustTest {
    private val endpoint=MobileLanEndpoint.parse("https://192.168.1.25:9444/")!!
    private val root=Base64.getDecoder().decode("MIIC2zCCAcOgAwIBAgIBATANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJUSUhVTFUgVEVTVCBST09UIDEwHhcNMjAwMTAxMDAwMDAwWhcNNDUwMTAxMDAwMDAwWjAdMRswGQYDVQQDDBJUSUhVTFUgVEVTVCBST09UIDEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC++6l6zVVaIgla7Rfr3irj7jZVaMJvamV/ZCTNHNH8HoCXHiwz2uyJEsR9EbaGG0ruEpH0gMkLX/dUJtVelqc8xWVSzojHkaTP0tzP/jqhljHvG9aZh39nYXlCaidKogyho0NKMk//0627MFACGDxvN+I9PVZ5uPCYZoehPR7b3cgD+PzVztIEPxnr/BUl/iidOBocsc3RQ3AY6hkMuToVSjabNrymWa8ldHK/jmGXBa4ABQL/3f47o/iVXKe8p5zdqAssbOaQL7S44MsEHbX6NShfuVb334a/0yqQ7uiPdD8T9fhMwX64NhTkewFvO9vgIXQ8KyR+WRA1P37fzlIZAgMBAAGjJjAkMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IBAQCMHJMnixS7Ks9HwLrzum2gM2X/Zb0MmgcMCaDzW5pNXmUBJ2IsJEs2vhR62SarVis/Xud3BR9ah9o4m8Q8vGPXb6UNaiN2i1mj1jXkwnBuZhUhDB6+rCQmSZ4aWwSb4BZQcnWGTEtMQEaODc0BeMxCAK04lHB1S1yd7I96K+iWmc/jLcyNNMoH+1TfGbZJ8lI/eahVxUJhzamIL3/ErkpGYkuNJ3DNdemG0dK1oVrvvTgMrky50NIswcr+D75ETgoWIYNaOXPS3LTHKXVrOcvqWpHPJDwaEhNIOjCYR/e2MleubZk5oBE9o9tyO5luOio91pNnJ3EQr0GdAgymv+gb")
    private val otherRoot=Base64.getDecoder().decode("MIIC2zCCAcOgAwIBAgIBAjANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJUSUhVTFUgVEVTVCBST09UIDIwHhcNMjAwMTAxMDAwMDAwWhcNNDUwMTAxMDAwMDAwWjAdMRswGQYDVQQDDBJUSUhVTFUgVEVTVCBST09UIDIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/dU9RrrUDcW5eegAN7FBDblNPv6Fgvjz7zgcyZF6a48WICZkTSvexQ4qyhQKY4QXxAL7RTomwDVVzDWDdaHSNqQ2DKOmsvMm7NBSuaPTCINU+umT6gl3mOLaLMXfi7M39Vny+/n/aGfY79oxNg/WjbjI5TwC0wiN0WxqbrpIKTyB+VQ9wMoAj40vMuDN9WFrgLvldE4TD3daaiYPXUmKvmWdJl93tI/cEZHDSpd6cNcgpvc4WxidiR5pRDgayUG72ueOO7VwklaIRUIm1IOQRS8I7XXVG7G2ejpso5UZxJE103ESg830mV8fg/XmIs0FIj/cOl/E8GtqonMK9BJZPAgMBAAGjJjAkMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IBAQBVO36O9xTDzCDSzHek9LGZqe19PXu3e/rvE8xJZo3+mB6Xo5Vop4+0Y7smIlI3jKAypK8+Qqq4aLxXU2O03e70sw69GAfcaN+ihB8j4iRPhhfhBIlsuqmOnsFDhyCa8fF84M9ZmwK/SVfpzsZIrQ7OpRHnAByQW2P3xiBD5P/2BguuQd/PdOS/zDQIBt81JUzS/bMnqCymndp99rBsyUQouSDBf/VOZ1Gzpuk9TTOVMjr9Fn4EpnN2pW4lvOJCndYeY/pW4dbUGx3vWInvm4zexi+uYAmjofDG2W9bkY6ppNXSskfvznj7QtddIQs3x7mK0pfXjpqp+6QnixovJB6N")
    private val leaf=Base64.getDecoder().decode("MIIC9TCCAd2gAwIBAgIBAzANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJUSUhVTFUgVEVTVCBST09UIDEwHhcNMjAwMTAxMDAwMDAwWhcNNDAwMTAxMDAwMDAwWjAXMRUwEwYDVQQDDAwxOTIuMTY4LjEuMjUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDnRtF2XYf7flJC3ofNjmgpaJabX7p71R8a8wMAIu1ifckTMbUiqD2lmpJUhmk6q1trGwhr+s+lAnfdEX+jg/rJEedhTZGP5vn7fs8pbwIiDL1JnlUs2eP1aZ8FdzkJc2qPuHU52JjuG8ynLi6j5c5mMBO+S7mlsZ7k1KHMXXimPSgKRPBePy1wuBMHy2oP4RNXYEspCpiMVy/dBEqpADULz7GuvOsRx6pU31XOgaoztGMQpdv0GtKatwLdr0fT5XDovsp53GNTtHn2JZP4TpJPM2F7SyYbTVl3EvR5QsRQuVUjgaF0CoqthCG8w1cTu811t3PTH3q4pGeryOtsOchpAgMBAAGjRjBEMAwGA1UdEwEB/wQCMAAwDwYDVR0RBAgwBocEwKgBGTATBgNVHSUEDDAKBggrBgEFBQcDATAOBgNVHQ8BAf8EBAMCBaAwDQYJKoZIhvcNAQELBQADggEBAK8bo4nC77CtvPjkVjv4CVkeSAHIQ2UzahxyHyc5k3/S6+k3J3Q6c6dBgzMItppjlrwjYnPCHfp7gN+X0aZ6j9jRtkF4KA78ESzEMjbe9pvZG3dArunYIDt2KF+z9W/XR2eoVD0D/27wUFhuZEzAn6KwF45JKgWce67v+ujxOmk9tujjRj8j9YzFK393+d67JMmgL6lo9vcgbrZvqV9o+FFnS4JR5aUoDJF2h9l+m5S5OILVzFI57qxHuyFkJTYb1vsjljY8aZVWMOKD43AnxbeZmB6Qgq6C2+CNxRR6UGuQYk3M9qcwbzASJ3PWn1q/gULEbqdJoMEPxv3lmP9GxGE=")
    private val fingerprint="dbe91dd12e6898c7bba52753631404467baf2f585eee5b0fb1588b9e37ac6e49"
    private fun certificate(der:ByteArray)=CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate

    @Test fun verifiedPrivateRootAcceptsOnlyItsChain() {
        val trust=checkNotNull(MobileLanTrust.verifiedRoot(endpoint,root,fingerprint))
        assertEquals(endpoint.host,trust.host)
        assertEquals(listOf(certificate(root)),trust.manager.acceptedIssuers.toList())
        trust.manager.checkServerTrusted(arrayOf(certificate(leaf)),"RSA")
        val wrong=checkNotNull(MobileLanTrust.verifiedRoot(endpoint,otherRoot,"6c6d0bf1d612cbfd809830a52324ec87327e8d5394fdfc7e6ae1eb56ebf64845"))
        assertTrue(runCatching {wrong.manager.checkServerTrusted(arrayOf(certificate(leaf)),"RSA")}.isFailure)
    }
    @Test fun rejectsUnverifiedAndNonRootCertificates() {
        assertNull(MobileLanTrust.verifiedRoot(endpoint,root,"00".repeat(32)))
        assertNull(MobileLanTrust.verifiedRoot(endpoint,otherRoot,fingerprint))
        assertNull(MobileLanTrust.verifiedRoot(endpoint,root,fingerprint+" "))
        assertNull(MobileLanTrust.verifiedRoot(endpoint,leaf,"88d6f1612c51256c6fed0bc56cdf5f6fc11ffed3ca163c9088bd7576e187e3d6"))
    }
    @Test fun rejectsTrailingDataEvenIfFingerprintMatches() {
        val appended=root+byteArrayOf(0)
        val digest=java.security.MessageDigest.getInstance("SHA-256").digest(appended).joinToString(""){"%02x".format(it.toInt() and 255)}
        assertNull(MobileLanTrust.verifiedRoot(endpoint,appended,digest))
    }
    @Test fun rejectsOversizeImport() {
        val over=ByteArray(MobileLanTrust.MAX_CERTIFICATE_BYTES+1)
        assertTrue(runCatching {MobileLanTrust.readDer(ByteArrayInputStream(over))}.isFailure)
        assertTrue(runCatching {MobileLanTrust.readDer(ByteArrayInputStream(byteArrayOf()))}.isFailure)
        assertArrayEquals(root,MobileLanTrust.readDer(ByteArrayInputStream(root)))
        assertNull(MobileLanTrust.verifiedRoot(endpoint,over,fingerprint))
    }
    @Test fun trustIsHostBoundAndDoesNotReplaceHostnameVerifier() {
        val trust=checkNotNull(MobileLanTrust.verifiedRoot(endpoint,root,fingerprint))
        val different=MobileLanEndpoint.parse("https://192.168.1.26:9444/")!!
        assertTrue(runCatching {MobileLanSocket(different,MobileLanSession.Selection.Keys,trust)}.isFailure)
        val builder=OkHttpClient.Builder()
        val verifier=builder.build().hostnameVerifier
        trust.configure(builder)
        assertSame(verifier,builder.build().hostnameVerifier)
    }
}
