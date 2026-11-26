package com.tihulu.mobile.air

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity

/** Native local-only stage. No camera, audio, network, MIDI, or permission
 * request. The paired performance path must be separately accepted. */
class TouchPianoPreviewActivity:ComponentActivity() {
    private lateinit var piano:TouchPianoView
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        val column=LinearLayout(this).apply {
            orientation=LinearLayout.VERTICAL
            val pad=(16*resources.displayMetrics.density).toInt()
            setPadding(pad,pad,pad,pad)
        }
        fun label(value:String)=TextView(this).also {it.text=value;column.addView(it)}
        label("TIHULU · Touch piano").textSize=24f
        label("Local logical-key preview · up to ten contacts · no sound or MIDI")
        val status=label("Stopped. Press Arm to begin.")
        val arm=Button(this).apply{text="Arm piano"}
        val release=Button(this).apply{text="Release all / stop"}
        piano=TouchPianoView(this) { output,armed ->
            val active=(0..24).filter{output.keys and (1 shl it)!=0}
            status.text=if(!armed)"Stopped. Press Arm to begin."
                else if(active.isEmpty())"Ready · no held keys"
                else "Held logical keys: "+active.joinToString{(it+1).toString()}
            arm.isEnabled=!armed;release.isEnabled=armed
        }
        column.addView(piano,LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,0,1f))
        arm.setOnClickListener{piano.arm()}
        release.setOnClickListener{piano.retire()}
        release.isEnabled=false
        column.addView(arm);column.addView(release)
        column.addView(Button(this).apply{text="Back to Air stage";setOnClickListener{piano.retire();finish()}})
        setContentView(column)
    }
    override fun onPause(){if(::piano.isInitialized)piano.retire();super.onPause()}
    override fun onDestroy(){if(::piano.isInitialized)piano.retire();super.onDestroy()}
}

