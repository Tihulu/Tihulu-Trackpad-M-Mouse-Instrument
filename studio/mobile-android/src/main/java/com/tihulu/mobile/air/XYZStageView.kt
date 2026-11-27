package com.tihulu.mobile.air

import android.app.Dialog
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.text.InputType
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.ViewGroup
import android.widget.*
import org.json.JSONArray

internal class XYZSettings(context:Context, private val cameraID:()->String?) : LinearLayout(context) {
    private val fields=ArrayList<EditText>()
    private val enabledAxes=ArrayList<CheckBox>()
    private val role=Spinner(context)
    val hybrid:Boolean get()=role.selectedItemPosition in 4..6
    val pitchAxis:Int? get()=role.selectedItemPosition.takeIf {it in 1..6}?.let {(it-1)%3}
    private val name=EditText(context)
    private val message=TextView(context)
    var selectionChanged: (() -> Unit)? = null
    val mask:Int get()=if(pitchAxis!=null&&!hybrid)7 else enabledAxes.foldIndexed(0){i,m,box->if(box.isChecked)m or (1 shl i) else m}
    fun volume():XYZVolume? {
        val v=fields.map {it.text.toString().toDoubleOrNull()?:return null}
        return XYZVolume(v[0],v[1],v[2],v[3],v[4],v[5]).takeIf {it.valid}
    }
    private fun store()=cameraID()?.let {context.getSharedPreferences("depthXYZ.v1."+it,Context.MODE_PRIVATE)}
    init {
        orientation=VERTICAL
        addView(TextView(context).apply{text="Move one isolated hand or object in front of the rear depth camera. X increases right, Y up and Z away."})
        role.contentDescription="XYZ instrument role and pitch axis"
        role.adapter=ArrayAdapter(context,android.R.layout.simple_spinner_dropdown_item,
            listOf("XYZ helper","Instrument · X pitch","Instrument · Y pitch","Instrument · Z pitch","Hybrid · X pitch","Hybrid · Y pitch","Hybrid · Z pitch"))
        addView(role)
        val axes=LinearLayout(context);addView(axes)
        role.onItemSelectedListener=object:AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent:AdapterView<*>?) {}
            override fun onItemSelected(parent:AdapterView<*>?, view:View?, position:Int, id:Long){
                axes.visibility=if(position==0||position>=4)View.VISIBLE else View.GONE
                selectionChanged?.invoke()
            }
        }
        for(axis in listOf("X", "Y", "Z")){
            val check=CheckBox(context).apply{text=axis;isChecked=true}
            check.contentDescription="Enable "+axis+" helper axis"
            check.setOnCheckedChangeListener { _, _ -> selectionChanged?.invoke() }
            enabledAxes.add(check);axes.addView(check)
        }
        val labels=listOf("Left","Right","Bottom","Top","Near (m)","Far (m)")
        val defaults=listOf(0.0,1.0,0.0,1.0,.25,.85)
        for((i,label) in labels.withIndex()){
            val line=LinearLayout(context);addView(line)
            val title=TextView(context).apply{text=label};line.addView(title,LayoutParams(0,-2,1f))
            val field=EditText(context).apply {
                id=View.generateViewId();inputType=InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                setSingleLine();setText(defaults[i].toString())
            }
            field.addTextChangedListener(object:TextWatcher {
                override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){}
                override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){}
                override fun afterTextChanged(s:Editable?){selectionChanged?.invoke()}
            })
            title.labelFor=field.id;fields.add(field);line.addView(field,LayoutParams(0,-2,1f))
        }
        name.hint="Calibration name";name.setSingleLine();addView(name)
        addView(Button(context).apply{text="Save new calibration";setOnClickListener {save()}})
        addView(Button(context).apply{text="Load named calibration";setOnClickListener {restore()}})
        addView(Button(context).apply{text="Update named calibration";setOnClickListener {update()}})
        addView(Button(context).apply{text="Delete named calibration";setOnClickListener {delete()}})
        addView(message)
    }
    private fun save(){
        val key=name.text.toString().trim()
        val prefs=store()
        val v=volume()
        if(prefs==null || key.isEmpty() || key.toByteArray().size>64 || key.any {it.isISOControl()} ||
            v==null || mask==0 || prefs.all.keys.any { it.equals(key,ignoreCase=true) } || prefs.all.size>=32){
            message.text="Choose a new name, valid bounds and enabled axes (up to 32 profiles per camera).";return
        }
        val json=JSONArray(listOf(v.left,v.right,v.bottom,v.top,v.near,v.far,mask,role.selectedItemPosition))
        prefs.edit().putString(key,json.toString()).apply();message.text="Saved "+key
    }
    private fun restore(){
        val prefs=store()?:return
        val keys=prefs.all.keys.sorted()
        if(keys.isEmpty()){message.text="No calibrations for this camera";return}
        android.app.AlertDialog.Builder(context).setTitle("Load calibration").setItems(keys.toTypedArray()){_,position->
            if(!isEnabled || store()!=prefs)return@setItems
            val key=keys[position]
            try{
                val data=JSONArray(prefs.getString(key,""))
                require(data.length() in 7..8)
                val values=(0..5).map {data.getDouble(it)}
                val v=XYZVolume(values[0],values[1],values[2],values[3],values[4],values[5])
                val bits=checkNotNull(XYZCalibrationRecord.axisMask(data.getDouble(6)))
                require(v.valid)
                val roleIndex=if(data.length()==8)checkNotNull(XYZCalibrationRecord.roleIndex(data.getDouble(7))) else 0
                role.setSelection(roleIndex)
                fields.forEachIndexed {i,f->f.setText(values[i].toString())}
                enabledAxes.forEachIndexed {i,box->box.isChecked=bits and (1 shl i)!=0}
                name.setText(key);message.text="Loaded "+key
            }catch(_:Exception){message.text="Invalid saved calibration"}
        }.show()
    }
    private fun update(){
        val prefs=store()?:return
        val v=volume()
        val bits=mask
        val roleIndex=role.selectedItemPosition
        if(v==null || bits !in 1..7 || roleIndex !in 0..6){message.text="Set valid calibration and role first";return}
        val replacement=JSONArray(listOf(v.left,v.right,v.bottom,v.top,v.near,v.far,bits,roleIndex)).toString()
        val keys=prefs.all.keys.sorted()
        if(keys.isEmpty()){message.text="No calibrations for this camera";return}
        android.app.AlertDialog.Builder(context).setTitle("Update calibration with current settings").setItems(keys.toTypedArray()){_,position->
            if(!isEnabled || store()!=prefs)return@setItems
            val key=keys[position]
            val original=prefs.all[key]
            android.app.AlertDialog.Builder(context).setTitle("Replace "+key+"?")
                .setNegativeButton("Cancel",null)
                .setPositiveButton("Replace"){_,_->
                    if(isEnabled && store()==prefs && prefs.contains(key) && prefs.all[key]==original){
                        prefs.edit().putString(key,replacement).apply()
                        message.text="Calibration updated"
                    }else message.text="Calibration changed; load again"
                }.show()
        }.show()
    }
    private fun delete(){
        val prefs=store()?:return
        val keys=prefs.all.keys.sorted()
        if(keys.isEmpty()){message.text="No calibrations for this camera";return}
        android.app.AlertDialog.Builder(context).setTitle("Delete calibration").setItems(keys.toTypedArray()){_,position->
            if(!isEnabled || store()!=prefs)return@setItems
            val key=keys[position]
            val original=prefs.all[key]
            android.app.AlertDialog.Builder(context).setTitle("Delete "+key+"?")
                .setNegativeButton("Cancel",null)
                .setPositiveButton("Delete"){_,_->
                    if(isEnabled && store()==prefs && prefs.contains(key) && prefs.all[key]==original){
                        prefs.edit().remove(key).apply()
                        message.text="Calibration deleted"
                    }
                }.show()
        }.show()
    }
    fun lock(locked:Boolean){
        fun enable(v:View){v.isEnabled=!locked;if(v is ViewGroup)for(i in 0 until v.childCount)enable(v.getChildAt(i))}
        enable(this)
    }
}

