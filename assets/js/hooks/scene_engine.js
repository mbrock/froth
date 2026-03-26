// SceneEngine — Canvas2D game renderer for pre-rendered RPG scenes
// Background: Flux 2 Pro. Walk map: Gemini Flash.

import {
  blockedRegionsFromState,
  constrainPointToWalkableRegions,
  regionAtPoint,
  regionScaleAtPoint,
  sceneRegionsFromState,
} from "@/js/lib/scene_regions.js"

const SceneEngine = {
  mounted() {
    this.canvas = document.getElementById("game-canvas")
    this.ctx = this.canvas.getContext("2d")
    this.bgImage = null
    this.spriteImages = {}
    this.characters = []
    this.walkmap = null
    this.regions = []
    this.blockedRegions = []
    this.showWalkmap = false
    this.camera = { x: 0, y: 0, zoom: 1 }
    this.sceneWidth = 2048
    this.sceneHeight = 1376
    this.dragging = false
    this.dragStart = { x: 0, y: 0 }
    this.lastMouse = { x: 0, y: 0 }

    // Load data from element attributes
    this.loadData()

    // Set up canvas sizing
    this.resize()
    window.addEventListener("resize", () => this.resize())

    // Mouse/touch events on canvas
    this.canvas.addEventListener("mousedown", (e) => this.onMouseDown(e))
    this.canvas.addEventListener("mousemove", (e) => this.onMouseMove(e))
    this.canvas.addEventListener("mouseup", (e) => this.onMouseUp(e))
    this.canvas.addEventListener("wheel", (e) => this.onWheel(e))
    this.canvas.addEventListener("contextmenu", (e) => e.preventDefault())

    // LiveView events
    this.handleEvent("move-character", ({ id, x, y }) => {
      const char = this.characters.find(c => c.id === id)
      if (char) {
        char.target_x = x
        char.target_y = y
        char.target_region_id = regionAtPoint(this.regions, x, y, this.blockedRegions)?.id || char.regionId
        char.state = "walking"
      }
    })

    // Start render loop
    this.frame = 0
    this.animate()
  },

  updated() {
    // Re-read data attributes on LiveView updates
    const el = this.el
    this.showWalkmap = el.dataset.showWalkmap === "true"

    // Update characters from server state
    try {
      const serverChars = JSON.parse(el.dataset.characters)
      for (const sc of serverChars) {
        const existing = this.characters.find(c => c.id === sc.id)
        if (!existing) {
          // New character
          this.characters.push({...sc, animFrame: 0, regionId: regionAtPoint(this.regions, sc.x, sc.y, this.blockedRegions)?.id || null, target_region_id: null})
          this.loadSprite(sc.sprite)
        } else {
          existing.x = sc.x ?? existing.x
          existing.y = sc.y ?? existing.y
          existing.regionId = regionAtPoint(this.regions, existing.x, existing.y, this.blockedRegions)?.id || existing.regionId
          if (sc.target_x != null && sc.target_y != null) {
            existing.target_x = sc.target_x
            existing.target_y = sc.target_y
            existing.target_region_id = regionAtPoint(this.regions, sc.target_x, sc.target_y, this.blockedRegions)?.id || existing.regionId
            existing.state = "walking"
          }
        }
      }
    } catch(e) {}
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    window.removeEventListener("resize", this._resizeHandler)
  },

  loadData() {
    const el = this.el

    // Background
    const bgUrl = el.dataset.bg
    if (bgUrl) {
      this.bgImage = new Image()
      this.bgImage.src = bgUrl
      this.bgImage.onload = () => {
        this.sceneWidth = this.bgImage.naturalWidth
        this.sceneHeight = this.bgImage.naturalHeight
        // Center camera
        this.camera.x = this.sceneWidth / 2
        this.camera.y = this.sceneHeight / 2
        this.fitScene()
      }
    }

    // Walk map
    try {
      this.walkmap = JSON.parse(el.dataset.walkmap)
      if (this.walkmap.dimensions) {
        this.sceneWidth = this.walkmap.dimensions.width
        this.sceneHeight = this.walkmap.dimensions.height
      }
      this.regions = sceneRegionsFromState(this.walkmap)
      this.blockedRegions = blockedRegionsFromState(this.walkmap)
    } catch(e) {
      this.walkmap = null
      this.regions = []
      this.blockedRegions = []
    }

    // Characters
    try {
      this.characters = JSON.parse(el.dataset.characters).map(c => ({
        ...c,
        animFrame: 0,
        bobOffset: Math.random() * Math.PI * 2,
        regionId: regionAtPoint(this.regions, c.x, c.y, this.blockedRegions)?.id || null,
        target_region_id: null,
      }))
      for (const c of this.characters) {
        if (c.sprite) this.loadSprite(c.sprite)
      }
    } catch(e) {
      this.characters = []
    }

    this.showWalkmap = el.dataset.showWalkmap === "true"
  },

  loadSprite(url) {
    if (this.spriteImages[url]) return
    const img = new Image()
    img.src = url
    this.spriteImages[url] = img
  },

  resize() {
    const dpr = window.devicePixelRatio || 1
    const rect = this.canvas.getBoundingClientRect()
    this.canvas.width = rect.width * dpr
    this.canvas.height = rect.height * dpr
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    this.canvasWidth = rect.width
    this.canvasHeight = rect.height
  },

  fitScene() {
    // Fit entire scene in view
    const scaleX = this.canvasWidth / this.sceneWidth
    const scaleY = this.canvasHeight / this.sceneHeight
    this.camera.zoom = Math.min(scaleX, scaleY)
    this.camera.x = this.sceneWidth / 2
    this.camera.y = this.sceneHeight / 2
  },

  // Convert screen coords to scene coords
  screenToScene(sx, sy) {
    const cx = this.canvasWidth / 2
    const cy = this.canvasHeight / 2
    return {
      x: (sx - cx) / this.camera.zoom + this.camera.x,
      y: (sy - cy) / this.camera.zoom + this.camera.y
    }
  },

  onMouseDown(e) {
    if (e.button === 2 || e.button === 1) {
      // Right/middle click — pan
      this.dragging = true
      this.dragStart = { x: e.clientX, y: e.clientY }
      this.dragCameraStart = { x: this.camera.x, y: this.camera.y }
      e.preventDefault()
    } else if (e.button === 0) {
      // Left click — move character
      const rect = this.canvas.getBoundingClientRect()
      const sx = e.clientX - rect.left
      const sy = e.clientY - rect.top
      const scene = this.screenToScene(sx, sy)

      // Check if clicking on a character (select it)
      let clickedChar = null
      for (const c of this.characters) {
        const dx = scene.x - c.x
        const dy = scene.y - c.y
        if (Math.abs(dx) < 40 && Math.abs(dy) < 40) {
          clickedChar = c
          break
        }
      }

      if (clickedChar) {
        this.pushEvent("select-char", { id: clickedChar.id })
      } else {
        // Move selected character
        this.pushEvent("scene-click", {
          x: Math.round(scene.x),
          y: Math.round(scene.y)
        })
      }
    }
  },

  onMouseMove(e) {
    if (this.dragging) {
      const dx = (e.clientX - this.dragStart.x) / this.camera.zoom
      const dy = (e.clientY - this.dragStart.y) / this.camera.zoom
      this.camera.x = this.dragCameraStart.x - dx
      this.camera.y = this.dragCameraStart.y - dy
    }
    const rect = this.canvas.getBoundingClientRect()
    this.lastMouse = {
      x: e.clientX - rect.left,
      y: e.clientY - rect.top
    }
  },

  onMouseUp(e) {
    this.dragging = false
  },

  onWheel(e) {
    e.preventDefault()
    const factor = e.deltaY > 0 ? 0.9 : 1.1
    const newZoom = Math.max(0.1, Math.min(3, this.camera.zoom * factor))
    // Zoom toward mouse position
    const scene = this.screenToScene(this.lastMouse.x, this.lastMouse.y)
    this.camera.zoom = newZoom
    // Adjust camera to keep mouse position stable
    const newScene = this.screenToScene(this.lastMouse.x, this.lastMouse.y)
    this.camera.x += scene.x - newScene.x
    this.camera.y += scene.y - newScene.y
  },

  isWalkable(x, y) {
    if (!this.walkmap) return true
    return Boolean(regionAtPoint(this.regions, x, y, this.blockedRegions))
  },

  updateCharacters() {
    for (const c of this.characters) {
      const currentPlacement = constrainPointToWalkableRegions(
        this.regions,
        this.blockedRegions,
        c.x,
        c.y,
        c.regionId,
      )
      c.x = currentPlacement.x
      c.y = currentPlacement.y
      c.regionId = currentPlacement.region?.id || c.regionId

      if (c.state === "walking" && c.target_x != null && c.target_y != null) {
        const dx = c.target_x - c.x
        const dy = c.target_y - c.y
        const dist = Math.sqrt(dx * dx + dy * dy)

        if (dist < 5) {
          c.state = "idle"
          c.target_x = null
          c.target_y = null
          c.target_region_id = null
          this.pushEvent("char-arrived", { id: c.id })
        } else {
          const speed = 3
          const nextX = c.x + (dx / dist) * speed
          const nextY = c.y + (dy / dist) * speed
          const nextPlacement = constrainPointToWalkableRegions(
            this.regions,
            this.blockedRegions,
            nextX,
            nextY,
            c.target_region_id || c.regionId,
          )
          const hitBoundary = Math.hypot(nextPlacement.x - nextX, nextPlacement.y - nextY) > 0.75

          c.x = nextPlacement.x
          c.y = nextPlacement.y
          c.regionId = nextPlacement.region?.id || c.regionId
          c.facing = dx > 0 ? "right" : "left"

          if (hitBoundary) {
            c.state = "idle"
            c.target_x = null
            c.target_y = null
            c.target_region_id = null
          }
        }
      }
      c.animFrame = (c.animFrame || 0) + 0.1
    }
  },

  animate() {
    this.frame++
    this.updateCharacters()
    this.render()
    this.rafId = requestAnimationFrame(() => this.animate())
  },

  render() {
    const ctx = this.ctx
    const w = this.canvasWidth
    const h = this.canvasHeight

    ctx.clearRect(0, 0, w, h)
    ctx.fillStyle = "#111"
    ctx.fillRect(0, 0, w, h)

    // Apply camera transform
    ctx.save()
    ctx.translate(w / 2, h / 2)
    ctx.scale(this.camera.zoom, this.camera.zoom)
    ctx.translate(-this.camera.x, -this.camera.y)

    // Draw background
    if (this.bgImage && this.bgImage.complete) {
      ctx.drawImage(this.bgImage, 0, 0)
    }

    // Draw walk map overlay
    if (this.showWalkmap && this.walkmap) {
      // Walk regions — green semi-transparent
      ctx.globalAlpha = 0.25
      for (const region of this.regions) {
        ctx.fillStyle = "#00ff00"
        ctx.strokeStyle = "#00ff00"
        ctx.lineWidth = 2
        ctx.beginPath()
        for (let i = 0; i < region.polygon.length; i++) {
          const [x, y] = region.polygon[i]
          if (i === 0) ctx.moveTo(x, y)
          else ctx.lineTo(x, y)
        }
        ctx.closePath()
        ctx.fill()
        ctx.stroke()

        // Label
        ctx.globalAlpha = 0.8
        ctx.fillStyle = "#0f0"
        ctx.font = "16px monospace"
        const cx = region.polygon.reduce((s, v) => s + v[0], 0) / region.polygon.length
        const cy = region.polygon.reduce((s, v) => s + v[1], 0) / region.polygon.length
        ctx.fillText(region.label + " (" + region.surface + ")", cx - 40, cy)
        ctx.globalAlpha = 0.25
      }

      // Blocked regions — red
      for (const b of this.blockedRegions) {
        ctx.fillStyle = "#ff0000"
        ctx.strokeStyle = "#ff0000"
        ctx.lineWidth = 2
        ctx.beginPath()
        for (let i = 0; i < b.vertices.length; i++) {
          const [x, y] = b.vertices[i]
          if (i === 0) ctx.moveTo(x, y)
          else ctx.lineTo(x, y)
        }
        ctx.closePath()
        ctx.fill()
        ctx.stroke()
      }

      // Interactive objects — yellow circles
      ctx.globalAlpha = 0.7
      const objects = this.walkmap.interactive_objects || []
      for (const obj of objects) {
        ctx.fillStyle = "#ffff00"
        ctx.strokeStyle = "#ffaa00"
        ctx.lineWidth = 2
        ctx.beginPath()
        ctx.arc(obj.x, obj.y, 20, 0, Math.PI * 2)
        ctx.fill()
        ctx.stroke()
        ctx.fillStyle = "#000"
        ctx.font = "12px monospace"
        ctx.fillText(obj.type, obj.x - 15, obj.y + 4)
      }

      // Spawn points — cyan diamonds
      const spawns = this.walkmap.spawn_points || []
      for (const sp of spawns) {
        ctx.fillStyle = "#00ffff"
        ctx.beginPath()
        ctx.moveTo(sp.x, sp.y - 15)
        ctx.lineTo(sp.x + 10, sp.y)
        ctx.lineTo(sp.x, sp.y + 15)
        ctx.lineTo(sp.x - 10, sp.y)
        ctx.closePath()
        ctx.fill()
      }

      // Light sources — orange circles with radius
      ctx.globalAlpha = 0.15
      const lights = (this.walkmap.lighting || {}).light_sources || []
      for (const l of lights) {
        const grad = ctx.createRadialGradient(l.x, l.y, 0, l.x, l.y, l.radius)
        grad.addColorStop(0, l.color || "#ffaa44")
        grad.addColorStop(1, "transparent")
        ctx.fillStyle = grad
        ctx.beginPath()
        ctx.arc(l.x, l.y, l.radius, 0, Math.PI * 2)
        ctx.fill()
      }

      ctx.globalAlpha = 1
    }

    // Draw characters
    for (const c of this.characters) {
      const img = this.spriteImages[c.sprite]
      const region = regionAtPoint(this.regions, c.x, c.y, this.blockedRegions) || this.regions[0] || null
      const spriteSize = region ? regionScaleAtPoint(region, c.x, c.y) : 64

      // Breathing/bobbing animation
      const bob = Math.sin((c.bobOffset || 0) + this.frame * 0.05) * 2
      const drawX = c.x - spriteSize / 2
      const drawY = c.y - spriteSize + bob

      if (img && img.complete && img.naturalWidth > 0) {
        ctx.save()
        // Flip horizontally if facing left
        if (c.facing === "left") {
          ctx.translate(c.x, 0)
          ctx.scale(-1, 1)
          ctx.translate(-c.x, 0)
        }
        ctx.drawImage(img, drawX, drawY, spriteSize, spriteSize)
        ctx.restore()
      } else {
        // Fallback: colored circle
        ctx.fillStyle = c.state === "walking" ? "#88ff88" : "#8888ff"
        ctx.beginPath()
        ctx.arc(c.x, c.y - 16 + bob, 12, 0, Math.PI * 2)
        ctx.fill()
        ctx.strokeStyle = "#fff"
        ctx.lineWidth = 2
        ctx.stroke()
      }

      // Name label
      ctx.fillStyle = "#fff"
      ctx.strokeStyle = "#000"
      ctx.lineWidth = 3
      ctx.font = "bold 14px monospace"
      ctx.textAlign = "center"
      ctx.strokeText(c.name, c.x, c.y - spriteSize - 8 + bob)
      ctx.fillText(c.name, c.x, c.y - spriteSize - 8 + bob)
      ctx.textAlign = "left"

      // Movement line
      if (c.target_x != null && c.target_y != null) {
        ctx.strokeStyle = "rgba(255,255,255,0.3)"
        ctx.lineWidth = 1
        ctx.setLineDash([4, 4])
        ctx.beginPath()
        ctx.moveTo(c.x, c.y)
        ctx.lineTo(c.target_x, c.target_y)
        ctx.stroke()
        ctx.setLineDash([])
      }
    }

    ctx.restore()

    // HUD: mouse scene coordinates
    const mouseScene = this.screenToScene(this.lastMouse.x, this.lastMouse.y)
    ctx.fillStyle = "#888"
    ctx.font = "11px monospace"
    ctx.fillText(
      `scene: ${Math.round(mouseScene.x)}, ${Math.round(mouseScene.y)} | zoom: ${this.camera.zoom.toFixed(2)}`,
      w - 280, h - 10
    )
  }
}

export default SceneEngine
