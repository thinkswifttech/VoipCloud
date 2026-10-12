package com.thinkswift.softphoneapp

import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Bounded burst buffer. No disk IO is performed by append's calling thread. */
internal class BufferedSipLogFile(
    private val file: () -> File,
    private val maxBytes: Long = 1_500_000L,
    private val maxPendingChars: Int = 256_000,
    private val executor: Executor = writerExecutor,
    private val onError: (Throwable) -> Unit = {}
) {
    private val pendingLock = Any()
    private val ioLock = Any()
    private val pending = ArrayDeque<String>()
    private var pendingChars = 0
    private var dropped = 0
    private var scheduled = false

    fun append(line: String) {
        synchronized(pendingLock) {
            val value = line.trimEnd() + "\n"
            if (value.length > maxPendingChars) {
                dropped++
            } else {
                while (pendingChars + value.length > maxPendingChars) {
                    pendingChars -= pending.removeFirst().length
                    dropped++
                }
                pending.addLast(value)
                pendingChars += value.length
            }
            if (!scheduled) {
                scheduled = true
                executor.execute { flush() }
            }
        }
    }

    private fun flush() = synchronized(ioLock) {
        while (true) {
            val batch = synchronized(pendingLock) takeBatch@ {
                if (pending.isEmpty() && dropped == 0) {
                    scheduled = false
                    return@takeBatch ""
                }
                buildString {
                    if (dropped > 0) append("[WARN] SIP log burst buffer dropped $dropped lines\n")
                    dropped = 0
                    while (pending.isNotEmpty()) append(pending.removeFirst())
                    pendingChars = 0
                }
            }
            if (batch.isEmpty()) break
            try {
                val target = file()
                target.parentFile?.mkdirs()
                if (target.exists() && target.length() > maxBytes) {
                    target.writeText(target.readText().takeLast((maxBytes / 2).toInt()))
                }
                target.appendText(batch)
            } catch (error: Throwable) {
                onError(error)
            }
        }
    }

    // Explicit export/clear are ordered with pending writes. Clear cannot be
    // undone by an older buffered batch, and exports include buffered lines.
    fun read(): String = synchronized(ioLock) {
        flush()
        try { file().takeIf { it.exists() }?.readText() ?: "" }
        catch (_: Throwable) { "" }
    }

    fun clear() = synchronized(ioLock) {
        synchronized(pendingLock) {
            pending.clear()
            pendingChars = 0
            dropped = 0
        }
        try { file().takeIf { it.exists() }?.writeText("") }
        catch (_: Throwable) {}
    }

    companion object {
        // Process-scoped worker: activity recreation must not leak threads.
        private val writerExecutor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "VoIPCloud-SIP-log-writer").apply { isDaemon = true }
        }
    }
}
