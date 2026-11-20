package com.spyou.watch_app.noflix

// Ad-free web player ported from NoFlix (https://github.com/zobaer53/NoFlix, Apache-2.0).
// It plays a TMDB title from the stream site inside a WebView. The NoFlix ad blocker
// (AdGuard/EasyPrivacy lists + native engine) blocks ads, pop-ups, trackers and redirects.

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.github.edsuns.adfilter.AdFilter

class NoFlixPlayerActivity : ComponentActivity() {

    companion object {
        private const val EXTRA_TMDB_ID = "tmdbId"
        private const val EXTRA_IS_TV = "isTv"
        private const val EXTRA_SEASON = "season"
        private const val EXTRA_EPISODE = "episode"
        private const val PREFS = "noflix_player"
        private const val MAX_RENDERER_RECOVERIES = 3
        private const val TAG = "NoFlixPlayer"

        private val FILTER_LISTS = mapOf(
            "AdGuard Base" to "https://filters.adtidy.org/extension/chromium/filters/2.txt",
            "EasyPrivacy Lite" to "https://filters.adtidy.org/extension/chromium/filters/118_optimized.txt",
            "AdGuard Tracking Protection" to "https://filters.adtidy.org/extension/chromium/filters/3.txt",
            "AdGuard Annoyances" to "https://filters.adtidy.org/extension/chromium/filters/14.txt",
            "AdGuard Chinese" to "https://filters.adtidy.org/extension/chromium/filters/224.txt",
            "NoCoin Filter List" to "https://filters.adtidy.org/extension/chromium/filters/242.txt",
        )

        fun intent(context: Context, tmdbId: Int, isTv: Boolean, season: Int?, episode: Int?) =
            Intent(context, NoFlixPlayerActivity::class.java).apply {
                putExtra(EXTRA_TMDB_ID, tmdbId)
                putExtra(EXTRA_IS_TV, isTv)
                if (season != null && episode != null) {
                    putExtra(EXTRA_SEASON, season)
                    putExtra(EXTRA_EPISODE, episode)
                }
            }

        /** AdFilter is a process-wide singleton; create it once. */
        @Volatile private var filterReady = false

        fun ensureFilter(context: Context): AdFilter {
            if (!filterReady) {
                synchronized(this) {
                    if (!filterReady) {
                        AdFilter.create(context.applicationContext)
                        filterReady = true
                    }
                }
            }
            val filter = AdFilter.get()
            // Download the filter lists on first use (once per install).
            if (!filter.hasInstallation) {
                val vm = filter.viewModel
                for ((name, url) in FILTER_LISTS) {
                    vm.download(vm.addFilter(name, url).id)
                }
            }
            return filter
        }
    }

    private lateinit var root: FrameLayout
    private lateinit var filter: AdFilter
    private var webView: WebView? = null
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var pageUrl: String = ""
    private var clearHistoryOnShowPage: Int? = null
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var rendererCrashes = 0
    private var lastSavedEpisode: StreamEpisode? = null

    private val fileChooser =
        registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
            fileChooserCallback?.onReceiveValue(uri?.let { arrayOf(it) })
            fileChooserCallback = null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val tmdbId = intent.getIntExtra(EXTRA_TMDB_ID, 0)
        if (tmdbId <= 0) {
            finish()
            return
        }
        val isTv = intent.getBooleanExtra(EXTRA_IS_TV, false)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        filter = ensureFilter(this)
        filter.viewModel.onDirty.observe(this) { webView?.clearCache(false) }

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        setContentView(root)

