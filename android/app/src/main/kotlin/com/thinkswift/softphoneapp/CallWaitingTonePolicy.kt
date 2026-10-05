package com.thinkswift.softphoneapp

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.PI

/** Original soft alert: a 400 ms beep followed by silence, repeated every 5 s.
 * Default 30% player volume gives a 2.4% PCM peak before system call volume.
 */
internal object CallWaitingTonePolicy {
    const val sampleRate = 8000
    const val intervalSeconds = 5
    fun wave(preview: Boolean = false): ByteArray {
        val samples = sampleRate * if (preview) 1 else intervalSeconds
        val payload = samples * 2
        val wave = ByteBuffer.allocate(44 + payload).order(ByteOrder.LITTLE_ENDIAN)
        wave.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(36 + payload)
        wave.put("WAVEfmt ".toByteArray(Charsets.US_ASCII)).putInt(16)
        wave.putShort(1).putShort(1).putInt(sampleRate).putInt(sampleRate * 2)
        wave.putShort(2).putShort(16)
        wave.put("data".toByteArray(Charsets.US_ASCII)).putInt(payload)
        repeat(samples) { index ->
            val time = index.toDouble() / sampleRate
            val sample = if (time < 0.4) {
                val ramp = minOf(time / 0.025, (0.4 - time) / 0.025).coerceIn(0.0, 1.0)
                val envelope = 0.5 - 0.5 * cos(PI * ramp)
                (sin(2 * PI * 440 * time) * 0.08 * envelope * 32767).toInt().toShort()
            } else 0.toShort()
            wave.putShort(sample)
        }
        return wave.array()
    }
}
