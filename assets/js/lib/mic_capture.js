/**
 * Captures microphone audio as 16-bit signed LE mono PCM
 * at the browser's native sample rate.
 */
export default class MicCapture {
  constructor({ onChunk, onError, onLog }) {
    this.onChunk = onChunk
    this.onError = onError || (() => {})
    this.onLog = onLog || (() => {})
    this.stream = null
    this.audioCtx = null
    this.scriptNode = null
    this.chunksSent = 0
    this.sampleRate = null
    this.stopped = false
    this.running = false
  }

  async start() {
    if (this.running) return true
    this.stopped = false
    this.onLog("requesting getUserMedia...")

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 }
      })

      if (this.stopped) {
        this.stream.getTracks().forEach(t => t.stop())
        this.stream = null
        return false
      }

      this.audioCtx = new AudioContext()
      this.sampleRate = this.audioCtx.sampleRate
      this.onLog(`opened ctx @ ${this.sampleRate}Hz, state=${this.audioCtx.state}`)

      const src = this.audioCtx.createMediaStreamSource(this.stream)
      this.scriptNode = this.audioCtx.createScriptProcessor(4096, 1, 1)
      this.chunksSent = 0

      this.scriptNode.onaudioprocess = (e) => {
        if (this.stopped) return

        const inp = e.inputBuffer.getChannelData(0)
        e.outputBuffer.getChannelData(0).fill(0)

        this.onChunk(float32ToPcm16(inp))

        this.chunksSent++
        if (this.chunksSent % 20 === 0) {
          let peak = 0
          for (let i = 0; i < inp.length; i++) {
            const a = Math.abs(inp[i])
            if (a > peak) peak = a
          }
          this.onLog(`sent ${this.chunksSent} chunks, peak=${peak.toFixed(3)}`)
        }
      }

      src.connect(this.scriptNode)
      this.scriptNode.connect(this.audioCtx.destination)
      this.running = true
      this.onLog("pipeline connected, streaming")
      return true
    } catch (err) {
      this.onLog(`ERROR ${err.name}: ${err.message}`)
      this.onError(err)
      return false
    }
  }

  stop() {
    this.stopped = true
    this.running = false
    const sent = this.chunksSent
    if (this.scriptNode) { this.scriptNode.disconnect(); this.scriptNode = null }
    if (this.stream) {
      this.stream.getTracks().forEach(t => t.stop())
      this.stream = null
    }
    if (this.audioCtx) { this.audioCtx.close(); this.audioCtx = null }
    if (sent > 0) this.onLog(`stopped after ${sent} chunks`)
  }
}

/** Convert float32 samples to 16-bit signed LE PCM ArrayBuffer. */
function float32ToPcm16(samples) {
  const buf = new ArrayBuffer(samples.length * 2)
  const dv = new DataView(buf)
  for (let i = 0; i < samples.length; i++) {
    let s = Math.max(-1, Math.min(1, samples[i]))
    dv.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true)
  }
  return buf
}
