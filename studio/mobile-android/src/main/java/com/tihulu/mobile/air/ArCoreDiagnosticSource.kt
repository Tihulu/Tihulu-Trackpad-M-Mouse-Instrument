package com.tihulu.mobile.air

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import com.google.ar.core.Session
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Single-use, offscreen GL owner for diagnostics only. No raw image output.
 * Owner must first obtain permission and complete ARCore installation.
 * Poll returns neutral if the underlying observation expires, even if the
 * sensor thread is blocked. Stop invalidates publication immediately. */
class ArCoreDiagnosticSource(private val context:Context,private val model:LocalHandModel?,
    private val rotation:Int,private val displayRotation:Int,private val role:HandRole,
    private val mode:AirMode,private val orientation:Orientation,private val mirror:Boolean,
    private val near:Double,private val far:Double) {
    data class Reading(val output:AirOutput=AirOutput(),val observedAt:Long?=null,val status:String="Stopped")
    private val state=AtomicReference(Reading())
    private val started=AtomicBoolean(false)
    private val cancelled=AtomicBoolean(false)
    private val stopped=AtomicBoolean(false)
    val isStopped get()=stopped.get()
    private val lease=Any()
    private val thread=HandlerThread("TIHULU-ARCore")
    private var handler:Handler?=null
    // All EGL, session and model objects are confined to the worker.
    private var display:EGLDisplay=EGL14.EGL_NO_DISPLAY
    private var surface:EGLSurface=EGL14.EGL_NO_SURFACE
    private var eglContext:EGLContext=EGL14.EGL_NO_CONTEXT
    private var texture=0
    private var stage:ArCoreAirStage?=null
    private fun publish(value:Reading){if(!cancelled.get())state.set(value)}
    @Synchronized fun start(){
        if(cancelled.get()||!started.compareAndSet(false,true))return
        if(!MobileCaptureLease.acquire(lease)){state.set(Reading(status="Another camera is still stopping"));stopped.set(true);return}
        state.set(Reading(status="Starting ARCore"))
        try {
            thread.start()
            val h=Handler(thread.looper);handler=h
            h.post {
                try {
                    if(cancelled.get()){cleanup();return@post}
                    initGL()
                    val next=ArCoreAirStage(context,"hand_landmarker.task",rotation,role,mode,(1 shl 25)-1,orientation,mirror,near,far,model)
                    stage=next
                    val session=Session(context)
                    if(!next.start(session,texture,displayRotation,640,480))error("Raw depth or session unavailable")
                    if(cancelled.get()){cleanup();return@post}
                    loop()
                }catch(_:Exception){fail("ARCore startup failed or raw depth unavailable")}
            }
        }catch(_:Exception){MobileCaptureLease.release(lease);stopped.set(true);state.set(Reading(status="Sensor worker unavailable"))}
    }
    private fun initGL(){
        display=EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display!=EGL14.EGL_NO_DISPLAY&&EGL14.eglInitialize(display,IntArray(1),0,IntArray(1),0))
        val configs=arrayOfNulls<EGLConfig>(1);val count=IntArray(1)
        val attrs=intArrayOf(EGL14.EGL_SURFACE_TYPE,EGL14.EGL_PBUFFER_BIT,EGL14.EGL_RENDERABLE_TYPE,EGL14.EGL_OPENGL_ES2_BIT,EGL14.EGL_RED_SIZE,8,EGL14.EGL_GREEN_SIZE,8,EGL14.EGL_BLUE_SIZE,8,EGL14.EGL_NONE)
        check(EGL14.eglChooseConfig(display,attrs,0,configs,0,1,count,0)&&count[0]>0)
        val config=checkNotNull(configs[0])
        eglContext=EGL14.eglCreateContext(display,config,EGL14.EGL_NO_CONTEXT,intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION,2,EGL14.EGL_NONE),0)
        surface=EGL14.eglCreatePbufferSurface(display,config,intArrayOf(EGL14.EGL_WIDTH,1,EGL14.EGL_HEIGHT,1,EGL14.EGL_NONE),0)
        check(eglContext!=EGL14.EGL_NO_CONTEXT&&surface!=EGL14.EGL_NO_SURFACE&&EGL14.eglMakeCurrent(display,surface,surface,eglContext))
        val ids=IntArray(1);GLES20.glGenTextures(1,ids,0);texture=ids[0];check(texture>0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,texture)
        for(p in intArrayOf(GLES20.GL_TEXTURE_MIN_FILTER,GLES20.GL_TEXTURE_MAG_FILTER))
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,p,GLES20.GL_LINEAR)
        for(p in intArrayOf(GLES20.GL_TEXTURE_WRAP_S,GLES20.GL_TEXTURE_WRAP_T))
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,p,GLES20.GL_CLAMP_TO_EDGE)
        check(GLES20.glGetError()==GLES20.GL_NO_ERROR)
    }
    private fun loop(){
        if(cancelled.get()){cleanup();return}
        try {
            val s=checkNotNull(stage);val output=s.tick()
            if(!s.active){fail("ARCore stopped; restart explicitly");return}
            publish(Reading(output,s.observationAt,"ARCore raw depth · estimated/fused"))
            handler?.postDelayed({loop()},16)
        }catch(_:Exception){fail("ARCore processing failed")}
    }
    fun read(now:Long=SystemClock.elapsedRealtimeNanos()):Reading {
        if(cancelled.get())return Reading()
        val r=state.get();val at=r.observedAt
        return if(at==null||now<at||now-at>=150_000_000L)r.copy(output=AirOutput(),observedAt=null) else r
    }
    @Synchronized fun stop(){
        if(!cancelled.compareAndSet(false,true))return
        state.set(Reading())
        val h=handler
        if(h==null){stopped.set(true);return}
        h.removeCallbacksAndMessages(null);h.post {cleanup()}
    }
    private fun fail(message:String){publish(Reading(status=message));cleanup()}
    private fun cleanup(){
        if(stopped.get())return
        try{stage?.close()}catch(_:Exception){}
        stage=null
        if(display!=EGL14.EGL_NO_DISPLAY){
            if(texture!=0)GLES20.glDeleteTextures(1,intArrayOf(texture),0)
            EGL14.eglMakeCurrent(display,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_CONTEXT)
            if(surface!=EGL14.EGL_NO_SURFACE)EGL14.eglDestroySurface(display,surface)
            if(eglContext!=EGL14.EGL_NO_CONTEXT)EGL14.eglDestroyContext(display,eglContext)
            EGL14.eglTerminate(display)
        }
        MobileCaptureLease.release(lease);stopped.set(true);thread.quitSafely()
    }
}
