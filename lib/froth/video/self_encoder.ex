defmodule Froth.Video.SelfEncoder do
  @moduledoc """
  Injects a self-encoding script into episode HTML.

  Two rendering paths:

  - **Canvas-native** (headless): Reads FrothVideo.data, draws scenes + text
    directly to canvas, encodes via MediaRecorder. Works with cross-origin images.
    Real-time speed.

  - **DOM capture** (headful): Uses element capture or tab capture with WebCodecs.
    Full CSS/DOM fidelity. Faster than real-time. Requires headful Chrome.

  RFC-0001 compliant.
  """

  @doc """
  Inject self-encoding into episode HTML.

  Options:
  - `:fps` - frames per second (default 24)
  - `:force` - skip URL param check, always encode (default false)
  """
  def inject(html, opts \\ []) when is_binary(html) and is_list(opts) do
    fps = Keyword.get(opts, :fps, 24)
    force = Keyword.get(opts, :force, false)

    script = canvas_encoder_js(fps, force)
    String.replace(html, "</body>", "#{script}\n</body>", global: false)
  end

  defp canvas_encoder_js(fps, force) do
    guard =
      if force, do: "// Force encode mode", else: "if (params.get('encode') !== '1') return;"

    ~s"""
    <script>
    // Self-Encoder — RFC-0001 (Canvas-Native Path)
    (function() {
      var params = new URLSearchParams(window.location.search);
      #{guard}

      var FPS = #{fps};

      function waitForReady() {
        return new Promise(function(resolve) {
          (function check() {
            if (window.FrothVideo && window.FrothVideo.ready) resolve(window.FrothVideo);
            else setTimeout(check, 100);
          })();
        });
      }

      async function loadImage(url) {
        var img = new Image();
        img.crossOrigin = 'anonymous';
        return new Promise(function(resolve, reject) {
          img.onload = function() { resolve(img); };
          img.onerror = function() { reject('Failed: ' + url); };
          img.src = url;
        });
      }

      async function encode() {
        var froth = await waitForReady();
        var data = froth.data;
        var duration = data.duration_s;
        var totalFrames = Math.ceil(duration * FPS);
        var W = 1080, H = 1920;

        document.title = 'loading-images';

        // Load all scene images
        var sceneImages = [];
        for (var i = 0; i < data.scenes.length; i++) {
          sceneImages.push(await loadImage(data.scenes[i].src));
          document.title = 'loading-images:' + (i+1) + '/' + data.scenes.length;
        }

        // Set up canvas + MediaRecorder
        var canvas = document.createElement('canvas');
        canvas.width = W; canvas.height = H;
        var ctx = canvas.getContext('2d');

        var stream = canvas.captureStream(FPS);
        var recorder = new MediaRecorder(stream, {
          mimeType: 'video/webm;codecs=vp9',
          videoBitsPerSecond: 6000000
        });

        window._dataChunks = [];
        recorder.ondataavailable = function(e) {
          if (e.data.size > 0) window._dataChunks.push(e.data);
        };
        var doneP = new Promise(function(r) { recorder.onstop = r; });
        recorder.start(1000);

        var startTime = performance.now();
        var frameDur = 1000 / FPS;

        for (var f = 0; f < totalFrames; f++) {
          var t = f / FPS;
          renderCanvasFrame(ctx, data, sceneImages, t, W, H);

          // Real-time pacing
          var target = startTime + (f + 1) * frameDur;
          var now = performance.now();
          if (target > now) await new Promise(function(r) { setTimeout(r, target - now); });

          if (f % FPS === 0) {
            document.title = 'encoding:' + Math.round(f / totalFrames * 100) + '%';
          }
        }

        await new Promise(function(r) { setTimeout(r, 1000); });
        recorder.stop();
        await doneP;

        var blob = new Blob(window._dataChunks, {type: 'video/webm'});
        var buffer = await blob.arrayBuffer();
        var bytes = new Uint8Array(buffer);
        var elapsed = (performance.now() - startTime) / 1000;

        // Base64 chunks for CDP extraction
        var chunkSize = 384 * 1024;
        window._b64 = [];
        for (var i = 0; i < bytes.length; i += chunkSize) {
          var slice = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
          var bin = '';
          for (var j = 0; j < slice.length; j++) bin += String.fromCharCode(slice[j]);
          window._b64.push(btoa(bin));
        }

        window._encodeResult = {
          totalSize: bytes.length,
          numChunks: window._b64.length,
          mimeType: 'video/webm',
          elapsed: elapsed,
          speed: (duration / elapsed).toFixed(1) + 'x',
          frames: totalFrames,
          duration: duration
        };
        document.title = 'encoded:' + (bytes.length/1024/1024).toFixed(1) + 'MB:' + (duration/elapsed).toFixed(1) + 'x';
      }

      function renderCanvasFrame(ctx, data, images, t, W, H) {
        // Background scene with crossfade
        ctx.globalAlpha = 1;
        ctx.fillStyle = '#0d1117';
        ctx.fillRect(0, 0, W, H);

        for (var i = 0; i < data.scenes.length; i++) {
          var scene = data.scenes[i];
          var opacity = sceneOpacity(data, i, t);
          if (opacity <= 0) continue;

          ctx.globalAlpha = opacity;
          var img = images[i];
          if (!img) continue;

          // Cover-fit the image
          var scale = Math.max(W / img.width, H / img.height);
          var w = img.width * scale;
          var h = img.height * scale;

          // Ken Burns
          var progress = Math.max(0, Math.min(1, (t - scene.start) / (scene.end - scene.start)));
          var ease = progress < 0.5 ? 2*progress*progress : 1 - Math.pow(-2*progress+2,2)/2;
          var zoom = 1 + ease * 0.08;

          var x = (W - w * zoom) / 2;
          var y = (H - h * zoom) / 2;
          ctx.drawImage(img, x, y, w * zoom, h * zoom);
        }

        // Dark overlay
        ctx.globalAlpha = 0.35;
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, W, H);
        ctx.globalAlpha = 1;

        // Find active phrase and word
        var phraseIdx = -1, wordIdx = -1;
        for (var p = 0; p < data.phrases.length; p++) {
          var ph = data.phrases[p];
          if (t >= ph.start - 0.15 && t < ph.end + 0.4) {
            phraseIdx = p;
            break;
          }
        }

        if (phraseIdx >= 0) {
          var phrase = data.phrases[phraseIdx];
          wordIdx = -1;
          for (var wi = 0; wi < phrase.word_indices.length; wi++) {
            var wdata = data.words[phrase.word_indices[wi]];
            if (t >= wdata.start && t < wdata.end + 0.1) {
              wordIdx = phrase.word_indices[wi];
              break;
            }
          }

          // Render phrase text
          var words = phrase.word_indices.map(function(wi) { return data.words[wi]; });
          var text = words.map(function(w) { return w.text; }).join(' ');

          ctx.textAlign = 'center';
          ctx.textBaseline = 'middle';
          ctx.font = 'bold 72px system-ui, -apple-system, sans-serif';

          // Word wrap
          var maxW = W - 120;
          var rawWords = text.split(' ');
          var lines = [], cur = '';
          for (var rw = 0; rw < rawWords.length; rw++) {
            var test = cur ? cur + ' ' + rawWords[rw] : rawWords[rw];
            if (ctx.measureText(test).width > maxW && cur) {
              lines.push(cur);
              cur = rawWords[rw];
            } else {
              cur = test;
            }
          }
          if (cur) lines.push(cur);

          var lineH = 95;
          var totalH = lines.length * lineH;
          var startY = H/2 - totalH/2;
          var globalWordOffset = 0;

          for (var l = 0; l < lines.length; l++) {
            var lineWords = lines[l].split(' ');
            var lineY = startY + l * lineH + lineH / 2;
            var lineW = ctx.measureText(lines[l]).width;
            var lx = W/2 - lineW/2;

            for (var lw = 0; lw < lineWords.length; lw++) {
              var globalWI = phrase.word_indices[globalWordOffset + lw];
              var isActive = globalWI === wordIdx;

              ctx.shadowColor = 'rgba(0,0,0,0.9)';
              ctx.shadowBlur = isActive ? 30 : 12;
              ctx.shadowOffsetX = 0;
              ctx.shadowOffsetY = 3;
              ctx.fillStyle = isActive ? '#FFD700' : 'rgba(255,255,255,0.95)';
              ctx.font = isActive ? 'bold 78px system-ui, sans-serif' : 'bold 72px system-ui, sans-serif';
              ctx.textAlign = 'left';
              ctx.fillText(lineWords[lw], lx, lineY);
              lx += ctx.measureText(lineWords[lw] + ' ').width;
            }
            globalWordOffset += lineWords.length;
          }
          ctx.shadowBlur = 0;
          ctx.shadowOffsetY = 0;
        }

        // Title bar
        ctx.textAlign = 'center';
        ctx.fillStyle = 'rgba(255,255,255,0.25)';
        ctx.font = '28px system-ui, sans-serif';
        ctx.fillText('THE SEALED ROOM', W/2, 120);
      }

      function sceneOpacity(data, index, t) {
        var scene = data.scenes[index];
        var trans = (data.transition_ms || 800) / 1000;
        if (t < scene.start || t >= scene.end) return 0;
        var opacity = 1;
        // Fade in
        if (index > 0 && t < scene.start + trans * 0.5) {
          opacity = (t - scene.start) / (trans * 0.5);
        }
        // Fade out
        var next = data.scenes[index + 1];
        if (next) {
          var fadeStart = Math.max(scene.start, next.start - trans);
          if (t >= fadeStart) {
            var prog = (t - fadeStart) / Math.max(next.start - fadeStart, 0.001);
            opacity *= (1 - prog);
          }
        }
        return Math.max(0, Math.min(1, opacity));
      }

      encode().catch(function(e) {
        window._encodeError = e.message + ' | ' + e.stack;
        document.title = 'encode-error:' + e.message;
      });
    })();
    </script>
    """
  end
end
