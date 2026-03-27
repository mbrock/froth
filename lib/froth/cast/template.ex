defmodule Froth.Cast.Template do
  @moduledoc false

  alias Froth.Cast.Recording

  @vendor_98_css_path Path.expand("../../../priv/static/vendor/98.css", __DIR__)
  @vendor_98_font_regular_path Path.expand(
                                 "../../../priv/static/vendor/ms_sans_serif.woff2",
                                 __DIR__
                               )
  @vendor_98_font_bold_path Path.expand(
                              "../../../priv/static/vendor/ms_sans_serif_bold.woff2",
                              __DIR__
                            )

  @external_resource @vendor_98_css_path
  @external_resource @vendor_98_font_regular_path
  @external_resource @vendor_98_font_bold_path

  @embedded_98_css (
                     regular_font = Base.encode64(File.read!(@vendor_98_font_regular_path))
                     bold_font = Base.encode64(File.read!(@vendor_98_font_bold_path))

                     File.read!(@vendor_98_css_path)
                     |> String.replace(
                       ~s|src:url(ms_sans_serif.woff) format("woff");src:url(ms_sans_serif.woff2) format("woff2")|,
                       ~s|src:url(data:font/woff2;base64,#{regular_font}) format("woff2")|
                     )
                     |> String.replace(
                       ~s|src:url(ms_sans_serif_bold.woff) format("woff");src:url(ms_sans_serif_bold.woff2) format("woff2")|,
                       ~s|src:url(data:font/woff2;base64,#{bold_font}) format("woff2")|
                     )
                     |> String.replace(~r|/\*# sourceMappingURL=.*?\*/|, "")
                   )

  def render(%Recording{} = recording, opts \\ []) when is_list(opts) do
    title =
      Keyword.get(opts, :title, recording.title || recording.command || "Terminal Recording")

    font_size = Keyword.get(opts, :font_size, 24)
    cell_width = Keyword.get(opts, :cell_width, Float.round(font_size * 0.615, 3))
    cell_height = Keyword.get(opts, :cell_height, Float.round(font_size * 1.45, 3))
    line_height = Keyword.get(opts, :line_height, Float.round(cell_height / font_size, 3))
    terminal_padding = Keyword.get(opts, :terminal_padding, 28)
    outer_padding = Keyword.get(opts, :outer_padding, 48)
    chrome_height = Keyword.get(opts, :chrome_height, 56)
    window_chrome? = Keyword.get(opts, :window_chrome?, true)
    theme = Map.fetch!(recording, :theme)
    data_json = script_json(template_data(recording, title, theme, opts))

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>#{html_escape(title)}</title>
        <style>
          #{@embedded_98_css}

          :root {
            --font-size: #{font_size}px;
            --line-height: #{line_height};
            --cell-width: #{cell_width}px;
            --cell-height: #{cell_height}px;
            --terminal-padding: #{terminal_padding}px;
            --outer-padding: #{outer_padding}px;
            --viewport-padding: clamp(18px, 2.35vmin, #{outer_padding}px);
            --viewport-gap: clamp(10px, 1.7vmin, 18px);
            --chrome-height: #{if(window_chrome?, do: chrome_height, else: 0)}px;
            --terminal-fg: #{theme.fg};
            --terminal-bg: #{theme.bg};
            --desktop-top: #{mix_hex(theme.bg, "#008080", 0.14)};
            --desktop-bottom: #{mix_hex(theme.bg, "#005454", 0.48)};
            --desktop-grid: rgba(255, 255, 255, 0.05);
            --desktop-highlight: rgba(255, 255, 255, 0.12);
            --chrome-meta-fg: rgba(255, 255, 255, 0.82);
            --screen-bezel: #6f6f6f;
            --marker-bg: #ffffe1;
            --marker-border: #5f5f5f;
            --marker-fg: #111111;
            --window-shadow-drop: #{rgba("#000000", 0.22)};
            --control-fill: #000080;
            --control-fill-soft: #{mix_hex(Enum.at(theme.palette, 14) || "#7dcfff", "#d8ecff", 0.36)};
          }

          * {
            box-sizing: border-box;
          }

          html,
          body {
            margin: 0;
            width: 100%;
            height: 100%;
            overflow: hidden;
            background:
              linear-gradient(var(--desktop-grid) 1px, transparent 1px),
              linear-gradient(90deg, var(--desktop-grid) 1px, transparent 1px),
              radial-gradient(circle at top left, var(--desktop-highlight), transparent 34%),
              linear-gradient(180deg, var(--desktop-top), var(--desktop-bottom));
            background-size: 28px 28px, 28px 28px, 100% 100%, 100% 100%;
            color: #111111;
            user-select: none;
          }

          body.recording #controls,
          body.recording #debug {
            display: none;
          }

          #stage {
            position: relative;
            width: 100vw;
            height: 100vh;
            padding: var(--viewport-padding);
            display: grid;
            grid-template-rows: minmax(0, 1fr) auto;
            justify-items: center;
            align-items: stretch;
            gap: var(--viewport-gap);
          }

          body.recording #stage {
            padding: var(--outer-padding);
            gap: 0;
          }

          #viewport {
            position: relative;
            width: 100%;
            height: 100%;
            min-height: 0;
            overflow: hidden;
          }

          #terminal-shell.window {
            position: absolute;
            left: 50%;
            top: 50%;
            overflow: hidden;
            transform: translate(-50%, -50%) scale(1);
            transform-origin: center center;
            box-shadow: 14px 14px 0 var(--window-shadow-drop);
          }

          #terminal-shell.plain {
            padding: 0;
            background: transparent;
            box-shadow: none;
          }

          #terminal-chrome {
            min-height: var(--chrome-height);
            gap: 10px;
            cursor: default;
          }

          #terminal-shell.plain #terminal-chrome {
            display: none;
          }

          #chrome-title-wrap {
            flex: 1;
            min-width: 0;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
          }

          #chrome-title {
            min-width: 0;
            margin-right: 0;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }

          #chrome-meta {
            color: var(--chrome-meta-fg);
            font-size: 11px;
            font-variant-numeric: tabular-nums;
            white-space: nowrap;
          }

          #terminal-frame.window-body {
            padding: var(--terminal-padding);
          }

          #terminal-shell.plain #terminal-frame.window-body {
            margin: 0;
          }

          #terminal-screen.sunken-panel {
            overflow: hidden;
            padding: 0;
            color: var(--terminal-fg);
            background: var(--terminal-bg);
            border: 2px solid var(--screen-bezel);
            box-shadow: inset 1px 1px 0 #000000, inset -1px -1px 0 rgba(255, 255, 255, 0.08);
            font-size: var(--font-size);
            line-height: var(--line-height);
            letter-spacing: 0;
            text-rendering: geometricPrecision;
            font-variant-ligatures: none;
            font-feature-settings: "liga" 0, "calt" 0;
            font-family:
              "Iosevka Term",
              "Berkeley Mono",
              "JetBrains Mono",
              "Lucida Console",
              "Courier New",
              monospace;
          }

          #terminal-shell.plain #terminal-screen {
            border: none;
            box-shadow: none;
          }

          .row {
            width: 100%;
            height: var(--cell-height);
            line-height: var(--cell-height);
            white-space: pre;
            overflow: hidden;
          }

          .segment {
            display: inline;
          }

          #marker {
            position: absolute;
            top: calc(var(--viewport-padding) * 0.55);
            right: calc(var(--viewport-padding) * 0.55);
            padding: 8px 10px;
            border-radius: 0;
            border: 1px solid var(--marker-border);
            background: var(--marker-bg);
            color: var(--marker-fg);
            box-shadow: inset 1px 1px 0 #fffff4, inset -1px -1px 0 #9a9a7e, 4px 4px 0 rgba(0, 0, 0, 0.18);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.04em;
            text-transform: uppercase;
            opacity: 0;
            transform: translateY(-4px);
            transition: opacity 160ms ease, transform 160ms ease;
            pointer-events: none;
          }

          #marker.visible {
            opacity: 1;
            transform: translateY(0);
          }

          #controls {
            width: min(100%, 1280px);
            box-shadow: 12px 12px 0 var(--window-shadow-drop);
          }

          #controls .window-body {
            display: flex;
            align-items: center;
            gap: 10px;
          }

          #timeline-wrap {
            flex: 1;
            min-width: 240px;
            display: flex;
            align-items: center;
            gap: 10px;
          }

          #timeline.sunken-panel {
            flex: 1;
            position: relative;
            height: 22px;
            padding: 0;
            overflow: hidden;
            cursor: pointer;
          }

          #timeline-progress {
            position: absolute;
            left: 2px;
            top: 2px;
            bottom: 2px;
            width: 0%;
            background: linear-gradient(90deg, var(--control-fill), #{mix_hex(Enum.at(theme.palette, 14) || "#7dcfff", "#d8ecff", 0.22)});
          }

          #timeline-buffer {
            position: absolute;
            inset: 2px;
            background: var(--control-fill-soft);
            width: 100%;
          }

          #controls-time {
            min-width: 142px;
            color: #111111;
            text-align: right;
            font-variant-numeric: tabular-nums;
            padding: 2px 6px;
          }

          #debug.status-bar {
            width: min(100%, 1280px);
            pointer-events: none;
          }

          #debug span {
            min-width: 0;
          }

          #debug-size {
            margin-left: auto;
          }

          @media (max-width: 900px) {
            #controls {
              width: 100%;
            }

            #controls .window-body {
              flex-wrap: wrap;
              justify-content: center;
            }

            #timeline-wrap {
              flex-basis: 100%;
            }

            #controls-time {
              width: 100%;
              text-align: center;
            }

            #chrome-meta {
              display: none;
            }
          }

          @media (max-width: 640px) {
            #debug {
              display: none;
            }

            #chrome-title {
              font-size: 14px;
            }
          }
        </style>
      </head>
      <body>
        <div id="stage">
          <div id="viewport">
            <div id="terminal-shell" class="window #{if(window_chrome?, do: "", else: "plain")}">
              <div id="terminal-chrome" class="title-bar">
                <div id="chrome-title-wrap">
                  <div id="chrome-title" class="title-bar-text">#{html_escape(title)}</div>
                  <div id="chrome-meta"></div>
                </div>
                <div class="title-bar-controls" aria-hidden="true">
                  <button type="button" aria-label="Minimize" tabindex="-1"></button>
                  <button type="button" aria-label="Maximize" tabindex="-1"></button>
                  <button type="button" aria-label="Close" tabindex="-1"></button>
                </div>
              </div>
              <div id="terminal-frame" class="window-body">
                <div id="terminal-screen" class="sunken-panel"></div>
              </div>
            </div>
          </div>
          <div id="controls" class="window">
            <div class="window-body">
              <button id="play-button" class="default" type="button">Play</button>
              <button id="restart-button" type="button">Restart</button>
              <div id="timeline-wrap">
                <div id="timeline" class="sunken-panel" role="slider" aria-label="Playback progress">
                  <div id="timeline-buffer"></div>
                  <div id="timeline-progress"></div>
                </div>
                <div id="controls-time" class="status-bar-field">0:00 / 0:00</div>
              </div>
            </div>
          </div>
          <div id="marker"></div>
          <div id="debug" class="status-bar">
            <span id="debug-time" class="status-bar-field">0.00s</span>
            <span id="debug-size" class="status-bar-field">#{recording.cols}x#{recording.rows}</span>
          </div>
        </div>
        <script>
          (() => {
            window.__frothVideoError = null;

            try {
            const data = #{data_json};
            const params = new URLSearchParams(window.location.search);
            const recordingMode = params.get("record") === "1";
            if (recordingMode) document.body.classList.add("recording");

            const viewportEl = document.getElementById("viewport");
            const shellEl = document.getElementById("terminal-shell");
            const screenEl = document.getElementById("terminal-screen");
            const chromeTitleEl = document.getElementById("chrome-title");
            const chromeMetaEl = document.getElementById("chrome-meta");
            const markerEl = document.getElementById("marker");
            const debugTimeEl = document.getElementById("debug-time");
            const debugSizeEl = document.getElementById("debug-size");
            const playButtonEl = document.getElementById("play-button");
            const restartButtonEl = document.getElementById("restart-button");
            const timelineEl = document.getElementById("timeline");
            const timelineProgressEl = document.getElementById("timeline-progress");
            const controlsTimeEl = document.getElementById("controls-time");

            const defaultAttr = () => ({
              fg: data.theme.fg,
              bg: data.theme.bg,
              bold: false,
              dim: false,
              italic: false,
              underline: false,
              inverse: false
            });

            const state = {
              cols: data.cols,
              rows: data.rows,
              cursorX: 0,
              cursorY: 0,
              savedCursor: null,
              scrollTop: 0,
              scrollBottom: data.rows - 1,
              cursorVisible: true,
              attr: defaultAttr(),
              screen: null,
              eventIndex: 0,
              currentTime: 0,
              dirty: true,
              title: data.title,
              exitCode: null,
              marker: null,
              markerUntil: 0,
              parser: {mode: "text", buffer: ""},
              altScreen: null
            };

            const playback = {
              playing: false,
              fromTime: 0,
              wallClockStart: 0,
              rafId: null
            };

            function createCell(ch = " ", attr = defaultAttr()) {
              const effective = effectiveColors(attr);

              return {
                ch,
                fg: effective.fg,
                bg: effective.bg,
                bold: !!attr.bold,
                dim: !!attr.dim,
                italic: !!attr.italic,
                underline: !!attr.underline
              };
            }

            function createRow(cols, attr) {
              const row = [];
              for (let i = 0; i < cols; i += 1) row.push(createCell(" ", attr));
              return row;
            }

            function createBuffer(cols, rows, attr) {
              const buffer = [];
              for (let y = 0; y < rows; y += 1) buffer.push(createRow(cols, attr));
              return buffer;
            }

            function cloneCell(cell) {
              return {
                ch: cell.ch,
                fg: cell.fg,
                bg: cell.bg,
                bold: cell.bold,
                dim: cell.dim,
                italic: cell.italic,
                underline: cell.underline
              };
            }

            function cloneRow(row) {
              return row.map(cloneCell);
            }

            function cloneBuffer(buffer) {
              return buffer.map(cloneRow);
            }

            function effectiveColors(attr) {
              const fg = attr.fg || data.theme.fg;
              const bg = attr.bg || data.theme.bg;

              if (attr.inverse) return {fg: bg, bg: fg};
              return {fg, bg};
            }

            function applyColor(index) {
              if (index >= 0 && index < data.palette.length) return data.palette[index];
              if (index >= 16 && index <= 231) {
                const n = index - 16;
                const r = Math.floor(n / 36);
                const g = Math.floor((n % 36) / 6);
                const b = n % 6;
                const level = [0, 95, 135, 175, 215, 255];
                return rgbHex(level[r], level[g], level[b]);
              }

              if (index >= 232 && index <= 255) {
                const value = 8 + (index - 232) * 10;
                return rgbHex(value, value, value);
              }

              return data.theme.fg;
            }

            function rgbHex(r, g, b) {
              return "#" + [r, g, b].map(v => v.toString(16).padStart(2, "0")).join("");
            }

            function blankCell() {
              return createCell(" ", defaultAttr());
            }

            function blankRow() {
              return createRow(state.cols, defaultAttr());
            }

            function resetTerminal() {
              state.cols = data.cols;
              state.rows = data.rows;
              state.cursorX = 0;
              state.cursorY = 0;
              state.savedCursor = null;
              state.scrollTop = 0;
              state.scrollBottom = state.rows - 1;
              state.cursorVisible = true;
              state.attr = defaultAttr();
              state.screen = createBuffer(state.cols, state.rows, defaultAttr());
              state.eventIndex = 0;
              state.currentTime = 0;
              state.dirty = true;
              state.title = data.title;
              state.exitCode = null;
              state.marker = null;
              state.markerUntil = 0;
              state.parser = {mode: "text", buffer: ""};
              state.altScreen = null;
            }

            function setCursor(x, y) {
              state.cursorX = Math.max(0, Math.min(x, state.cols - 1));
              state.cursorY = Math.max(0, Math.min(y, state.rows - 1));
            }

            function lineFeed() {
              if (state.cursorY === state.scrollBottom) {
                scrollUp(1);
              } else {
                state.cursorY = Math.min(state.rows - 1, state.cursorY + 1);
              }
            }

            function scrollUp(count) {
              for (let i = 0; i < count; i += 1) {
                state.screen.splice(state.scrollTop, 1);
                state.screen.splice(state.scrollBottom, 0, blankRow());
              }
              state.dirty = true;
            }

            function scrollDown(count) {
              for (let i = 0; i < count; i += 1) {
                state.screen.splice(state.scrollBottom, 1);
                state.screen.splice(state.scrollTop, 0, blankRow());
              }
              state.dirty = true;
            }

            function writeChar(ch) {
              if (!state.screen[state.cursorY]) return;

              state.screen[state.cursorY][state.cursorX] = createCell(ch, state.attr);
              state.dirty = true;
              state.cursorX += 1;

              if (state.cursorX >= state.cols) {
                state.cursorX = 0;
                lineFeed();
              }
            }

            function eraseDisplay(mode) {
              if (mode === 2 || mode === 3) {
                state.screen = createBuffer(state.cols, state.rows, defaultAttr());
              } else if (mode === 1) {
                for (let y = 0; y <= state.cursorY; y += 1) {
                  const to = y === state.cursorY ? state.cursorX : state.cols - 1;
                  for (let x = 0; x <= to; x += 1) state.screen[y][x] = blankCell();
                }
              } else {
                for (let y = state.cursorY; y < state.rows; y += 1) {
                  const from = y === state.cursorY ? state.cursorX : 0;
                  for (let x = from; x < state.cols; x += 1) state.screen[y][x] = blankCell();
                }
              }

              state.dirty = true;
            }

            function eraseLine(mode) {
              const row = state.screen[state.cursorY];
              if (!row) return;

              if (mode === 2) {
                for (let x = 0; x < state.cols; x += 1) row[x] = blankCell();
              } else if (mode === 1) {
                for (let x = 0; x <= state.cursorX; x += 1) row[x] = blankCell();
              } else {
                for (let x = state.cursorX; x < state.cols; x += 1) row[x] = blankCell();
              }

              state.dirty = true;
            }

            function insertChars(count) {
              const row = state.screen[state.cursorY];
              if (!row) return;

              const blanks = Array.from({length: count}, () => blankCell());
              row.splice(state.cursorX, 0, ...blanks);
              row.length = state.cols;
              state.dirty = true;
            }

            function deleteChars(count) {
              const row = state.screen[state.cursorY];
              if (!row) return;

              row.splice(state.cursorX, count);
              while (row.length < state.cols) row.push(blankCell());
              state.dirty = true;
            }

            function eraseChars(count) {
              const row = state.screen[state.cursorY];
              if (!row) return;

              for (let x = state.cursorX; x < Math.min(state.cols, state.cursorX + count); x += 1) {
                row[x] = blankCell();
              }

              state.dirty = true;
            }

            function insertLines(count) {
              if (state.cursorY < state.scrollTop || state.cursorY > state.scrollBottom) return;

              for (let i = 0; i < count; i += 1) {
                state.screen.splice(state.cursorY, 0, blankRow());
                state.screen.splice(state.scrollBottom + 1, 1);
              }

              state.dirty = true;
            }

            function deleteLines(count) {
              if (state.cursorY < state.scrollTop || state.cursorY > state.scrollBottom) return;

              for (let i = 0; i < count; i += 1) {
                state.screen.splice(state.cursorY, 1);
                state.screen.splice(state.scrollBottom, 0, blankRow());
              }

              state.dirty = true;
            }

            function saveCursor() {
              state.savedCursor = {x: state.cursorX, y: state.cursorY};
            }

            function restoreCursor() {
              if (state.savedCursor) setCursor(state.savedCursor.x, state.savedCursor.y);
            }

            function resizeTerminal(cols, rows) {
              const nextCols = Math.max(1, cols);
              const nextRows = Math.max(1, rows);
              const nextBuffer = [];

              for (let y = 0; y < nextRows; y += 1) {
                const existing = state.screen[y] || [];
                const row = [];

                for (let x = 0; x < nextCols; x += 1) {
                  row.push(existing[x] ? cloneCell(existing[x]) : blankCell());
                }

                nextBuffer.push(row);
              }

              state.cols = nextCols;
              state.rows = nextRows;
              state.screen = nextBuffer;
              state.scrollTop = 0;
              state.scrollBottom = nextRows - 1;
              setCursor(state.cursorX, state.cursorY);
              state.dirty = true;
            }

            function enterAltScreen() {
              if (!state.altScreen) {
                state.altScreen = {
                  cols: state.cols,
                  rows: state.rows,
                  cursorX: state.cursorX,
                  cursorY: state.cursorY,
                  savedCursor: state.savedCursor ? {...state.savedCursor} : null,
                  scrollTop: state.scrollTop,
                  scrollBottom: state.scrollBottom,
                  screen: cloneBuffer(state.screen)
                };
              }

              state.screen = createBuffer(state.cols, state.rows, defaultAttr());
              state.cursorX = 0;
              state.cursorY = 0;
              state.savedCursor = null;
              state.scrollTop = 0;
              state.scrollBottom = state.rows - 1;
              state.dirty = true;
            }

            function leaveAltScreen() {
              if (!state.altScreen) return;

              state.cols = state.altScreen.cols;
              state.rows = state.altScreen.rows;
              state.cursorX = state.altScreen.cursorX;
              state.cursorY = state.altScreen.cursorY;
              state.savedCursor = state.altScreen.savedCursor;
              state.scrollTop = state.altScreen.scrollTop;
              state.scrollBottom = state.altScreen.scrollBottom;
              state.screen = cloneBuffer(state.altScreen.screen);
              state.altScreen = null;
              state.dirty = true;
            }

            function handleSgr(rawParams) {
              const params = rawParams.length === 0 ? [0] : rawParams;

              for (let i = 0; i < params.length; i += 1) {
                const code = params[i];

                switch (code) {
                  case 0:
                    state.attr = defaultAttr();
                    break;
                  case 1:
                    state.attr.bold = true;
                    break;
                  case 2:
                    state.attr.dim = true;
                    break;
                  case 3:
                    state.attr.italic = true;
                    break;
                  case 4:
                    state.attr.underline = true;
                    break;
                  case 7:
                    state.attr.inverse = true;
                    break;
                  case 22:
                    state.attr.bold = false;
                    state.attr.dim = false;
                    break;
                  case 23:
                    state.attr.italic = false;
                    break;
                  case 24:
                    state.attr.underline = false;
                    break;
                  case 27:
                    state.attr.inverse = false;
                    break;
                  case 39:
                    state.attr.fg = data.theme.fg;
                    break;
                  case 49:
                    state.attr.bg = data.theme.bg;
                    break;
                  default:
                    if (code >= 30 && code <= 37) state.attr.fg = applyColor(code - 30);
                    else if (code >= 40 && code <= 47) state.attr.bg = applyColor(code - 40);
                    else if (code >= 90 && code <= 97) state.attr.fg = applyColor(code - 82);
                    else if (code >= 100 && code <= 107) state.attr.bg = applyColor(code - 92);
                    else if (code === 38 || code === 48) {
                      const target = code === 38 ? "fg" : "bg";
                      const mode = params[i + 1];

                      if (mode === 5 && Number.isInteger(params[i + 2])) {
                        state.attr[target] = applyColor(params[i + 2]);
                        i += 2;
                      } else if (
                        mode === 2 &&
                        Number.isInteger(params[i + 2]) &&
                        Number.isInteger(params[i + 3]) &&
                        Number.isInteger(params[i + 4])
                      ) {
                        state.attr[target] = rgbHex(params[i + 2], params[i + 3], params[i + 4]);
                        i += 4;
                      }
                    }
                }
              }
            }

            function parseParams(body) {
              if (!body) return [];

              return body
                .replaceAll(":", ";")
                .split(";")
                .filter(part => part !== "")
                .map(part => {
                  const parsed = Number.parseInt(part, 10);
                  return Number.isNaN(parsed) ? 0 : parsed;
                });
            }

            function handleCsi(sequence) {
              const final = sequence.slice(-1);
              const body = sequence.slice(0, -1);
              const privateMode = body.startsWith("?");
              const raw = privateMode ? body.slice(1) : body;
              const params = parseParams(raw);
              const first = params[0] || 0;

              if (privateMode) {
                if (final === "h" || final === "l") {
                  const enabled = final === "h";

                  params.forEach(param => {
                    if (param === 25) state.cursorVisible = enabled;
                    if (param === 1047) enabled ? enterAltScreen() : leaveAltScreen();
                    if (param === 1048) enabled ? saveCursor() : restoreCursor();
                    if (param === 1049) {
                      if (enabled) {
                        saveCursor();
                        enterAltScreen();
                      } else {
                        leaveAltScreen();
                        restoreCursor();
                      }
                    }
                  });
                }

                return;
              }

              switch (final) {
                case "A":
                  setCursor(state.cursorX, state.cursorY - Math.max(first, 1));
                  break;
                case "B":
                  setCursor(state.cursorX, state.cursorY + Math.max(first, 1));
                  break;
                case "C":
                  setCursor(state.cursorX + Math.max(first, 1), state.cursorY);
                  break;
                case "D":
                  setCursor(state.cursorX - Math.max(first, 1), state.cursorY);
                  break;
                case "E":
                  setCursor(0, state.cursorY + Math.max(first, 1));
                  break;
                case "F":
                  setCursor(0, state.cursorY - Math.max(first, 1));
                  break;
                case "G":
                  setCursor(Math.max(first, 1) - 1, state.cursorY);
                  break;
                case "H":
                case "f": {
                  const row = Math.max(params[0] || 1, 1) - 1;
                  const col = Math.max(params[1] || 1, 1) - 1;
                  setCursor(col, row);
                  break;
                }
                case "J":
                  eraseDisplay(first);
                  break;
                case "K":
                  eraseLine(first);
                  break;
                case "L":
                  insertLines(Math.max(first, 1));
                  break;
                case "M":
                  deleteLines(Math.max(first, 1));
                  break;
                case "P":
                  deleteChars(Math.max(first, 1));
                  break;
                case "@":
                  insertChars(Math.max(first, 1));
                  break;
                case "X":
                  eraseChars(Math.max(first, 1));
                  break;
                case "S":
                  scrollUp(Math.max(first, 1));
                  break;
                case "T":
                  scrollDown(Math.max(first, 1));
                  break;
                case "d":
                  setCursor(state.cursorX, Math.max(first, 1) - 1);
                  break;
                case "m":
                  handleSgr(params);
                  break;
                case "r": {
                  const top = Math.max((params[0] || 1) - 1, 0);
                  const bottom = Math.min((params[1] || state.rows) - 1, state.rows - 1);
                  state.scrollTop = top;
                  state.scrollBottom = Math.max(top, bottom);
                  setCursor(0, 0);
                  break;
                }
                case "s":
                  saveCursor();
                  break;
                case "u":
                  restoreCursor();
                  break;
                default:
                  break;
              }
            }

            function handleOsc(buffer) {
              const parts = buffer.split(";");
              if (parts.length >= 2 && (parts[0] === "0" || parts[0] === "1" || parts[0] === "2")) {
                state.title = parts.slice(1).join(";");
              }
            }

            function feedOutput(text) {
              for (const ch of text) {
                if (state.parser.mode === "text") {
                  if (ch === "\\u001b") {
                    state.parser.mode = "esc";
                    continue;
                  }

                  if (ch === "\\n") {
                    lineFeed();
                    continue;
                  }

                  if (ch === "\\r") {
                    state.cursorX = 0;
                    continue;
                  }

                  if (ch === "\\b") {
                    setCursor(state.cursorX - 1, state.cursorY);
                    continue;
                  }

                  if (ch === "\\t") {
                    const nextTab = Math.min(state.cols - 1, (Math.floor(state.cursorX / 8) + 1) * 8);
                    state.cursorX = nextTab;
                    continue;
                  }

                  if (ch >= " ") {
                    writeChar(ch);
                  }

                  continue;
                }

                if (state.parser.mode === "esc") {
                  if (ch === "[") {
                    state.parser.mode = "csi";
                    state.parser.buffer = "";
                    continue;
                  }

                  if (ch === "]") {
                    state.parser.mode = "osc";
                    state.parser.buffer = "";
                    continue;
                  }

                  if (ch === "7") saveCursor();
                  else if (ch === "8") restoreCursor();
                  else if (ch === "D") lineFeed();
                  else if (ch === "E") {
                    state.cursorX = 0;
                    lineFeed();
                  } else if (ch === "M") scrollDown(1);
                  else if (ch === "c") resetTerminal();

                  state.parser.mode = "text";
                  continue;
                }

                if (state.parser.mode === "csi") {
                  state.parser.buffer += ch;

                  if (ch >= "@" && ch <= "~") {
                    handleCsi(state.parser.buffer);
                    state.parser.mode = "text";
                    state.parser.buffer = "";
                  }

                  continue;
                }

                if (state.parser.mode === "osc") {
                  if (ch === "\\u0007") {
                    handleOsc(state.parser.buffer);
                    state.parser.mode = "text";
                    state.parser.buffer = "";
                  } else if (ch === "\\u001b") {
                    state.parser.mode = "osc-esc";
                  } else {
                    state.parser.buffer += ch;
                  }

                  continue;
                }

                if (state.parser.mode === "osc-esc") {
                  if (ch === "\\\\") {
                    handleOsc(state.parser.buffer);
                    state.parser.mode = "text";
                    state.parser.buffer = "";
                  } else {
                    state.parser.buffer += "\\u001b" + ch;
                    state.parser.mode = "osc";
                  }
                }
              }
            }

            function applyEvent(event) {
              switch (event.code) {
                case "o":
                  feedOutput(String(event.data || ""));
                  break;
                case "r": {
                  const match = String(event.data || "").match(/^(\\d+)x(\\d+)$/);
                  if (match) resizeTerminal(Number.parseInt(match[1], 10), Number.parseInt(match[2], 10));
                  break;
                }
                case "m":
                  state.marker = String(event.data || "").trim();
                  state.markerUntil = event.at + 1.6;
                  break;
                case "x":
                  state.exitCode = String(event.data || "");
                  break;
                default:
                  break;
              }

              state.dirty = true;
            }

            function advanceTo(targetSeconds) {
              while (
                state.eventIndex < data.events.length &&
                data.events[state.eventIndex].at <= targetSeconds + 1e-9
              ) {
                applyEvent(data.events[state.eventIndex]);
                state.eventIndex += 1;
              }
            }

            function styleKey(cell) {
              return [
                cell.fg,
                cell.bg,
                cell.bold ? "1" : "0",
                cell.dim ? "1" : "0",
                cell.italic ? "1" : "0",
                cell.underline ? "1" : "0"
              ].join("|");
            }

            function styleString(cell) {
              const parts = [`color:${cell.fg}`, `background:${cell.bg}`];
              if (cell.bold) parts.push("font-weight:700");
              if (cell.dim) parts.push("opacity:0.72");
              if (cell.italic) parts.push("font-style:italic");
              if (cell.underline) parts.push("text-decoration:underline");
              return parts.join(";");
            }

            function escapeHtml(text) {
              return text
                .replaceAll("&", "&amp;")
                .replaceAll("<", "&lt;")
                .replaceAll(">", "&gt;");
            }

            function renderRows() {
              const rows = [];

              for (let y = 0; y < state.rows; y += 1) {
                const original = state.screen[y] || blankRow();
                const row = original.map(cloneCell);

                if (state.cursorVisible && y === state.cursorY && state.cursorX >= 0 && state.cursorX < row.length) {
                  const cursorCell = cloneCell(row[state.cursorX]);
                  cursorCell.fg = data.theme.bg;
                  cursorCell.bg = data.theme.fg;
                  row[state.cursorX] = cursorCell;
                }

                let html = "";
                let currentKey = null;
                let currentStyle = "";
                let buffer = "";

                row.forEach(cell => {
                  const key = styleKey(cell);

                  if (currentKey === null) {
                    currentKey = key;
                    currentStyle = styleString(cell);
                    buffer = cell.ch;
                    return;
                  }

                  if (key === currentKey) {
                    buffer += cell.ch;
                    return;
                  }

                  html += `<span class="segment" style="${currentStyle}">${escapeHtml(buffer)}</span>`;
                  currentKey = key;
                  currentStyle = styleString(cell);
                  buffer = cell.ch;
                });

                if (buffer !== "") {
                  html += `<span class="segment" style="${currentStyle}">${escapeHtml(buffer)}</span>`;
                }

                rows.push(`<div class="row">${html}</div>`);
              }

              screenEl.innerHTML = rows.join("");
            }

            function syncLayout() {
              const innerWidth = Math.ceil(state.cols * data.cell_width);
              const innerHeight = Math.ceil(state.rows * data.cell_height);
              const frameWidth = innerWidth + data.terminal_padding * 2;
              const frameHeight = innerHeight + data.terminal_padding * 2 + data.chrome_height;

              screenEl.style.width = `${innerWidth}px`;
              screenEl.style.height = `${innerHeight}px`;
              shellEl.style.width = `${frameWidth}px`;
              shellEl.style.height = `${frameHeight}px`;
              syncViewportScale(frameWidth, frameHeight);
            }

            function syncViewportScale(frameWidth, frameHeight) {
              if (recordingMode) {
                shellEl.style.transform = "translate(-50%, -50%) scale(1)";
                return;
              }

              const availableWidth = Math.max(1, viewportEl.clientWidth - 4);
              const availableHeight = Math.max(1, viewportEl.clientHeight - 4);
              const scale = Math.max(0.1, Math.min(availableWidth / frameWidth, availableHeight / frameHeight));
              shellEl.style.transform = `translate(-50%, -50%) scale(${scale})`;
            }

            function formatTime(seconds) {
              const rounded = Math.max(0, seconds);
              const minutes = Math.floor(rounded / 60);
              const secs = Math.floor(rounded % 60);
              const millis = Math.floor((rounded % 1) * 10);
              return `${minutes}:${secs.toString().padStart(2, "0")}.${millis}`;
            }

            function updateMarker(seconds) {
              if (state.marker && seconds <= state.markerUntil) {
                markerEl.textContent = state.marker || "Marker";
                markerEl.classList.add("visible");
              } else {
                markerEl.classList.remove("visible");
              }
            }

            function updateMeta(seconds) {
              const duration = Math.max(data.duration_s, 0.001);
              const pct = Math.max(0, Math.min(1, seconds / duration));

              debugTimeEl.textContent = `${seconds.toFixed(2)}s / ${duration.toFixed(2)}s`;
              debugSizeEl.textContent = `${state.cols}x${state.rows}`;
              chromeTitleEl.textContent = state.title || data.title;
              chromeMetaEl.textContent =
                `${state.cols}x${state.rows}` +
                (state.exitCode === null ? "" : ` • exit ${state.exitCode}`);
              controlsTimeEl.textContent = `${formatTime(seconds)} / ${formatTime(duration)}`;
              timelineProgressEl.style.width = `${(pct * 100).toFixed(3)}%`;
              playButtonEl.textContent = playback.playing ? "Pause" : "Play";
            }

            function renderAt(seconds) {
              const target = Math.max(0, Math.min(seconds, data.duration_s));

              if (target + 1e-9 < state.currentTime) {
                resetTerminal();
              }

              advanceTo(target);

              if (state.dirty) {
                syncLayout();
                renderRows();
                state.dirty = false;
              }

              updateMarker(target);
              updateMeta(target);
              state.currentTime = target;

              return {
                seconds: target,
                eventIndex: state.eventIndex,
                cols: state.cols,
                rows: state.rows
              };
            }

            function cancelTick() {
              if (playback.rafId !== null) {
                window.cancelAnimationFrame(playback.rafId);
                playback.rafId = null;
              }
            }

            function pausePlayback() {
              playback.playing = false;
              cancelTick();
              updateMeta(state.currentTime);
            }

            function tick(now) {
              if (!playback.playing) return;

              const elapsed = (now - playback.wallClockStart) / 1000;
              const nextTime = Math.min(data.duration_s, playback.fromTime + elapsed);
              renderAt(nextTime);

              if (nextTime >= data.duration_s - 1e-9) {
                pausePlayback();
                return;
              }

              playback.rafId = window.requestAnimationFrame(tick);
            }

            function playPlayback() {
              if (playback.playing) return;
              if (state.currentTime >= data.duration_s - 1e-9) renderAt(0);

              playback.playing = true;
              playback.fromTime = state.currentTime;
              playback.wallClockStart = performance.now();
              updateMeta(state.currentTime);
              playback.rafId = window.requestAnimationFrame(tick);
            }

            function togglePlayback() {
              if (playback.playing) pausePlayback();
              else playPlayback();
            }

            function seek(seconds) {
              const wasPlaying = playback.playing;
              pausePlayback();
              renderAt(seconds);
              if (wasPlaying) playPlayback();
            }

            playButtonEl.addEventListener("click", () => togglePlayback());
            restartButtonEl.addEventListener("click", () => {
              pausePlayback();
              renderAt(0);
            });

            timelineEl.addEventListener("click", event => {
              const rect = timelineEl.getBoundingClientRect();
              const pct = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
              seek(data.duration_s * pct);
            });

            shellEl.addEventListener("click", () => {
              if (!recordingMode) togglePlayback();
            });

            window.addEventListener("keydown", event => {
              if (event.key === " " || event.code === "Space") {
                event.preventDefault();
                togglePlayback();
              } else if (event.key === "ArrowLeft") {
                event.preventDefault();
                seek(Math.max(0, state.currentTime - 5));
              } else if (event.key === "ArrowRight") {
                event.preventDefault();
                seek(Math.min(data.duration_s, state.currentTime + 5));
              }
            });

            window.addEventListener("resize", () => {
              syncLayout();
              updateMeta(state.currentTime);
            });

            resetTerminal();
            renderAt(0);

            if (!recordingMode && params.get("autoplay") === "1") {
              playPlayback();
            }

            window.FrothVideo = {
              data,
              ready: true,
              renderAt,
              play: playPlayback,
              pause: pausePlayback,
              togglePlay: togglePlayback,
              seek
            };
            } catch (error) {
              window.__frothVideoError = {
                message: error.message,
                stack: error.stack
              };

              document.body.dataset.frothVideoError = error.message;
              throw error;
            }
          })();
        </script>
      </body>
    </html>
    """
  end

  defp template_data(recording, title, theme, opts) do
    %{
      title: title,
      command: recording.command,
      cols: recording.cols,
      rows: recording.rows,
      max_cols: recording.max_cols,
      max_rows: recording.max_rows,
      duration_s: recording.duration_s,
      theme: theme,
      palette: theme.palette,
      terminal_padding: Keyword.get(opts, :terminal_padding, 28),
      chrome_height:
        if(
          Keyword.get(opts, :window_chrome?, true),
          do: Keyword.get(opts, :chrome_height, 56),
          else: 0
        ),
      cell_width:
        Keyword.get(opts, :cell_width, Float.round(Keyword.get(opts, :font_size, 24) * 0.615, 3)),
      cell_height:
        Keyword.get(opts, :cell_height, Float.round(Keyword.get(opts, :font_size, 24) * 1.45, 3)),
      events: recording.events
    }
  end

  defp script_json(data) do
    data
    |> Jason.encode!()
    |> String.replace("</", "<\\/")
  end

  defp html_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp mix_hex(left, right, ratio) do
    {lr, lg, lb} = hex_to_rgb(left)
    {rr, rg, rb} = hex_to_rgb(right)

    rgb_to_hex(
      round(lr * ratio + rr * (1 - ratio)),
      round(lg * ratio + rg * (1 - ratio)),
      round(lb * ratio + rb * (1 - ratio))
    )
  end

  defp rgba(hex, alpha) do
    {r, g, b} = hex_to_rgb(hex)
    "rgba(#{r}, #{g}, #{b}, #{Float.round(alpha, 3)})"
  end

  defp hex_to_rgb("#" <> <<r1, r2, g1, g2, b1, b2>>) do
    {hex_pair(<<r1, r2>>), hex_pair(<<g1, g2>>), hex_pair(<<b1, b2>>)}
  end

  defp rgb_to_hex(r, g, b) do
    "#" <>
      Enum.map_join([r, g, b], fn value ->
        value
        |> max(0)
        |> min(255)
        |> Integer.to_string(16)
        |> String.pad_leading(2, "0")
      end)
  end

  defp hex_pair(pair) do
    pair
    |> Base.decode16!(case: :mixed)
    |> :binary.decode_unsigned()
  end
end
