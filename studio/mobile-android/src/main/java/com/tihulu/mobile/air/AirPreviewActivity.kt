package com.tihulu.mobile.air

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.widget.*
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle

/** Reusable, non-exported diagnostic screen inside a future host application.
 * Only local derived hand data. No sound, network, or live depth capture. */
class AirPreviewActivity: ComponentActivity() {
    private val handler=Handler(Looper.getMainLooper())
    private lateinit var cameraPick:Spinner
    private lateinit var modePick:Spinner
    private lateinit var rolePick:Spinner
    private lateinit var orientationPick:Spinner
    private lateinit var zoomBar:SeekBar
    private lateinit var zoomLabel:TextView
    private lateinit var status:TextView
    private lateinit var meter:TextView
    private lateinit var start:Button
    private lateinit var stopButton:Button
    private lateinit var flip:Button
    private lateinit var minus:Button
    private lateinit var plus:Button
    private lateinit var reset:Button
    private lateinit var mirror:CheckBox
    private var choices:List<CameraChoice> = emptyList()
    private var range:ZoomRange?=null
    private var zoom=1f
    private var source:RgbHandSource?=null
    private var retiring:RgbHandSource?=null
    private var projection:AirProjection?=null
    private var pending=false
    private var ticket=0L
    private val modes=AirMode.entries.filter {it!=AirMode.BEAM_KEYS&&it!=AirMode.BEAM_HELPER}
    private val busy get()=pending||source!=null||retiring!=null
    private val permission=registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        // Permission callback never starts capture; user must press Start again.
        status.text=if(granted)"Camera permission granted. Press Start." else "Camera permission denied."
        controls()
    }
    private val pulse=object:Runnable {
        override fun run() {
            if(retiring?.isStopped==true) {retiring=null;controls()}
            val s=source;val p=projection
            if(s!=null&&p!=null) {
                val now=SystemClock.elapsedRealtimeNanos()
                var out:AirOutput?=null
                for(frame in s.drain()) out=p.receive(frame,now)
                val expired=p.expire(now)
                if(expired!=null) out=expired
                if(out!=null) meter.text=out.level?.let {"Helper: "+(it*100).toInt()+"%"}
                    ?: if(out.keys==0) "All preview keys released" else "Logical keys: "+(0..24).filter {(out.keys and (1 shl it))!=0}.joinToString { (it+1).toString() }
            }
            handler.postDelayed(this,50)
        }
    }
    override fun onCreate(state:Bundle?) {
        super.onCreate(state)
        val column=LinearLayout(this).apply {orientation=LinearLayout.VERTICAL;setPadding(24,24,24,24)}
        fun label(text:String)=TextView(this).also {it.text=text;column.addView(it)}
        fun button(text:String,action:()->Unit)=Button(this).also {it.text=text;it.setOnClickListener {action()};column.addView(it)}
        fun spinner(labels:List<String>)=Spinner(this).also {
            it.adapter=ArrayAdapter(this,android.R.layout.simple_spinner_dropdown_item,labels);column.addView(it)
        }
        label("TIHULU · Android Air stage")
        label("RGB-only diagnostics · no MIDI, no network, no stored images")
        choices=CameraInventory.list(this)
        cameraPick=spinner(choices.map { c ->
            val facing=when(c.facing){CameraCharacteristics.LENS_FACING_FRONT->"Front";CameraCharacteristics.LENS_FACING_BACK->"Rear";else->"External"}
            "$facing · camera ${c.id} · ${c.focalLengths.joinToString()} mm"+if(c.physicalIds.size>1)" · multi-lens" else ""
        })
        flip=button("Switch front / rear") {
            if(!busy) {
                val current=choices.getOrNull(cameraPick.selectedItemPosition)?.facing
                val target=if(current==CameraCharacteristics.LENS_FACING_FRONT)CameraCharacteristics.LENS_FACING_BACK else CameraCharacteristics.LENS_FACING_FRONT
                val i=choices.indexOfFirst {it.facing==target}
                if(i>=0) cameraPick.setSelection(i)
            }
        }
        zoomLabel=label("Zoom")
        zoomBar=SeekBar(this).also {it.max=1000;column.addView(it)}
        minus=button("Zoom −"){setZoom(zoom/1.25f)}
        plus=button("Zoom +"){setZoom(zoom*1.25f)}
        reset=button("Reset zoom"){range?.let {setZoom(it.reset)}}
        label("Instrument / helper")
        modePick=spinner(modes.map {it.name.replace('_',' ')})
        rolePick=spinner(HandRole.entries.map {it.name})
        orientationPick=spinner(Orientation.entries.map {it.name})
        mirror=CheckBox(this).also {it.text="Mirror X";column.addView(it)}
        label("Depth mode unavailable in this preview. Camera2 depth capability is shown, not a verified aligned stream.")
        status=label("Stopped")
        meter=label("All preview keys released")
        start=button("Start sensors"){begin()}
        stopButton=button("Stop / release"){end("Stopped")}
        cameraPick.onItemSelectedListener=object:AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent:AdapterView<*>?) {range=null;controls()}
            override fun onItemSelected(parent:AdapterView<*>?,view:View?,position:Int,id:Long) {
                if(!busy) {
                    range=choices.getOrNull(position)?.zoom
                    setZoom(range?.reset ?: 1f)
                    val c=choices.getOrNull(position)
                    status.text=if(c?.depth16Advertised==true)"DEPTH16 advertised · not live" else "RGB camera selected"
                    controls()
                }
            }
        }
        zoomBar.setOnSeekBarChangeListener(object:SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(bar:SeekBar?,progress:Int,fromUser:Boolean) {
                val r=range ?: return
                if(fromUser&&!busy){zoom=r.min+(r.max-r.min)*progress/1000f;showZoom()}
            }
            override fun onStartTrackingTouch(bar:SeekBar?) {}
            override fun onStopTrackingTouch(bar:SeekBar?) {}
        })
        setContentView(ScrollView(this).apply {addView(column)})
        controls()
    }
    private fun showZoom(){zoomLabel.text="Lens-relative zoom: %.2f×".format(zoom)}
    private fun setZoom(value:Float) {
        if(busy)return
        val r=range ?: return
        zoom=value.coerceIn(r.min,r.max)
        zoomBar.progress=if(r.max==r.min)0 else ((zoom-r.min)/(r.max-r.min)*1000).toInt()
        showZoom()
    }
    private fun controls() {
        val b=busy;val r=range
        for(v in listOf(cameraPick,modePick,rolePick,orientationPick,mirror))v.isEnabled=!b
        flip.isEnabled=!b&&choices.any {it.facing==CameraCharacteristics.LENS_FACING_FRONT}&&choices.any {it.facing==CameraCharacteristics.LENS_FACING_BACK}
        for(v in listOf(zoomBar,minus,plus,reset))v.isEnabled=!b&&r!=null&&r.max>r.min
        start.isEnabled=!b&&r?.admits(zoom)==true
        stopButton.isEnabled=pending||source!=null
    }
    private fun begin() {
        if(busy||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))return
        if(ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED) {
            permission.launch(Manifest.permission.CAMERA);return
        }
        val c=choices.getOrNull(cameraPick.selectedItemPosition) ?: return
        val mode=modes[modePick.selectedItemPosition]
        val role=HandRole.entries[rolePick.selectedItemPosition]
        val p=runCatching {AirProjection(mode,(1 shl 25)-1,role,Orientation.entries[orientationPick.selectedItemPosition],mirror.isChecked)}.getOrElse {
            status.text="Select left or right hand for two-hand chords";return
        }
        // The local model must be supplied by the embedding application.
        if(runCatching {assets.open("hand_landmarker.task").use {}}.isFailure) {
            status.text="Local hand_landmarker.task asset required";return
        }
        val epoch=++ticket;pending=true;controls();status.text="Opening camera"
        val future=ProcessCameraProvider.getInstance(this)
        future.addListener({
            if(epoch==ticket&&pending&&lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                try {
                    val s=RgbHandSource(this,this,future.get(),"hand_landmarker.task") { message ->
                        if(epoch==ticket)end(message)
                    }
                    source=s;projection=p;pending=false;controls()
                    s.start(c.id,zoom);status.text="Sensor requested · waiting for observations"
                } catch(_:Exception){end("Camera provider unavailable")}
            }
        },ContextCompat.getMainExecutor(this))
    }
    private fun end(message:String) {
        ticket++;pending=false
        source?.let {it.stop();retiring=it};source=null;projection=null
        meter.text="All preview keys released";status.text=message;controls()
    }
    override fun onResume(){super.onResume();handler.removeCallbacks(pulse);handler.post(pulse)}
    override fun onPause(){end("App inactive · stopped");handler.removeCallbacks(pulse);super.onPause()}
    override fun onDestroy(){handler.removeCallbacks(pulse);super.onDestroy()}
}
