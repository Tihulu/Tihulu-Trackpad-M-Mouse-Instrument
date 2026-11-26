package com.tihulu.mobile.air

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.google.ar.core.Config
import com.google.ar.core.Session

/**
 * Single-use owner-thread ARCore diagnostic stage. The embedding app must
 * handle ARCore availability/install, camera permission, a current GL context,
 * OES camera texture, display geometry and exclusive camera ownership.
 * It transfers ownership of a PAUSED Session to start(); no CameraX overlap.
 * No sound, MIDI transport, UI thread dispatch or raw image export.
 */
class ArCoreAirStage(private val context:Context,private val modelAsset:String,
    private val rotation:Int,private val role:HandRole,mode:AirMode,
    authorized:Int,orientation:Orientation=Orientation.UP,mirror:Boolean=false,
    near:Double=.25,far:Double=.85,private val localModel:LocalHandModel?=null):AutoCloseable {
    init {
        require(rotation in listOf(0,90,180,270))
        require(mode==AirMode.BEAM_KEYS||mode==AirMode.BEAM_HELPER)
    }
    private val owner=Thread.currentThread()
    private val projection=AirProjection(mode,authorized,role,orientation,mirror,near,far,allowEstimatedDepth=true)
    private var session:Session?=null
    private var processor:ArCoreAirFrameProcessor?=null
    private var attempted=false
    private var stopped=false
    private var output=AirOutput()
    var observationAt:Long?=null
        private set
    val active:Boolean get() {checkOwner();return session!=null&&!stopped}
    private fun checkOwner(){check(Thread.currentThread()===owner)}
    fun start(pausedSession:Session,textureName:Int,displayRotation:Int,width:Int,height:Int):Boolean {
        checkOwner()
        // Invalid or repeated invocation does not acquire ownership.
        if(attempted||stopped||textureName<=0||displayRotation !in 0..3||width<=0||height<=0)return false
        attempted=true;session=pausedSession
        return try {
            if(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED||
                !ArCoreDepthReader.supports(pausedSession)){close();false}
            else {
                val config=pausedSession.config
                config.depthMode=Config.DepthMode.RAW_DEPTH_ONLY
                config.updateMode=Config.UpdateMode.LATEST_CAMERA_IMAGE
                pausedSession.configure(config)
                pausedSession.setCameraTextureName(textureName)
                pausedSession.setDisplayGeometry(displayRotation,width,height)
                processor=ArCoreAirFrameProcessor(context,modelAsset,rotation,localModel)
                pausedSession.resume()
                true
            }
        }catch(_:Exception){close();false}
    }
    /** Call on the GL owner with the texture context still current.
     * Duplicate sensor frames cannot refresh a note. The host also needs a
     * separate deadline watchdog outside this render loop before live MIDI. */
    fun tick():AirOutput {
        checkOwner()
        val s=session?:return AirOutput()
        if(stopped)return AirOutput()
        if(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED){
            close();return AirOutput()
        }
        return try {
            val capture=processor?.read(s.update(),role)
            val now=SystemClock.elapsedRealtimeNanos()
            if(capture!=null){output=projection.receive(capture.frame,now,capture.depth);observationAt=capture.frame.timeNs}
            projection.expire(now)?.let {output=it;if(it==AirOutput())observationAt=null}
            output
        }catch(_:Exception){close();AirOutput()}
    }
    /** Explicit release, pause, destruction or display/zoom reconfiguration.
     * Single-use: a fresh stage/session is needed to start again. */
    override fun close(){
        checkOwner()
        if(stopped)return
        stopped=true;output=AirOutput();observationAt=null
        val s=session;session=null
        try {s?.pause()}catch(_:Exception){}
        try {processor?.close()}catch(_:Exception){}
        processor=null
        try {s?.close()}catch(_:Exception){}
    }
}
