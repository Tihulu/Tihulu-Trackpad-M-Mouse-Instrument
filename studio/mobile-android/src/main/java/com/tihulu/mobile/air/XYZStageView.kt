package com.tihulu.mobile.air

import android.app.Dialog
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.widget.*
import org.json.JSONArray

internal class XYZSettings(context:Context, private val cameraID:()->String?) : LinearLayout(context) {
    private val fields=ArrayList<EditText>()
    private val enabledAxes=ArrayList<CheckBox>()
    private val name=EditText(context)
    private val message=TextView(context)
    val mask:Int get()=enabledAxes.foldIndexed(0){i,m,box->if(box.isChecked)m or (1 shl i) else m}
    fun volume():XYZVolume? {
        val v=fields.map {it.text.toString().toDoubleOrNull()?:return null}
        return XYZVolume(v[0],v[1],v[2],v[3],v[4],v[5]).takeIf {it.valid}
    }
    private fun store()=cameraID()?.let {context.getSharedPreferences("depthXYZ.v1."+it,Context.MODE_PRIVATE)}
    init {
        orientation=VERTICAL
        addView(TextView(context).apply{text="Move one isolated hand or object in front of the rear depth camera. X increases right, Y up and Z away."})
        val axes=LinearLayout(context);addView(axes)
        for(axis in listOf("X", "Y", "Z")){
            val check=CheckBox(context).apply{text=axis;isChecked=true}
            enabledAxes.add(check);axes.addView(check)
        }
        val labels=listOf("Left","Right","Bottom","Top","Near (m)","Far (m)")
        val defaults=listOf(0.0,1.0,0.0,1.0,.25,.85)
        for((i,label) in labels.withIndex()){
            val line=LinearLayout(context);addView(line)
            val title=TextView(context).apply{text=label};line.addView(title)
            val field=EditText(context).apply {
                id=View.generateViewId();inputType=InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                setSingleLine();setText(defaults[i].toString())
            }
            title.labelFor=field.id;fields.add(field);line.addView(field)
        }
        name.hint="Calibration name";name.setSingleLine();addView(name)
        addView(Button(context).apply{text="Save new calibration";setOnClickListener {save()}})
        addView(Button(context).apply{text="Load named calibration";setOnClickListener {restore()}})
        addView(message)
    }
    private fun save(){
        val key=name.text.toString().trim()
        val prefs=store()
        val v=volume()
        if(prefs==null || key.isEmpty() || key.toByteArray().size>64 || key.any {it.isISOControl()} ||
            v==null || mask==0 || prefs.contains(key) || prefs.all.size>=32){
            message.text="Choose a new name, valid bounds and enabled axes (up to 32 profiles per camera).";return
        }
        val json=JSONArray(listOf(v.left,v.right,v.bottom,v.top,v.near,v.far,mask))
        prefs.edit().putString(key,json.toString()).apply();message.text="Saved "+key
    }
    private fun restore(){
        val prefs=store()?:return
        val keys=prefs.all.keys.sorted()
        if(keys.isEmpty()){message.text="No calibrations for this camera";return}
        android.app.AlertDialog.Builder(context).setTitle("Load calibration").setItems(keys.toTypedArray()){_,position->
            if(!isEnabled)return@setItems
            val key=keys[position]
            try{
                val data=JSONArray(prefs.getString(key,""))
                require(data.length()==7)
                val values=(0..5).map {data.getDouble(it)}
                val v=XYZVolume(values[0],values[1],values[2],values[3],values[4],values[5])
                val bits=data.getInt(6)
                require(v.valid && bits in 1..7 && data.getDouble(6)==bits.toDouble())
                fields.forEachIndexed {i,f->f.setText(values[i].toString())}
                enabledAxes.forEachIndexed {i,box->box.isChecked=bits and (1 shl i)!=0}
                name.setText(key);message.text="Loaded "+key
            }catch(_:Exception){message.text="Invalid saved calibration"}
        }.show()
    }
    fun lock(locked:Boolean){
        fun enable(v:View){v.isEnabled=!locked;if(v is ViewGroup)for(i in 0 until v.childCount)enable(v.getChildAt(i))}
        enable(this)
    }
}

internal class XYZStageView(context:Context, mask:Int, private val stop:(String)->Unit) {
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
        column.addView(TextView(context).apply{text="Measured XYZ · "+(0..2).filter {mask and (1 shl it)!=0}.joinToString {listOf("X → 1","Y → 2","Z → 3")[it]}})
        column.addView(indicator)
        area.setBackgroundColor(Color.DKGRAY);column.addView(area,LinearLayout.LayoutParams(-1,0,1f))
        depth.max=100;column.addView(depth)
        for(action in listOf("Stop","Panic"))column.addView(Button(context).apply {text=action;setOnClickListener {stop(action+" · this source released")}})
        dialog.setContentView(column);dialog.setTitle("Depth instrument");dialog.setOnCancelListener {stop("Stage closed")}
        dialog.show();dialog.window?.setLayout(-1,-1)
        update(null,XYZVolume())
    }
    fun update(p:MeasuredXYZ?,volume:XYZVolume){
        point=p;area.invalidate()
        depth.progress=p?.let {((it.metres-volume.near)/(volume.far-volume.near)*100).toInt()}?:0
        indicator.text=if(p==null)"Tracking lost or acquiring · released" else
            "X %.0f%% · Y %.0f%% · Z %.2f m · confidence %.0f%%".format(p.x*100,p.y*100,p.metres,p.confidence*100)
    }
    fun close(){dialog.setOnCancelListener(null);dialog.dismiss()}
}
