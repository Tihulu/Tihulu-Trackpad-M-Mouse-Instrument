package com.tihulu.mobile.air

import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader

/** Bounded local QR decoding. Never opens a URL, imports trust or reads
 * an invitation from a QR. Only the existing canonical address parser
 * may authorize the returned address. */
internal object AirAddressQr {
    const val MAX_SIDE=1024
    fun admits(width:Int,height:Int)=width in 1..MAX_SIDE&&height in 1..MAX_SIDE
    fun decode(pixels:IntArray,width:Int,height:Int):String? {
        if(!admits(width,height)||pixels.size!=width*height)return null
        return try {
            val source=RGBLuminanceSource(width,height,pixels)
            val result=QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)),
                mapOf(DecodeHintType.TRY_HARDER to true))
            val address=result.text
            if(MobileLanEndpoint.parse(address)!=null)address else null
        }catch(_:Exception){null}
    }
}
