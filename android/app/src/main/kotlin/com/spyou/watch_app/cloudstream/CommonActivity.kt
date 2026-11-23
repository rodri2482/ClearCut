package com.lagradost.cloudstream3

import android.app.Activity

/** CloudStream toast compatibility. Extension messages stay off the app screen. */
object CommonActivity {
    @Volatile
    var activity: Activity? = null

    fun setActivityInstance(newActivity: Activity?) {
        activity = newActivity
    }

    fun showToast(message: String?, duration: Int? = null) = Unit

    fun showToast(act: Activity?, message: String?, duration: Int? = null) =
        showToast(message, duration)
}
