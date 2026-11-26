package com.tihulu.mobile.air

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics as C
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicBoolean

/** One depth-only rear camera session. The image never leaves this worker.
 * Retain the retiring owner until the pending open/close callback completes. */
internal class Camera2XYZSource(context:Context, private val choice:CameraChoice,
    private val displayDegrees:Int, private val volume:XYZVolume) {
    data class Frame(val at:Long,val point:MeasuredXYZ?)
    private val manager=context.getSystemService(CameraManager::class.java)
    private val thread=HandlerThread("Tihulu measured depth").apply {start()}
    private val worker=Handler(thread.looper)
    private val closed=AtomicBoolean(false)
    @Volatile var stopped=false; private set
    @Volatile var fault:String?=null; private set
    private var device:CameraDevice?=null
    private var session:CameraCaptureSession?=null
    private var reader:ImageReader?=null
    private var opening=false
    private val frames=ArrayDeque<Frame>()
    fun drain():List<Frame> = synchronized(frames){ frames.toList().also{frames.clear()} }

    fun stop(){
        if(closed.compareAndSet(false,true))worker.post { closeResources() }
    }
    private fun fail(reason:String){
        if(fault==null)fault=reason
        stop()
    }
    private fun finish(){
        if(stopped)return
        stopped=true
        worker.looper.quitSafely()
    }
    private fun closeResources(){
        session?.close();session=null
        reader?.close();reader=null
        val d=device
        if(d!=null)d.close() else if(!opening)finish()
    }
    @SuppressLint("MissingPermission")
    fun start(){
        worker.post {
            if(closed.get())return@post
            try{
                val c=manager.getCameraCharacteristics(choice.id)
                val angle=c.get(C.SENSOR_ORIENTATION)
                if(!choice.depth16Advertised || c.get(C.LENS_FACING)!=C.LENS_FACING_BACK ||
                    angle==null || angle !in listOf(0,90,180,270) ||
                    c.get(C.SENSOR_INFO_TIMESTAMP_SOURCE)!=C.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME){
                    fail("Rear DEPTH16 with a verified real-time sensor clock is required");return@post
                }
                val size=c.get(C.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(ImageFormat.DEPTH16)
                    ?.filter {it.width in 32..1920 && it.height in 24..1080}
                    ?.minByOrNull {it.width*it.height}
                if(size==null){fail("No supported DEPTH16 stream size");return@post}
                val imageReader=ImageReader.newInstance(size.width,size.height,ImageFormat.DEPTH16,3)
                reader=imageReader
                val rotation=(angle-displayDegrees+360)%360
                imageReader.setOnImageAvailableListener({ source ->
                    if(!closed.get())try {
                        source.acquireNextImage()?.use { image ->
                            val at=image.timestamp
                            val age=SystemClock.elapsedRealtimeNanos()-at
                            if(at<=0 || age !in 0 until AirSendGate.FRESH_NS){
                                fail("Depth capture timestamp expired");return@use
                            }
                            val p=image.planes.singleOrNull()
                            val crop=image.cropRect
                            val point=if(image.format==ImageFormat.DEPTH16 && p!=null &&
                                crop.left==0 && crop.top==0 && crop.width()==image.width && crop.height()==image.height)
                                MeasuredDepthXYZ.read(DepthPlane(p.buffer,image.width,image.height,p.rowStride,p.pixelStride,2),volume,rotation)
                                else null
                            synchronized(frames){
                                if(frames.size>=12)fail("Depth frame backlog")
                                else frames.addLast(Frame(at,point))
                            }
                        }
                    }catch(_:Exception){fail("Depth frame unavailable")}
                },worker)
                opening=true
                manager.openCamera(choice.id,object:CameraDevice.StateCallback(){
                    override fun onOpened(camera:CameraDevice){
                        opening=false;device=camera
                        if(closed.get()){camera.close();return}
                        try {
                            @Suppress("DEPRECATION")
                            camera.createCaptureSession(listOf(imageReader.surface),object:CameraCaptureSession.StateCallback(){
                                override fun onConfigured(capture:CameraCaptureSession){
                                    if(closed.get()){capture.close();return}
                                    session=capture
                                    try{
                                        val request=camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                        request.addTarget(imageReader.surface)
                                        capture.setRepeatingRequest(request.build(),null,worker)
                                    }catch(_:Exception){fail("Depth acquisition failed")}
                                }
                                override fun onConfigureFailed(capture:CameraCaptureSession){capture.close();fail("DEPTH16 configuration rejected")}
                            },worker)
                        }catch(_:Exception){fail("Cannot configure the depth camera")}
                    }
                    override fun onDisconnected(camera:CameraDevice){opening=false;device=camera;fail("Depth camera disconnected");camera.close()}
                    override fun onError(camera:CameraDevice,error:Int){opening=false;device=camera;fail("Depth camera unavailable");camera.close()}
                    override fun onClosed(camera:CameraDevice){
                        device=null;opening=false
                        if(!closed.get())fail("Depth camera closed")
                        closeResources()
                    }
                },worker)
            }catch(_:Exception){opening=false;fail("Depth camera or permission unavailable")}
        }
    }
}
