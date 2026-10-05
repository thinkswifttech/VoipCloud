package com.thinkswift.softphoneapp

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

class CallWaitingTonePolicyTest {
    @Test fun waveIsFiveSecondMonoPcmWithSoftBeepAndSilentGap() {
        val bytes = CallWaitingTonePolicy.wave()
        val wave = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(44 + 8000 * 5 * 2, bytes.size)
        assertEquals("RIFF", String(bytes, 0, 4, Charsets.US_ASCII))
        assertEquals(bytes.size - 8, wave.getInt(4))
        assertEquals("WAVEfmt ", String(bytes, 8, 8, Charsets.US_ASCII))
        assertEquals(1, wave.getShort(20).toInt())
        assertEquals(1, wave.getShort(22).toInt())
        assertEquals(8000, wave.getInt(24))
        assertEquals(16, wave.getShort(34).toInt())
        assertEquals("data", String(bytes, 36, 4, Charsets.US_ASCII))
        val samples = (0 until 8000 * 5).map { wave.getShort(44 + it * 2).toInt() }
        assertTrue(samples.take(3200).any { it != 0 })
        assertTrue(samples.drop(3200).all { it == 0 })
        assertTrue(samples.maxOf { abs(it) } <= 2621)
        assertTrue(samples.take(20).maxOf { abs(it) } < 200)
        assertTrue(samples.slice(3180 until 3200).maxOf { abs(it) } < 200)
    }

    @Test fun toneIsDeterministicForAssetRepair() {
        assertArrayEquals(CallWaitingTonePolicy.wave(), CallWaitingTonePolicy.wave())
    }

    @Test fun previewUsesIdenticalBeepWithoutRepeating() {
        val preview = CallWaitingTonePolicy.wave(preview = true)
        assertEquals(44 + 8000 * 2, preview.size)
        assertArrayEquals(CallWaitingTonePolicy.wave().copyOfRange(44, preview.size), preview.copyOfRange(44, preview.size))
    }
}
