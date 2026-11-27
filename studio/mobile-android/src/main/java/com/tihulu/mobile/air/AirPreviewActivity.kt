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
import android.text.Editable
import android.text.TextWatcher
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
    private lateinit var touchPreview:Button
    private lateinit var touchLive:Button
    private lateinit var touchPanel:LinearLayout
    private var livePiano:TouchPianoView?=null
    private var touchStage=false
    private lateinit var cameraPick:Spinner
    private lateinit var modePick:Spinner
    private lateinit var rolePick:Spinner
    private lateinit var orientationPick:Spinner
    private lateinit var zoomBar:SeekBar
    private lateinit var zoomLabel:TextView
    private lateinit var status:TextView
    private lateinit var meter:TextView
    private lateinit var feedback:AirStageFeedbackView
    private lateinit var start:Button
    private lateinit var stopButton:Button
    private lateinit var flip:Button
    private lateinit var minus:Button
    private lateinit var plus:Button
    private lateinit var reset:Button
    private lateinit var mirror:CheckBox
    private lateinit var depthToggle:CheckBox
    private lateinit var depthRange:Spinner
    private lateinit var customNear:EditText
    private lateinit var customFar:EditText
    private lateinit var modeGuide:TextView
    private lateinit var responseGuide:TextView
    private var captureRotation:Int?=null
    private lateinit var imageRotation:Spinner
    private var depthSource:ArCoreDiagnosticSource?=null
    private var depthRetiring:ArCoreDiagnosticSource?=null
    private lateinit var xyz:CheckBox
    private lateinit var xyzSettings:XYZSettings
    private var xyzSource:Camera2XYZSource?=null
    private var xyzRetiring:Camera2XYZSource?=null
    private var xyzVolume:XYZVolume?=null
    private var xyzCaptureSelection:XYZSetupSelection?=null
    private var xyzTracking:MeasuredXYZTracking?=null
    private var xyzStage:XYZStageView?=null
    private var xyzKeys:MeasuredXYZKeys?=null
    private var xyzRotation=0
    private var xyzLastAt:Long?=null
    @Suppress("DEPRECATION")
    private fun displayDegrees()=windowManager.defaultDisplay.rotation*90
    private val measuredMode get()=xyz.isChecked && !wantsTouchPair
    private fun measuredCamera()=choices.getOrNull(cameraPick.selectedItemPosition)?.takeIf {
        it.depth16Advertised && it.facing==CameraCharacteristics.LENS_FACING_BACK
    }
    private fun xyzAssigned():Boolean {
        val manifest=lan?.status()?.assignment?:return false
        val selected=xyzSettings.selection?:return false
        return when {
            selected.hybrid -> manifest.hybridLane(selected.mask)!=null
            selected.pitchAxis!=null -> manifest.keysLane()!=null
            else -> manifest.xyzLane(selected.mask)!=null
        }
    }
    private var installRequested=false
    private val depthModes=listOf(AirMode.BEAM_KEYS,AirMode.BEAM_HELPER)
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
    private lateinit var touchOnly:CheckBox
    private lateinit var address:EditText
    private lateinit var invitation:EditText
    private lateinit var fingerprint:EditText
    private lateinit var qrButton:Button
    private lateinit var rootButton:Button
    private lateinit var rootStatus:TextView
    private lateinit var helperPick:Spinner
    private lateinit var connectButton:Button
    private lateinit var disconnectButton:Button
    private lateinit var pauseModeButton:Button
    private lateinit var connectionStatus:TextView
    private lateinit var pairPanel:LinearLayout
    private var qrRequested=false
    private var rootDer:ByteArray?=null
    private var lan:BoundedMobileLanSocket?=null
    private var observationFence:PairedObservationFence?=null
    private var lastPhase:MobileLanSession.Phase?=null
    private val locked get()=busy||lan!=null||qrRequested
    private val wantsPair get()=pairedAllowed&&paired.isChecked
    private val wantsTouchPair get()=wantsPair&&touchOnly.isChecked
    private val canEditInstrument get()=!wantsTouchPair&&!busy&&!qrRequested&&(lan==null||lan?.status()?.phase==MobileLanSession.Phase.READY)
    private fun selectedMode()=(if(depthToggle.isChecked)depthModes else modes).getOrNull(modePick.selectedItemPosition)
    private fun selectedRole()=HandRole.entries.getOrNull(rolePick.selectedItemPosition)
    private fun selectedRange()=AirDepthCalibration.selected(depthRange.selectedItemPosition,customNear.text.toString(),customFar.text.toString())
    private fun validRole()=selectedMode()!=null && selectedRole()!=null && (selectedMode()!=AirMode.CHORDS || selectedRole()!=HandRole.SINGLE)
    private fun airSetup()=AirSetupSnapshot.resolve(depthToggle.isChecked,selectedMode(),selectedRole(),
        orientationPick.selectedItemPosition,imageRotation.selectedItemPosition,
        if(depthToggle.isChecked) selectedRange() else null)
    private fun validAirSetup()=airSetup()!=null
    private fun pairedProjection(setup:AirSetupSnapshot?=airSetup()):AirProjection? {
        val selected=setup?:return null
        return lan?.newProjection(selected.mode,selected.role,selected.orientation,mirror.isChecked,
            selected.near,selected.far,selected.rawRotation!=null)
    }
    private fun clearInvitation(){invitation.text.clear()}
    private val qrCamera=registerForActivityResult(ActivityResultContracts.TakePicturePreview()) { bitmap ->
        val expected=qrRequested
        qrRequested=false
        if(bitmap==null||!expected||destroyed||!wantsPair||locked) {
            bitmap?.recycle()
            if(!destroyed)controls()
            return@registerForActivityResult
        }
        val epoch=++ticket
        importing=true;controls();connectionStatus.text="Reading QR locally"
        importer.execute {
            val result=try {
                if(!AirAddressQr.admits(bitmap.width,bitmap.height))null else {
                    val pixels=IntArray(bitmap.width*bitmap.height)
                    bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
                    AirAddressQr.decode(pixels,bitmap.width,bitmap.height)
                }
            }catch(_:Exception){null}
            finally{bitmap.recycle()}
            handler.post {
                if(!destroyed&&epoch==ticket&&importing){
                    importing=false
                    if(result!=null&&wantsPair) {
                        address.setText(result);clearInvitation()
                        connectionStatus.text="Mac address scanned. Enter the separate invitation and verify the root."
                    }else connectionStatus.text="No valid private Mac address QR. Try again or type the address."
                    controls()
                }
            }
        }
    }
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
    private val busy get()=xyzSource!=null||xyzRetiring!=null||touchStage||pending||source!=null||retiring!=null||importing||depthSource!=null||depthRetiring!=null
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
    private fun cameraPermitted() = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    private fun captureFailure() = AirCaptureLifecycle.failure(captureRotation, displayDegrees(),
        lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED), cameraPermitted())
    private val pulse=object:Runnable {
        override fun run() {
            if(pending||source!=null||depthSource!=null||xyzSource!=null) {
                captureFailure()?.let {
                    end(it.message);handler.postDelayed(this,50);return
                }
            }
            lan?.let {client->
                val state=client.status()
                if(state.phase==MobileLanSession.Phase.CLOSED) {
                    end(state.message);handler.postDelayed(this,50);return
                }
                if(state.phase!=lastPhase) {
                    lastPhase=state.phase
                    connectionStatus.text=state.assignment?.let {assignment->
                        if(assignment.piano!=0 && assignment.pedals!=0) "Assigned XYZ Hybrid · keys and helper axes"
                        else if(assignment.piano!=0)"Assigned keys: "+(0..24).filter{assignment.piano and (1 shl it)!=0}.joinToString{(it+1).toString()}
                        else "Assigned helper lane"
                    }?:state.message
                    controls()
                }
            }
            if(lan!=null&&!wantsTouchPair&&!cameraPermitted()) {
                end("Camera permission lost");handler.postDelayed(this,50);return
            }
            if(retiring?.isStopped==true) {retiring=null;controls()}
            if(depthRetiring?.isStopped==true){depthRetiring=null;controls()}
            if(xyzRetiring?.stopped==true){xyzRetiring=null;controls()}
            xyzSource?.let { source ->
                val volume=xyzVolume
                val tracker=xyzTracking
                val selected=xyzCaptureSelection
                val failure=source.fault
                if(failure!=null || displayDegrees()!=xyzRotation || volume==null || tracker==null || selected==null){
                    end(failure?:"Display rotation changed · restart required")
                } else {
                    for(frame in source.drain()) {
                        val axes=tracker.observe(frame.point,frame.at,SystemClock.elapsedRealtimeNanos())
                        val pitch=xyzKeys?.output(frame.point?.takeIf {axes.xyz!=null}?.let {volume.axes(it,7)})
                        val output=when {
                            pitch==null -> axes
                            selected.hybrid -> axes.copy(keys=pitch.keys)
                            else -> pitch
                        }
                        if(!submit(output,frame.at,emptyMap(),false))break
                        xyzLastAt=frame.at
                        xyzStage?.update(frame.point.takeIf {axes.xyz!=null},volume,output.keys)
                    }
                    if(tracker.expire(SystemClock.elapsedRealtimeNanos()) || xyzLastAt?.let {SystemClock.elapsedRealtimeNanos()-it>=AirSendGate.FRESH_NS}==true){
                        xyzLastAt=null;xyzKeys?.output(null);xyzStage?.update(null,volume)
                    }
                }
            }
            depthSource?.let {d->
                val reading=d.read()
                if(d.isStopped){end(reading.status)}else {
                    status.text=reading.status
                    val at=reading.observedAt
                    if(at==null || submit(reading.output,at,emptyMap(),true)) {
                        if(depthSource===d)showOutput(reading.output)
                    }
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
        touchPreview=button("Touch piano · local preview") {
            if(!locked)startActivity(android.content.Intent(this,TouchPianoPreviewActivity::class.java))
        }
        label(if(pairedAllowed)"Local preview by default · explicit Mac pairing · no camera image transmission" else "RGB / optional ARCore diagnostics · no MIDI, no app network, no stored images")
        paired=CheckBox(this).also {it.text="Play through paired Mac";it.visibility=if(pairedAllowed)View.VISIBLE else View.GONE;column.addView(it)}
        pairPanel=LinearLayout(this).apply {orientation=LinearLayout.VERTICAL;visibility=View.GONE}
        column.addView(pairPanel)
        fun field(hintText:String,secret:Boolean=false):EditText=EditText(this).also {
            it.hint=hintText;it.setSingleLine(true);it.isSaveEnabled=false
            it.importantForAutofill=View.IMPORTANT_FOR_AUTOFILL_NO
            it.inputType=InputType.TYPE_CLASS_TEXT or if(secret)InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            it.filters=arrayOf(InputFilter.LengthFilter(128))
            pairPanel.addView(it)
        }
        fun pairButton(text:String,action:()->Unit)=Button(this).also {it.text=text;it.setOnClickListener{action()};pairPanel.addView(it)}
        touchOnly=CheckBox(this).also {it.text="Pair for touch piano only (no camera)";pairPanel.addView(it)}
        address=field("Mac controller HTTPS address")
        qrButton=pairButton("Scan Mac address QR (camera photo)"){scanAddress()}
        invitation=field("Separate one-time invitation",true)
        fingerprint=field("Verified root SHA-256 (64 hex)")
        rootButton=pairButton("Choose verified Mac root (.der)") {if(!locked)rootPicker.launch(arrayOf("application/pkix-cert","application/octet-stream","*/*"))}
        rootStatus=TextView(this).also{it.text="No root loaded. Compare the fingerprint directly with the Mac.";pairPanel.addView(it)}
        helperPick=Spinner(this).also {it.adapter=ArrayAdapter(this,android.R.layout.simple_spinner_dropdown_item,listOf("Pedal 1","Pedal 2","Pedal 3"));pairPanel.addView(it)}
        connectButton=pairButton("Connect to Mac"){connectMac()}
        disconnectButton=pairButton("Disconnect / release"){end("Disconnected")}
        pauseModeButton=pairButton("Pause / change instrument"){pauseInstrument()}
        connectionStatus=TextView(this).also{it.text="Not connected";pairPanel.addView(it)}
        touchLive=pairButton("Open assigned touch piano"){openTouchPiano()}
        touchPanel=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;visibility=View.GONE}
        column.addView(touchPanel)

        modelButton=button("Choose trusted local hand_landmarker.task") {if(!locked)modelPicker.launch(arrayOf("application/octet-stream","application/zip","*/*"))}
        modelStatus=label("No imported model. Select a trusted local .task file; its hash will be displayed.")
        choices=CameraInventory.list(this)
        cameraPick=spinner(choices.map { c ->
            val facing=when(c.facing){CameraCharacteristics.LENS_FACING_FRONT->"Front";CameraCharacteristics.LENS_FACING_BACK->"Rear";else->"External"}
            "$facing · camera ${c.id} · ${c.focalLengths.joinToString()} mm"+if(c.physicalIds.size>1)" · multi-lens" else ""
        })
        flip=button("Switch front / rear") {
            if(canEditInstrument&&!depthToggle.isChecked) {
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
        depthRange=spinner(listOf("25–85 cm","15–55 cm","40–120 cm","Custom (cm)"))
        fun calibrationField(hintText:String,initial:String)=EditText(this).also {
            it.hint=hintText;it.contentDescription=hintText;it.setSingleLine(true)
            it.inputType=InputType.TYPE_CLASS_NUMBER;it.filters=arrayOf(InputFilter.LengthFilter(3))
            it.setText(initial);column.addView(it)
        }
        customNear=calibrationField("Near distance (cm)","25")
        customFar=calibrationField("Far distance (cm)","85")
        imageRotation=spinner(listOf("Raw image 0°","Raw image 90°","Raw image 180°","Raw image 270°"))
        label("Instrument / helper")
        modePick=spinner(modes.map {it.name.replace('_',' ')}).apply {contentDescription="Air instrument or helper mode"}
        rolePick=spinner(HandRole.entries.map {it.name}).apply {contentDescription="Performing hand"}
        orientationPick=spinner(Orientation.entries.map {it.name}).apply {contentDescription="Musical control orientation"}
        mirror=CheckBox(this).also {it.text="Mirror X";column.addView(it)}
        modeGuide=label("")
        responseGuide=label("")
        xyz=CheckBox(this).apply {text="Measured XYZ · Camera2 DEPTH16";column.addView(this)}
        xyzSettings=XYZSettings(this){measuredCamera()?.id}
        column.addView(xyzSettings)
        label("ARCore may require Google Play Services for AR; live depth is experimental. Native calibrated view: lens and zoom locked. Measured XYZ requires a rear DEPTH16 stream with a real-time sensor clock.")
        status=label("Stopped")
        meter=label("All preview keys released")
        feedback=AirStageFeedbackView(this);column.addView(feedback)
        start=button("Start sensors"){begin()}
        stopButton=button("Stop / release"){end("Stopped")}
        cameraPick.onItemSelectedListener=object:AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent:AdapterView<*>?) {range=null;controls()}
            override fun onItemSelected(parent:AdapterView<*>?,view:View?,position:Int,id:Long) {
                if(canEditInstrument&&!depthToggle.isChecked) {
                    range=choices.getOrNull(position)?.zoom
                    setZoom(range?.reset ?: 1f)
                    val c=choices.getOrNull(position)
                    status.text=if(c?.depth16Advertised==true)"DEPTH16 advertised · select Measured XYZ to start" else "RGB camera selected"
                    controls()
                }
            }
        }
        zoomBar.setOnSeekBarChangeListener(object:SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(bar:SeekBar?,progress:Int,fromUser:Boolean) {
                val r=range ?: return
                if(fromUser&&canEditInstrument&&!depthToggle.isChecked){zoom=r.min+(r.max-r.min)*progress/1000f;showZoom()}
            }
            override fun onStartTrackingTouch(bar:SeekBar?) {}
            override fun onStopTrackingTouch(bar:SeekBar?) {}
        })
        depthToggle.setOnCheckedChangeListener {_,checked->
            if(canEditInstrument){modePick.adapter=ArrayAdapter(this,android.R.layout.simple_spinner_dropdown_item,(if(checked)depthModes else modes).map {it.name.replace('_',' ')});controls()}
        }
        xyz.setOnCheckedChangeListener {_,checked ->
            if(!locked){
                if(checked)depthToggle.isChecked=false
                controls()
            }
        }
        paired.setOnCheckedChangeListener {_,checked->
            if(!locked){pairPanel.visibility=if(checked&&pairedAllowed)View.VISIBLE else View.GONE;clearInvitation();controls()}
        }
        touchOnly.setOnCheckedChangeListener {_,_->if(!locked){clearInvitation();controls()}}
        val refreshSelection=object:AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent:AdapterView<*>?) {controls()}
            override fun onItemSelected(parent:AdapterView<*>?,view:View?,position:Int,id:Long){controls()}
        }
        for(picker in listOf(modePick,rolePick,depthRange,orientationPick,imageRotation,helperPick))picker.onItemSelectedListener=refreshSelection
        val refreshCalibration=object:TextWatcher {
            override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){}
            override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){}
            override fun afterTextChanged(s:Editable?){controls()}
        }
        customNear.addTextChangedListener(refreshCalibration);customFar.addTextChangedListener(refreshCalibration)
        xyzSettings.selectionChanged={controls()}
        setContentView(ScrollView(this).apply {addView(column)})
        controls()
    }
    private fun showOutput(out:AirOutput){
        if(touchStage){
            meter.text=if(out.keys==0) "All preview keys released" else "Logical keys: "+(0..24).filter {(out.keys and (1 shl it))!=0}.joinToString { (it+1).toString() }
            return
        }
        val mode=selectedMode() ?: return
        val keys=if(wantsPair)lan?.status()?.assignment?.piano?:0 else (1 shl 25)-1
        val state=AirStageFeedback.from(mode,keys,out)
        feedback.render(mode,state)
        val description=if(mode.isHelper)state.level?.let {"Projected helper: "+(it*100).toInt()+"%"} ?: "Helper released"
            else if(state.active.isEmpty()) "All preview keys released" else "Projected logical keys: "+state.active.joinToString { (it+1).toString() }
        if(meter.text.toString()!=description)meter.text=description
    }
    private fun showZoom(){zoomLabel.text="Lens-relative zoom: %.2f×".format(zoom)}
    private fun setZoom(value:Float) {
        if(!canEditInstrument||depthToggle.isChecked)return
        val r=range ?: return
        zoom=value.coerceIn(r.min,r.max)
        zoomBar.progress=if(r.max==r.min)0 else ((zoom-r.min)/(r.max-r.min)*1000).toInt()
        showZoom()
    }
    private fun controls() {
        val b=locked;val r=range
        val depth=depthToggle.isChecked
        for(v in listOf(modePick,rolePick,orientationPick,mirror,depthToggle))v.isEnabled=canEditInstrument
        cameraPick.isEnabled=canEditInstrument&&!depth
        depthRange.isEnabled=canEditInstrument&&depth;imageRotation.isEnabled=canEditInstrument&&depth
        val custom=depth&&!measuredMode&&depthRange.selectedItemPosition==AirDepthCalibration.presets.size
        for(field in listOf(customNear,customFar)){
            field.visibility=if(custom)View.VISIBLE else View.GONE
            field.isEnabled=custom&&canEditInstrument
        }
        modeGuide.visibility=if(measuredMode||wantsTouchPair)View.GONE else View.VISIBLE
        responseGuide.visibility=if(measuredMode||wantsTouchPair)View.GONE else View.VISIBLE
        responseGuide.text=when(val mode=selectedMode()) {
            AirMode.PINCH_HELPER, AirMode.TOGGLE_HELPER -> "Binary gate · use Absolute response on the Mac. The current assignment does not report its response mode."
            null -> "Choose a source."
            else -> AirRelativeEligibility.forMode(mode).explanation
        }
        feedback.visibility=if(measuredMode||wantsTouchPair||touchStage)View.GONE else View.VISIBLE
        if(!busy&&!measuredMode&&!wantsTouchPair&&!touchStage)showOutput(AirOutput())
        modeGuide.text=when {
            depth&&selectedRange()==null -> "Enter a valid near/far range: near 10–150 cm, far 20–300 cm, at least 10 cm apart. If an exact 10 cm gap is rejected, increase the gap by 1 cm."
            !validRole() -> "Choose a valid mode and performing hand; chords require left or right."
            orientationPick.selectedItemPosition !in Orientation.entries.indices -> "Choose a control orientation."
            depth && imageRotation.selectedItemPosition !in 0..3 -> "Choose a raw image orientation."
            wantsPair && lan==null && airSetup()?.canPair(helperPick.selectedItemPosition)==false -> "Choose a helper channel before connecting."
            else -> when(selectedMode()) {
                AirMode.PINCH_KEYS -> "Move horizontally to choose a key; open then pinch to hold, open to release."
                AirMode.CHORDS -> "Select with the other hand; pinch with the performing hand. Loss of either hand releases."
                AirMode.STRINGS -> "Cross the three vertical string regions for short note pulses."
                AirMode.HORIZONTAL -> "Horizontal position controls the helper."
                AirMode.VERTICAL -> "Vertical position controls the helper."
                AirMode.APERTURE -> "Thumb-to-index aperture controls the helper."
                AirMode.SPEED -> "Hand motion speed controls the helper."
                AirMode.PINCH_HELPER -> "Open then pinch to engage; open to disengage."
                AirMode.TOGGLE_HELPER -> "Open then pinch to toggle; tracking loss clears the latch."
                AirMode.BEAM_KEYS -> "Move within the selected depth range to choose a logical key zone. Invalid depth releases."
                AirMode.BEAM_HELPER -> "Near/far distance controls the helper. Invalid depth releases."
                null -> "Choose an instrument."
            }
        }
        flip.isEnabled=canEditInstrument&&!depth&&choices.any {it.facing==CameraCharacteristics.LENS_FACING_FRONT}&&choices.any {it.facing==CameraCharacteristics.LENS_FACING_BACK}
        for(v in listOf(zoomBar,minus,plus,reset))v.isEnabled=canEditInstrument&&!depth&&r!=null&&r.max>r.min
        xyz.isEnabled=!b&&!wantsTouchPair
        xyzSettings.visibility=if(measuredMode)View.VISIBLE else View.GONE
        xyzSettings.lock(b)
        if(measuredMode){
            for(v in listOf(modePick,rolePick,orientationPick,mirror,depthToggle,depthRange,imageRotation,
                zoomBar,minus,plus,reset,flip))v.isEnabled=false
            cameraPick.isEnabled=!b
        }
        touchPreview.isEnabled=!b
        touchLive.isEnabled=!busy&&!qrRequested&&lan?.status()?.assignment?.touchPianoMask()!=null
        modelButton.isEnabled=!b
        paired.isEnabled=!b&&pairedAllowed
        for(v in listOf(address,invitation,fingerprint,qrButton,rootButton,helperPick))v.isEnabled=!b&&wantsPair
        touchOnly.isEnabled=!b&&wantsPair
        helperPick.visibility=if(!measuredMode&&!wantsTouchPair&&selectedMode()?.isHelper==true)View.VISIBLE else View.GONE
        connectButton.isEnabled=!b&&wantsPair&&(when {
            wantsTouchPair -> true
            measuredMode -> measuredCamera()!=null&&xyzSettings.volume()!=null&&xyzSettings.selection!=null
            else -> airSetup()?.canPair(helperPick.selectedItemPosition)==true
        })
        disconnectButton.isEnabled=lan!=null
        pauseModeButton.isEnabled=lan?.status()?.phase==MobileLanSession.Phase.READY&&(pending||source!=null||depthSource!=null)
        start.text=if(wantsPair)"Start playing" else "Start sensors"
        if(!measuredMode&&!wantsTouchPair&&lan?.status()?.phase==MobileLanSession.Phase.READY&&!busy&&pairedProjection()==null)
            status.text="Mode incompatible with assignment: choose the same family or disconnect and pair again."
        start.isEnabled=!wantsTouchPair&&!busy&&!qrRequested&&validAirSetup()&&(depth||r?.admits(zoom)==true)&&(!wantsPair||pairedProjection()!=null)
        if(measuredMode){
            val validVolume=xyzSettings.volume()!=null && xyzSettings.selection!=null
            start.isEnabled=!busy&&!qrRequested&&measuredCamera()!=null&&validVolume&&(!wantsPair||xyzAssigned())
            xyzSettings.describeEligibility(when {
                measuredCamera()==null -> "Select a rear camera with advertised DEPTH16."
                !validVolume -> "Set valid XYZ bounds and enable at least one helper axis for Helper or Hybrid."
                wantsPair&&!xyzAssigned() -> "Wait for a compatible Mac assignment; reconnect to change role or axes."
                else -> null
            })
            modelButton.isEnabled=false
        }
        stopButton.isEnabled=xyzSource!=null||pending||source!=null||depthSource!=null||lan!=null
    }
    private fun scanAddress() {
        if(!wantsPair||locked||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))return
        if(ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED){
            permission.launch(Manifest.permission.CAMERA);return
        }
        clearInvitation()
        qrRequested=true;controls()
        try {qrCamera.launch(null)}
        catch(_:Exception){qrRequested=false;connectionStatus.text="Camera QR capture unavailable; type the address.";controls()}
    }
    private fun connectMac() {
        if(!wantsPair||locked||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))return
        if(!wantsTouchPair&&ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED){
            permission.launch(Manifest.permission.CAMERA);return
        }
        val endpoint=MobileLanEndpoint.parse(address.text.toString())
        val secret=invitation.text.toString()
        val check=MobileLanEndpoint.invitationBytes(secret)
        check?.fill(0)
        val root=rootDer
        val digest=fingerprint.text.toString()
        val touchPair=wantsTouchPair
        val measuredPair=measuredMode
        val setup=if(!touchPair&&!measuredPair) airSetup() else null
        val requestedHelper=helperPick.selectedItemPosition
        if(endpoint==null||check==null||root==null){
            connectionStatus.text="Enter the exact Mac address, invitation and verified DER root.";return
        }
        if(!measuredPair&&!touchPair&&setup?.canPair(requestedHelper)!=true){
            connectionStatus.text="Choose a valid Air mode, hand, orientation, range and applicable helper channel.";return
        }
        if(measuredMode && (measuredCamera()==null || xyzSettings.volume()==null || xyzSettings.selection==null)){
            connectionStatus.text="Select a rear DEPTH16 camera, enabled axes and valid volume";return
        }
        val selection=when {
            measuredMode && xyzSettings.hybrid -> MobileLanSession.Selection.Hybrid(xyzSettings.mask)
            measuredMode && xyzSettings.pitchAxis==null -> MobileLanSession.Selection.XYZ(xyzSettings.mask)
            !measuredPair && !touchPair && setup?.mode?.isHelper==true -> MobileLanSession.Selection.Helper(requestedHelper)
            else -> MobileLanSession.Selection.Keys
        }
        clearInvitation()
        val epoch=++ticket;importing=true;controls();connectionStatus.text="Verifying selected private root"
        importer.execute {
            val trust=MobileLanTrust.verifiedRoot(endpoint,root,digest)
            handler.post {
                if(destroyed||epoch!=ticket||!importing)return@post
                importing=false
                if(trust==null||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)||
                    (!wantsTouchPair&&!cameraPermitted())){
                    connectionStatus.text="Root fingerprint or certificate invalid, app inactive or camera permission lost";controls();return@post
                }
                if(wantsTouchPair!=touchPair || measuredMode!=measuredPair ||
                    (!touchPair&&!measuredPair&&(airSetup()!=setup || setup?.canPair(requestedHelper)!=true ||
                    (setup?.mode?.isHelper==true && helperPick.selectedItemPosition!=requestedHelper)))) {
                    connectionStatus.text="Setup changed; connect explicitly again";controls();return@post
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
        if(wantsTouchPair||busy||qrRequested||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)||wantsPair&&(if(measuredMode)!xyzAssigned() else pairedProjection()==null))return
        if(ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED) {
            permission.launch(Manifest.permission.CAMERA);return
        }
        if(measuredMode){
            val camera=measuredCamera()?:return
            val volume=xyzSettings.volume()
            val selected=xyzSettings.selection
            if(volume==null || selected==null){status.text="Set valid bounds, role and required axes";return}
            val mask=selected.mask
            xyzKeys=selected.pitchAxis?.let { axis->
                val allowed=if(wantsPair)lan?.status()?.assignment?.piano?:0 else (1 shl 25)-1
                if(allowed !in 1 until (1 shl 25)){end("No assigned keys");return}
                MeasuredXYZKeys(allowed,axis)
            }
            xyzRotation=displayDegrees();captureRotation=xyzRotation;xyzVolume=volume;xyzCaptureSelection=selected;xyzLastAt=null
            xyzTracking=MeasuredXYZTracking(volume,mask)
            observationFence=if(wantsPair)PairedObservationFence(SystemClock.elapsedRealtimeNanos()) else null
            val measured=Camera2XYZSource(applicationContext,camera,xyzRotation,volume)
            xyzSource=measured;xyzStage=XYZStageView(this,mask,selected.pitchAxis,selected.hybrid,::end)
            measured.start();controls();return
        }
        val setup=airSetup()?:run{status.text="Choose valid Air mode, hand, orientation and range";return}
        if(setup.rawRotation!=null){beginDepth(setup);return}
        val c=choices.getOrNull(cameraPick.selectedItemPosition) ?: return
        val p=if(wantsPair)pairedProjection(setup) else runCatching {AirProjection(setup.mode,(1 shl 25)-1,setup.role,setup.orientation,mirror.isChecked)}.getOrNull()
        if(p==null){status.text="Select a compatible assigned instrument and performing hand";return}
        // The local model must be supplied by the embedding application.
        val model=localModel
        if(model==null&&runCatching {assets.open("hand_landmarker.task").use {}}.isFailure) {
            status.text="Local hand_landmarker.task asset required";return
        }
        observationFence=if(wantsPair)PairedObservationFence(SystemClock.elapsedRealtimeNanos()) else null
        captureRotation=displayDegrees()
        val epoch=++ticket;pending=true;controls();status.text="Opening camera"
        val future=ProcessCameraProvider.getInstance(this)
        future.addListener({
            if(epoch==ticket&&pending) {
                captureFailure()?.let {end(it.message);return@addListener}
                try {
                    if(airSetup()!=setup){end("Setup changed; restart explicitly");return@addListener}
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
    private fun beginDepth(setup:AirSetupSnapshot){
        val model=localModel
        if(model==null&&runCatching {assets.open("hand_landmarker.task").use {}}.isFailure){status.text="Choose a trusted local hand_landmarker.task first";return}
        try {
            val installer=ArCoreApk.getInstance()
            when(installer.requestInstall(this,!installRequested)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {installRequested=true;status.text="Complete ARCore installation, then press Start again";return}
                ArCoreApk.InstallStatus.INSTALLED -> installRequested=false
            }
            if(!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)||!cameraPermitted()){
                end("App inactive or camera permission lost");return
            }
            val rotation=setup.rawRotation?:run{status.text="Invalid raw image orientation";return}
            if(airSetup()!=setup){end("Setup changed; restart explicitly");return}
            val keys=if(wantsPair){
                if(pairedProjection(setup)==null){end("Mac assignment ended");return}
                lan?.status()?.assignment?.piano?:run{end("Mac assignment ended");return}
            } else (1 shl 25)-1
            observationFence=if(wantsPair)PairedObservationFence(SystemClock.elapsedRealtimeNanos()) else null
            @Suppress("DEPRECATION") val displayRotation=windowManager.defaultDisplay.rotation
            val s=ArCoreDiagnosticSource(applicationContext,model,rotation,displayRotation,
                setup.role,setup.mode,setup.orientation,mirror.isChecked,setup.near,setup.far,keys)
            captureRotation=displayDegrees()
            depthSource=s;controls();s.start();status.text="Starting ARCore diagnostic sensor"
        }catch(_:Exception){end("ARCore unavailable, unsupported or install declined")}
        catch(_:LinkageError){end("ARCore runtime not included by embedding app")}
    }
    private fun openTouchPiano(){
        val client=lan?:return
        val assigned=client.status().assignment?.touchPianoMask()?:return
        if(busy||assigned==0||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))return
        touchStage=true
        val hint=TextView(this).apply{text="Assigned touch piano · press Arm to play through Mac"}
        val arm=Button(this).apply{text="Arm touch piano"}
        val leave=Button(this).apply{text="Release / disconnect"}
        val piano=TouchPianoView(this,assigned,live={sample->
            if(lan!==client||!touchStage||!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)||
                client.status().assignment?.touchPianoMask()!=assigned)false
            else {
                client.offer(sample.output,sample.ownerAt)
                client.status().phase==MobileLanSession.Phase.READY
            }
        }) {out,armed->
            if(touchStage){
                if(!armed)end("Touch piano released · disconnected")
                else {showOutput(out);arm.isEnabled=false}
            }
        }
        livePiano=piano
        touchPanel.addView(hint)
        val stageDp=(resources.configuration.screenHeightDp*0.38f).coerceIn(110f,240f)
        touchPanel.addView(piano,LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,(stageDp*resources.displayMetrics.density).toInt()))
        touchPanel.addView(arm)
        touchPanel.addView(leave)
        arm.setOnClickListener{
            if(lan===client&&client.status().assignment?.touchPianoMask()==assigned)piano.arm()?.let{hint.text=it}
            else end("Assignment ended")
        }
        leave.setOnClickListener{end("Touch piano released")}
        touchPanel.visibility=View.VISIBLE
        controls()
    }
    private fun retireCapture(beforeWorkerStop:()->Unit={}) {
        touchStage=false
        livePiano?.retire();livePiano=null
        touchPanel.removeAllViews();touchPanel.visibility=View.GONE
        ticket++;pending=false;importing=false;captureRotation=null
        observationFence?.retire();observationFence=null
        // No capture callback can renew the old session after this fence.
        beforeWorkerStop()
        xyzSource?.let {it.stop();xyzRetiring=it};xyzSource=null
        xyzStage?.close();xyzStage=null;xyzKeys=null;xyzTracking=null;xyzVolume=null;xyzCaptureSelection=null;xyzLastAt=null
        source?.let {it.stop();retiring=it};source=null;projection=null
        depthSource?.let {it.stop();depthRetiring=it};depthSource=null
        showOutput(AirOutput())
        meter.text="All preview keys released"
    }
    private fun pauseInstrument() {
        val client=lan?:return
        if(client.status().phase!=MobileLanSession.Phase.READY)return
        // Old callbacks are invalidated before the explicit neutral fence.
        // No new sensor is opened until release ACK and worker retirement.
        // Neutral request precedes potentially blocking sensor stop.
        retireCapture {
            lastPhase=null
            client.pauseForModeChange()
        }
        status.text="Waiting for neutral ACK; then select a compatible mode and press Start."
        controls()
    }
    private fun end(message:String) {
        retireCapture {
            val client=lan;lan=null;lastPhase=null
            client?.let {it.stop();connectionStatus.text=message}
        }
        clearInvitation()
        status.text=message;controls()
    }
    override fun onResume(){super.onResume();handler.removeCallbacks(pulse);handler.post(pulse)}
    override fun onPause(){end("App inactive · stopped");handler.removeCallbacks(pulse);super.onPause()}
    override fun onDestroy(){destroyed=true;qrRequested=false;end("View closed");importer.shutdownNow();localModel=null;rootDer=null;handler.removeCallbacks(pulse);super.onDestroy()}
}
