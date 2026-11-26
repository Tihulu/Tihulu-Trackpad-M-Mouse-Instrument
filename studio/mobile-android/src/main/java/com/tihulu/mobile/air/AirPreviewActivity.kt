package com.tihulu.mobile.air

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.os.Bundle
import java.util.concurrent.Executors
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.text.InputFilter
import android.text.InputType
import android.widget.*
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import com.google.ar.core.ArCoreApk

/** Local Air stage. Pairing is opt-in and only exposed by the separately
 * permissioned experimental companion. Raw camera/depth images stay local. */
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
    private lateinit var depthToggle:CheckBox
    private lateinit var depthRange:Spinner
    private lateinit var imageRotation:Spinner
    private var depthSource:ArCoreDiagnosticSource?=null
    private var depthRetiring:ArCoreDiagnosticSource?=null
    private var installRequested=false
    private val depthModes=listOf(AirMode.BEAM_KEYS,AirMode.BEAM_HELPER)
    private val depthRanges=listOf(.25 to .85,.15 to .55,.4 to 1.2)
    private lateinit var modelButton:Button
    private lateinit var modelStatus:TextView
    private val importer=Executors.newSingleThreadExecutor()
    private var localModel:LocalHandModel?=null
    private var importing=false
    private var destroyed=false
    private var choices:List<CameraChoice> = emptyList()
    private var range:ZoomRange?=null
    private var zoom=1f
    private var source:RgbHandSource?=null
    private var retiring:RgbHandSource?=null
    private var projection:AirProjection?=null
    private var pending=false
    private var ticket=0L
    private var pairedAllowed=false
    private lateinit var paired:CheckBox
    private lateinit var address:EditText
    private lateinit var invitation:EditText
    private lateinit var fingerprint:EditText
    private lateinit var rootButton:Button
    private lateinit var rootStatus:TextView
    private lateinit var helperPick:Spinner
    private lateinit var connectButton:Button
    private lateinit var disconnectButton:Button
    private lateinit var connectionStatus:TextView
    private lateinit var pairPanel:LinearLayout
    private var rootDer:ByteArray?=null
    private var lan:BoundedMobileLanSocket?=null
    private var observationFence:PairedObservationFence?=null
    private var lastPhase:MobileLanSession.Phase?=null
    private val locked get()=busy||lan!=null
    private val wantsPair get()=pairedAllowed&&paired.isChecked
    private fun selectedMode()=(if(depthToggle.isChecked)depthModes else modes).getOrNull(modePick.selectedItemPosition)
    private fun selectedRole()=HandRole.entries.getOrNull(rolePick.selectedItemPosition)
    private fun selectedOrientation()=Orientation.entries.getOrNull(orientationPick.selectedItemPosition)
    private fun selectedRange()=depthRanges.getOrNull(depthRange.selectedItemPosition)?:depthRanges.first()
    private fun pairedProjection():AirProjection? {
        val mode=selectedMode()?:return null
        val role=selectedRole()?:return null
        val orientation=selectedOrientation()?:return null
        val (near,far)=selectedRange()
        return lan?.newProjection(mode,role,orientation,mirror.isChecked,near,far,depthToggle.isChecked)
    }
    private fun clearInvitation(){invitation.text.clear()}
    private val rootPicker=registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if(uri!=null&&pairedAllowed&&!locked&&!destroyed) {
            val epoch=++ticket
            importing=true;rootDer=null;rootStatus.text="Reading bounded DER root…";controls()
            importer.execute {
                val result=runCatching {contentResolver.openInputStream(uri)?.use {MobileLanTrust.readDer(it)} ?: error("Cannot open certificate")}
                handler.post {
                    if(!destroyed&&epoch==ticket&&importing) {
                        importing=false
                        result.onSuccess {rootDer=it;rootStatus.text="Root loaded. Compare its fingerprint on your Mac before connecting."}
                            .onFailure {rootDer=null;rootStatus.text="Root rejected: empty, unreadable or too large"}
                        controls()
                    }
                }
            }
        }
    }
    private val modes=AirMode.entries.filter {it!=AirMode.BEAM_KEYS&&it!=AirMode.BEAM_HELPER}
    private val busy get()=pending||source!=null||retiring!=null||importing||depthSource!=null||depthRetiring!=null
    private val modelPicker=registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if(uri!=null&&!locked&&!destroyed) {
            val epoch=++ticket;importing=true;controls();modelStatus.text="Reading selected local model…"
            importer.execute {
                val result=runCatching {contentResolver.openInputStream(uri)?.use {LocalHandModel.read(it)} ?: error("Cannot open model")}
                handler.post {
                    if(!destroyed&&epoch==ticket&&importing) {
                        importing=false
                        result.onSuccess {localModel=it;modelStatus.text="Selected model SHA-256: "+it.sha256}
                            .onFailure {localModel=null;modelStatus.text="Model rejected: unreadable, empty or too large"}
                        controls()
                    }
                }
            }
        }
    }
    private val permission=registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        // Permission callback never starts capture; user must press Start again.
        status.text=if(granted)"Camera permission granted. Press Start." else "Camera permission denied."
        controls()
    }
    private val pulse=object:Runnable {
        override fun run() {
            lan?.let {client->
                val state=client.status()
                if(state.phase==MobileLanSession.Phase.CLOSED) {
                    end(state.message);handler.postDelayed(this,50);return
                }
                if(state.phase!=lastPhase) {
                    lastPhase=state.phase
                    connectionStatus.text=state.assignment?.let {assignment->
                        if(assignment.piano!=0)"Assigned keys: "+(0..24).filter{assignment.piano and (1 shl it)!=0}.joinToString{(it+1).toString()}
                        else "Assigned helper lane"
                    }?:state.message
                    controls()
                }
            }
            if((source!=null||depthSource!=null||lan!=null)&&ContextCompat.checkSelfPermission(this@AirPreviewActivity,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED) {
                end("Camera permission lost");handler.postDelayed(this,50);return
            }
            if(retiring?.isStopped==true) {retiring=null;controls()}
            if(depthRetiring?.isStopped==true){depthRetiring=null;controls()}
            depthSource?.let {d->
                val reading=d.read()
                if(d.isStopped){end(reading.status)}else {
                    status.text=reading.status
                    showOutput(reading.output)
                    reading.observedAt?.let {submit(reading.output,it,emptyMap(),true)}
                }
            }
            val s=source;val p=projection
            if(s!=null&&p!=null) {
                val now=SystemClock.elapsedRealtimeNanos()
                var out:AirOutput?=null
                for(frame in s.drain()) {
                    out=p.receive(frame,now)
                    if(!submit(out,frame.timeNs,p.stringDeadlines,false))break
                }
                if(source===s) {
                    val expired=p.expire(now)
                    if(expired!=null) out=expired
                    if(out!=null)showOutput(out)
                }
            }
            handler.postDelayed(this,50)
        }
    }
    override fun onCreate(state:Bundle?) {
        super.onCreate(state)
        pairedAllowed=ContextCompat.checkSelfPermission(this,Manifest.permission.INTERNET)==PackageManager.PERMISSION_GRANTED&&
            runCatching {packageManager.getApplicationInfo(packageName,PackageManager.GET_META_DATA)
                .metaData?.getBoolean("com.tihulu.mobile.PAIRED_AIR",false)==true}.getOrDefault(false)
        val column=LinearLayout(this).apply {orientation=LinearLayout.VERTICAL;setPadding(24,24,24,24)}
        fun label(text:String)=TextView(this).also {it.text=text;column.addView(it)}
        fun button(text:String,action:()->Unit)=Button(this).also {it.text=text;it.setOnClickListener {action()};column.addView(it)}
        fun spinner(labels:List<String>)=Spinner(this).also {
            it.adapter=ArrayAdapter(this,android.R.layout.simple_spinner_dropdown_item,labels);column.addView(it)
        }
        label("TIHULU · Android Air stage")
        label(if(pairedAllowed)"Local preview by default · explicit Mac pairing · no camera image transmission" else "RGB / optional ARCore diagnostics · no MIDI, no app network, no stored images")
        paired=CheckBox(this).also {it.text="Play through paired Mac";it.visibility=if(pairedAllowed)View.VISIBLE else View.GONE;column.addView(it)}
        pairPanel=LinearLayout(this).apply {orientation=LinearLayout.VERTICAL;visibility=View.GONE}
        column.addView(pairPanel)
        fun field(hintText:String,secret:Boolean=false):EditText=EditText(this).also {
            it.hint=hintText;it.setSingleLine(true);it.isSaveEnabled=false
            it.importantForAutofill=View.IMPORTANT_FOR_AUTOFILL_NO
            it.inputType=InputType.TYPE_CLASS_TEXT or if(secret)InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            it.filters=arrayOf(InputFilter.LengthFilter(64))
            pairPanel.addView(it)
        }
        fun pairButton(text:String,action:()->Unit)=Button(this).also {it.text=text;it.setOnClickListener{action()};pairPanel.addView(it)}
        address=field("Mac controller HTTPS address")
        invitation=field("Separate one-time invitation",true)
        fingerprint=field("Verified root SHA-256 (64 hex)")
        rootButton=pairButton("Choose verified Mac root (.der)") {if(!locked)rootPicker.launch(arrayOf("application/pkix-cert","application/octet-stream","*/*"))}
        rootStatus=TextView(this).also{it.text="No root loaded. Compare the fingerprint directly with the Mac.";pairPanel.addView(it)}
        helperPick=Spinner(this).also {it.adapter=ArrayAdapter(this,android.R.layout.simple_spinner_dropdown_item,listOf("Pedal 1","Pedal 2","Pedal 3"));pairPanel.addView(it)}
        connectButton=pairButton("Connect to Mac"){connectMac()}
        disconnectButton=pairButton("Disconnect / release"){end("Disconnected")}
        connectionStatus=TextView(this).also{it.text="Not connected";pairPanel.addView(it)}

        modelButton=button("Choose trusted local hand_landmarker.task") {if(!locked)modelPicker.launch(arrayOf("application/octet-stream","application/zip","*/*"))}
        modelStatus=label("No imported model. Select a trusted local .task file; its hash will be displayed.")
        choices=CameraInventory.list(this)
        cameraPick=spinner(choices.map { c ->
            val facing=when(c.facing){CameraCharacteristics.LENS_FACING_FRONT->"Front";CameraCharacteristics.LENS_FACING_BACK->"Rear";else->"External"}
            "$facing · camera ${c.id} · ${c.focalLengths.joinToString()} mm"+if(c.physicalIds.size>1)" · multi-lens" else ""
        })
        flip=button("Switch front / rear") {
            if(!locked) {
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
        depthToggle=CheckBox(this).also {it.text="Use ARCore raw depth (estimated/fused, rear camera)";column.addView(it)}
        depthRange=spinner(listOf("25–85 cm","15–55 cm","40–120 cm"))
        imageRotation=spinner(listOf("Raw image 0°","Raw image 90°","Raw image 180°","Raw image 270°"))
        label("Instrument / helper")
        modePick=spinner(modes.map {it.name.replace('_',' ')})
        rolePick=spinner(HandRole.entries.map {it.name})
        orientationPick=spinner(Orientation.entries.map {it.name})
        mirror=CheckBox(this).also {it.text="Mirror X";column.addView(it)}
        label("ARCore may require Google Play Services for AR; live depth is experimental. Native calibrated view: lens and zoom locked. Camera2 DEPTH16 remains inventory only.")
        status=label("Stopped")
        meter=label("All preview keys released")
        start=button("Start sensors"){begin()}
        stopButton=button("Stop / release"){end("Stopped")}
        cameraPick.onItemSelectedListener=object:AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent:AdapterView<*>?) {range=null;controls()}
            override fun onItemSelected(parent:AdapterView<*>?,view:View?,position:Int,id:Long) {
                if(!locked) {
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
                if(fromUser&&!locked){zoom=r.min+(r.max-r.min)*progress/1000f;showZoom()}
            }
            override fun onStartTrackingTouch(bar:SeekBar?) {}
            override fun onStopTrackingTouch(bar:SeekBar?) {}
        })
        depthToggle.setOnCheckedChangeListener {_,checked->
            if(!locked){modePick.adapter=ArrayAdapter(this,android.R.layout.simple_spinner_dropdown_item,(if(checked)depthModes else modes).map {it.name.replace('_',' ')});controls()}
        }
        paired.setOnCheckedChangeListener {_,checked->
            if(!locked){pairPanel.visibility=if(checked&&pairedAllowed)View.VISIBLE else View.GONE;clearInvitation();controls()}
        }
        modePick.onItemSelectedListener=object:AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent:AdapterView<*>?) {controls()}
            override fun onItemSelected(parent:AdapterView<*>?,view:View?,position:Int,id:Long){controls()}
        }
        setContentView(ScrollView(this).apply {addView(column)})
        controls()
    }
    private fun showOutput(out:AirOutput){
        meter.text=out.level?.let {"Helper: "+(it*100).toInt()+"%"}
            ?: if(out.keys==0) "All preview keys released" else "Logical keys: "+(0..24).filter {(out.keys and (1 shl it))!=0}.joinToString { (it+1).toString() }
    }
    private fun showZoom(){zoomLabel.text="Lens-relative zoom: %.2f×".format(zoom)}
    private fun setZoom(value:Float) {
        if(locked)return
        val r=range ?: return
        zoom=value.coerceIn(r.min,r.max)
        zoomBar.progress=if(r.max==r.min)0 else ((zoom-r.min)/(r.max-r.min)*1000).toInt()
        showZoom()
    }
    private fun controls() {
        val b=locked;val r=range
        val depth=depthToggle.isChecked
        for(v in listOf(modePick,rolePick,orientationPick,mirror,depthToggle))v.isEnabled=!b
        cameraPick.isEnabled=!b&&!depth
        depthRange.isEnabled=!b&&depth;imageRotation.isEnabled=!b&&depth
        flip.isEnabled=!b&&!depth&&choices.any {it.facing==CameraCharacteristics.LENS_FACING_FRONT}&&choices.any {it.facing==CameraCharacteristics.LENS_FACING_BACK}
        for(v in listOf(zoomBar,minus,plus,reset))v.isEnabled=!b&&!depth&&r!=null&&r.max>r.min
        modelButton.isEnabled=!b
        paired.isEnabled=!b&&pairedAllowed
        for(v in listOf(address,invitation,fingerprint,rootButton,helperPick))v.isEnabled=!b&&wantsPair
        helperPick.visibility=if(selectedMode()?.isHelper==true)View.VISIBLE else View.GONE
        connectButton.isEnabled=!b&&wantsPair
        disconnectButton.isEnabled=lan!=null
        start.text=if(wantsPair)"Start playing" else "Start sensors"
        start.isEnabled=!busy&&(depth||r?.admits(zoom)==true)&&(!wantsPair||pairedProjection()!=null)
        stopButton.isEnabled=pending||source!=null||depthSource!=null||lan!=null
    }
    private fun connectMac() {
        if(!wantsPair||locked||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))return
        if(ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED){
            permission.launch(Manifest.permission.CAMERA);return
        }
        val endpoint=MobileLanEndpoint.parse(address.text.toString())
        val secret=invitation.text.toString()
        val check=MobileLanEndpoint.invitationBytes(secret)
        check?.fill(0)
        val root=rootDer
        val digest=fingerprint.text.toString()
        val mode=selectedMode()
        if(endpoint==null||check==null||root==null||mode==null){
            connectionStatus.text="Enter the exact Mac address, invitation and verified DER root.";return
        }
        if(mode==AirMode.CHORDS&&selectedRole()==HandRole.SINGLE){
            connectionStatus.text="Choose a left or right performing hand for chords.";return
        }
        val selection=if(mode.isHelper)MobileLanSession.Selection.Helper(helperPick.selectedItemPosition) else MobileLanSession.Selection.Keys
        clearInvitation()
        val epoch=++ticket;importing=true;controls();connectionStatus.text="Verifying selected private root"
        importer.execute {
            val trust=MobileLanTrust.verifiedRoot(endpoint,root,digest)
            handler.post {
                if(destroyed||epoch!=ticket||!importing)return@post
                importing=false
                if(trust==null||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)){
                    connectionStatus.text="Root fingerprint or certificate invalid, or app inactive";controls();return@post
                }
                val client=BoundedMobileLanSocket(endpoint,selection,trust)
                lan=client;lastPhase=null
                if(!client.connect(secret)){end("Connection setup failed");return@post}
                connectionStatus.text="Connecting securely to selected Mac";controls()
            }
        }
    }
    private fun submit(out:AirOutput,at:Long,deadlines:Map<Int,Long>,latest:Boolean):Boolean {
        val client=lan?:return !wantsPair
        val fence=observationFence
        if(fence==null){end("Capture generation missing");return false}
        return when(fence.observe(at,SystemClock.elapsedRealtimeNanos(),latest)){
            PairedObservationFence.Verdict.DUPLICATE->true
            PairedObservationFence.Verdict.RETIRE->{end("Stale or replayed sensor observation");false}
            PairedObservationFence.Verdict.SEND->{client.offer(out,at,deadlines);true}
        }
    }
    private fun begin() {
        if(busy||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)||wantsPair&&pairedProjection()==null)return
        if(ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED) {
            permission.launch(Manifest.permission.CAMERA);return
        }
        if(depthToggle.isChecked){beginDepth();return}
        val c=choices.getOrNull(cameraPick.selectedItemPosition) ?: return
        val mode=modes[modePick.selectedItemPosition]
        val role=HandRole.entries[rolePick.selectedItemPosition]
        val p=if(wantsPair)pairedProjection() else runCatching {AirProjection(mode,(1 shl 25)-1,role,Orientation.entries[orientationPick.selectedItemPosition],mirror.isChecked)}.getOrNull()
        if(p==null){status.text="Select a compatible assigned instrument and performing hand";return}
        // The local model must be supplied by the embedding application.
        val model=localModel
        if(model==null&&runCatching {assets.open("hand_landmarker.task").use {}}.isFailure) {
            status.text="Local hand_landmarker.task asset required";return
        }
        observationFence=if(wantsPair)PairedObservationFence(SystemClock.elapsedRealtimeNanos()) else null
        val epoch=++ticket;pending=true;controls();status.text="Opening camera"
        val future=ProcessCameraProvider.getInstance(this)
        future.addListener({
            if(epoch==ticket&&pending&&lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                try {
                    if(wantsPair&&lan?.status()?.phase!=MobileLanSession.Phase.READY){end("Mac assignment ended");return@addListener}
                    val s=RgbHandSource(this,this,future.get(),"hand_landmarker.task",model) { message ->
                        if(epoch==ticket)end(message)
                    }
                    source=s;projection=p;pending=false;controls()
                    s.start(c.id,zoom);status.text="Sensor requested · waiting for observations"
                } catch(_:Exception){end("Camera provider unavailable")}
            }
        },ContextCompat.getMainExecutor(this))
    }
    private fun beginDepth(){
        val model=localModel
        if(model==null&&runCatching {assets.open("hand_landmarker.task").use {}}.isFailure){status.text="Choose a trusted local hand_landmarker.task first";return}
        try {
            val installer=ArCoreApk.getInstance()
            when(installer.requestInstall(this,!installRequested)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {installRequested=true;status.text="Complete ARCore installation, then press Start again";return}
                ArCoreApk.InstallStatus.INSTALLED -> installRequested=false
            }
            if(!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))return
            val range=depthRanges[depthRange.selectedItemPosition]
            val keys=if(wantsPair){
                if(pairedProjection()==null){end("Mac assignment ended");return}
                lan?.status()?.assignment?.piano?:run{end("Mac assignment ended");return}
            } else (1 shl 25)-1
            observationFence=if(wantsPair)PairedObservationFence(SystemClock.elapsedRealtimeNanos()) else null
            @Suppress("DEPRECATION") val displayRotation=windowManager.defaultDisplay.rotation
            val s=ArCoreDiagnosticSource(applicationContext,model,imageRotation.selectedItemPosition*90,displayRotation,
                HandRole.entries[rolePick.selectedItemPosition],depthModes[modePick.selectedItemPosition],
                Orientation.entries[orientationPick.selectedItemPosition],mirror.isChecked,range.first,range.second,keys)
            depthSource=s;controls();s.start();status.text="Starting ARCore diagnostic sensor"
        }catch(_:Exception){end("ARCore unavailable, unsupported or install declined")}
        catch(_:LinkageError){end("ARCore runtime not included by embedding app")}
    }
    private fun end(message:String) {
        ticket++;pending=false;importing=false
        observationFence?.retire();observationFence=null
        lan?.let {it.stop();connectionStatus.text=message};lan=null;lastPhase=null
        clearInvitation()
        source?.let {it.stop();retiring=it};source=null;projection=null
        depthSource?.let {it.stop();depthRetiring=it};depthSource=null
        meter.text="All preview keys released";status.text=message;controls()
    }
    override fun onResume(){super.onResume();handler.removeCallbacks(pulse);handler.post(pulse)}
    override fun onPause(){end("App inactive · stopped");handler.removeCallbacks(pulse);super.onPause()}
    override fun onDestroy(){destroyed=true;end("View closed");importer.shutdownNow();localModel=null;rootDer=null;handler.removeCallbacks(pulse);super.onDestroy()}
}
