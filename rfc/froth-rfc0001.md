# FROTH-RFC-0001: In-Browser Video Encoding via WebCodecs

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-20
Supersedes: The screenshot-to-PNG-to-ffmpeg pipeline

## Problem

Rendering a 4-minute video at 24fps currently requires:

1. 6083 calls to Browser.screenshot()
2. 6083 PNG files written to disk (9.7GB)
3. One ffmpeg invocation reading all PNGs back
4. 15 minutes wall time (serial) or 10 minutes (4 workers)

The browser renders every pixel. Then we photograph the pixels.
Then we give the photographs to a C program that turns them back
into pixels in a different format. The intermediate representation
is nine gigabytes of lossless bitmaps on a filesystem.

## Proposal

Replace the screenshot+ffmpeg pipeline with WebCodecs running
inside the same Chrome instance that renders the frames.

The browser renders the frame. The browser encodes the frame.
The browser muxes the encoded frame. No screenshot. No PNG.
No disk. No ffmpeg. The pixels never leave the GPU.

## Architecture

### Encoder Script (injected into the reel HTML)

```
async function encodeVideo(durationS, fps) {
  const canvas = document.querySelector('#video canvas')
    || createOffscreenCanvas();

  const chunks = [];
  const encoder = new VideoEncoder({
    output: (chunk, meta) => {
      const buf = new ArrayBuffer(chunk.byteLength);
      chunk.copyTo(buf);
      chunks.push({
        type: chunk.type,
        timestamp: chunk.timestamp,
        duration: chunk.duration,
        data: btoa(String.fromCharCode(...new Uint8Array(buf)))
      });
    },
    error: (e) => console.error('Encoder error:', e)
  });

  encoder.configure({
    codec: 'avc1.640028',       // H.264 High Profile Level 4.0
    width: 1080,
    height: 1920,
    bitrate: 4_000_000,         // 4 Mbps
    framerate: fps,
    latencyMode: 'quality',
    avc: { format: 'annexb' }   // Raw NAL units
  });

  const frameCount = Math.ceil(durationS * fps);

  for (let i = 0; i < frameCount; i++) {
    const t = i / fps;
    window.FrothVideo.renderAt(t);

    // Capture the current viewport as a VideoFrame
    const frame = new VideoFrame(canvas, {
      timestamp: Math.round(t * 1_000_000),  // microseconds
      duration: Math.round(1_000_000 / fps)
    });

    const keyFrame = (i % (fps * 2)) === 0;  // keyframe every 2s
    encoder.encode(frame, { keyFrame });
    frame.close();

    // Yield to prevent UI lockup (optional in headless)
    if (i % 100 === 0) await new Promise(r => setTimeout(r, 0));
  }

  await encoder.flush();
  encoder.close();

  return chunks;
}
```

### Canvas Requirement

WebCodecs needs a canvas or offscreen canvas to create VideoFrames.
The current template renders to DOM elements (divs with background
images, text spans). Two options:

A. **html2canvas approach**: After each renderAt(), use
   html2canvas or a similar library to rasterize the DOM to a
   canvas. Adds ~20ms per frame. Total overhead: ~2 minutes
   for a 4-minute video.

B. **Native canvas rendering**: Rewrite the renderer to paint
   directly to a canvas using CanvasRenderingContext2D. Faster
   but loses CSS typography, transitions, and layout. Wrong
   tradeoff for our use case where the CSS IS the production
   value.

C. **OffscreenCanvas from screenshot**: Use Chrome DevTools
   Page.captureScreenshot but decode it into a VideoFrame
   instead of writing to disk. Hybrid approach: DOM rendering
   for quality, WebCodecs for encoding. Still uses DevTools
   but eliminates disk I/O.

D. **Chrome's --enable-features=CanvasOopRasterization**: With
   GPU rasterization enabled in headless Chrome, the entire
   page render is already on the GPU. A VideoFrame can be
   constructed from the compositor output via
   `document.startViewTransition` or similar emerging APIs.
   This is the zero-copy path. Not stable yet.

**Recommended: Option C for v1, Option D when Chrome ships it.**

