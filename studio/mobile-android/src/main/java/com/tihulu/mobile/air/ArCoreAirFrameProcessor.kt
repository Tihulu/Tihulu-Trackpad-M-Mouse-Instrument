package com.tihulu.mobile.air

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.os.SystemClock
import com.google.ar.core.Frame as ArFrame
import com.google.ar.core.TrackingState
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker

/** GL/session-owner-thread processor. Inference and depth read occur before
 * the next Session.update(). Does not own a session or transmit MIDI.
 * Caller must separately expire the projection on a monotonic consumer clock.
 * Receipt time bounds inference only: ARCore timestamp is not assumed to
 * share the elapsedRealtimeNanos epoch. */
class ArCoreAirFrameProcessor(context:Context,modelAsset:String,private val clockwise:Int,localModel:LocalHandModel?=null):AutoCloseable {
    init { require(clockwise in listOf(0,90,180,270)) }
    private val owner=Thread.currentThread()
    private val engine=HandLandmarker.createFromOptions(context,
        HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(BaseOptions.builder().apply {if(localModel!=null)setModelAssetBuffer(localModel.directBuffer()) else setModelAssetPath(modelAsset)}.build())
            .setRunningMode(RunningMode.VIDEO).setNumHands(2)
            .setMinHandDetectionConfidence(.75f).setMinHandPresenceConfidence(.75f)
            .setMinTrackingConfidence(.75f).build())
    private var closed=false
    private var lastSensor=0L
    private var lastReceipt=-1L
    data class Capture(val frame:Frame,val depth:AlignedDepth?)
    private data class Detected(val observation:Observation,val palm:Point)
    fun read(frame:ArFrame,role:HandRole):Capture? {
        check(Thread.currentThread()===owner&&!closed)
        val now=SystemClock.elapsedRealtimeNanos()
        val sensor=frame.timestamp
        fun loss()=Capture(Frame(emptyList(),now,sensor),null)
        if(sensor<=0||frame.camera.trackingState!=TrackingState.TRACKING)return loss()
        if(sensor==lastSensor)return null // same camera frame; never refresh consumer lifetime
        if(sensor<lastSensor)return loss()
        lastSensor=sensor
        if(lastReceipt>=0&&now-lastReceipt<66_666_667L)return null
        lastReceipt=now
        var raw:Bitmap?=null
        var rotated:Bitmap?=null
        return try {
            val detected=frame.acquireCameraImage().use { image ->
                if(image.timestamp!=sensor||image.format!=ImageFormat.YUV_420_888||
                    image.cropRect.left!=0||image.cropRect.top!=0||
                    image.cropRect.right!=image.width||image.cropRect.bottom!=image.height||
                    image.planes.size!=3)return loss()
                val planes=image.planes.map {Yuv420.Plane(it.buffer,it.rowStride,it.pixelStride)}
                val pixels=Yuv420.argb(image.width,image.height,planes[0],planes[1],planes[2])?:return loss()
                val bmp=Bitmap.createBitmap(pixels,image.width,image.height,Bitmap.Config.ARGB_8888)
                raw=bmp
                val upright=Bitmap.createBitmap(bmp,0,0,bmp.width,bmp.height,
                    Matrix().apply {postRotate(clockwise.toFloat())},true)
                rotated=upright
                val mp=BitmapImageBuilder(upright).build()
                val result=try {engine.detectForVideo(mp,now/1_000_000)}finally {mp.close()}
                result.landmarks().mapIndexedNotNull {i,points->
                    if(points.size!=21)return@mapIndexedNotNull null
                    fun point(j:Int)=Point(points[j].x().toDouble(),1-points[j].y().toDouble())
                    val hand=Hand.from(point(4),point(8),point(0),point(9))?:return@mapIndexedNotNull null
                    val category=result.handedness().getOrNull(i)?.firstOrNull()
                    val score=category?.score()?:0f
                    val side=category?.categoryName()?.lowercase()?.takeIf {it in listOf("left","right")&&score.isFinite()&&score>=.75f}
                    val fingers=FingerGeometry.count(listOf(Triple(point(1),point(2),point(4)),Triple(point(5),point(6),point(8)),Triple(point(9),point(10),point(12)),Triple(point(13),point(14),point(16)),Triple(point(17),point(18),point(20))))
                    val a=point(0);val b=point(9)
                    val palm=PalmCoordinates.raw((a.x+b.x)/2,1-(a.y+b.y)/2,clockwise)?:return@mapIndexedNotNull null
                    Detected(Observation(hand,side,score,fingers),Point(palm.x*image.width,palm.y*image.height))
                }
            }
            if(SystemClock.elapsedRealtimeNanos()-now>=150_000_000L)return loss()
            val target=when(role) {
                HandRole.SINGLE->detected.singleOrNull()
                HandRole.LEFT->detected.filter {it.observation.side=="left"}.singleOrNull()
                HandRole.RIGHT->detected.filter {it.observation.side=="right"}.singleOrNull()
            }
            val depth=target?.let {ArCoreDepthReader.read(frame,sensor,it.palm.x.toFloat(),it.palm.y.toFloat(),role)}
            if(SystemClock.elapsedRealtimeNanos()-now>=150_000_000L)return loss()
            Capture(Frame(detected.map {it.observation},now,sensor),depth)
        } catch(_:Exception){loss()}
        finally {if(rotated!==raw)rotated?.recycle();raw?.recycle()}
    }
    override fun close() {
        check(Thread.currentThread()===owner)
        if(!closed){closed=true;engine.close()}
    }
}
