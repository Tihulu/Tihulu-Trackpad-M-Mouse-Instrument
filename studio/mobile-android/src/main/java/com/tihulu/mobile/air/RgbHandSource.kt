package com.tihulu.mobile.air

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.camera2.CameraCharacteristics
import android.os.SystemClock
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Single-use RGB sensor. Host UI owns permission and the consumer watchdog.
 * No MIDI, Internet permission, images in callbacks, or inferred depth.
 * Use a new source after stop before changing camera/zoom. */
@OptIn(ExperimentalCamera2Interop::class)
class RgbHandSource(private val context: Context, private val owner: LifecycleOwner,
    private val provider: ProcessCameraProvider, private val modelAsset: String,
    private val localModel:LocalHandModel?=null, private val fault: (String) -> Unit): DefaultLifecycleObserver {
    private val worker = Executors.newSingleThreadExecutor()
    private val closed = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val stopped = AtomicBoolean(false)
    val isStopped get() = stopped.get()
    private val ready = AtomicBoolean(false)
    private val lease=Any()
    private var analysis: ImageAnalysis? = null
    private var detector: HandLandmarker? = null // worker confined
    private var last = -1L
    private var lastSensor = -1L
    private var realtimeClock = false
    private val mailbox=ArrayDeque<Frame>()
    private val mailboxLock=Any()
    fun drain():List<Frame> = synchronized(mailboxLock) {
        val batch=mailbox.toList();mailbox.clear();batch
    }
    private fun emit(frame:Frame) {
        val overflow=synchronized(mailboxLock) {
            if (closed.get()) return
            if (mailbox.size>=16) { mailbox.clear();true } else {mailbox.addLast(frame);false}
        }
        if (overflow) fail("Sensor backlog; restart explicitly")
    }
    private val main = ContextCompat.getMainExecutor(context)
    // Main-thread only. The requested camera ID must be exposed by CameraX.
    fun start(id: String, zoom: Float) {
        if (!started.compareAndSet(false,true) || closed.get()) return
        if (!owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) ||
            ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            fail("Camera permission or active lifecycle required"); return
        }
        if(!MobileCaptureLease.acquire(lease)){fail("Another sensor is still stopping");return}
        owner.lifecycle.addObserver(this)
        try {
            val selector = CameraSelector.Builder().addCameraFilter { choices ->
                choices.filter { Camera2CameraInfo.from(it).cameraId == id }
            }.build()
            val useCase = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .setTargetResolution(android.util.Size(640,480)).build()
            analysis = useCase
            val camera: Camera = provider.bindToLifecycle(owner,selector,useCase)
            realtimeClock=Camera2CameraInfo.from(camera.cameraInfo).getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)==CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
            val state = camera.cameraInfo.zoomState.value ?: error("Zoom state unavailable")
            if (!ZoomRange(state.minZoomRatio,state.maxZoomRatio).admits(zoom)) error("Zoom unavailable")
            val applied = camera.cameraControl.setZoomRatio(zoom)
            applied.addListener({
                if (!closed.get()) {
                    try {
                        applied.get()
                        // Detector is allocated only after the zoom change was accepted.
                        ready.set(true)
                        useCase.setAnalyzer(worker,::analyze)
                    } catch (_: Exception) { fail("Camera zoom or analyzer setup failed") }
                }
            },main)
        } catch (_: Exception) { fail("Camera setup failed") }
    }
    override fun onPause(owner: LifecycleOwner) { stop() }
    override fun onDestroy(owner: LifecycleOwner) { stop() }
    fun stop() {
        if (!closed.compareAndSet(false,true)) return
        ready.set(false)
        synchronized(mailboxLock) {mailbox.clear()}
        main.execute {
            analysis?.let { it.clearAnalyzer(); provider.unbind(it) }
            analysis = null
            owner.lifecycle.removeObserver(this)
            worker.execute { try { detector?.close() } finally { detector=null; MobileCaptureLease.release(lease); stopped.set(true) } }
            worker.shutdown()
        }
    }
    private fun fail(message: String) {
        stop()
        main.execute { fault(message) }
    }
    private fun analyze(image: ImageProxy) {
        var raw: Bitmap? = null
        var upright: Bitmap? = null
        try {
            if (closed.get() || !ready.get()) return
            val receipt=SystemClock.elapsedRealtimeNanos()
            val sensor=image.imageInfo.timestamp
            if (sensor<=0 || sensor<=lastSensor) {emit(Frame(emptyList(),receipt));return}
            lastSensor=sensor
            val t=if(realtimeClock)sensor else receipt
            if(t>receipt||receipt-t>=150_000_000L) {emit(Frame(emptyList(),receipt));return}
            if (last >= 0 && t-last < 66_666_667L) return
            last=t
            val p=image.planes.firstOrNull() ?: run {emit(Frame(emptyList(),t));return}
            val crop=image.cropRect
            val pixels=RgbaPlane.toArgb(p.buffer,p.rowStride,p.pixelStride,image.width,image.height,crop.left,crop.top,crop.right,crop.bottom)
                ?: run {emit(Frame(emptyList(),t));return}
            val bitmap=Bitmap.createBitmap(pixels,crop.width(),crop.height(),Bitmap.Config.ARGB_8888)
            raw=bitmap
            val angle=image.imageInfo.rotationDegrees
            if (angle !in listOf(0,90,180,270)) { emit(Frame(emptyList(),t));return }
            val rotated=Bitmap.createBitmap(bitmap,0,0,bitmap.width,bitmap.height,
                Matrix().apply { postRotate(angle.toFloat()) },true)
            upright=rotated
            val engine=detector ?: HandLandmarker.createFromOptions(context,
                HandLandmarker.HandLandmarkerOptions.builder()
                    .setBaseOptions(BaseOptions.builder().apply {
                        if(localModel!=null)setModelAssetBuffer(localModel.directBuffer()) else setModelAssetPath(modelAsset)
                    }.build())
                    .setRunningMode(RunningMode.VIDEO).setNumHands(2)
                    .setMinHandDetectionConfidence(0.75f).setMinHandPresenceConfidence(0.75f)
                    .setMinTrackingConfidence(0.75f).build()).also { detector=it }
            val mp=BitmapImageBuilder(rotated).build()
            val result=try { engine.detectForVideo(mp,t/1_000_000) } finally { mp.close() }
            if (closed.get()) return
            if (SystemClock.elapsedRealtimeNanos()-t >= 150_000_000) {
                emit(Frame(emptyList(),t));return
            }
            val hands=result.landmarks().mapIndexedNotNull { i, points ->
                if (points.size != 21) return@mapIndexedNotNull null
                fun point(j:Int)=Point(points[j].x().toDouble(),1.0-points[j].y().toDouble())
                val hand=Hand.from(point(4),point(8),point(0),point(9)) ?: return@mapIndexedNotNull null
                val category=result.handedness().getOrNull(i)?.firstOrNull()
                val score=category?.score() ?: 0f
                val side=category?.categoryName()?.lowercase()?.takeIf { it in listOf("left","right") && score>=0.75f }
                Observation(hand,side,score,FingerGeometry.count(listOf(Triple(point(1),point(2),point(4)),Triple(point(5),point(6),point(8)),Triple(point(9),point(10),point(12)),Triple(point(13),point(14),point(16)),Triple(point(17),point(18),point(20)))))
            }
            emit(Frame(hands,t))
        } catch (_: Exception) { if (!closed.get()) fail("Hand inference failed; verify local model asset") }
        finally {
            if (upright !== raw) upright?.recycle()
            raw?.recycle(); image.close()
        }
    }
}
