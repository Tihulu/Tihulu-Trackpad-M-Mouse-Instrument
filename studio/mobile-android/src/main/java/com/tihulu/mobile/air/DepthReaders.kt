package com.tihulu.mobile.air

import android.graphics.ImageFormat
import android.media.Image
import com.google.ar.core.Config
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame as ArFrame
import com.google.ar.core.Session
import com.google.ar.core.TrackingState

/**
 * A reader for an embedding app's already-configured ARCore session.
 * The host owns camera permission, install check, GL/session lifecycle,
 * raw CPU-image hand inference and camera clock validation. Call synchronously
 * on the current Frame, before the next Session.update(). No session is opened
 * here. Never use a CameraX frame from a separate camera session.
 */
object ArCoreDepthReader {
    fun supports(session:Session):Boolean =
        session.isDepthModeSupported(Config.DepthMode.RAW_DEPTH_ONLY)
    fun read(frame:ArFrame,cpuImageTimestamp:Long,palmX:Float,palmY:Float,role:HandRole):AlignedDepth? {
        val t=frame.timestamp
        if(t<=0||t!=cpuImageTimestamp||frame.camera.trackingState!=TrackingState.TRACKING||
            !palmX.isFinite()||!palmY.isFinite()||palmX<0||palmY<0)return null
        return try {
            val size=frame.camera.imageIntrinsics.imageDimensions
            if(size.size!=2||palmX>=size[0]||palmY>=size[1])return null
            val uv=floatArrayOf(Float.NaN,Float.NaN)
            frame.transformCoordinates2d(Coordinates2d.IMAGE_PIXELS,floatArrayOf(palmX,palmY),Coordinates2d.TEXTURE_NORMALIZED,uv)
            if(uv.any {!it.isFinite()||it<0||it>=1})return null
            frame.acquireRawDepthImage16Bits().use {depth ->
                // Reprojected/older depth is not evidence for a moving hand.
                if(depth.timestamp!=t)return null
                frame.acquireRawDepthConfidenceImage().use {confidence ->
                    if(confidence.timestamp!=t)return null
                    val d=plane(depth,2)?:return null
                    val c=plane(confidence,1)?:return null
                    val meters=DepthNeighborhood.arCore(d,c,(uv[0]*d.width).toInt(),(uv[1]*d.height).toInt())?:return null
                    AlignedDepth(meters,DepthProvenance.ARCORE_ESTIMATED_OR_FUSED,t,t,role)
                }
            }
        }catch(_:Exception){null}
    }
}

/** Camera2 DEPTH16 reader. Caller must establish same-session RGB/depth
 * calibration and map the raw RGB palm to depth-plane pixel coordinates.
 * This does not infer alignment from equal dimensions or matching timestamps. */
object Camera2DepthReader {
    fun readAligned(image:Image,rgbTimestamp:Long,x:Int,y:Int,role:HandRole):AlignedDepth? {
        if(image.format!=ImageFormat.DEPTH16||!DepthPolicy.sameAcquisition(rgbTimestamp,image.timestamp))return null
        val d=plane(image,2)?:return null
        val meters=DepthNeighborhood.camera2(d,x,y)?:return null
        return AlignedDepth(meters,DepthProvenance.CAMERA2_DEPTH16,rgbTimestamp,image.timestamp,role)
    }
}
private fun plane(image:Image,sampleBytes:Int):DepthPlane? {
    val p=image.planes.singleOrNull()?:return null
    if(image.cropRect.left!=0||image.cropRect.top!=0||
        image.cropRect.right!=image.width||image.cropRect.bottom!=image.height)return null
    return DepthPlane(p.buffer,image.width,image.height,p.rowStride,p.pixelStride,sampleBytes)
}
