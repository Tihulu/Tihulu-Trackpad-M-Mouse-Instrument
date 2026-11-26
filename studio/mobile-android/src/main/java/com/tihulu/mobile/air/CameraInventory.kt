package com.tihulu.mobile.air

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics as C
import android.hardware.camera2.CameraManager
import android.os.Build

data class CameraChoice(val id: String, val facing: Int?, val focalLengths: List<Float>,
    val physicalIds: Set<String>, val zoom: ZoomRange?, val depth16Advertised: Boolean,
    val depthExclusive: Boolean?, val sensorOrientation: Int?)

object CameraInventory {
    fun list(context: Context): List<CameraChoice> {
        val manager = context.getSystemService(CameraManager::class.java)
        return manager.cameraIdList.mapNotNull { id ->
            runCatching {
                val c = manager.getCameraCharacteristics(id)
                val native = if (Build.VERSION.SDK_INT >= 30) c.get(C.CONTROL_ZOOM_RATIO_RANGE) else null
                val max = c.get(C.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
                val zoom = if (native != null) ZoomRange(native.lower,native.upper)
                    else max?.takeIf { it.isFinite() && it >= 1 }?.let { ZoomRange(1f,it) }
                val caps = c.get(C.REQUEST_AVAILABLE_CAPABILITIES) ?: intArrayOf()
                val depth = C.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT in caps &&
                    c.get(C.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(ImageFormat.DEPTH16)?.isNotEmpty() == true
                CameraChoice(id,c.get(C.LENS_FACING),c.get(C.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.filter { it.isFinite() && it > 0 }?.sorted() ?: emptyList(),
                    if (Build.VERSION.SDK_INT >= 28) c.physicalCameraIds else emptySet(),
                    zoom,depth,c.get(C.DEPTH_DEPTH_IS_EXCLUSIVE),c.get(C.SENSOR_ORIENTATION))
            }.getOrNull()
        }
    }
}
