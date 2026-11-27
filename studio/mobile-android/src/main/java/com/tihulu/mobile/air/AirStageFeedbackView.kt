package com.tihulu.mobile.air

import android.content.Context
import android.graphics.Color
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.view.Gravity
import android.view.View

/** Visual-only stage; the adjacent text meter exposes the same state to TalkBack. */
internal class AirStageFeedbackView(context: Context) : LinearLayout(context) {
    private val title = TextView(context)
    private val levelBar = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal)
    private val grid = LinearLayout(context).apply { orientation = VERTICAL }
    private val cells = mutableMapOf<Int, TextView>()
    private var shownMode: AirMode? = null
    private var shownSlots = emptyList<Int>()
    private val density = resources.displayMetrics.density
    init {
        orientation = VERTICAL
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(title)
        levelBar.max = 100
        addView(levelBar, LayoutParams(-1, (24 * density).toInt()))
        addView(grid)
        visibility = View.GONE
    }
    fun render(mode: AirMode, state: AirStageFeedback) {
        if (mode != shownMode || state.slots != shownSlots) {
            shownMode = mode; shownSlots = state.slots
            cells.clear(); grid.removeAllViews()
            val columns = if (mode == AirMode.STRINGS) 3 else if (resources.configuration.screenWidthDp >= 600) 8 else 5
            for (keys in state.slots.chunked(columns)) {
                val row = LinearLayout(context)
                for (key in keys) {
                    val cell = TextView(context).apply {
                        gravity = Gravity.CENTER
                        minHeight = (40 * density).toInt()
                    }
                    row.addView(cell, LayoutParams(0, -2, 1f).apply { setMargins(2, 2, 2, 2) })
                    cells[key] = cell
                }
                grid.addView(row)
            }
        }
        title.text = when (mode) {
            AirMode.STRINGS -> "Projected string pulses"
            AirMode.CHORDS -> "Projected chord keys"
            AirMode.BEAM_KEYS -> "Projected depth-zone keys · not measured distance"
            AirMode.BEAM_HELPER -> "Projected depth helper · not measured distance"
            else -> if (mode.isHelper) "Projected " + mode.name.lowercase().replace('_', ' ') + " level" else "Projected logical keys"
        }
        levelBar.visibility = if (mode.isHelper) View.VISIBLE else View.GONE
        levelBar.progress = ((state.level ?: 0.0) * 100).toInt()
        for ((key, cell) in cells) {
            val active = key in state.active
            cell.text = if (active) "● " + (key + 1) else (key + 1).toString()
            cell.setTextColor(if (active) Color.WHITE else Color.rgb(34, 42, 51))
            cell.setBackgroundColor(if (active) Color.rgb(28, 93, 153) else Color.rgb(236, 239, 242))
        }
    }
}
