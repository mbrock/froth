// SceneEditor — quad-based walking plane editor
// All state from the channel. All mutations through the channel.
// Walking planes are quads (4 draggable screen-space points).
// Characters scale via bilinear interpolation inside quads.

import * as THREE from "@/vendor/three.module.min.js"
import { createCloud, createLaraCroft } from "@/js/lib/primitive_characters.js"
import {
  bilinearInterpolate, scaleAtV, screenToUV, pointInQuad,
  generateGrid, generateGridLines
} from "@/js/lib/quad_math.js"
import { Socket } from "phoenix"

const CHAR_DEFS = { cloud: createCloud, lara: createLaraCroft }

const SceneEditor = {
  mounted() {
    this.el.innerHTML = ""
    this.clock = new THREE.Clock()

    this.state = {
      background: null,
      dimensions: { width: 2048, height: 1376 },
      planes: [],      // walking planes: { id, corners: [[x,y]x4], surface, elevation }
      objects: [],
      spawns: [],
      characters: []
    }

    // Editor
    this.selectedPlane = null
    this.dragCorner = null  // { planeId, cornerIndex }
    this.showGrid = true
    this.gridDensity = 10
    this.lastSeq = 0

    // Character wandering state
    this.charStates = {}

    // Three.js
    this.renderer = new THREE.WebGLRenderer({ antialias: false })
    this.renderer.setClearColor(0x111111)
    this.el.appendChild(this.renderer.domElement)
    this.renderer.domElement.style.display = "block"
    this.renderer.domElement.style.width = "100%"
    this.renderer.domElement.style.height = "100%"
    this.renderer.domElement.style.cursor = "crosshair"

    this.scene = new THREE.Scene()
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, -1000, 1000)
    this.camera.position.set(0, 0, 100)
    this.camera.lookAt(0, 0, 0)
    this.scene.add(new THREE.AmbientLight(0xffffff, 0.75))
    const dir = new THREE.DirectionalLight(0xffd080, 0.4)
    dir.position.set(1, 2, 1)
    this.scene.add(dir)

    this.bgMesh = null
    this.overlayGroup = new THREE.Group()
    this.scene.add(this.overlayGroup)
    this.charGroup = new THREE.Group()
    this.scene.add(this.charGroup)
    this.handleGroup = new THREE.Group()
    this.scene.add(this.handleGroup)

    // Build UI panels
    this.el.style.position = "relative"
    this.buildToolbar()
    this.buildPropsPanel()
    this.buildStatusBar()

    // Mouse
    this.renderer.domElement.addEventListener("mousedown", (e) => this.onMouseDown(e))
    this.renderer.domElement.addEventListener("mousemove", (e) => this.onMouseMove(e))
    this.renderer.domElement.addEventListener("mouseup", (e) => this.onMouseUp(e))
    this.renderer.domElement.addEventListener("contextmenu", (e) => e.preventDefault())

    // Channel
    this.sceneId = this.el.dataset.sceneId || "default"
    this.bgUrl = this.el.dataset.bgUrl
    const socketPath = "/froth/socket"
    this.socket = new Socket(socketPath)
    this.socket.connect()
    this.channel = this.socket.channel("scene:" + this.sceneId, {})
    this.channel.join()
      .receive("ok", (resp) => {
        this.state = this.migrateState(resp.state)
        this.lastSeq = resp.last_seq
        if (!this.state.background && this.bgUrl) {
          this.emit("set_background", { url: this.bgUrl })
        }
        this.rebuildScene()
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

  migrateState(s) {
    // Ensure planes array exists (old events used walk_polygons)
    if (!s.planes) s.planes = []
    if (!s.objects) s.objects = []
    if (!s.spawns) s.spawns = []
    if (!s.characters) s.characters = []
    if (!s.dimensions) s.dimensions = { width: 2048, height: 1376 }
    return s
  },

  // --- UI ---

  buildToolbar() {
    this.toolbar = document.createElement("div")
    this.toolbar.style.cssText = "position:absolute;top:0;left:0;bottom:0;width:180px;background:rgba(17,17,17,0.92);border-right:1px solid #333;padding:12px;display:flex;flex-direction:column;gap:8px;z-index:10;overflow-y:auto;"

    const title = document.createElement("div")
    title.textContent = "SCENE EDITOR"
    title.style.cssText = "font:bold 13px monospace;color:#888;letter-spacing:2px;margin-bottom:4px;"
    this.toolbar.appendChild(title)

    // Tool buttons
    const tools = [
      { id: "add_plane", label: "＋ Add Walking Plane", color: "#0f0", action: () => this.addPlane() },
      { id: "add_cloud", label: "＋ Cloud", color: "#88f", action: () => this.addChar("cloud") },
      { id: "add_lara", label: "＋ Lara", color: "#f8f", action: () => this.addChar("lara") },
    ]

    for (const t of tools) {
      const btn = document.createElement("button")
      btn.textContent = t.label
      btn.style.cssText = `padding:8px 12px;font:12px monospace;background:#1a1a2a;color:${t.color};border:1px solid #333;cursor:pointer;text-align:left;border-radius:3px;`
      btn.onmouseenter = () => btn.style.borderColor = t.color
      btn.onmouseleave = () => btn.style.borderColor = "#333"
      btn.onclick = t.action
      this.toolbar.appendChild(btn)
    }

    // Divider
    const div1 = document.createElement("hr")
    div1.style.cssText = "border:none;border-top:1px solid #333;margin:4px 0;"
    this.toolbar.appendChild(div1)

    // Grid toggle
    const gridRow = document.createElement("div")
    gridRow.style.cssText = "display:flex;align-items:center;gap:8px;"
    const gridCheck = document.createElement("input")
    gridCheck.type = "checkbox"
    gridCheck.checked = this.showGrid
    gridCheck.onchange = () => { this.showGrid = gridCheck.checked; this.rebuildOverlay() }
    const gridLabel = document.createElement("label")
    gridLabel.textContent = "Show Grid"
    gridLabel.style.cssText = "font:11px monospace;color:#aaa;cursor:pointer;"
    gridLabel.onclick = () => { gridCheck.checked = !gridCheck.checked; gridCheck.onchange() }
    gridRow.appendChild(gridCheck)
    gridRow.appendChild(gridLabel)
    this.toolbar.appendChild(gridRow)

    // Grid density slider
    const densRow = document.createElement("div")
    densRow.style.cssText = "display:flex;flex-direction:column;gap:2px;"
    const densLabel = document.createElement("div")
    densLabel.style.cssText = "font:10px monospace;color:#777;"
    densLabel.textContent = `Grid: ${this.gridDensity}×${this.gridDensity}`
    const densSlider = document.createElement("input")
    densSlider.type = "range"
    densSlider.min = 3; densSlider.max = 20; densSlider.value = this.gridDensity
    densSlider.style.cssText = "width:100%;accent-color:#0f0;"
    densSlider.oninput = () => {
      this.gridDensity = parseInt(densSlider.value)
      densLabel.textContent = `Grid: ${this.gridDensity}×${this.gridDensity}`
      this.rebuildOverlay()
    }
    densRow.appendChild(densLabel)
    densRow.appendChild(densSlider)
    this.toolbar.appendChild(densRow)

    // Divider
    const div2 = document.createElement("hr")
    div2.style.cssText = "border:none;border-top:1px solid #333;margin:4px 0;"
    this.toolbar.appendChild(div2)

    // Delete button
    this.deleteBtn = document.createElement("button")
    this.deleteBtn.textContent = "Delete Selected"
    this.deleteBtn.style.cssText = "padding:6px 10px;font:11px monospace;background:#2a1a1a;color:#f44;border:1px solid #333;cursor:pointer;border-radius:3px;opacity:0.4;"
    this.deleteBtn.onclick = () => this.deleteSelected()
    this.toolbar.appendChild(this.deleteBtn)

    // Planes list
    this.planesList = document.createElement("div")
    this.planesList.style.cssText = "margin-top:8px;display:flex;flex-direction:column;gap:3px;"
    this.toolbar.appendChild(this.planesList)

    this.el.appendChild(this.toolbar)
  },

  buildPropsPanel() {
    this.propsPanel = document.createElement("div")
    this.propsPanel.style.cssText = "position:absolute;top:0;right:0;width:200px;background:rgba(17,17,17,0.92);border-left:1px solid #333;padding:12px;z-index:10;display:none;font:11px monospace;color:#aaa;"
    this.el.appendChild(this.propsPanel)
  },

  buildStatusBar() {
    this.statusBar = document.createElement("div")
    this.statusBar.style.cssText = "position:absolute;bottom:0;left:180px;right:0;height:24px;background:rgba(17,17,17,0.85);border-top:1px solid #333;padding:0 12px;font:11px monospace;color:#666;display:flex;align-items:center;z-index:10;"
    this.el.appendChild(this.statusBar)
  },

  updatePlanesList() {
    this.planesList.innerHTML = ""
    for (const pl of this.state.planes) {
      const row = document.createElement("div")
      row.style.cssText = `padding:4px 6px;font:10px monospace;cursor:pointer;border-radius:2px;border:1px solid ${this.selectedPlane === pl.id ? "#0f0" : "#333"};color:${this.selectedPlane === pl.id ? "#0f0" : "#888"};background:${this.selectedPlane === pl.id ? "#0a1a0a" : "transparent"};`
      row.textContent = `${pl.id} (${pl.surface || "grass"})`
      row.onclick = () => { this.selectedPlane = pl.id; this.updatePlanesList(); this.rebuildOverlay(); this.updatePropsPanel() }
      this.planesList.appendChild(row)
    }
    this.deleteBtn.style.opacity = this.selectedPlane ? "1" : "0.4"
  },

  updatePropsPanel() {
    if (!this.selectedPlane) {
      this.propsPanel.style.display = "none"
      return
    }
    const pl = this.state.planes.find(p => p.id === this.selectedPlane)
    if (!pl) { this.propsPanel.style.display = "none"; return }

    this.propsPanel.style.display = "block"
    this.propsPanel.innerHTML = ""

    const title = document.createElement("div")
    title.textContent = pl.id
    title.style.cssText = "font:bold 12px monospace;color:#0f0;margin-bottom:8px;"
    this.propsPanel.appendChild(title)

    // Surface type
    const surfLabel = document.createElement("div")
    surfLabel.textContent = "Surface:"
    surfLabel.style.cssText = "color:#777;margin-bottom:2px;"
    this.propsPanel.appendChild(surfLabel)

    const surfaces = ["grass", "cobblestone", "wood", "dirt", "stone", "water", "sand"]
    const surfSelect = document.createElement("select")
    surfSelect.style.cssText = "width:100%;padding:4px;font:11px monospace;background:#222;color:#aaa;border:1px solid #444;margin-bottom:8px;"
    for (const s of surfaces) {
      const opt = document.createElement("option")
      opt.value = s; opt.textContent = s
      if (pl.surface === s) opt.selected = true
      surfSelect.appendChild(opt)
    }
    surfSelect.onchange = () => {
      this.emit("update_plane", { id: pl.id, surface: surfSelect.value })
    }
    this.propsPanel.appendChild(surfSelect)

    // Corner coordinates (read-only for now)
    const cornersLabel = document.createElement("div")
    cornersLabel.textContent = "Corners (drag to edit):"
    cornersLabel.style.cssText = "color:#777;margin-bottom:4px;"
    this.propsPanel.appendChild(cornersLabel)

    const cornerNames = ["TL", "TR", "BR", "BL"]
    for (let i = 0; i < 4; i++) {
      const c = pl.corners[i]
      const row = document.createElement("div")
      row.textContent = `${cornerNames[i]}: ${Math.round(c[0])}, ${Math.round(c[1])}`
      row.style.cssText = "color:#999;font:10px monospace;padding:1px 0;"
      this.propsPanel.appendChild(row)
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
    return {
      x: Math.round(vec.x + this.state.dimensions.width / 2),
      y: Math.round(-vec.y + this.state.dimensions.height / 2)
    }
  },

  // --- Events ---

  emit(type, payload) {
    if (this.channel) this.channel.push("event", { type, payload })
  },

  applyEvent(evt) {
    const p = evt.payload
    switch (evt.type) {
      case "set_background":
        this.state.background = p.url
        this.loadBackground(p.url)
        break
      case "add_plane":
        this.state.planes.push({ id: p.id, corners: p.corners, surface: p.surface || "grass", elevation: p.elevation || 0 })
        this.rebuildOverlay(); this.updatePlanesList()
        break
      case "update_plane":
        { const pl = this.state.planes.find(x => x.id === p.id)
          if (pl) {
            if (p.corners) pl.corners = p.corners
            if (p.surface) pl.surface = p.surface
            if (p.elevation !== undefined) pl.elevation = p.elevation
            this.rebuildOverlay(); this.updatePropsPanel()
          } }
        break
      case "remove_plane":
        this.state.planes = this.state.planes.filter(x => x.id !== p.id)
        if (this.selectedPlane === p.id) this.selectedPlane = null
        this.rebuildOverlay(); this.updatePlanesList(); this.updatePropsPanel()
        break
      case "add_character":
        this.state.characters.push({ id: p.id, type: p.type, x: p.x, y: p.y })
        this.rebuildCharacters()
        break
      case "add_spawn":
        this.state.spawns.push({ id: p.id, x: p.x, y: p.y, facing: p.facing })
        this.rebuildOverlay()
        break
      case "add_object":
        this.state.objects.push({ id: p.id, x: p.x, y: p.y, type: p.type, label: p.label })
        this.rebuildOverlay()
        break
      // Legacy walk_polygon events -> ignore for now
      default: break
    }
  },

  // --- Mouse ---

  onMouseDown(e) {
    const scene = this.screenToScene(e.clientX, e.clientY)

    // Check if clicking a corner handle
    for (const pl of this.state.planes) {
      for (let i = 0; i < 4; i++) {
        const dx = scene.x - pl.corners[i][0]
        const dy = scene.y - pl.corners[i][1]
        const handleSize = 20
        if (Math.abs(dx) < handleSize && Math.abs(dy) < handleSize) {
          this.dragCorner = { planeId: pl.id, cornerIndex: i }
          this.selectedPlane = pl.id
          this.updatePlanesList()
          this.updatePropsPanel()
          this.renderer.domElement.style.cursor = "grabbing"
          return
        }
      }
    }

    // Check if clicking inside a plane
    for (const pl of this.state.planes) {
      if (pointInQuad(pl.corners, scene.x, scene.y)) {
        this.selectedPlane = pl.id
        this.updatePlanesList()
        this.updatePropsPanel()
        this.rebuildOverlay()
        return
      }
    }

    // Clicked nothing — deselect
    this.selectedPlane = null
    this.updatePlanesList()
    this.updatePropsPanel()
    this.rebuildOverlay()
  },

  onMouseMove(e) {
    const scene = this.screenToScene(e.clientX, e.clientY)
    this.statusBar.textContent = `${scene.x}, ${scene.y} | planes: ${this.state.planes.length} | chars: ${this.state.characters.length}`

    if (this.dragCorner) {
      const pl = this.state.planes.find(p => p.id === this.dragCorner.planeId)
      if (pl) {
        pl.corners[this.dragCorner.cornerIndex] = [scene.x, scene.y]
        this.rebuildOverlay()
        this.updatePropsPanel()
      }
    } else {
      // Hover cursor
      let onHandle = false
      for (const pl of this.state.planes) {
        for (let i = 0; i < 4; i++) {
          const dx = scene.x - pl.corners[i][0]
          const dy = scene.y - pl.corners[i][1]
          if (Math.abs(dx) < 20 && Math.abs(dy) < 20) { onHandle = true; break }
        }
        if (onHandle) break
      }
      this.renderer.domElement.style.cursor = onHandle ? "grab" : "crosshair"
    }
  },

  onMouseUp(e) {
    if (this.dragCorner) {
      // Persist the corner move
      const pl = this.state.planes.find(p => p.id === this.dragCorner.planeId)
      if (pl) {
        this.emit("update_plane", { id: pl.id, corners: pl.corners })
      }
      this.dragCorner = null
      this.renderer.domElement.style.cursor = "crosshair"
    }
  },

  // --- Actions ---

  addPlane() {
    const W = this.state.dimensions.width
    const H = this.state.dimensions.height
    const id = "plane_" + Date.now()
    // Default quad centered with perspective
    const cx = W / 2, cy = H / 2
    const corners = [
      [cx - 200, cy - 150],  // TL (far)
      [cx + 200, cy - 150],  // TR (far)
      [cx + 300, cy + 200],  // BR (near)
      [cx - 300, cy + 200],  // BL (near)
    ]
    this.emit("add_plane", { id, corners, surface: "grass" })
    this.selectedPlane = id
  },

  addChar(type) {
    const id = type + "_" + Date.now()
    const W = this.state.dimensions.width
    const H = this.state.dimensions.height
    this.emit("add_character", { id, type, x: W / 2, y: H / 2 })
  },

  deleteSelected() {
    if (!this.selectedPlane) return
    this.emit("remove_plane", { id: this.selectedPlane })
    this.selectedPlane = null
  },

  // --- Three.js ---

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
      this.camera.top = H / 2; this.camera.bottom = -H / 2
      this.camera.left = -H / 2 * viewAspect; this.camera.right = H / 2 * viewAspect
    } else {
      this.camera.left = -W / 2; this.camera.right = W / 2
      this.camera.top = W / 2 / viewAspect; this.camera.bottom = -W / 2 / viewAspect
    }
    this.camera.updateProjectionMatrix()
  },

  rebuildScene() {
    this.loadBackground(this.state.background)
    this.rebuildOverlay()
    this.rebuildCharacters()
    this.updatePlanesList()
    this.updatePropsPanel()
  },

  loadBackground(url) {
    if (!url) return
    if (this.bgMesh) { this.scene.remove(this.bgMesh); this.bgMesh = null }
    new THREE.TextureLoader().load(url, (tex) => {
      tex.minFilter = THREE.LinearFilter; tex.magFilter = THREE.LinearFilter
      const W = this.state.dimensions.width, H = this.state.dimensions.height
      this.bgMesh = new THREE.Mesh(
        new THREE.PlaneGeometry(W, H),
        new THREE.MeshBasicMaterial({ map: tex })
      )
      this.bgMesh.position.z = -10
      this.scene.add(this.bgMesh)
    })
  },

  rebuildOverlay() {
    this.clearGroup(this.overlayGroup)
    this.clearGroup(this.handleGroup)

    for (const pl of this.state.planes) {
      const selected = this.selectedPlane === pl.id
      const color = selected ? 0x00ff88 : 0x00ff44
      const alpha = selected ? 0.15 : 0.06

      // Quad fill
      this.drawQuadFill(pl.corners, color, alpha, -5)

      // Quad outline
      this.drawQuadOutline(pl.corners, color, selected ? 0.7 : 0.3, -4.9)

      // Grid
      if (this.showGrid) {
        const gridLines = generateGridLines(pl.corners, this.gridDensity, this.gridDensity)
        for (const line of gridLines) {
          const pts = line.map(p => {
            const t = this.s2t(p.x, p.y)
            return new THREE.Vector3(t.x, t.y, -4.5)
          })
          const geo = new THREE.BufferGeometry().setFromPoints(pts)
          const mat = new THREE.LineBasicMaterial({
            color: selected ? 0x00ff66 : 0x00aa44,
            transparent: true,
            opacity: selected ? 0.2 : 0.08
          })
          this.overlayGroup.add(new THREE.Line(geo, mat))
        }

        // Standing figures at grid intersections
        if (selected) {
          const grid = generateGrid(pl.corners, this.gridDensity, this.gridDensity)
          for (const gp of grid) {
            if (gp.u === 0 || gp.u === 1 || gp.v === 0 || gp.v === 1) continue
            const t = this.s2t(gp.x, gp.y)
            const figScale = gp.scale * 4
            // Simple stick figure
            const figGeo = new THREE.BufferGeometry().setFromPoints([
              new THREE.Vector3(t.x, t.y, -3),
              new THREE.Vector3(t.x, t.y + figScale * 3, -3),
            ])
            const figMat = new THREE.LineBasicMaterial({ color: 0x88ffaa, transparent: true, opacity: 0.4 })
            this.overlayGroup.add(new THREE.Line(figGeo, figMat))
            // Head
            const headGeo = new THREE.CircleGeometry(figScale * 0.8, 6)
            const headMat = new THREE.MeshBasicMaterial({ color: 0x88ffaa, transparent: true, opacity: 0.3 })
            const headMesh = new THREE.Mesh(headGeo, headMat)
            headMesh.position.set(t.x, t.y + figScale * 3.8, -3)
            this.overlayGroup.add(headMesh)
          }
        }
      }

      // Corner handles
      const cornerNames = ["TL", "TR", "BR", "BL"]
      for (let i = 0; i < 4; i++) {
        const c = pl.corners[i]
        const t = this.s2t(c[0], c[1])
        // Square handle
        const hSize = selected ? 12 : 8
        const hGeo = new THREE.PlaneGeometry(hSize, hSize)
        const hMat = new THREE.MeshBasicMaterial({
          color: selected ? 0xffffff : 0x00ff66,
          transparent: true,
          opacity: selected ? 0.9 : 0.5
        })
        const hMesh = new THREE.Mesh(hGeo, hMat)
        hMesh.position.set(t.x, t.y, -1)
        this.handleGroup.add(hMesh)

        // Label
        if (selected) {
          const label = this.makeSmallLabel(cornerNames[i])
          label.position.set(t.x, t.y + 18, -0.5)
          this.handleGroup.add(label)
        }
      }
    }
  },

  drawQuadFill(corners, color, opacity, z) {
    // Two triangles: TL-TR-BR and TL-BR-BL
    const verts = []
    for (const idx of [[0,1,2], [0,2,3]]) {
      for (const i of idx) {
        const t = this.s2t(corners[i][0], corners[i][1])
        verts.push(t.x, t.y, z)
      }
    }
    const geo = new THREE.BufferGeometry()
    geo.setAttribute("position", new THREE.Float32BufferAttribute(verts, 3))
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity, side: THREE.DoubleSide })
    this.overlayGroup.add(new THREE.Mesh(geo, mat))
  },

  drawQuadOutline(corners, color, opacity, z) {
    const pts = [...corners, corners[0]].map(c => {
      const t = this.s2t(c[0], c[1])
      return new THREE.Vector3(t.x, t.y, z)
    })
    const geo = new THREE.BufferGeometry().setFromPoints(pts)
    const mat = new THREE.LineBasicMaterial({ color, transparent: true, opacity })
    this.overlayGroup.add(new THREE.Line(geo, mat))
  },

  makeSmallLabel(text) {
    const canvas = document.createElement("canvas")
    canvas.width = 64; canvas.height = 32
    const ctx = canvas.getContext("2d")
    ctx.font = "bold 18px monospace"; ctx.textAlign = "center"
    ctx.fillStyle = "#fff"; ctx.fillText(text, 32, 22)
    const tex = new THREE.CanvasTexture(canvas)
    const mat = new THREE.SpriteMaterial({ map: tex, transparent: true })
    const sprite = new THREE.Sprite(mat)
    sprite.scale.set(30, 15, 1)
    return sprite
  },

  clearGroup(group) {
    while (group.children.length > 0) {
      const c = group.children[0]
      group.remove(c)
      if (c.geometry) c.geometry.dispose()
      if (c.material) { if (c.material.map) c.material.map.dispose(); c.material.dispose() }
    }
  },

  // --- Characters ---

  rebuildCharacters() {
    this.clearGroup(this.charGroup)
    this.charStates = {}
    for (const ch of this.state.characters) {
      const factory = CHAR_DEFS[ch.type]
      if (!factory) continue
      const def = factory()
      const boneMap = {}
      const group = this.buildSkeleton(def.skeleton, boneMap)
      // Base scale (will be modulated by quad position)
      group.scale.set(3, 3, 3)
      this.charGroup.add(group)
      const label = this.makeLabel(def.name)
      this.charGroup.add(label)

      this.charStates[ch.id] = {
        def, group, boneMap, label,
        x: ch.x, y: ch.y,
        target_x: null, target_y: null,
        state: "idle", facing: "right",
        animTime: Math.random() * 10,
        wanderCooldown: Math.random() * 2
      }
    }
  },

  updateCharacters(dt) {
    const planes = this.state.planes

    for (const [id, c] of Object.entries(this.charStates)) {
      // Wandering
      if (c.state === "idle") {
        c.wanderCooldown -= dt
        if (c.wanderCooldown <= 0 && planes.length > 0) {
          const pl = planes[Math.floor(Math.random() * planes.length)]
          const u = 0.1 + Math.random() * 0.8
          const v = 0.1 + Math.random() * 0.8
          const target = bilinearInterpolate(pl.corners, u, v)
          c.target_x = target.x; c.target_y = target.y
          c.targetPlane = pl; c.targetUV = { u, v }
          c.state = "walking"
          c.wanderCooldown = 2 + Math.random() * 4
        }
      }

      if (c.state === "walking" && c.target_x != null) {
        const dx = c.target_x - c.x, dy = c.target_y - c.y
        const dist = Math.sqrt(dx * dx + dy * dy)
        if (dist < 5) {
          c.state = "idle"; c.target_x = null; c.target_y = null
          c.wanderCooldown = 1 + Math.random() * 3
        } else {
          const speed = 60 * dt
          c.x += (dx / dist) * speed; c.y += (dy / dist) * speed
          c.facing = dx > 0 ? "right" : "left"
        }
      }

      // Find which plane the character is in and get their scale
      let charScale = 3
      for (const pl of planes) {
        if (pointInQuad(pl.corners, c.x, c.y)) {
          const uv = screenToUV(pl.corners, c.x, c.y)
          charScale = scaleAtV(pl.corners, uv.v) * 3
          break
        }
      }

      const t = this.s2t(c.x, c.y)
      c.group.position.set(t.x, t.y, 0)
      c.group.scale.set(charScale, charScale, charScale)
      c.group.rotation.y = c.facing === "left" ? Math.PI : 0
      c.label.position.set(t.x, t.y + charScale * 22, 1)
      c.label.scale.set(charScale * 30, charScale * 8, 1)
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
      group.add(new THREE.Mesh(geo, new THREE.MeshLambertMaterial({ color: bone.color || 0x888888, flatShading: true })))
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
    const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, transparent: true }))
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
