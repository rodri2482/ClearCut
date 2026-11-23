package eu.kanade.tachiyomi.util.system

import android.content.Context
import android.widget.Toast
import androidx.annotation.StringRes

/**
 * Display a toast in this context.
 *
 * No-op by design in ClearCut: Mihon/Aniyomi extensions call this from their
 * own threads with arbitrary messages ("Opening Comic Reader…", verification
 * prompts), and those toasts were appearing over the video player. Callers
 * still receive a Toast so existing extension code compiles unchanged, but it
 * is never shown. User-facing status in ClearCut comes from its own UI.
 */
fun Context.toast(
    @StringRes resource: Int,
    duration: Int = Toast.LENGTH_SHORT,
    block: (Toast) -> Unit = {}
): Toast {
    return toast(getString(resource), duration, block)
}

/** @see toast */
fun Context.toast(
    text: String?,
    duration: Int = Toast.LENGTH_SHORT,
    block: (Toast) -> Unit = {}
): Toast {
    return Toast.makeText(applicationContext, text.orEmpty(), duration).also(block)
}
