package io.github.ccch1mneyyy.dsh_app.phone

import java.util.Collections
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Production dispatch on real serial queues; only the Android control/transport calls are fakes. */
class PhoneSwitchDispatchTest {
    private val controlIo = Executors.newSingleThreadExecutor()
    private val io = Executors.newSingleThreadExecutor()

    @After fun close() {
        controlIo.shutdownNow()
        io.shutdownNow()
        assertTrue(controlIo.awaitTermination(5, TimeUnit.SECONDS))
        assertTrue(io.awaitTermination(5, TimeUnit.SECONDS))
    }

    @Test fun offChangesTheSwitchWhileTransportIsBusyButWaitsForCleanupBeforeReplying() {
        val busy = AtomicBoolean()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val holder = io.submit {
            busy.set(true)
            entered.countDown()
            try { check(release.await(5, TimeUnit.SECONDS)) }
            finally { busy.set(false) }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val enabled = AtomicBoolean(true)
            val changed = CountDownLatch(1)
            val cleanupCalls = AtomicInteger()
            val reply = CompletableFuture<Result<Boolean>>()
            dispatchPhoneSwitch(false, controlIo, io,
                change = { enabled.set(false); changed.countDown(); true },
                backgroundOff = { cleanupCalls.incrementAndGet(); !busy.get() },
                complete = { reply.complete(it) },
            )
            assertTrue(changed.await(5, TimeUnit.SECONDS))
            assertFalse(enabled.get())
            assertEquals(0, cleanupCalls.get())
            assertFalse(reply.isDone)
            release.countDown()
            assertTrue(reply.get(5, TimeUnit.SECONDS).getOrThrow())
            holder.get(5, TimeUnit.SECONDS)
            assertEquals(1, cleanupCalls.get())
        } finally { release.countDown() }
    }

    @Test fun cleanupIsQueuedBeforeALaterModeRequestEvenWhenControlHasNotRunYet() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val holder = controlIo.submit {
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS))
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val cleanupQueued = CountDownLatch(1)
            val observedIo = Executor { action -> io.execute { cleanupQueued.countDown(); action.run() } }
            val events = Collections.synchronizedList(mutableListOf<String>())
            val reply = CompletableFuture<Result<Boolean>>()
            dispatchPhoneSwitch(false, controlIo, observedIo,
                change = { events.add("switch off"); true },
                backgroundOff = { events.add("background off"); true },
                complete = { reply.complete(it) },
            )
            assertTrue(cleanupQueued.await(5, TimeUnit.SECONDS))
            val later = io.submit { events.add("later mode") }
            release.countDown()
            assertTrue(reply.get(5, TimeUnit.SECONDS).getOrThrow())
            later.get(5, TimeUnit.SECONDS)
            holder.get(5, TimeUnit.SECONDS)
            assertEquals(listOf("switch off", "background off", "later mode"), events.toList())
        } finally { release.countDown() }
    }

    @Test fun bothSwitchDirectionsKeepTheirOrderWhileTheTransportQueueWaits() {
        for (requests in listOf(listOf(true, false), listOf(false, true))) {
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val holder = io.submit { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
            try {
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                val enabled = AtomicBoolean()
                val changes = Collections.synchronizedList(mutableListOf<Boolean>())
                val cleanupCalls = AtomicInteger()
                val replies = requests.map { value ->
                    CompletableFuture<Result<Boolean>>().also { reply ->
                        dispatchPhoneSwitch(value, controlIo, io,
                            change = { enabled.set(value); changes.add(value); true },
                            backgroundOff = { cleanupCalls.incrementAndGet(); true },
                            complete = { reply.complete(it) },
                        )
                    }
                }
                controlIo.submit {}.get(5, TimeUnit.SECONDS)
                assertEquals(requests, changes.toList())
                assertEquals(requests.last(), enabled.get())
                assertEquals(0, cleanupCalls.get())
                assertTrue(replies.none { it.isDone })
                release.countDown()
                replies.forEach { assertTrue(it.get(5, TimeUnit.SECONDS).getOrThrow()) }
                holder.get(5, TimeUnit.SECONDS)
                assertEquals(requests.last(), enabled.get())
                assertEquals(1, cleanupCalls.get())
            } finally { release.countDown() }
        }
    }

    @Test fun anUnacceptedChangeDoesNotRunBackgroundCleanup() {
        for (enabled in listOf(false, true)) {
            val cleanupCalls = AtomicInteger()
            val reply = CompletableFuture<Result<Boolean>>()
            dispatchPhoneSwitch(enabled, controlIo, io,
                change = { false },
                backgroundOff = { cleanupCalls.incrementAndGet(); true },
                complete = { reply.complete(it) },
            )
            assertFalse(reply.get(5, TimeUnit.SECONDS).getOrThrow())
            assertEquals(0, cleanupCalls.get())
        }
    }

    @Test fun exceptionsKeepTheirOriginalIdentityAcrossBothQueues() {
        for (failChange in listOf(true, false)) {
            val failure = IllegalStateException("synthetic switch failure")
            val reply = CompletableFuture<Result<Boolean>>()
            dispatchPhoneSwitch(false, controlIo, io,
                change = { if (failChange) throw failure; true },
                backgroundOff = { throw failure },
                complete = { reply.complete(it) },
            )
            assertSame(failure, reply.get(5, TimeUnit.SECONDS).exceptionOrNull())
        }
    }
}
