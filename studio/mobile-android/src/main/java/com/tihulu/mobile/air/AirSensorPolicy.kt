package com.tihulu.mobile.air

import kotlin.math.abs
import kotlin.math.hypot

data class ZoomRange(val min: Float, val max: Float) {
    init { require(min.isFinite() && max.isFinite() && min > 0 && max >= min) }
    fun admits(value: Float) = value.isFinite() && value in min..max
    val reset: Float get() = 1f.coerceIn(min, max)
}
data class Point(val x: Double, val y: Double) {
    val valid get() = x.isFinite() && y.isFinite() && x in 0.0..1.0 && y in 0.0..1.0
    fun distance(other: Point) = hypot(x-other.x,y-other.y)
}
data class Hand(val x: Double, val y: Double, val aperture: Double) {
    companion object {
        fun from(thumb: Point, index: Point, wrist: Point, middle: Point): Hand? {
            if (!listOf(thumb,index,wrist,middle).all { it.valid }) return null
            val palm = wrist.distance(middle)
            if (palm < 0.025) return null
            return Hand(index.x, index.y, (thumb.distance(index)/(palm*1.5)).coerceIn(0.0,1.0))
        }
    }
}
data class Observation(val hand: Hand, val side: String?, val score: Float, val fingers:Int? = null)
data class Frame(val hands: List<Observation>, val timeNs: Long, val acquisitionNs:Long=timeNs)
enum class DepthProvenance { NONE, CAMERA2_DEPTH16, ARCORE_ESTIMATED_OR_FUSED }
object DepthPolicy {
    // DEPTH16: 13-bit millimetres, 3-bit confidence encoding.
    // 0 = highest confidence, 1 = lowest, 7 = 6/7.
    fun decode(sample: Int): Double? {
        if (sample !in 0..65535) return null
        val mm = sample and 0x1fff
        val confidence = sample ushr 13
        if (mm == 0 || (confidence != 0 && confidence < 6)) return null
        return mm/1000.0
    }
    fun palmDepth(samples: List<Int>): Double? {
        if (samples.size != 9) return null
        val valid = samples.mapNotNull(::decode).sorted()
        if (valid.size < 5) return null
        val median = valid[valid.size/2]
        val cluster = valid.filter { abs(it-median) <= maxOf(0.03,median*0.08) }
        return if (cluster.size >= 5) cluster[cluster.size/2] else null
    }
    fun sameAcquisition(rgbNs: Long, depthNs: Long): Boolean =
        rgbNs > 0 && rgbNs == depthNs // strict until calibrated timestamp contract is verified
}
