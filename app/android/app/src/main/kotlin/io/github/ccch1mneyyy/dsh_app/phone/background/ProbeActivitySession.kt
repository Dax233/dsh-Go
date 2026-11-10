package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Retains the original finish endpoint across timeouts, including a late Activity creation. */
internal class ProbeActivitySession {
    private var started = false
    private var finisher: (() -> Unit)? = null
    private val destroyed = CountDownLatch(1)
    private val cleanup = ProbeCleanup {
        val finish = synchronized(this) {
            if (!started) destroyed.countDown()
            finisher
        }
        finish?.invoke()
    }
    val isSealed: Boolean get() = cleanup.isSealed

    @Synchronized fun starting() {
        check(!isSealed && !started)
        started = true
    }

    /** Only a definite rejection of the PendingIntent, never a timeout or transport ambiguity. */
    @Synchronized fun rejected() {
        check(finisher == null)
        destroyed.countDown()
    }

    fun connected(finish: () -> Unit): Boolean {
        val closeNow = synchronized(this) {
            if (finisher != null) return false
            finisher = finish
            isSealed
        }
        if (closeNow) finish()
        return true
    }

    @Synchronized fun detached() {
        if (finisher != null) destroyed.countDown()
    }

    fun close(timeoutMs: Long = 2_000) {
        // The job only sends a Binder finish request; it does not run or wait on an Android UI.
        cleanup.close(onUiThread = true, post = { false })
        if (destroyed.await(timeoutMs, TimeUnit.MILLISECONDS)) return
        // A PendingIntent that was accepted can still be dropped silently (background
        // activity limits), leaving no Activity to finish. Reporting a timeout there keeps
        // this probe retained forever and the channel busy, so an unconnected session is
        // closed as clean; a late creation is finished by connected() seeing the seal.
        val neverConnected = synchronized(this) { finisher == null }
        if (neverConnected) { destroyed.countDown(); return }
        throw TimeoutException()
    }
}
