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
import SceneEngine from "./hooks/scene_engine"
import SceneEngine3D from "./hooks/scene_engine_3d"
import SceneView from "./hooks/scene_view"
import SceneEditor from "./hooks/scene_editor"

const ToolScroll = {
  mounted() {
    this.atBottom = true
    this.lastAutoScrollAt = 0
    this.raf = null
    this.mutationObserver = null
    this.observedNode = null
    this.mutationTicking = false
    this.scrollBody = null
    this.scrollTarget = null
    this.endMarker = null
    this.updateFollowMode()
    this.onScroll = () => this.updateAtBottom()
    this.resolveScrollElements()
    this.onResize = () => {
      this.updateFollowMode()
      this.resolveScrollElements()
      this.updateAtBottom()
      if (this.followMode === "always") this.scheduleScroll("auto")
    }
    window.addEventListener("resize", this.onResize, {passive: true})
    window.visualViewport && window.visualViewport.addEventListener("resize", this.onResize)
    this.updateAtBottom()
    this.observeMutations()

    this.handleEvent("tg-close", () => {
      if (window.Telegram && window.Telegram.WebApp) {
        Telegram.WebApp.close()
      }
    })

    this.handleEvent("follow-scroll", () => {
      this.scheduleScroll("smooth")
    })

    if (this.followMode !== "manual") this.scheduleScroll("auto")
  },

  updated() {
    this.updateFollowMode()
    this.resolveScrollElements()
    this.observeMutations()
    const shouldStick = this.followMode === "always" || (this.followMode === "smart" && this.atBottom)
    this.updateAtBottom()
    if (shouldStick) {
      this.scheduleScroll(this.followMode === "always" ? "auto" : "smooth")
    }
  },

  destroyed() {
    this.bindScrollTarget(null)
    window.removeEventListener("resize", this.onResize)
    window.visualViewport && window.visualViewport.removeEventListener("resize", this.onResize)
    this.disconnectMutationObserver()
    if (this.raf) window.cancelAnimationFrame(this.raf)
  },

  updateFollowMode() {
    this.followMode = this.el.dataset.followMode || "smart"
  },

  resolveScrollElements() {
    const explicitBody = this.el.querySelector("[data-scroll-body]")
    const body = explicitBody || this.pickScrollBody()

    const target =
      body === document.documentElement || body === document.body
        ? window
        : body

    this.bindScrollTarget(target)
    this.scrollBody = body
    this.endMarker = this.el.querySelector("[data-scroll-end]") || document.getElementById("tool-feed-end")
  },

  observeMutations() {
    const node = this.el
    if (!node) return
    if (this.observedNode === node && this.mutationObserver) return

    this.disconnectMutationObserver()

    this.mutationObserver = new MutationObserver(() => {
      if (this.mutationTicking) return
      this.mutationTicking = true

      window.requestAnimationFrame(() => {
        this.mutationTicking = false
        const shouldStick = this.followMode === "always" || (this.followMode === "smart" && this.atBottom)
        this.resolveScrollElements()
        this.updateAtBottom()

        if (shouldStick) {
          this.scheduleScroll(this.followMode === "always" ? "auto" : "smooth")
        }
      })
    })

    this.mutationObserver.observe(node, {
      childList: true,
      subtree: true,
      characterData: true,
    })

    this.observedNode = node
  },

  disconnectMutationObserver() {
    if (this.mutationObserver) this.mutationObserver.disconnect()
    this.mutationObserver = null
    this.observedNode = null
    this.mutationTicking = false
  },

  pickScrollBody() {
    const candidates = [
      this.el,
      document.scrollingElement,
      document.documentElement,
      document.body,
    ].filter(Boolean)

    return candidates.find(node => this.canScrollNode(node)) ||
      document.scrollingElement ||
      document.documentElement
  },

  canScrollNode(node) {
    if (!node) return false

    if (node === document.documentElement || node === document.body || node === document.scrollingElement) {
      const root = document.scrollingElement || document.documentElement
      const viewportHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight
      return root.scrollHeight - viewportHeight > 1
    }

    const style = window.getComputedStyle(node)
    const overflowY = style.overflowY || style.overflow
    const scrollableOverflow = ["auto", "scroll", "overlay"].includes(overflowY)

    return scrollableOverflow && node.scrollHeight - node.clientHeight > 1
  },

  bindScrollTarget(target) {
    if (this.scrollTarget === target) return
    if (this.scrollTarget) this.scrollTarget.removeEventListener("scroll", this.onScroll)
    this.scrollTarget = target
    if (this.scrollTarget) this.scrollTarget.addEventListener("scroll", this.onScroll, {passive: true})
  },

  updateAtBottom() {
    const thresholdPx = this.followMode === "always" ? 220 : 120
    const body = this.scrollBody || document.scrollingElement || document.documentElement
    const bottomOffset =
      body === document.documentElement || body === document.body
        ? body.scrollHeight - (body.scrollTop + (window.visualViewport ? window.visualViewport.height : window.innerHeight))
        : body.scrollHeight - (body.scrollTop + body.clientHeight)

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

    const body = this.scrollBody || document.scrollingElement || document.documentElement

    if (body !== document.documentElement && body !== document.body) {
      this.scrollElementTo(body, body.scrollHeight, effectiveBehavior)
      this.atBottom = true
      return
    }

    if (this.endMarker) {
      try {
        this.endMarker.scrollIntoView({block: "end", behavior: effectiveBehavior})
      } catch (_error) {
        this.endMarker.scrollIntoView(false)
      }

      this.scrollRootTo((document.scrollingElement || document.documentElement).scrollHeight, effectiveBehavior)
      this.atBottom = true
      return
    }

    const root = document.scrollingElement || document.documentElement
    this.scrollRootTo(root.scrollHeight, effectiveBehavior)
    this.atBottom = true
  },

  scrollElementTo(element, top, behavior) {
    try {
      if (typeof element.scrollTo === "function") {
        element.scrollTo({top, behavior})
      } else {
        element.scrollTop = top
      }
    } catch (_error) {
      element.scrollTop = top
    }
  },

  scrollRootTo(top, behavior) {
    const root = document.scrollingElement || document.documentElement

    try {
      window.scrollTo({top, behavior})
    } catch (_error) {
      window.scrollTo(0, top)
    }

    root.scrollTop = top
  },
}

