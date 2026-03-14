// SceneEditor — event-sourced collaborative scene editor
// All state comes from the channel. All mutations go through the channel.
// The renderer is a pure function of the current state.

import * as THREE from "@/vendor/three.module.min.js"
import { createCloud, createLaraCroft } from "@/js/lib/primitive_characters.js"
import { Socket } from "phoenix"

const CHAR_DEFS = { cloud: createCloud, lara: createLaraCroft }

const SceneEditor = {
  mounted() {
    this.el.innerHTML = ""
    this.clock = new THREE.Clock()

    // State — materialized from events
    this.state = {
      background: null,
      dimensions: { width: 2048, height: 1376 },
      projection: { scale: 1, offset_x: 0, offset_y: 0, rotation: 0 },
      walk_polygons: [],
      blocked_regions: [],
      objects: [],
      spawns: [],
      characters: []
    }

    // Editor state (local only)
    this.mode = "walk"  // "walk" | "blocked" | "select" | "spawn" | "object"
    this.drawing = false
    this.currentVertices = []
    this.selectedId = null
    this.lastSeq = 0

    // Wandering character state (local)
    this.charStates = {}

    // Three.js
    this.renderer = new THREE.WebGLRenderer({ antialias: false })
    this.renderer.setClearColor(0x111111)
    this.renderer.domElement.style.display = "block"
    this.renderer.domElement.style.width = "100%"
    this.renderer.domElement.style.height = "100%"
    this.el.appendChild(this.renderer.domElement)

    this.scene = new THREE.Scene()
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, -1000, 1000)
    this.camera.position.set(0, 0, 100)
    this.camera.lookAt(0, 0, 0)

    this.scene.add(new THREE.AmbientLight(0xffffff, 0.75))
    const dir = new THREE.DirectionalLight(0xffd080, 0.4)
    dir.position.set(1, 2, 1)
    this.scene.add(dir)

    // Managed Three.js objects
    this.bgMesh = null
    this.overlayGroup = new THREE.Group()
    this.scene.add(this.overlayGroup)
    this.charGroup = new THREE.Group()
    this.scene.add(this.charGroup)
    this.drawingGroup = new THREE.Group()  // current polygon being drawn
    this.scene.add(this.drawingGroup)

    // HUD overlay (HTML)
    this.hud = document.createElement("div")
    this.hud.style.cssText = "position:absolute;top:8px;left:8px;z-index:10;font:12px monospace;color:#ccc;display:flex;flex-direction:column;gap:4px;"
    this.el.style.position = "relative"
    this.el.appendChild(this.hud)

    this.buildHUD()

    // Mouse events
    this.renderer.domElement.addEventListener("click", (e) => this.onClick(e))
    this.renderer.domElement.addEventListener("dblclick", (e) => this.onDblClick(e))
    this.renderer.domElement.addEventListener("contextmenu", (e) => {
      e.preventDefault()
      this.finishDrawing()
    })
    this.renderer.domElement.addEventListener("mousemove", (e) => this.onMouseMove(e))

    // Keyboard
    window.addEventListener("keydown", (e) => this.onKey(e))

    // Connect to channel
    this.sceneId = this.el.dataset.sceneId || "default"
    this.bgUrl = this.el.dataset.bgUrl

    // Use the existing Phoenix socket from LiveView
    const socketPath = "/froth/socket"
    this.socket = new Socket(socketPath)
    this.socket.connect()
    this.channel = this.socket.channel("scene:" + this.sceneId, {})
    this.channel.join()
      .receive("ok", (resp) => {
        console.log("Joined scene:", this.sceneId, resp)
        this.state = resp.state
        this.lastSeq = resp.last_seq
        // If no background set, use default
        if (!this.state.background && this.bgUrl) {
          this.emit("set_background", { url: this.bgUrl })
        }
        this.rebuildScene()
      })
      .receive("error", (resp) => {
        console.error("Failed to join scene:", resp)
      })

    this.channel.on("event", (evt) => {
      this.lastSeq = evt.seq
      this.applyEvent(evt)
    })

    this.resize()
    window.addEventListener("resize", () => this.resize())
    this.animate()
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    if (this.channel) this.channel.leave()
    if (this.socket) this.socket.disconnect()
    this.renderer.dispose()
  },

  // --- HUD ---

  buildHUD() {
    const modes = [
      { key: "w", mode: "walk", label: "Walk (W)", color: "#0f0" },
      { key: "b", mode: "blocked", label: "Blocked (B)", color: "#f33" },
      { key: "s", mode: "spawn", label: "Spawn (S)", color: "#0ff" },
      { key: "o", mode: "object", label: "Object (O)", color: "#ff0" },
      { key: "v", mode: "select", label: "Select (V)", color: "#fff" },
    ]

    this.modeButtons = {}
    for (const m of modes) {
      const btn = document.createElement("button")
      btn.textContent = m.label
      btn.style.cssText = `padding:3px 8px;font:11px monospace;background:#222;color:${m.color};border:1px solid #444;cursor:pointer;text-align:left;`
      btn.onclick = () => this.setMode(m.mode)
      this.hud.appendChild(btn)
      this.modeButtons[m.mode] = btn
    }

    // Add characters buttons
    const charDiv = document.createElement("div")
    charDiv.style.cssText = "margin-top:8px;display:flex;flex-direction:column;gap:2px;"
    for (const type of ["cloud", "lara"]) {
      const btn = document.createElement("button")
      btn.textContent = `+ ${type}`
      btn.style.cssText = "padding:2px 6px;font:10px monospace;background:#223;color:#88f;border:1px solid #446;cursor:pointer;"
      btn.onclick = () => this.addCharacter(type)
      charDiv.appendChild(btn)
    }
    this.hud.appendChild(charDiv)

    // Instructions
    const info = document.createElement("div")
    info.style.cssText = "margin-top:8px;font:10px monospace;color:#666;max-width:180px;line-height:1.4;"
    info.innerHTML = "click: add vertex<br>right-click: finish polygon<br>dblclick: finish + close<br>esc: cancel drawing<br>del: remove selected"
    this.hud.appendChild(info)

    // Status line
    this.statusEl = document.createElement("div")
    this.statusEl.style.cssText = "margin-top:4px;font:10px monospace;color:#888;"
    this.hud.appendChild(this.statusEl)

    this.updateModeButtons()
  },

  setMode(mode) {
    this.mode = mode
    this.cancelDrawing()
    this.updateModeButtons()
  },

  updateModeButtons() {
    for (const [m, btn] of Object.entries(this.modeButtons)) {
      btn.style.borderColor = m === this.mode ? "#fff" : "#444"
      btn.style.fontWeight = m === this.mode ? "bold" : "normal"
    }
  },

  // --- Coordinate conversion ---

  s2t(x, y) {
    return {
      x: x - this.state.dimensions.width / 2,
      y: -(y - this.state.dimensions.height / 2)
    }
  },

  screenToScene(clientX, clientY) {
    const rect = this.renderer.domElement.getBoundingClientRect()
    const nx = ((clientX - rect.left) / rect.width) * 2 - 1
    const ny = -((clientY - rect.top) / rect.height) * 2 + 1

    const vec = new THREE.Vector3(nx, ny, 0)
    vec.unproject(this.camera)

    // Three.js coords to scene coords
    const sx = vec.x + this.state.dimensions.width / 2
    const sy = -vec.y + this.state.dimensions.height / 2
    return { x: Math.round(sx), y: Math.round(sy) }
  },

  // --- Events ---

  emit(type, payload) {
    if (this.channel) {
      this.channel.push("event", { type, payload })
    }
  },

  applyEvent(evt) {
    // Apply server event to local state
    const p = evt.payload
    switch (evt.type) {
      case "set_background":
        this.state.background = p.url
        this.loadBackground(p.url)
        break
      case "add_walk_polygon":
        this.state.walk_polygons.push({ id: p.id, vertices: p.vertices, surface: p.surface || "grass", elevation: p.elevation || 0 })
        this.rebuildOverlay()
        break
      case "update_walk_polygon":
        { const wp = this.state.walk_polygons.find(w => w.id === p.id)
          if (wp) { wp.vertices = p.vertices; this.rebuildOverlay() } }
        break
      case "remove_walk_polygon":
        this.state.walk_polygons = this.state.walk_polygons.filter(w => w.id !== p.id)
        this.rebuildOverlay()
        break
      case "add_blocked_region":
        this.state.blocked_regions.push({ id: p.id, vertices: p.vertices, type: p.type || "wall" })
        this.rebuildOverlay()
        break
      case "remove_blocked_region":
        this.state.blocked_regions = this.state.blocked_regions.filter(b => b.id !== p.id)
        this.rebuildOverlay()
        break
      case "add_object":
        this.state.objects.push({ id: p.id, x: p.x, y: p.y, type: p.type, label: p.label })
        this.rebuildOverlay()
        break
      case "remove_object":
        this.state.objects = this.state.objects.filter(o => o.id !== p.id)
        this.rebuildOverlay()
        break
      case "add_spawn":
        this.state.spawns.push({ id: p.id, x: p.x, y: p.y, facing: p.facing })
        this.rebuildOverlay()
        break
      case "remove_spawn":
        this.state.spawns = this.state.spawns.filter(s => s.id !== p.id)
        this.rebuildOverlay()
        break
      case "add_character":
        this.state.characters.push({ id: p.id, type: p.type, x: p.x, y: p.y })
        this.rebuildCharacters()
        break
      case "set_dimensions":
        this.state.dimensions = { width: p.width, height: p.height }
        this.resize()
        break
    }
  },

  // --- Drawing ---

  onClick(e) {
    const scene = this.screenToScene(e.clientX, e.clientY)

    if (this.mode === "walk" || this.mode === "blocked") {
      this.drawing = true
      this.currentVertices.push([scene.x, scene.y])
      this.updateDrawingPreview()
    } else if (this.mode === "spawn") {
      const id = "spawn_" + Date.now()
      this.emit("add_spawn", { id, x: scene.x, y: scene.y, facing: "right" })
    } else if (this.mode === "object") {
      const id = "obj_" + Date.now()
      const type = prompt("Object type (chest/door/npc/sign/shrine/campfire):") || "chest"
      this.emit("add_object", { id, x: scene.x, y: scene.y, type, label: type })
    } else if (this.mode === "select") {
      this.selectAt(scene.x, scene.y)
    }
  },

  onDblClick(e) {
    if (this.drawing && this.currentVertices.length >= 3) {
      this.finishDrawing()
    }
  },

  onMouseMove(e) {
    const scene = this.screenToScene(e.clientX, e.clientY)
    this.statusEl.textContent = `${scene.x}, ${scene.y} | ${this.mode}${this.drawing ? ` (${this.currentVertices.length} pts)` : ""}`

    if (this.drawing && this.currentVertices.length > 0) {
      this.updateDrawingPreview([scene.x, scene.y])
    }
  },

  onKey(e) {
    if (e.key === "Escape") this.cancelDrawing()
    else if (e.key === "w") this.setMode("walk")
    else if (e.key === "b") this.setMode("blocked")
    else if (e.key === "s") this.setMode("spawn")
    else if (e.key === "o") this.setMode("object")
    else if (e.key === "v") this.setMode("select")
    else if (e.key === "Delete" || e.key === "Backspace") this.deleteSelected()
    else if (e.key === "Enter" && this.drawing) this.finishDrawing()
  },

  finishDrawing() {
    if (!this.drawing || this.currentVertices.length < 3) {
      this.cancelDrawing()
      return
    }

    const id = (this.mode === "walk" ? "walk_" : "blocked_") + Date.now()
    if (this.mode === "walk") {
      this.emit("add_walk_polygon", { id, vertices: this.currentVertices, surface: "grass" })
    } else if (this.mode === "blocked") {
      this.emit("add_blocked_region", { id, vertices: this.currentVertices, type: "wall" })
    }

    this.currentVertices = []
    this.drawing = false
    this.clearDrawingPreview()
  },

  cancelDrawing() {
    this.currentVertices = []
    this.drawing = false
    this.clearDrawingPreview()
  },

  selectAt(sx, sy) {
    // Find nearest polygon or object
    let best = null, bestDist = 40

    for (const wp of this.state.walk_polygons) {
      const cx = wp.vertices.reduce((s, v) => s + v[0], 0) / wp.vertices.length
      const cy = wp.vertices.reduce((s, v) => s + v[1], 0) / wp.vertices.length
      const d = Math.sqrt((sx - cx) ** 2 + (sy - cy) ** 2)
      if (d < bestDist) { best = { type: "walk", id: wp.id }; bestDist = d }
    }

    for (const br of this.state.blocked_regions) {
      const cx = br.vertices.reduce((s, v) => s + v[0], 0) / br.vertices.length
      const cy = br.vertices.reduce((s, v) => s + v[1], 0) / br.vertices.length
      const d = Math.sqrt((sx - cx) ** 2 + (sy - cy) ** 2)
      if (d < bestDist) { best = { type: "blocked", id: br.id }; bestDist = d }
    }

    for (const obj of this.state.objects) {
      const d = Math.sqrt((sx - obj.x) ** 2 + (sy - obj.y) ** 2)
      if (d < bestDist) { best = { type: "object", id: obj.id }; bestDist = d }
    }

    for (const sp of this.state.spawns) {
      const d = Math.sqrt((sx - sp.x) ** 2 + (sy - sp.y) ** 2)
      if (d < bestDist) { best = { type: "spawn", id: sp.id }; bestDist = d }
    }

    this.selectedId = best
    this.rebuildOverlay()
  },

  deleteSelected() {
    if (!this.selectedId) return
    const { type, id } = this.selectedId
    if (type === "walk") this.emit("remove_walk_polygon", { id })
    else if (type === "blocked") this.emit("remove_blocked_region", { id })
    else if (type === "object") this.emit("remove_object", { id })
    else if (type === "spawn") this.emit("remove_spawn", { id })
    this.selectedId = null
  },

  addCharacter(type) {
    const id = type + "_" + Date.now()
    const cx = this.state.dimensions.width / 2
    const cy = this.state.dimensions.height / 2
    this.emit("add_character", { id, type, x: cx, y: cy })
  },

  // --- Three.js rendering ---

  resize() {
    const rect = this.el.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1
    this.renderer.setSize(rect.width, rect.height)
    this.renderer.setPixelRatio(dpr)

    const W = this.state.dimensions.width
    const H = this.state.dimensions.height
    const viewAspect = rect.width / rect.height
    const sceneAspect = W / H

    if (viewAspect > sceneAspect) {
      this.camera.top = H / 2
      this.camera.bottom = -H / 2
      this.camera.left = -H / 2 * viewAspect
      this.camera.right = H / 2 * viewAspect
    } else {
      this.camera.left = -W / 2
      this.camera.right = W / 2
      this.camera.top = W / 2 / viewAspect
      this.camera.bottom = -W / 2 / viewAspect
    }
    this.camera.updateProjectionMatrix()
  },

  rebuildScene() {
    this.loadBackground(this.state.background)
    this.rebuildOverlay()
    this.rebuildCharacters()
  },

  loadBackground(url) {
    if (!url) return
    if (this.bgMesh) { this.scene.remove(this.bgMesh); this.bgMesh = null }
    const loader = new THREE.TextureLoader()
    loader.load(url, (tex) => {
      tex.minFilter = THREE.LinearFilter
      tex.magFilter = THREE.LinearFilter
      const W = this.state.dimensions.width
      const H = this.state.dimensions.height
      const geo = new THREE.PlaneGeometry(W, H)
      const mat = new THREE.MeshBasicMaterial({ map: tex })
      this.bgMesh = new THREE.Mesh(geo, mat)
      this.bgMesh.position.z = -10
      this.scene.add(this.bgMesh)
    })
  },

  rebuildOverlay() {
    // Clear
    while (this.overlayGroup.children.length > 0) {
      const c = this.overlayGroup.children[0]
      this.overlayGroup.remove(c)
      if (c.geometry) c.geometry.dispose()
      if (c.material) c.material.dispose()
    }

    // Walk polygons
    for (const wp of this.state.walk_polygons) {
      const selected = this.selectedId && this.selectedId.type === "walk" && this.selectedId.id === wp.id
      this.drawPolygon(wp.vertices, selected ? 0x00ff88 : 0x00ff44, selected ? 0.3 : 0.12, -5)
      this.drawPolyline(wp.vertices, selected ? 0x00ffaa : 0x00ff66, selected ? 0.8 : 0.35, -4.9, true)
      // Vertices as dots
      for (const v of wp.vertices) {
        this.drawDot(v[0], v[1], 6, 0x00ff88, 0.6, -4.8)
      }
    }

    // Blocked regions
    for (const br of this.state.blocked_regions) {
      const selected = this.selectedId && this.selectedId.type === "blocked" && this.selectedId.id === br.id
      this.drawPolygon(br.vertices, selected ? 0xff4444 : 0xff2200, selected ? 0.25 : 0.08, -5)
      this.drawPolyline(br.vertices, selected ? 0xff6666 : 0xff4400, selected ? 0.7 : 0.25, -4.9, true)
    }

    // Spawns
    for (const sp of this.state.spawns) {
      const selected = this.selectedId && this.selectedId.type === "spawn" && this.selectedId.id === sp.id
      this.drawDot(sp.x, sp.y, selected ? 16 : 12, 0x00ffff, selected ? 0.8 : 0.5, -3)
    }

    // Objects
    for (const obj of this.state.objects) {
      const selected = this.selectedId && this.selectedId.type === "object" && this.selectedId.id === obj.id
      this.drawDot(obj.x, obj.y, selected ? 14 : 10, 0xffcc00, selected ? 0.8 : 0.4, -3)
    }
  },

  drawPolygon(vertices, color, opacity, z) {
    if (vertices.length < 3) return
    const shape = new THREE.Shape()
    for (let i = 0; i < vertices.length; i++) {
      const t = this.s2t(vertices[i][0], vertices[i][1])
      if (i === 0) shape.moveTo(t.x, t.y)
      else shape.lineTo(t.x, t.y)
    }
    const geo = new THREE.ShapeGeometry(shape)
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity, side: THREE.DoubleSide })
    const mesh = new THREE.Mesh(geo, mat)
    mesh.position.z = z
    this.overlayGroup.add(mesh)
  },

  drawPolyline(vertices, color, opacity, z, closed) {
    const pts = vertices.map(v => {
      const t = this.s2t(v[0], v[1])
      return new THREE.Vector3(t.x, t.y, z)
    })
    if (closed && pts.length > 0) pts.push(pts[0].clone())
    const geo = new THREE.BufferGeometry().setFromPoints(pts)
    const mat = new THREE.LineBasicMaterial({ color, transparent: true, opacity })
    this.overlayGroup.add(new THREE.Line(geo, mat))
  },

  drawDot(sx, sy, radius, color, opacity, z) {
    const t = this.s2t(sx, sy)
    const geo = new THREE.CircleGeometry(radius, 8)
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity })
    const mesh = new THREE.Mesh(geo, mat)
    mesh.position.set(t.x, t.y, z)
    this.overlayGroup.add(mesh)
  },

  // Drawing preview
  updateDrawingPreview(mousePos) {
    this.clearDrawingPreview()
    const verts = [...this.currentVertices]
    if (mousePos) verts.push(mousePos)
    if (verts.length < 2) {
      // Just a dot
      if (verts.length === 1) {
        this.drawPreviewDot(verts[0][0], verts[0][1])
      }
      return
    }
    const color = this.mode === "walk" ? 0x00ff88 : 0xff6666
    const pts = verts.map(v => {
      const t = this.s2t(v[0], v[1])
      return new THREE.Vector3(t.x, t.y, -2)
    })
    const geo = new THREE.BufferGeometry().setFromPoints(pts)
    const mat = new THREE.LineBasicMaterial({ color, linewidth: 2 })
    this.drawingGroup.add(new THREE.Line(geo, mat))
    for (const v of this.currentVertices) {
      this.drawPreviewDot(v[0], v[1])
    }
  },

  drawPreviewDot(sx, sy) {
    const t = this.s2t(sx, sy)
    const geo = new THREE.CircleGeometry(5, 6)
    const mat = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.8 })
    const mesh = new THREE.Mesh(geo, mat)
    mesh.position.set(t.x, t.y, -1)
    this.drawingGroup.add(mesh)
  },

  clearDrawingPreview() {
    while (this.drawingGroup.children.length > 0) {
      const c = this.drawingGroup.children[0]
      this.drawingGroup.remove(c)
      if (c.geometry) c.geometry.dispose()
      if (c.material) c.material.dispose()
    }
  },

  // --- Characters ---

  rebuildCharacters() {
    while (this.charGroup.children.length > 0) {
      const c = this.charGroup.children[0]
      this.charGroup.remove(c)
      // dispose recursively
    }
    this.charStates = {}

    for (const ch of this.state.characters) {
      const factory = CHAR_DEFS[ch.type]
      if (!factory) continue
      const def = factory()
      const boneMap = {}
      const group = this.buildSkeleton(def.skeleton, boneMap)
      const scale = 50 / def.height
      group.scale.set(scale, scale, scale)
      this.charGroup.add(group)

      // Label
      const label = this.makeLabel(def.name)
      this.charGroup.add(label)

      this.charStates[ch.id] = {
        def, group, boneMap, label,
        x: ch.x, y: ch.y,
        target_x: null, target_y: null,
        state: "idle",
        facing: "right",
        animTime: Math.random() * 10,
        wanderCooldown: Math.random() * 3
      }
    }
  },

  // --- Character wandering & animation (same as before) ---

  pointInPolygon(x, y, vertices) {
    let inside = false
    for (let i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
      const xi = vertices[i][0], yi = vertices[i][1]
      const xj = vertices[j][0], yj = vertices[j][1]
      if (((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi))
        inside = !inside
    }
    return inside
  },

  randomPointInPolygon(vertices) {
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (const [x, y] of vertices) {
      minX = Math.min(minX, x); maxX = Math.max(maxX, x)
      minY = Math.min(minY, y); maxY = Math.max(maxY, y)
    }
    for (let i = 0; i < 100; i++) {
      const x = minX + Math.random() * (maxX - minX)
      const y = minY + Math.random() * (maxY - minY)
      if (this.pointInPolygon(x, y, vertices)) return { x, y }
    }
    return {
      x: vertices.reduce((s, v) => s + v[0], 0) / vertices.length,
      y: vertices.reduce((s, v) => s + v[1], 0) / vertices.length
    }
  },

  updateCharacters(dt) {
    const walkPolys = this.state.walk_polygons || []

    for (const [id, c] of Object.entries(this.charStates)) {
      if (c.state === "idle") {
        c.wanderCooldown -= dt
        if (c.wanderCooldown <= 0 && walkPolys.length > 0) {
          const poly = walkPolys[Math.floor(Math.random() * walkPolys.length)]
          const target = this.randomPointInPolygon(poly.vertices)
          c.target_x = target.x; c.target_y = target.y; c.state = "walking"
          c.wanderCooldown = 1 + Math.random() * 4
        }
      }

      if (c.state === "walking" && c.target_x != null) {
        const dx = c.target_x - c.x, dy = c.target_y - c.y
        const dist = Math.sqrt(dx * dx + dy * dy)
        if (dist < 8) {
          c.state = "idle"; c.target_x = null; c.target_y = null
          c.wanderCooldown = 1.5 + Math.random() * 3
        } else {
          const speed = 60 * dt
          c.x += (dx / dist) * speed; c.y += (dy / dist) * speed
          c.facing = dx > 0 ? "right" : "left"
        }
      }

      const t = this.s2t(c.x, c.y)
      c.group.position.set(t.x, t.y, 0)
      c.group.rotation.y = c.facing === "left" ? Math.PI : 0
      c.label.position.set(t.x, t.y + 55, 1)
      this.applyBoneAnimation(c, dt)
    }
  },

  applyBoneAnimation(char, dt) {
    const animName = char.state === "walking" ? "walk" : "idle"
    const anim = char.def.animations[animName]
    if (!anim) return
    char.animTime += dt
    const t = (char.animTime % anim.duration) / anim.duration
    for (const [boneName, keyframes] of Object.entries(anim.keyframes)) {
      const bone = char.boneMap[boneName]
      if (!bone) continue
      const r = this.lerp(keyframes, t)
      if (!r) continue
      if (r.type === "rotation") bone.rotation.set(bone.userData.baseRotation.x + r.value[0], bone.userData.baseRotation.y + r.value[1], bone.userData.baseRotation.z + r.value[2])
      else if (r.type === "position") bone.position.set(r.value[0], r.value[1], r.value[2])
    }
  },

  lerp(kf, t) {
    if (!kf || !kf.length) return null
    let prev = kf[0], next = kf[kf.length - 1]
    for (let i = 0; i < kf.length - 1; i++) { if (t >= kf[i].t && t <= kf[i+1].t) { prev = kf[i]; next = kf[i+1]; break } }
    const range = next.t - prev.t, f = range > 0 ? (t - prev.t) / range : 0
    if (prev.rotation) return { type: "rotation", value: [0,1,2].map(i => prev.rotation[i] + (next.rotation[i] - prev.rotation[i]) * f) }
    if (prev.position) return { type: "position", value: [0,1,2].map(i => prev.position[i] + (next.position[i] - prev.position[i]) * f) }
    return null
  },

  // --- Skeleton builders (same as before) ---

  buildSkeleton(skeleton, boneMap) {
    const root = new THREE.Group()
    for (const [name, bone] of Object.entries(skeleton)) root.add(this.buildBone(name, bone, boneMap))
    return root
  },

  buildBone(name, bone, boneMap) {
    const group = new THREE.Group()
    group.name = name
    if (bone.position) group.position.set(...bone.position)
    if (bone.rotation) group.rotation.set(...bone.rotation)
    group.userData.basePosition = group.position.clone()
    group.userData.baseRotation = group.rotation.clone()
    if (bone.shape) {
      const geo = this.createGeo(bone.shape, bone.size)
      const mat = new THREE.MeshLambertMaterial({ color: bone.color || 0x888888, flatShading: true })
      group.add(new THREE.Mesh(geo, mat))
    }
    boneMap[name] = group
    if (bone.children) { for (const [cn, cb] of Object.entries(bone.children)) group.add(this.buildBone(cn, cb, boneMap)) }
    return group
  },

  createGeo(shape, size) {
    switch (shape) {
      case "box": return new THREE.BoxGeometry(size[0], size[1], size[2] || size[0])
      case "sphere": return new THREE.SphereGeometry(size[0], 6, 4)
      case "cylinder": return new THREE.CylinderGeometry(size[0], size[1], size[2], 6)
      default: return new THREE.BoxGeometry(1, 1, 1)
    }
  },

  makeLabel(text) {
    const canvas = document.createElement("canvas")
    canvas.width = 256; canvas.height = 64
    const ctx = canvas.getContext("2d")
    ctx.font = "bold 28px monospace"; ctx.textAlign = "center"
    ctx.strokeStyle = "#000"; ctx.lineWidth = 4; ctx.strokeText(text, 128, 40)
    ctx.fillStyle = "#fff"; ctx.fillText(text, 128, 40)
    const tex = new THREE.CanvasTexture(canvas)
    const mat = new THREE.SpriteMaterial({ map: tex, transparent: true })
    const sprite = new THREE.Sprite(mat)
    sprite.scale.set(80, 20, 1)
    return sprite
  },

  animate() {
    const dt = this.clock.getDelta()
    this.updateCharacters(dt)
    this.renderer.render(this.scene, this.camera)
    this.rafId = requestAnimationFrame(() => this.animate())
  }
}

export default SceneEditor
