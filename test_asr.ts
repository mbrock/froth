#!/usr/bin/env bun
/**
 * End-to-end ASR test against the running Phoenix app.
 *
 * Usage:
 *   bun test_asr.ts test_3sentences.mp3
 *   bun test_asr.ts test_3sentences.mp3 --fake
 *   bun test_asr.ts test_3sentences.mp3 --rate 16000
 */

import { Socket } from "./deps/phoenix/priv/static/phoenix.mjs"
import { execSync } from "child_process"
import { readFileSync } from "fs"

const CHUNK_SAMPLES = 4096
const DEFAULT_RATE = 48000
const SOCKET_URL = "ws://localhost:4000/froth/socket"
const FAKE_PORT = 8765

const file = process.argv[2]
if (!file) {
  console.error("Usage: bun test_asr.ts <audio-file> [--fake] [--rate N]")
  process.exit(1)
}

const rateIdx = process.argv.indexOf("--rate")
const sendRate = rateIdx !== -1 ? parseInt(process.argv[rateIdx + 1]) : DEFAULT_RATE
const useFake = process.argv.includes("--fake")

const t0 = performance.now()
function elapsed(): string {
  return `${((performance.now() - t0) / 1000).toFixed(1)}s`
}
function log(msg: string) {
  console.log(`[${elapsed()}] ${msg}`)
}

// --- Fake Qwen server (inline) ---

function startFakeQwen(): Promise<void> {
  return new Promise((resolve) => {
    let totalFrames = 0
    let totalAudioBytes = 0
    let speechActive = false
    let silentMs = 0
    let itemId = ""

    Bun.serve({
      port: FAKE_PORT,
      fetch(req, server) {
        if (server.upgrade(req)) return
        return new Response("fake qwen", { status: 200 })
      },
      websocket: {
        open(ws) {
          const sampleRate = 16000
          ;(ws as any).sampleRate = sampleRate
          log(`fake: connected`)
          ws.send(JSON.stringify({
            event_id: `e_${Date.now()}`,
            type: "session.created",
            session: {
              id: `sess_fake_${Date.now()}`,
              object: "realtime.session",
              model: "fake",
              modalities: ["text"],
              input_audio_format: "pcm",
              sample_rate: sampleRate,
              input_audio_transcription: { model: "fake" },
              turn_detection: { type: "server_vad", threshold: 0.2, silence_duration_ms: 800 },
            }
          }))
        },
        message(ws, msg) {
          if (typeof msg !== "string") return
          let event: any
          try { event = JSON.parse(msg) } catch { return }

          if (event.type === "session.update") {
            const rate = event.session?.sample_rate || (ws as any).sampleRate
            ;(ws as any).sampleRate = rate
            log(`fake: session.update rate=${rate}`)
            ws.send(JSON.stringify({
              event_id: `e_${Date.now()}`,
              type: "session.updated",
              session: {
                id: `sess_fake_${Date.now()}`,
                object: "realtime.session",
                model: "fake",
                modalities: ["text"],
                input_audio_format: "pcm",
                input_audio_transcription: {
                  model: "fake",
                  language: event.session?.input_audio_transcription?.language || "en",
                },
                turn_detection: event.session?.turn_detection || {
                  type: "server_vad", threshold: 0.2, silence_duration_ms: 800,
                  create_response: true, interrupt_response: true,
                },
                sample_rate: rate,
              }
            }))
          } else if (event.type === "input_audio_buffer.append") {
            const bytes = Buffer.from(event.audio, "base64")
            const sampleRate = (ws as any).sampleRate || 16000
            totalFrames++
            totalAudioBytes += bytes.length
            const frameSamples = bytes.length / 2
            const frameMs = (frameSamples / sampleRate) * 1000
            const totalMs = (totalAudioBytes / 2 / sampleRate) * 1000

            let sumSq = 0
            for (let i = 0; i < bytes.length - 1; i += 2) {
              const s = bytes.readInt16LE(i)
              sumSq += s * s
            }
            const rms = Math.sqrt(sumSq / frameSamples)
            const hasVoice = rms > 200

            if (totalFrames % 12 === 0 || totalFrames <= 3) {
              log(`fake: #${totalFrames} ${bytes.length}B rms=${rms.toFixed(0)} total=${(totalMs/1000).toFixed(1)}s`)
            }

            if (hasVoice && !speechActive) {
              speechActive = true
              silentMs = 0
              itemId = `item_fake_${Date.now()}`
              ws.send(JSON.stringify({
                event_id: `e_${Date.now()}`, type: "input_audio_buffer.speech_started",
                audio_start_ms: Math.round(totalMs), item_id: itemId,
              }))
              ws.send(JSON.stringify({
                event_id: `e_${Date.now()}`, type: "conversation.item.created",
                item: { id: itemId, object: "realtime.item", type: "message", status: "in_progress", role: "assistant", content: [{ type: "input_audio" }] },
              }))
              log(`fake: VAD speech_started at ${(totalMs/1000).toFixed(1)}s`)
            }

            if (!hasVoice && speechActive) {
              silentMs += frameMs
              if (silentMs >= 800) {
                speechActive = false
                ws.send(JSON.stringify({
                  event_id: `e_${Date.now()}`, type: "input_audio_buffer.speech_stopped",
                  audio_end_ms: Math.round(totalMs), item_id: itemId,
                }))
                ws.send(JSON.stringify({
                  event_id: `e_${Date.now()}`, type: "input_audio_buffer.committed", item_id: itemId,
                }))
                ws.send(JSON.stringify({
                  event_id: `e_${Date.now()}`, type: "conversation.item.input_audio_transcription.completed",
                  item_id: itemId, content_index: 0,
                  transcript: `[fake transcript, speech ended at ${(totalMs/1000).toFixed(1)}s]`,
                  language: "en", emotion: "neutral",
                }))
                log(`fake: VAD speech_stopped at ${(totalMs/1000).toFixed(1)}s (${silentMs.toFixed(0)}ms silence)`)
              }
            } else if (hasVoice) {
              silentMs = 0
            }

            if (speechActive && totalFrames % 6 === 0) {
              ws.send(JSON.stringify({
                event_id: `e_${Date.now()}`, type: "conversation.item.input_audio_transcription.text",
                item_id: itemId, content_index: 0,
                text: "", stash: `[partial at ${(totalMs/1000).toFixed(1)}s]`,
                language: "en", emotion: "neutral",
              }))
            }
          } else if (event.type === "session.finish") {
            log(`fake: session.finish — ${totalFrames} frames, ${totalAudioBytes}B`)
            ws.send(JSON.stringify({ event_id: `e_${Date.now()}`, type: "session.finished" }))
            ws.close()
          }
        },
        close() {
          log(`fake: ws closed — ${totalFrames} frames, ${totalAudioBytes}B`)
        },
      }
    })

    log(`fake: listening on ws://localhost:${FAKE_PORT}`)
    resolve()
  })
}