/** Full current MotionEvent pointer set, not a queue of individual attacks. */
internal class TouchPianoView(context:Context,
    private val authorized:Int=(1 shl 13)-1,
    private val live:((MobileTouchLiveLease.Snapshot)->Boolean)?=null,
    private val changed:(AirOutput,Boolean)->Unit):View(context) {
    private val keyList=MobileTouchKeys(authorized).keys
    private var owner:MobileTouchLiveLease?=null
    private var armedUptime=0L
    private fun ownerActive():Boolean {
        if(!isAttachedToWindow||!isShown||!hasWindowFocus()||windowVisibility!=VISIBLE||width<=0||height<=0)return false
        // A scroll-clipped or partially offscreen playing surface cannot
        // renew a held contact. Scroll the whole surface into view first.
        val visible=Rect()
        return getLocalVisibleRect(visible)&&visible==Rect(0,0,width,height)
    }
    private val pulse=object:Runnable {
        override fun run(){
            val current=owner?:return
            val sample=current.pulse(SystemClock.elapsedRealtimeNanos(),ownerActive())
            if(sample==null||live?.invoke(sample)==false){retire();return}
            if(owner===current)postDelayed(this,50)
        }
    }
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG)
    init {
        contentDescription="${keyList.size} assigned logical piano zones; use multiple fingers."
        isFocusable=true
        importantForAccessibility=IMPORTANT_FOR_ACCESSIBILITY_YES
    }
    fun arm(){
        if(!ownerActive()||owner!=null)return
        armedUptime=SystemClock.uptimeMillis()
        owner=MobileTouchLiveLease(authorized,SystemClock.elapsedRealtimeNanos())
        changed(AirOutput(),true);invalidate()
        postDelayed(pulse,50)
    }
    fun retire(){
        val old=owner?:return
        owner=null;removeCallbacks(pulse);old.retire()
        parent?.requestDisallowInterceptTouchEvent(false)
        changed(AirOutput(),false);invalidate()
    }
    override fun onDraw(canvas:Canvas){
        super.onDraw(canvas)
        val mask=owner?.output?.keys?:0
        val cell=width.toFloat()/keyList.size
        val density=resources.displayMetrics.density
        for((i,key) in keyList.withIndex()){
            val left=i*cell;val right=(i+1)*cell
            paint.color=if(mask and (1 shl key)!=0)Color.rgb(72,145,204)
                else if(owner==null)Color.rgb(184,190,196) else Color.rgb(242,244,246)
            canvas.drawRect(left+1f,1f,right-1f,height.toFloat()-1f,paint)
            paint.color=Color.rgb(34,42,51);paint.textAlign=Paint.Align.CENTER
            paint.textSize=minOf(14*density,cell*.58f)
            canvas.drawText((key+1).toString(),(left+right)/2,height-16*density,paint)
        }
    }
    override fun onTouchEvent(event:MotionEvent):Boolean {
        val current=owner?:return true
        val uptime=SystemClock.uptimeMillis()
        if(!ownerActive()||event.eventTime<=armedUptime||event.eventTime>uptime||
            uptime-event.eventTime>=150||event.flags and (MotionEvent.FLAG_WINDOW_IS_OBSCURED or MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED)!=0||
            event.pointerCount !in 1..MobileTouchKeys.MAX_CONTACTS){
            retire();return true
        }
        val change=when(event.actionMasked){
            MotionEvent.ACTION_DOWN,MotionEvent.ACTION_POINTER_DOWN->MobileTouchOwnership.Change.BEGAN
            MotionEvent.ACTION_MOVE->MobileTouchOwnership.Change.MOVED
            MotionEvent.ACTION_UP,MotionEvent.ACTION_POINTER_UP->MobileTouchOwnership.Change.ENDED
            else->{retire();return true}
        }
        if(event.actionIndex !in 0 until event.pointerCount){retire();return true}
        val single=event.actionMasked==MotionEvent.ACTION_DOWN||event.actionMasked==MotionEvent.ACTION_UP
        val multi=event.actionMasked==MotionEvent.ACTION_POINTER_DOWN||event.actionMasked==MotionEvent.ACTION_POINTER_UP
        if(single&&event.pointerCount!=1||multi&&event.pointerCount<2){retire();return true}
        if(event.actionMasked==MotionEvent.ACTION_DOWN)parent?.requestDisallowInterceptTouchEvent(true)
        val contacts=ArrayList<MobileTouchKeys.Contact>(event.pointerCount)
        for(i in 0 until event.pointerCount){
            if(event.getToolType(i)!=MotionEvent.TOOL_TYPE_FINGER||
                event.getY(i) !in 0f..height.toFloat()){retire();return true}
            contacts.add(MobileTouchKeys.Contact(event.getPointerId(i),event.getX(i).toDouble()/width))
        }
        val changedID=if(change==MobileTouchOwnership.Change.MOVED)null else event.getPointerId(event.actionIndex)
        val sample=current.pointerEvent(change,contacts,changedID,SystemClock.elapsedRealtimeNanos(),ownerActive())
        if(sample==null||live?.invoke(sample)==false){retire();return true}
        if(owner!==current)return true
        if(current.activeIDs.isEmpty())parent?.requestDisallowInterceptTouchEvent(false)
        changed(sample.output,true);invalidate()
        return true
    }
    override fun onWindowFocusChanged(hasWindowFocus:Boolean){
        super.onWindowFocusChanged(hasWindowFocus)
        if(!hasWindowFocus)retire()
    }
    override fun onSizeChanged(w:Int,h:Int,oldw:Int,oldh:Int){
        super.onSizeChanged(w,h,oldw,oldh)
        if(oldw>0&&oldh>0&&(w!=oldw||h!=oldh))retire()
    }
    override fun onWindowVisibilityChanged(visibility:Int){
        super.onWindowVisibilityChanged(visibility)
        if(visibility!=VISIBLE)retire()
    }
    override fun onDetachedFromWindow(){retire();super.onDetachedFromWindow()}
}