const CodexTimeline = {
  mounted() {
    this.cacheElements()
    this.followEnabled = this.followInput ? this.followInput.checked : true
    this.atBottom = true
    this.knownIds = this.collectEntryIds()

    this.onScroll = () => {
      this.atBottom = this.isNearBottom()
    }

    this.onFollowChange = () => {
      this.followEnabled = this.followInput ? this.followInput.checked : true

      if (this.followEnabled) {
        this.scrollToBottom("smooth")
      }
    }

    if (this.scrollBody) {
      this.scrollBody.addEventListener("scroll", this.onScroll, {passive: true})
    }

    if (this.followInput) {
      this.followInput.addEventListener("change", this.onFollowChange)
    }

    window.requestAnimationFrame(() => this.scrollToBottom("auto"))
  },

  updated() {
    const hadAutoFollow = this.followEnabled && this.atBottom
    const previousIds = this.knownIds instanceof Set ? this.knownIds : new Set(this.knownIds || [])

    this.cacheElements()
    const nextIds = this.collectEntryIds()
    let hasNewEntries = false

    for (const id of nextIds) {
      if (!previousIds.has(id)) {
        hasNewEntries = true
        break
      }
    }

    this.knownIds = nextIds

    if (hadAutoFollow && hasNewEntries) {
      this.scrollToBottom("smooth")
    } else {
      this.atBottom = this.isNearBottom()
    }
  },

  destroyed() {
    if (this.scrollBody) {
      this.scrollBody.removeEventListener("scroll", this.onScroll)
    }

    if (this.followInput) {
      this.followInput.removeEventListener("change", this.onFollowChange)
    }
  },

  cacheElements() {
    this.scrollBody = this.el.querySelector("[data-scroll-body]")
    this.feed = this.el.querySelector("[data-codex-feed]")
    this.endMarker = this.el.querySelector("[data-scroll-end]")
    this.followInput = this.el.querySelector("#codex-follow-tail")
  },

  collectEntryIds() {
    if (!this.feed) return new Set()

    return new Set(
      Array.from(this.feed.querySelectorAll("[data-codex-entry]"))
        .map(node => node.id)
        .filter(Boolean)
    )
  },

  isNearBottom() {
    if (!this.scrollBody) return true

    const remaining =
      this.scrollBody.scrollHeight - (this.scrollBody.scrollTop + this.scrollBody.clientHeight)

    return remaining <= 24
  },

  scrollToBottom(behavior) {
    if (!this.scrollBody) return

    if (this.endMarker && typeof this.endMarker.scrollIntoView === "function") {
      this.endMarker.scrollIntoView({block: "end", behavior})
    } else {
      this.scrollBody.scrollTo({top: this.scrollBody.scrollHeight, behavior})
    }

    this.atBottom = true
  },
}

const CodexComposer = {
  mounted() {
    this.form = this.el.form

    this.onInput = () => this.autosize()
    this.onKeyDown = event => this.handleKeyDown(event)
    this.onPaste = event => this.handlePaste(event)

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKeyDown)
    this.el.addEventListener("paste", this.onPaste)

    window.requestAnimationFrame(() => this.autosize())
  },

  updated() {
    this.autosize()
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKeyDown)
    this.el.removeEventListener("paste", this.onPaste)
  },

  autosize() {
    this.el.style.height = "0px"
    this.el.style.height = `${Math.min(this.el.scrollHeight, 320)}px`
    this.el.style.overflowY = this.el.scrollHeight > 320 ? "auto" : "hidden"
  },

  handleKeyDown(event) {
    if (
      event.key !== "Enter" ||
      event.shiftKey ||
      event.altKey ||
      event.ctrlKey ||
      event.metaKey ||
      event.isComposing
    ) {
      return
    }

    event.preventDefault()
    this.submit()
  },

  handlePaste(event) {
    const clipboard = event.clipboardData
    if (!clipboard) return

    const files = Array.from(clipboard.items || [])
      .filter(item => item.kind === "file" && item.type.startsWith("image/"))
      .map(item => item.getAsFile())
      .filter(Boolean)

    if (files.length === 0) return

    event.preventDefault()

    const text = clipboard.getData("text/plain")
    if (text) {
      this.insertText(text)
    }

    this.attachFiles(files)
  },

  insertText(text) {
    const start = this.el.selectionStart || 0
    const end = this.el.selectionEnd || 0
    this.el.setRangeText(text, start, end, "end")
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
  },

  attachFiles(files) {
    if (files.length === 0) return

    const transfer = new DataTransfer()
    files.forEach(file => transfer.items.add(file))

    this.upload("images", transfer.files)
  },

  submit() {
    if (!this.form) return

    const submitter = this.form.querySelector("#codex-send")

    if (typeof this.form.requestSubmit === "function") {
      this.form.requestSubmit(submitter || undefined)
      return
    }

    if (submitter) {
      submitter.click()
      return
    }

    this.form.submit()
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let useViewTransition = false
const liveSocket = new LiveSocket("/froth/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    ToolScroll,
    CodexTimeline,
    CodexComposer,
    VoiceAudio,
    SceneEngine,
    SceneEngine3D,
    SceneView,
    SceneEditor,
  },
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
