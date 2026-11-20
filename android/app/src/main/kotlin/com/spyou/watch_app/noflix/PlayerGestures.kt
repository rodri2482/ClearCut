package com.spyou.watch_app.noflix

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.os.SystemClock
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * VLC-style touch gestures for the NoFlix web player:
 *  - swipe left / right  → seek back / forward (up to ±90 s across the screen)
 *  - swipe up / down on the RIGHT half → volume up / down
 *  - swipe up / down on the LEFT half  → brightness up / down
 *
 * Taps and short movements still go to the page, so the site's own player
 * buttons keep working. Once a finger has clearly moved one way, the gesture
 * takes over and the page gets a cancel instead.
 *
 * The video sits inside the site's cross-origin player iframe, so seeking is
 * done by [SEEK_FRAME_SCRIPT] (injected into every frame) via postMessage.
 */
class PlayerGestures(private val activity: Activity, private val webView: () -> WebView?) {

    private val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val slop = ViewConfiguration.get(activity).scaledTouchSlop * 2

    private var mode = IDLE
    private var downX = 0f
    private var downY = 0f
    private var startLevel = 0f
    private var seekSeconds = 0

    private val hud: TextView = TextView(activity).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        gravity = Gravity.CENTER
        val pad = (16 * resources.displayMetrics.density).roundToInt()
        setPadding(pad * 2, pad, pad * 2, pad)
        background = GradientDrawable().apply {
            cornerRadius = 18 * resources.displayMetrics.density
            setColor(0xCC000000.toInt())
        }
        visibility = View.GONE
    }
    private val hideHud = Runnable { hud.visibility = View.GONE }

    /** Adds the HUD on top of everything (also above HTML5 full-screen video). */
    fun attachHud() {
        val decor = activity.window.decorView as? FrameLayout ?: return
        (hud.parent as? FrameLayout)?.removeView(hud)
        decor.addView(
            hud,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )
    }

    /** Re-raises the HUD above a newly added full-screen view. */
    fun bringHudToFront() = hud.bringToFront()

    @SuppressLint("ClickableViewAccessibility")
    fun attach(target: View) {
        target.setOnTouchListener { v, e -> onTouch(v, e) }
    }

    private fun onTouch(view: View, e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = IDLE
                downX = e.x
                downY = e.y
                return false // let the page see the press
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                // Two fingers: leave pinch-zoom etc. to the page.
                if (mode == IDLE) mode = PASS
                return mode != PASS && mode != IDLE
            }
            MotionEvent.ACTION_MOVE -> {
                if (mode == PASS) return false
                val dx = e.x - downX
                val dy = e.y - downY
                if (mode == IDLE) {
                    if (abs(dx) < slop && abs(dy) < slop) return false
                    mode = when {
                        abs(dx) > abs(dy) * 1.5f -> SEEK
                        abs(dy) > abs(dx) * 1.5f ->
                            if (downX > view.width / 2f) VOLUME else BRIGHTNESS
                        else -> PASS
                    }
                    if (mode == PASS) return false
                    startLevel = when (mode) {
                        VOLUME -> volumeLevel()
                        BRIGHTNESS -> brightnessLevel()
                        else -> 0f
                    }
                    cancelPageTouch(view, e)
                }
                when (mode) {
                    SEEK -> {
                        seekSeconds = ((dx / view.width.coerceAtLeast(1)) * MAX_SEEK_SECONDS)
                            .roundToInt()
                        show(if (seekSeconds >= 0) "⏩  +${seekSeconds}s" else "⏪  ${seekSeconds}s")
                    }
                    VOLUME -> {
                        val level = (startLevel - dy / (view.height * 0.8f)).coerceIn(0f, 1f)
                        setVolume(level)
                        show("🔊  ${(level * 100).roundToInt()}%")
                    }
                    BRIGHTNESS -> {
                        val level = (startLevel - dy / (view.height * 0.8f)).coerceIn(0.01f, 1f)
                        setBrightness(level)
                        show("☀  ${(level * 100).roundToInt()}%")
                    }
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val handled = mode != IDLE && mode != PASS
                if (mode == SEEK && seekSeconds != 0 && e.actionMasked == MotionEvent.ACTION_UP) {
                    seek(seekSeconds)
                }
                mode = IDLE
                seekSeconds = 0
                hud.removeCallbacks(hideHud)
                hud.postDelayed(hideHud, 700)
                return handled
            }
        }
        return mode != IDLE && mode != PASS
    }

    /** The page already saw ACTION_DOWN; end its touch so it doesn't act on the swipe. */
    private fun cancelPageTouch(view: View, e: MotionEvent) {
        val now = SystemClock.uptimeMillis()
        val cancel = MotionEvent.obtain(now, now, MotionEvent.ACTION_CANCEL, e.x, e.y, 0)
        view.onTouchEvent(cancel)
        cancel.recycle()
    }

    private fun show(text: String) {
        hud.removeCallbacks(hideHud)
        hud.text = text
        hud.visibility = View.VISIBLE
    }

    private fun seek(seconds: Int) {
        webView()?.evaluateJavascript(
            "window.postMessage({__clearcutSeek:$seconds},'*');", null
        )
    }

    private fun volumeLevel(): Float =
        audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() /
            audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)

    private fun setVolume(level: Float) {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, (level * max).roundToInt(), 0)
    }

    private fun brightnessLevel(): Float {
        val current = activity.window.attributes.screenBrightness
        if (current >= 0f) return current
        return try {
            Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f
        } catch (_: Exception) {
            0.5f
        }
    }

    private fun setBrightness(level: Float) {
        val lp = activity.window.attributes
        lp.screenBrightness = level
        activity.window.attributes = lp
    }

    companion object {
        private const val IDLE = 0
        private const val PASS = 1
        private const val SEEK = 2
        private const val VOLUME = 3
        private const val BRIGHTNESS = 4
        private const val MAX_SEEK_SECONDS = 90f

        /** Every frame that can see the origin rules gets this. */
        val ALL_FRAMES = setOf("*")

        /**
         * Seeks every <video> in this frame, then passes the request down to child
         * frames (the player iframe is cross-origin, so only postMessage reaches it).
         */
        const val SEEK_FRAME_SCRIPT = """
(function () {
  if (window.__clearcutSeekReady) return;
  window.__clearcutSeekReady = true;
  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || typeof d.__clearcutSeek !== 'number') return;
    var vids = document.querySelectorAll('video');
    for (var i = 0; i < vids.length; i++) {
      var v = vids[i];
      if (!isFinite(v.duration) || v.duration <= 0) continue;
      v.currentTime = Math.max(0, Math.min(v.duration - 1, v.currentTime + d.__clearcutSeek));
    }
    var frames = document.querySelectorAll('iframe');
    for (var j = 0; j < frames.length; j++) {
      try { frames[j].contentWindow.postMessage(d, '*'); } catch (err) {}
    }
  });
})();
"""
    }
}