// --- Audio prep ---

function fileToPcm(path: string, rate: number): Buffer {
  if (path.endsWith(".raw") || path.endsWith(".pcm")) return readFileSync(path)
  return Buffer.from(execSync(
    `ffmpeg -i "${path}" -ar ${rate} -ac 1 -f s16le -acodec pcm_s16le -v error -`,
    { maxBuffer: 50 * 1024 * 1024 }
  ))
}

function createStream(rate: number): string {
  const result = execSync(
    `cd /home/mbrock/froth && mix run -e 's = Froth.Repo.insert!(%Voice.Stream{rate: ${rate}}); IO.puts(s.id)'`,
    { encoding: "utf-8" }
  ).trim()
  return result.split("\n").pop()!.trim()
}

// --- Main ---

async function main() {
  if (useFake) await startFakeQwen()

  log(`converting ${file} to ${sendRate}Hz PCM...`)
  const pcm = fileToPcm(file, sendRate)

  const chunkBytes = CHUNK_SAMPLES * 2
  const chunkMs = Math.floor((CHUNK_SAMPLES * 1000) / sendRate)
  const chunks: ArrayBuffer[] = []
  for (let i = 0; i + chunkBytes <= pcm.length; i += chunkBytes) {
    const ab = new ArrayBuffer(chunkBytes)
    new Uint8Array(ab).set(pcm.subarray(i, i + chunkBytes))
    chunks.push(ab)
  }
  const durationS = pcm.length / (sendRate * 2)
  const chunksPerSec = (1000 / chunkMs).toFixed(1)
  const kbPerSec = ((chunkBytes * 1000 / chunkMs) / 1024).toFixed(1)
  log(`${chunks.length} chunks, ${durationS.toFixed(1)}s audio, ${chunkMs}ms/chunk (${chunksPerSec} chunks/s, ${kbPerSec} KB/s raw PCM)`)

  log("creating stream in DB...")
  const streamId = createStream(sendRate)
  log(`stream: ${streamId}`)

  log(`connecting to ${SOCKET_URL}...`)
  const socket = new Socket(SOCKET_URL, { transport: WebSocket })
  socket.onError((e: any) => log(`socket error: ${e}`))
  socket.connect()

  const channel = socket.channel("room:voice", { input: streamId, outputs: [] })
  channel.on("pcm", () => {})

  channel.join()
    .receive("ok", async () => {
      log("joined room:voice")

      channel.push("audio_config", { sample_rate: sendRate })
      channel.push("start_asr", useFake ? { fake: true } : {})
        .receive("ok", (r: any) => log(`ASR: ${r.status}`))
        .receive("error", (r: any) => { log(`ASR start failed: ${JSON.stringify(r)}`); process.exit(1) })

      await Bun.sleep(2000)

      const streamStart = performance.now()
      log(`streaming ${chunks.length} chunks (1 every ${chunkMs}ms = realtime)...`)
      for (let i = 0; i < chunks.length; i++) {
        channel.push("audio", chunks[i])
        if ((i + 1) % 50 === 0 || i === chunks.length - 1) {
          const wallMs = performance.now() - streamStart
          const audioMs = (i + 1) * chunkMs
          const drift = wallMs - audioMs
          log(`  sent ${i + 1}/${chunks.length}  wall=${(wallMs/1000).toFixed(1)}s  audio=${(audioMs/1000).toFixed(1)}s  drift=${drift > 0 ? '+' : ''}${(drift/1000).toFixed(2)}s`)
        }
        await Bun.sleep(chunkMs)
      }

      log("streaming done, sending stop_asr (session.finish)...")
      channel.push("stop_asr", {})

      log("waiting 30s for Qwen to finish...")
      await Bun.sleep(30000)
      log("done")
      process.exit(0)
    })
    .receive("error", (r: any) => { log(`join error: ${JSON.stringify(r)}`); process.exit(1) })
}

main()
