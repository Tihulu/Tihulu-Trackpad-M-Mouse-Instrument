package com.tihulu.mobile.air

import android.os.SystemClock
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Experimental bounded LAN socket, not enabled in the APK. One read
 * worker, one write worker, one independent deadline worker. No I/O
 * under the policy monitor, no unbounded write executor queue and no
 * automatic reconnect. A retired session closes its raw channel even
 * when a reader or writer is blocked. Actual TLS/device timing awaits
 * acceptance; this is not a hard real-time guarantee.
 */
internal class BoundedMobileLanSocket internal constructor(
    private val channel:LanChannel,
    selection:MobileLanSession.Selection,
    private val clock:()->Long
) {
    constructor(endpoint:MobileLanEndpoint,selection:MobileLanSession.Selection,
        privateRoot:MobileLanTrust?=null):this(BoundedLanTlsChannel(endpoint,privateRoot),selection,
            {SystemClock.elapsedRealtimeNanos()})

    private val driver=BoundedLanDriver(selection)
    private val lock=Any()
    private val wake=Semaphore(0)
    private val disposed=AtomicBoolean(false)
    private val reader=Executors.newSingleThreadExecutor {r->Thread(r,"TIHULU-bounded-LAN-read").apply{isDaemon=true}}
    private val writer=Executors.newSingleThreadExecutor {r->Thread(r,"TIHULU-bounded-LAN-write").apply{isDaemon=true}}
    private val watchdog=Executors.newSingleThreadScheduledExecutor {r->Thread(r,"TIHULU-bounded-LAN-deadline").apply{isDaemon=true}}
    private var output:OutputStream?=null

    /** State transitions are serialized; resource close is always outside
     * this monitor so blocked socket I/O cannot hold the policy hostage. */
    private fun <T> state(action:()->T):T {
        try {
            return synchronized(lock) {
                try {action()}
                finally {
                    if(driver.closed)output=null
                    if(driver.writeWaiting&&wake.availablePermits()==0)wake.release()
                }
            }
        }finally{
            if(synchronized(lock){driver.closed})dispose()
        }
    }
    data class Status(val phase:MobileLanSession.Phase,val message:String,
        val assignment:MobileLanCapabilities.Manifest?)
    fun status():Status=state {Status(driver.phase,driver.message,driver.assignment)}
    fun connect(invitation:String):Boolean {
        if(!state {driver.connect(invitation,clock())})return false
        return try {
            watchdog.scheduleAtFixedRate({
                try {state {driver.poll(clock())}}
                catch(_:Exception){retire("Deadline worker failed")}
            },25,25,TimeUnit.MILLISECONDS)
            writer.execute {writeLoop()}
            reader.execute {readLoop()}
            !state {driver.closed}
        }catch(_:Exception){retire("Connection setup failed");false}
    }
    fun offer(output:AirOutput,observedAt:Long,deadlines:Map<Int,Long> = emptyMap()) {
        try {state {driver.offer(output,observedAt,clock(),deadlines)}}
        catch(_:Exception){retire("Sensor submission failed")}
    }
    fun pauseForModeChange() {
        try {state {driver.pauseForModeChange(clock())}}
        catch(_:Exception){retire("Mode transition failed")}
    }
    fun newProjection(mode:AirMode,role:HandRole=HandRole.SINGLE,
        orientation:Orientation=Orientation.UP,mirror:Boolean=false,
        near:Double=.25,far:Double=.85,allowEstimatedDepth:Boolean=false):AirProjection? =
        state {driver.projection(mode,role,orientation,mirror,near,far,allowEstimatedDepth)}
    fun stop()=retire("Stopped explicitly")
    private fun retire(reason:String){state {driver.stop(reason)}}

    private fun readLoop() {
        try {
            val streams=channel.open()
            val ready=state {
                if(driver.closed)false else {
                    output=streams.output
                    driver.verifiedUpgrade(clock())
                    !driver.closed
                }
            }
            if(!ready)return
            val parser=BoundedLanFrameReader(streams.input)
            while(!state {driver.closed}) {
                val event=parser.next()
                state {driver.receive(event,clock())}
            }
        }catch(_:Exception){retire("TLS or receive failed")}
    }
    private fun writeLoop() {
        try {
            while(!state {driver.closed}) {
                wake.acquire()
                val job=state {
                    val lease=driver.take(clock())?:return@state null
                    val stream=output
                    if(stream==null){
                        lease.erase()
                        driver.stop("Transport missing")
                        null
                    }else lease to stream
                }?:continue
                val (lease,stream)=job
                try {
                    stream.write(lease.bytes)
                    stream.flush()
                    state {driver.complete(lease,clock())}
                }finally{lease.erase()}
            }
        }catch(_:Exception){retire("Transport write failed")}
    }
    private fun dispose() {
        if(!disposed.compareAndSet(false,true))return
        try {channel.close()}catch(_:Exception){}
        finally {
            watchdog.shutdownNow()
            reader.shutdownNow()
            writer.shutdownNow()
        }
    }
}
