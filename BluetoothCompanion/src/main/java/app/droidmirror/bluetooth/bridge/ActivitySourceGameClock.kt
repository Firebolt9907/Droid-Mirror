package app.droidmirror.bluetooth.bridge

import android.content.Context
import android.content.ContextWrapper
import android.os.Handler
import android.os.Looper
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.View
import android.widget.Chronometer

/** Run the source widget without a window/overlay or access to private timer state.
 * RemoteViews alone calls start/stop/setBase. We supply visibility and a UI handler,
 * then observe the original Chronometer's text exactly as an attached host would.
 */
internal class ActivitySourceGameClock(context: Context, attrs: AttributeSet?) : Chronometer(context, attrs) {
    private var hosted = false
    override fun isShown(): Boolean = hosted && visibility == View.VISIBLE
    override fun postDelayed(action: Runnable, delayMillis: Long): Boolean = ui.postDelayed(action, delayMillis)
    override fun removeCallbacks(action: Runnable): Boolean { ui.removeCallbacks(action); return true }
    fun observe(onText: ((String) -> Unit)?) {
        setOnChronometerTickListener(if (onText == null) null else OnChronometerTickListener { onText(it.text.toString()) })
        hosted = onText != null
        dispatchWindowVisibilityChanged(if (hosted) View.VISIBLE else View.INVISIBLE)
    }
    companion object {
        private val ui by lazy { Handler(Looper.getMainLooper()) }
        fun inflationContext(base: Context): Context = object : ContextWrapper(base) {
            private val inflater by lazy {
                LayoutInflater.from(base).cloneInContext(this).apply {
                    factory2 = object : LayoutInflater.Factory2 {
                        override fun onCreateView(parent: View?, name: String, context: Context, attrs: AttributeSet): View? =
                            if (name == "Chronometer" || name == "android.widget.Chronometer") ActivitySourceGameClock(context, attrs) else null
                        override fun onCreateView(name: String, context: Context, attrs: AttributeSet): View? = onCreateView(null, name, context, attrs)
                    }
                }
            }
            override fun getSystemService(name: String): Any? = if (name == Context.LAYOUT_INFLATER_SERVICE) inflater else super.getSystemService(name)
        }
    }
}
