package com.tihulu.mobile.air

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.*
import org.junit.Test

class AirAddressQrTest {
    private fun encoded(value:String):String? {
        val bits=QRCodeWriter().encode(value,BarcodeFormat.QR_CODE,256,256)
        val pixels=IntArray(256*256){i->if(bits[i%256,i/256])0xff000000.toInt() else 0xffffffff.toInt()}
        return AirAddressQr.decode(pixels,256,256)
    }
    @Test fun validAddressOnly() {
        val address="https://192.168.1.25:9444/"
        assertEquals(address,encoded(address))
        assertEquals("https://10.0.0.2:9444/",encoded("https://10.0.0.2:9444/"))
    }
    @Test fun neverAcceptTokenRedirectOrExternalAddress() {
        for(value in listOf("ab".repeat(32),"https://example.com:9444/","http://192.168.1.25:9444/",
            "https://192.168.1.25:9444/?invite="+"ab".repeat(32),"https://192.168.1.25:9444/#secret",
            "https://192.168.1.25:9444/ ","https://127.0.0.1:9444/"))assertNull(encoded(value))
    }
    @Test fun invalidDimensionsAndNonQrAreRejected() {
        assertFalse(AirAddressQr.admits(1025,1))
        assertFalse(AirAddressQr.admits(0,1))
        assertTrue(AirAddressQr.admits(1024,1024))
        assertNull(AirAddressQr.decode(IntArray(1),1025,1))
        assertNull(AirAddressQr.decode(IntArray(1),2,2))
        assertNull(AirAddressQr.decode(IntArray(256){-1},16,16))
    }
}