        // An explicit episode from Zangetsu wins; otherwise a TV show resumes its last episode.
        val explicit = if (intent.hasExtra(EXTRA_SEASON)) {
            StreamEpisode(tmdbId, intent.getIntExtra(EXTRA_SEASON, 1), intent.getIntExtra(EXTRA_EPISODE, 1))
        } else null
        val resume = if (isTv) explicit ?: loadLastEpisode(tmdbId) else null
        pageUrl = buildStreamUrl(tmdbId, if (isTv) "tv" else "movie", resume)
        createWebView()

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val view = webView
                val episode = parseStreamEpisode(pageUrl)
                when {
                    customView != null -> hideCustomView()
                    view != null && episode != null -> openShowPage(view, episode)
                    view?.canGoBack() == true -> view.goBack()
                    else -> finish()
                }
            }
        })
    }

    override fun onDestroy() {
        webView?.let { root.removeView(it); it.destroy() }
        webView = null
        fileChooserCallback?.onReceiveValue(null)
        super.onDestroy()
    }

    // ── WebView ────────────────────────────────────────────────────────────

    @SuppressLint("SetJavaScriptEnabled", "RequiresFeature", "RestrictedApi")
    private fun createWebView() {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        val view = WebView(this)
        filter.setupWebView(view)
        view.setBackgroundColor(Color.BLACK)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            cacheMode = WebSettings.LOAD_DEFAULT
            if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
                WebSettingsCompat.setAlgorithmicDarkeningAllowed(this, false)
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(
                view, STREAM_DOCUMENT_START_SCRIPT, STREAM_ALLOWED_ORIGIN_RULES
            )
        }
        // The page script posts its watch progress here; the site keeps the position itself,
        // so the app only needs the bridge to exist.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(
                view, STREAM_BRIDGE_NAME, STREAM_ALLOWED_ORIGIN_RULES
            ) { _, _, _, _, _ -> }
        }
        view.webChromeClient = ChromeClient()
        view.webViewClient = BlockingClient()
        root.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        webView = view
        updateOrientation()
        view.loadUrl(pageUrl)
    }

    /** A dead renderer leaves the WebView unusable: rebuild it on the page that was open. */
    private fun onRendererGone(dead: WebView) {
        if (customView != null) hideCustomView()
        root.removeView(dead)
        dead.destroy()
        if (webView === dead) webView = null
        rendererCrashes++
        if (rendererCrashes > MAX_RENDERER_RECOVERIES) {
            Toast.makeText(this, "The player stopped working. Try again.", Toast.LENGTH_LONG).show()
            finish()
        } else {
            createWebView()
        }
    }

    private fun updateOrientation() {
        requestedOrientation = if (customView != null || isStreamWatchUrl(pageUrl)) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
    }

    private fun hideCustomView() {
        (window.decorView as? FrameLayout)?.removeView(customView)
        customView = null
        customViewCallback?.onCustomViewHidden()
        customViewCallback = null
        updateOrientation()
    }

    /** Back from an episode goes to its show page, not through earlier auto-advanced episodes. */
    private fun openShowPage(view: WebView, episode: StreamEpisode) {
        val history = view.copyBackForwardList()
        val previousUrl = history.getItemAtIndex(history.currentIndex - 1)?.url
        if (isStreamShowUrl(previousUrl, episode.tvShowId)) {
            view.goBack()
        } else {
            clearHistoryOnShowPage = episode.tvShowId
            view.loadUrl(buildStreamShowUrl(episode.tvShowId, episode.season))
        }
    }

    // ── Resume (last watched episode per show) ─────────────────────────────

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun loadLastEpisode(showId: Int): StreamEpisode? {
        val raw = prefs().getString("ep_$showId", null) ?: return null
        val parts = raw.split(':').mapNotNull { it.toIntOrNull() }
        return if (parts.size == 2) StreamEpisode(showId, parts[0], parts[1]) else null
    }

    private fun saveEpisode(episode: StreamEpisode) {
        if (episode == lastSavedEpisode) return
        lastSavedEpisode = episode
        prefs().edit()
            .putString("ep_${episode.tvShowId}", "${episode.season}:${episode.episode}")
            .apply()
    }

    // ── Clients ────────────────────────────────────────────────────────────

    private inner class ChromeClient : WebChromeClient() {
        override fun onShowCustomView(view: View?, callback: CustomViewCallback?) {
            val decor = window.decorView as? FrameLayout
            if (view == null || decor == null || customView != null) {
                callback?.onCustomViewHidden()
                return
            }
            decor.addView(
                view,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
            )
            customView = view
            customViewCallback = callback
            updateOrientation()
        }

        override fun onHideCustomView() = hideCustomView()

        // The player's "Upload .srt / .vtt" button. Any MIME type: Android has none for .srt.
        override fun onShowFileChooser(
            webView: WebView?,
            filePathCallback: ValueCallback<Array<Uri>>?,
            fileChooserParams: FileChooserParams?
        ): Boolean {
            fileChooserCallback?.onReceiveValue(null)
            fileChooserCallback = filePathCallback
            return try {
                fileChooser.launch("*/*")
                true
            } catch (e: ActivityNotFoundException) {
                fileChooserCallback = null
                false
            }
        }
    }

    private inner class BlockingClient : WebViewClient() {
        override fun shouldInterceptRequest(
            view: WebView?,
            request: WebResourceRequest?
        ): WebResourceResponse? {
            if (view == null || request == null) return null
            return filter.shouldIntercept(view, request).resourceResponse
        }

        // Ad scripts redirect the whole page on taps; only the stream site may load on top.
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            if (request == null || !request.isForMainFrame) return false
            val url = request.url.toString()
            if (isStreamSiteUrl(url)) return false
            Log.d(TAG, "blocked navigation to $url")
            return true
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            filter.performScript(view, url)
        }

        override fun onPageCommitVisible(view: WebView?, url: String?) = injectStyle(view, url)

        override fun onPageFinished(view: WebView?, url: String?) {
            injectStyle(view, url)
            val showId = clearHistoryOnShowPage
            if (view != null && showId != null && isStreamShowUrl(url, showId)) {
                view.clearHistory()
                clearHistoryOnShowPage = null
            }
        }

        override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
            url ?: return
            pageUrl = url
            updateOrientation()
            parseStreamEpisode(url)?.let(::saveEpisode)
        }

        override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
            Log.w(TAG, "renderer gone, crashed=${detail?.didCrash()}")
            view?.let { onRendererGone(it) }
            return true
        }

        private fun injectStyle(view: WebView?, url: String?) {
            if (isStreamSiteUrl(url)) view?.evaluateJavascript(STREAM_PAGE_SCRIPT, null)
        }
    }
}

/** Method channel "zangetsu/noflix": `open {tmdbId, isTv, season?, episode?}`. */
object NoFlixPlayerBridge {
    fun open(activity: Activity, tmdbId: Int, isTv: Boolean, season: Int?, episode: Int?) {
        activity.startActivity(
            NoFlixPlayerActivity.intent(activity, tmdbId, isTv, season, episode)
        )
    }
}
