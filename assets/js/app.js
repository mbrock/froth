// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/froth"
import topbar from "../vendor/topbar"
import VoiceAudio from "./hooks/voice_audio"

const ToolScroll = {
  mounted() {
    this.atBottom = true
    this.lastAutoScrollAt = 0
    this.raf = null
    this.updateFollowMode()
    this.onScroll = () => this.updateAtBottom()
    this.onResize = () => {
      this.updateFollowMode()
      this.updateAtBottom()
      if (this.followMode === "always") this.scheduleScroll("auto")
    }
    window.addEventListener("scroll", this.onScroll, {passive: true})
    window.addEventListener("resize", this.onResize, {passive: true})
    window.visualViewport && window.visualViewport.addEventListener("resize", this.onResize)
    this.updateAtBottom()

    this.handleEvent("tg-close", () => {
      if (window.Telegram && window.Telegram.WebApp) {
        Telegram.WebApp.close()
      }
    })

    this.scheduleScroll("auto")
  },

  updated() {
    this.updateFollowMode()
    const shouldStick = this.followMode === "always" || this.atBottom
    this.updateAtBottom()
    if (shouldStick) {
      this.scheduleScroll(this.followMode === "always" ? "auto" : "smooth")
    }
  },

  destroyed() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
    window.visualViewport && window.visualViewport.removeEventListener("resize", this.onResize)
    if (this.raf) window.cancelAnimationFrame(this.raf)
  },

  updateFollowMode() {
    this.followMode = this.el.dataset.followMode || "smart"
  },

  updateAtBottom() {
    const thresholdPx = this.followMode === "always" ? 220 : 120
    const root = document.scrollingElement || document.documentElement
    const viewportHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight
    const bottomOffset = root.scrollHeight - (root.scrollTop + viewportHeight)
    this.atBottom = bottomOffset <= thresholdPx
  },

  scheduleScroll(behavior) {
    if (this.raf) window.cancelAnimationFrame(this.raf)
    this.raf = window.requestAnimationFrame(() => {
      this.raf = window.requestAnimationFrame(() => this.scrollToBottom(behavior))
    })
  },

  scrollToBottom(behavior) {
    const now = Date.now()
    const effectiveBehavior = now - this.lastAutoScrollAt < 180 ? "auto" : behavior
    this.lastAutoScrollAt = now

    const end = document.getElementById("tool-feed-end")
    if (end) {
      end.scrollIntoView({block: "end", behavior: effectiveBehavior})
    } else {
      const root = document.scrollingElement || document.documentElement
      window.scrollTo({top: root.scrollHeight, behavior: effectiveBehavior})
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let useViewTransition = false
const liveSocket = new LiveSocket("/froth/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ToolScroll, VoiceAudio},
  dom: {
    // Use the View Transitions API when available.
    onDocumentPatch(start) {
      if (!useViewTransition) return start()
      useViewTransition = false
      if (!document.startViewTransition) return start()
      try {
        document.startViewTransition(() => start())
      } catch (_e) {
        start()
      }
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", info => {
  // Only animate view transitions for navigation events.
  useViewTransition = ["patch", "redirect"].includes(info.detail && info.detail.kind)
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// PWA service worker (scope is /froth/)
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/froth/sw.js").catch((_err) => {})
  })
}

// iOS Safari keyboard handling: keep fixed bottom bar visible and prevent "send" being clipped.
// We expose a CSS var `--kb` (keyboard height in px) derived from VisualViewport.
const setKeyboardVar = () => {
  const vv = window.visualViewport
  if (!vv) return

  // innerHeight is layout viewport height; visualViewport shrinks when keyboard shows.
  const kb = Math.max(0, window.innerHeight - vv.height - vv.offsetTop)
  document.documentElement.style.setProperty("--kb", `${kb}px`)
}

if (window.visualViewport) {
  setKeyboardVar()
  window.visualViewport.addEventListener("resize", setKeyboardVar)
  window.visualViewport.addEventListener("scroll", setKeyboardVar)
  window.addEventListener("focusin", setKeyboardVar)
  window.addEventListener("focusout", () => document.documentElement.style.setProperty("--kb", "0px"))
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