### Muxing

Encoded chunks need to be assembled into an MP4 container.

**In-browser (preferred):**
- mp4-muxer (npm): ~50KB, produces spec-compliant fMP4
- Inject via CDN URL or inline the library

**Server-side fallback:**
- Stream chunks back to Elixir via DevTools eval
- Assemble with an Elixir MP4 writer or pipe to ffmpeg
- Still eliminates PNGs; ffmpeg reads raw H.264 from stdin

### Audio

WebCodecs has AudioEncoder. The podcast MP3 can be decoded
via AudioContext.decodeAudioData(), re-encoded as AAC via
AudioEncoder, and muxed alongside the video track. Or: mux
the video-only MP4 server-side and add the audio with one
ffmpeg call (ffmpeg -i video.mp4 -i audio.mp3 -c copy out.mp4).
The audio mux is trivial. Do not let it block the video path.

## Integration with Froth.Compute

The distributed compute system (RFC pending) remains valuable.
Each compute worker runs Chrome with the encoder inside it.
Instead of:

    worker claims task → boots Chrome → screenshots N frames
    → writes PNGs → completes task with file artifacts

It becomes:

    worker claims task → boots Chrome → encodes N frames
    → returns binary H.264 segment → completes task with
      binary artifact

The coordination layer (jobs, tasks, leases, heartbeats) is
unchanged. The artifact kind changes from "frame_batch_png"
to "encoded_segment_h264". The final mux concatenates segments
instead of encoding from PNGs.

Parallel encoding across nodes: each node encodes its time
range independently. Keyframe alignment at segment boundaries
ensures clean concatenation. The ffmpeg concat demuxer handles
this natively:

    ffmpeg -f concat -i segments.txt -c copy final.mp4

## Performance Estimate

Current pipeline (screenshot + ffmpeg):
- 55ms per frame capture (screenshot to PNG)
- 6083 frames × 55ms = 335s (5.5 min serial)
- 4 workers: ~165s (2.75 min)
- Plus ffmpeg mux: ~60s
- Total: ~4 min with 4 workers

WebCodecs pipeline (Option C):
- 55ms per frame capture (screenshot via DevTools)
- ~2ms per frame encode (hardware H.264)
- 6083 frames × 57ms = 347s serial
- 4 workers: ~87s (1.5 min)
- Plus segment concat: ~5s
- Total: ~1.5 min with 4 workers
- Disk I/O: zero intermediate files

WebCodecs pipeline (Option D, future):
- ~15ms per frame (DOM render only, no screenshot)
- ~2ms per frame encode
- 6083 frames × 17ms = 103s serial
- 4 workers: ~26s
- Total: ~30s with 4 workers

## Migration Path

1. Keep current screenshot pipeline as fallback
2. Implement Option C: DevTools screenshot → VideoFrame → encode
3. Stream encoded chunks back via DevTools Runtime.evaluate
4. Wire into ComputeRenderer as the default encode path
5. Measure. If faster, delete the PNG path.
6. When Chrome ships zero-copy compositor access, implement Option D

## Open Questions

- Does headless Chrome support hardware-accelerated VideoEncoder?
  If not, software H.264 encoding adds ~10ms/frame. Still faster
  than writing PNGs to disk.
- Maximum chunk size returnablvia DevTools eval? May need to
  stream chunks via WebSocket instead of returning them all at
  once. The ComputeWorkerChannel already speaks WebSocket.
- Can OffscreenCanvas capture the full page render including
  CSS animations, or only explicit canvas draws? If the latter,
  Option C (DevTools screenshot → VideoFrame) is the correct v1.

## References

- WebCodecs API: https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API
- VideoEncoder: https://developer.mozilla.org/en-US/docs/Web/API/VideoEncoder
- mp4-muxer: https://github.com/niclas-niclas/mp4-muxer
- Chrome headless WebCodecs support: chromium.org/blog (pending verification)
- Froth.Compute: lib/froth/compute.ex
- Froth.Video.ComputeRenderer: lib/froth/video/compute_renderer.ex
