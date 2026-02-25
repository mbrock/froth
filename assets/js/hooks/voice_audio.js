import {Socket} from "phoenix"
import MicCapture from "../lib/mic_capture"
import PcmPlayer from "../lib/pcm_player"

export default {
  mounted() {
    this.t0 = performance.now()
    this.mic = null
    this.micStarting = false
    this.pendingMicStart = false
    this.player = new PcmPlayer({ sampleRate: 24000, onLog: (m) => this.log(`play: ${m}`) })
    this.channel = null
    this.channelSocket = null
    this.channelJoined = false
    this.micBtn = document.getElementById("mic-btn")
    this.onMicBtnPointerDown = () => this.player.prepare()

    if (this.micBtn) {
      this.micBtn.addEventListener("pointerdown", this.onMicBtnPointerDown, { passive: true })
    }

    this.log("hook mounted, joining room...")
    this.connectChannel()

    this.handleEvent("start_mic", () => this.startMic())
    this.handleEvent("stop_mic", () => this.stopMic())
    this.handleEvent("scroll_down", () => {
      const el = document.getElementById("transcript-scroll")
      if (el) el.scrollTop = el.scrollHeight
    })
  },

  destroyed() {
    this.pendingMicStart = false
    this.channelJoined = false
    this.stopMic()
    this.player.close()
    if (this.channel) this.channel.leave()
    if (this.channelSocket) this.channelSocket.disconnect()

    if (this.micBtn && this.onMicBtnPointerDown) {
      this.micBtn.removeEventListener("pointerdown", this.onMicBtnPointerDown)
    }
  },

  connectChannel() {
    const micId = this.el.dataset.micId
    const speakerId = this.el.dataset.speakerId
    if (!micId || !speakerId) { this.log("ERROR: missing stream ids"); return }

    this.channelSocket = new Socket("/froth/socket")
    this.channelSocket.onError(() => this.log("socket transport error"))
    this.channelSocket.connect()

    this.channel = this.channelSocket.channel("room:voice", {
      input: micId,
      outputs: [speakerId]
    })
    this.channel.on("pcm", (payload) => {
      const pcm = toArrayBuffer(payload)
      if (!pcm) {
        this.log("play: unsupported pcm payload shape")
        return
      }

      this.player.play(pcm)
    })

    this.channel.onError(() => {
      this.channelJoined = false
      this.log("room channel error")
    })

    this.channel.onClose(() => {
      this.channelJoined = false
      this.log("room channel closed")
    })

    this.channel.join()
      .receive("ok", () => {
        this.channelJoined = true
        this.log("room joined")

        if (this.pendingMicStart) {
          this.pendingMicStart = false
          this.startMic()
        }
      })
      .receive("error", (r) => this.log(`room join error: ${JSON.stringify(r)}`))
  },

  async startMic() {
    if (this.mic || this.micStarting) return

    if (!this.channelJoined) {
      this.pendingMicStart = true
      this.log("mic start queued (waiting for room join)")
      return
    }

    this.micStarting = true
    this.pendingMicStart = false
    this.player.prepare()

    let micConfigured = false

    const mic = new MicCapture({
      onChunk: (buf) => {
        if (!micConfigured) return
        if (this.channel && this.channelJoined) this.channel.push("audio", buf)
      },
      onLog: (m) => this.log(`mic: ${m}`),
      onError: (err) => {
        this.log(`mic ERROR: ${err.message || "unknown error"}`)
        this.pushEvent("client_error", {
          source: "mic",
          message: err.message || "Microphone access failed"
        })
        console.error("Mic error:", err)
      },
    })

    this.mic = mic
    const started = await mic.start()
    this.micStarting = false

    if (!started) {
      if (this.mic === mic) this.mic = null
      return
    }

    if (this.mic !== mic) {
      mic.stop()
      return
    }

    if (this.channel && this.channelJoined) {
      this.channel.push("audio_config", {
        sample_rate: Math.round(mic.sampleRate || 48000),
      })
      micConfigured = true
      this.channel.push("start_asr", {})
        .receive("ok", (r) => this.log(`ASR: ${r.status || "ok"}`))
        .receive("error", (r) => this.log(`ASR start error: ${JSON.stringify(r)}`))
    }
  },

  stopMic() {
    this.pendingMicStart = false
    this.micStarting = false

    if (this.mic) {
      this.mic.stop()
      this.mic = null
    }

    if (this.channel && this.channelJoined) {
      this.channel.push("stop_asr", {})
    }
  },

  log(msg) {
    const ms = ((performance.now() - this.t0) / 1000).toFixed(1)
    const line = `[${ms}s] ${msg}`
    console.log(`%c[VoiceAudio] ${line}`, "color: #8be9fd")
    const el = document.getElementById("debug-log")
    if (el) {
      const p = document.createElement("p")
      p.textContent = line
      el.appendChild(p)
      if (el.children.length > 200) el.children[1].remove()
      el.scrollTop = el.scrollHeight
    }
  },
}

function toArrayBuffer(payload) {
  if (payload instanceof ArrayBuffer) return payload

  if (ArrayBuffer.isView(payload)) {
    const { buffer, byteOffset, byteLength } = payload
    return buffer.slice(byteOffset, byteOffset + byteLength)
  }

  if (payload && payload.buffer instanceof ArrayBuffer && typeof payload.byteLength === "number") {
    return payload.buffer.slice(payload.byteOffset || 0, (payload.byteOffset || 0) + payload.byteLength)
  }

  if (payload && typeof payload === "object") {
    const values = Object.values(payload)
    if (values.length > 0 && values.every(v => Number.isInteger(v) && v >= 0 && v <= 255)) {
      return new Uint8Array(values).buffer
    }
  }

  return null
}