internal class XYZStageView(context:Context, mask:Int, pitchAxis:Int?, hybrid:Boolean, private val stop:(String)->Unit) {
    private val dialog=Dialog(context)
    private val indicator=TextView(context)
    private val depth=ProgressBar(context,null,android.R.attr.progressBarStyleHorizontal)
    private var point:MeasuredXYZ?=null
    private val brush=Paint(Paint.ANTI_ALIAS_FLAG).apply {color=Color.CYAN}
    private val area=object:View(context){
        override fun onDraw(canvas:Canvas){
            super.onDraw(canvas)
            point?.let{canvas.drawCircle((it.x*width).toFloat(),((1-it.y)*height).toFloat(),12*resources.displayMetrics.density,brush)}
        }
    }
    init{
        val column=LinearLayout(context).apply {orientation=LinearLayout.VERTICAL;setPadding(16,16,16,16)}
        column.addView(TextView(context).apply{text=buildString {
            if(pitchAxis!=null)append("Pitch on "+listOf("X","Y","Z")[pitchAxis])
            if(hybrid)append(" · ")
            if(pitchAxis==null || hybrid)append((0..2).filter {mask and (1 shl it)!=0}.joinToString {listOf("X → 1","Y → 2","Z → 3")[it]})
        }})
        column.addView(indicator)
        area.setBackgroundColor(Color.DKGRAY);column.addView(area,LinearLayout.LayoutParams(-1,0,1f))
        depth.max=100;column.addView(depth)
        for(action in listOf("Stop","Panic"))column.addView(Button(context).apply {text=action;setOnClickListener {stop(action+" · this source released")}})
        dialog.setContentView(column);dialog.setTitle("Depth instrument");dialog.setOnCancelListener {stop("Stage closed")}
        dialog.show();dialog.window?.setLayout(-1,-1)
        update(null,XYZVolume())
    }
    fun update(p:MeasuredXYZ?,volume:XYZVolume,keys:Int=0){
        val normalized=p?.let {volume.axes(it,7)}
        point=if(p!=null && normalized!=null)p.copy(x=normalized[0]!!,y=normalized[1]!!) else null;area.invalidate()
        depth.progress=p?.let {((it.metres-volume.near)/(volume.far-volume.near)*100).toInt()}?:0
        indicator.text=if(p==null)"Tracking lost or acquiring · released" else
            "X %.0f%% · Y %.0f%% · Z %.2f m · confidence %.0f%%".format((point?.x?:0.0)*100,(point?.y?:0.0)*100,p.metres,p.confidence*100) +
                (if(keys>0)" · logical key "+(Integer.numberOfTrailingZeros(keys)+1) else "")
    }
    fun close(){dialog.setOnCancelListener(null);dialog.dismiss()}
}
