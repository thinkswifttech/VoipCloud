package com.thinkswift.softphoneapp

import java.nio.file.Files
import java.util.concurrent.Executor
import org.junit.Assert.*
import org.junit.Test

class BufferedSipLogFileTest {
    @Test fun burstSchedulesOneWriteAndExportFlushesPendingLines() {
        val target = Files.createTempFile("sip-log", ".txt").toFile()
        try {
            val tasks = mutableListOf<Runnable>()
            val writer = BufferedSipLogFile({ target }, executor = Executor { tasks.add(it) })
            repeat(1000) { writer.append("line $it") }
            assertEquals(1, tasks.size)
            assertEquals("", target.readText())
            assertTrue(writer.read().endsWith("line 999\n"))
            assertEquals(1000, target.readLines().size)
        } finally { target.delete() }
    }

    @Test fun clearCannotBeUndoneByQueuedWrites() {
        val target = Files.createTempFile("sip-log", ".txt").toFile()
        try {
            val tasks = mutableListOf<Runnable>()
            val writer = BufferedSipLogFile({ target }, executor = Executor { tasks.add(it) })
            writer.append("old")
            writer.clear()
            tasks.forEach { it.run() }
            assertEquals("", writer.read())
            writer.append("new")
            assertEquals("new\n", writer.read())
        } finally { target.delete() }
    }

    @Test fun overloadIsBoundedAndReported() {
        val target = Files.createTempFile("sip-log", ".txt").toFile()
        try {
            val writer = BufferedSipLogFile({ target }, maxPendingChars = 20, executor = Executor {})
            repeat(100) { writer.append("line $it") }
            val output = writer.read()
            assertTrue(output.contains("buffer dropped"))
            assertTrue(output.endsWith("line 99\n"))
            assertTrue(output.length < 200)
        } finally { target.delete() }
    }
}
