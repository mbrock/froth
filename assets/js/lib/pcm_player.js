/**
 * Gapless playback of 16-bit signed LE PCM audio chunks.
 * Accepts ArrayBuffer payloads. Creates an AudioContext on first chunk.
 */
export default class PcmPlayer {
  constructor({ sampleRate = 24000, onLog } = {}) {
    this.sampleRate = sampleRate
    this.onLog = onLog || (() => {})
    this.ctx = null
    this.nextPlayTime = 0
    this.chunksPlayed = 0
    this.gaps = 0
  }

  prepare() {
    this.ensureContext()

    if (this.ctx?.state === "suspended") {
      this.ctx.resume()
        .then(() => this.onLog(`resumed AudioContext, state=${this.ctx.state}`))
        .catch((err) => this.onLog(`resume failed: ${err.message}`))
    }
  }

  play(arrayBuffer) {
    if (!(arrayBuffer instanceof ArrayBuffer) || arrayBuffer.byteLength < 2) return

    this.ensureContext()

    if (this.ctx.state === "suspended") {
      this.ctx.resume().catch(() => {})
    }

    const byteLen = arrayBuffer.byteLength - (arrayBuffer.byteLength % 2)
    if (byteLen < 2) return

    const int16 = new Int16Array(arrayBuffer, 0, byteLen / 2)
    const float32 = new Float32Array(int16.length)
    for (let i = 0; i < int16.length; i++) float32[i] = int16[i] / 32768.0

    const buffer = this.ctx.createBuffer(1, float32.length, this.sampleRate)
    buffer.getChannelData(0).set(float32)
    const node = this.ctx.createBufferSource()
    node.buffer = buffer
    node.connect(this.ctx.destination)

    const now = this.ctx.currentTime
    const scheduled = Math.max(now + 0.02, this.nextPlayTime)
    const gap = scheduled - this.nextPlayTime

    if (this.chunksPlayed > 0 && gap > 0.05) {
      this.gaps++
      this.onLog(`GAP ${(gap * 1000).toFixed(0)}ms before chunk #${this.chunksPlayed + 1}`)
    }

    node.start(scheduled)
    this.nextPlayTime = scheduled + buffer.duration
    this.chunksPlayed++

    if (this.chunksPlayed <= 3 || this.chunksPlayed % 10 === 0) {
      const dur_ms = (float32.length / this.sampleRate * 1000).toFixed(0)
      const ahead = ((this.nextPlayTime - now) * 1000).toFixed(0)
      let peak = 0
      for (let i = 0; i < float32.length; i++) {
        const a = Math.abs(float32[i])
        if (a > peak) peak = a
      }
      this.onLog(`chunk #${this.chunksPlayed} ${dur_ms}ms peak=${peak.toFixed(3)} buffer=${ahead}ms ahead`)
    }

    node.onended = () => {
      if (this.nextPlayTime <= this.ctx?.currentTime + 0.01) {
        this.onLog(`queue drained after ${this.chunksPlayed} chunks (${this.gaps} gaps)`)
      }
    }
  }

  ensureContext() {
    if (!this.ctx) {
      this.ctx = new AudioContext({ sampleRate: this.sampleRate })
      this.nextPlayTime = 0
      this.chunksPlayed = 0
      this.gaps = 0
      this.onLog(`created AudioContext, state=${this.ctx.state}`)
    }
  }

  close() {
    if (this.ctx) { this.ctx.close(); this.ctx = null }
  }
}
