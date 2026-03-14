// SceneView — minimal scene renderer
// No zoom. No buttons. Characters wander the walk polygons.
// Subtle walkmap overlay so you can evaluate Gemini's output.

import * as THREE from "@/vendor/three.module.min.js"
import { createCloud, createLaraCroft } from "@/js/lib/primitive_characters.js"

const SceneView = {
  mounted() {
    this.canvas = document.getElementById("game-canvas")
    this.ctx = this.canvas.getContext("2d")
    this.bgImage = null
    this.walkmap = null
    this.sceneWidth = 2048
    this.sceneHeight = 1376
    this.characters = []

    // Three.js for 3D characters
    this.renderer3d = new THREE.WebGLRenderer({ antialias: false, alpha: true })
    this.renderer3d.setClearColor(0x000000, 0)
    this.renderer3d.domElement.style.position = "absolute"
    this.renderer3d.domElement.style.top = "0"
    this.renderer3d.domElement.style.left = "0"
    this.renderer3d.domElement.style.pointerEvents = "none"
    this.el.appendChild(this.renderer3d.domElement)

    this.scene3d = new THREE.Scene()
    this.scene3d.add(new THREE.AmbientLight(0xffffff, 0.7))
    const dir = new THREE.DirectionalLight(0xffd080, 0.5)
    dir.position.set(1, 2, 1)
    this.scene3d.add(dir)

    // Orthographic camera — fixed, no zoom
    this.camera3d = new THREE.OrthographicCamera(-1, 1, 1, -1, -1000, 1000)
    this.camera3d.position.set(0, 0, 100)
    this.camera3d.lookAt(0, 0, 0)

    // Load data
    try { this.walkmap = JSON.parse(this.el.dataset.walkmap) } catch(e) {}
    if (this.walkmap && this.walkmap.dimensions) {
      this.sceneWidth = this.walkmap.dimensions.width
      this.sceneHeight = this.walkmap.dimensions.height
    }

    // Background
    const bgUrl = this.el.dataset.bg
    if (bgUrl) {
      this.bgImage = new Image()
      this.bgImage.src = bgUrl
    }

    // Build characters
    const charDefs = [createCloud(), createLaraCroft()]
    const startPositions = [
      { x: 600, y: 950 },
      { x: 1000, y: 1000 }
    ]

    for (let i = 0; i < charDefs.length; i++) {
      const def = charDefs[i]
      const boneMap = {}
      const group = this.buildSkeleton(def.skeleton, boneMap)
      const scale = 50 / def.height
      group.scale.set(scale, scale, scale)
      this.scene3d.add(group)

      this.characters.push({
        def, group, boneMap,
        x: startPositions[i].x,
        y: startPositions[i].y,
        target_x: null,
        target_y: null,
        state: "idle",
        facing: Math.random() > 0.5 ? "right" : "left",
        animTime: Math.random() * 10,
        waitTimer: 0,
        wanderCooldown: Math.random() * 2
      })
    }

    // Precompute walkable areas for wandering
    this.walkablePolygons = (this.walkmap && this.walkmap.walk_polygons) || []

    this.resize()
    window.addEventListener("resize", () => this.resize())
    this.clock = new THREE.Clock()
    this.animate()
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    this.renderer3d.dispose()
  },

  resize() {
    const rect = this.el.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1

    // Canvas2D for background + walkmap overlay
    this.canvas.width = rect.width * dpr
    this.canvas.height = rect.height * dpr
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    this.canvasWidth = rect.width
    this.canvasHeight = rect.height

    // Three.js
    this.renderer3d.setSize(rect.width, rect.height)
    this.renderer3d.setPixelRatio(dpr)

    // Compute scale to fit scene
    const scaleX = rect.width / this.sceneWidth
    const scaleY = rect.height / this.sceneHeight
    this.fitScale = Math.min(scaleX, scaleY)
    this.offsetX = (rect.width - this.sceneWidth * this.fitScale) / 2
    this.offsetY = (rect.height - this.sceneHeight * this.fitScale) / 2

    // Update ortho camera to match
    const hw = rect.width / (2 * this.fitScale)
    const hh = rect.height / (2 * this.fitScale)
    this.camera3d.left = -hw
    this.camera3d.right = hw
    this.camera3d.top = hh
    this.camera3d.bottom = -hh
    this.camera3d.position.set(
      this.sceneWidth / 2 - this.offsetX / this.fitScale,
      -(this.sceneHeight / 2 - this.offsetY / this.fitScale),
      100
    )
    // Actually simpler: center on scene
    this.camera3d.position.set(0, 0, 100)
    this.camera3d.left = -this.sceneWidth / 2
    this.camera3d.right = this.sceneWidth / 2
    this.camera3d.top = this.sceneHeight / 2
    this.camera3d.bottom = -this.sceneHeight / 2
    this.camera3d.updateProjectionMatrix()
  },

  // Random point inside a polygon
  randomPointInPolygon(vertices) {
    // Bounding box approach with rejection sampling
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (const [x, y] of vertices) {
      minX = Math.min(minX, x); maxX = Math.max(maxX, x)
      minY = Math.min(minY, y); maxY = Math.max(maxY, y)
    }
    for (let attempt = 0; attempt < 100; attempt++) {
      const x = minX + Math.random() * (maxX - minX)
      const y = minY + Math.random() * (maxY - minY)
      if (this.pointInPolygon(x, y, vertices)) return { x, y }
    }
    // Fallback: centroid
    const cx = vertices.reduce((s, v) => s + v[0], 0) / vertices.length
    const cy = vertices.reduce((s, v) => s + v[1], 0) / vertices.length
    return { x: cx, y: cy }
  },

  pointInPolygon(x, y, vertices) {
    let inside = false
    for (let i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
      const xi = vertices[i][0], yi = vertices[i][1]
      const xj = vertices[j][0], yj = vertices[j][1]
      if (((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) {
        inside = !inside
      }
    }
    return inside
  },

  pickWanderTarget(char) {
    if (this.walkablePolygons.length === 0) return null
    // Pick a random walkable polygon, then a random point inside it
    const poly = this.walkablePolygons[Math.floor(Math.random() * this.walkablePolygons.length)]
    return this.randomPointInPolygon(poly.vertices)
  },

  updateCharacters(dt) {
    for (const c of this.characters) {
      // Wandering AI
      if (c.state === "idle") {
        c.wanderCooldown -= dt
        if (c.wanderCooldown <= 0) {
          const target = this.pickWanderTarget(c)
          if (target) {
            c.target_x = target.x
            c.target_y = target.y
            c.state = "walking"
          }
          c.wanderCooldown = 1 + Math.random() * 4
        }
      }

      if (c.state === "walking" && c.target_x != null) {
        const dx = c.target_x - c.x
        const dy = c.target_y - c.y
        const dist = Math.sqrt(dx * dx + dy * dy)
        if (dist < 8) {
          c.state = "idle"
          c.target_x = null
          c.target_y = null
          c.wanderCooldown = 1.5 + Math.random() * 3
        } else {
          const speed = 60 * dt
          c.x += (dx / dist) * speed
          c.y += (dy / dist) * speed
          c.facing = dx > 0 ? "right" : "left"
        }
      }

      // Update Three.js position
      const sx = c.x - this.sceneWidth / 2
      const sy = -(c.y - this.sceneHeight / 2)
      c.group.position.set(sx, sy, 10)
      c.group.rotation.y = c.facing === "left" ? Math.PI : 0

      // Animate bones
      this.applyAnimation(c, dt)
    }
  },

  applyAnimation(char, dt) {
    const animName = char.state === "walking" ? "walk" : "idle"
    const anim = char.def.animations[animName]
    if (!anim) return
    char.animTime += dt
    const t = (char.animTime % anim.duration) / anim.duration

    for (const [boneName, keyframes] of Object.entries(anim.keyframes)) {
      const bone = char.boneMap[boneName]
      if (!bone) continue
      const result = this.interpolateKeyframes(keyframes, t)
      if (!result) continue
      if (result.type === "rotation") {
        bone.rotation.set(
          bone.userData.baseRotation.x + result.value[0],
          bone.userData.baseRotation.y + result.value[1],
          bone.userData.baseRotation.z + result.value[2]
        )
      } else if (result.type === "position") {
        bone.position.set(result.value[0], result.value[1], result.value[2])
      }
    }
  },

  interpolateKeyframes(keyframes, t) {
    if (!keyframes || keyframes.length === 0) return null
    let prev = keyframes[0], next = keyframes[keyframes.length - 1]
    for (let i = 0; i < keyframes.length - 1; i++) {
      if (t >= keyframes[i].t && t <= keyframes[i + 1].t) {
        prev = keyframes[i]; next = keyframes[i + 1]; break
      }
    }
    const range = next.t - prev.t
    const frac = range > 0 ? (t - prev.t) / range : 0
    if (prev.rotation) {
      return { type: "rotation", value: [
        prev.rotation[0] + (next.rotation[0] - prev.rotation[0]) * frac,
        prev.rotation[1] + (next.rotation[1] - prev.rotation[1]) * frac,
        prev.rotation[2] + (next.rotation[2] - prev.rotation[2]) * frac
      ]}
    }
    if (prev.position) {
      return { type: "position", value: [
        prev.position[0] + (next.position[0] - prev.position[0]) * frac,
        prev.position[1] + (next.position[1] - prev.position[1]) * frac,
        prev.position[2] + (next.position[2] - prev.position[2]) * frac
      ]}
    }
    return null
  },

  buildSkeleton(skeleton, boneMap) {
    const root = new THREE.Group()
    for (const [name, bone] of Object.entries(skeleton)) {
      root.add(this.buildBone(name, bone, boneMap))
    }
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

    if (bone.children) {
      for (const [cn, cb] of Object.entries(bone.children)) {
        group.add(this.buildBone(cn, cb, boneMap))
      }
    }
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

  render2D() {
    const ctx = this.ctx
    const w = this.canvasWidth
    const h = this.canvasHeight
    ctx.clearRect(0, 0, w, h)
    ctx.fillStyle = "#111"
    ctx.fillRect(0, 0, w, h)

    // Draw background fitted to canvas
    ctx.save()
    ctx.translate(this.offsetX, this.offsetY)
    ctx.scale(this.fitScale, this.fitScale)

    if (this.bgImage && this.bgImage.complete) {
      ctx.drawImage(this.bgImage, 0, 0)
    }

    // Subtle walkmap overlay — always on
    if (this.walkmap) {
      // Walk polygons — faint green
      ctx.globalAlpha = 0.12
      for (const wp of (this.walkmap.walk_polygons || [])) {
        ctx.fillStyle = "#00ff44"
        ctx.strokeStyle = "#00ff88"
        ctx.lineWidth = 2
        ctx.beginPath()
        for (let i = 0; i < wp.vertices.length; i++) {
          const [x, y] = wp.vertices[i]
          if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
        }
        ctx.closePath()
        ctx.fill()
        ctx.globalAlpha = 0.35
        ctx.stroke()
        ctx.globalAlpha = 0.12
      }

      // Blocked regions — faint red
      ctx.globalAlpha = 0.08
      for (const br of (this.walkmap.blocked_regions || [])) {
        ctx.fillStyle = "#ff2200"
        ctx.strokeStyle = "#ff4400"
        ctx.lineWidth = 1.5
        ctx.beginPath()
        for (let i = 0; i < br.vertices.length; i++) {
          const [x, y] = br.vertices[i]
          if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
        }
        ctx.closePath()
        ctx.fill()
        ctx.globalAlpha = 0.25
        ctx.stroke()
        ctx.globalAlpha = 0.08
      }

      // Interactive objects — small yellow dots
      ctx.globalAlpha = 0.5
      for (const obj of (this.walkmap.interactive_objects || [])) {
        ctx.fillStyle = "#ffcc00"
        ctx.beginPath()
        ctx.arc(obj.x, obj.y, 8, 0, Math.PI * 2)
        ctx.fill()
      }

      // Labels for walk regions
      ctx.globalAlpha = 0.4
      ctx.fillStyle = "#88ff88"
      ctx.font = "18px monospace"
      for (const wp of (this.walkmap.walk_polygons || [])) {
        const cx = wp.vertices.reduce((s, v) => s + v[0], 0) / wp.vertices.length
        const cy = wp.vertices.reduce((s, v) => s + v[1], 0) / wp.vertices.length
        ctx.fillText(wp.id + " (" + wp.surface + ")", cx - 60, cy)
      }

      ctx.globalAlpha = 1
    }

    // Character name labels (drawn in scene space)
    for (const c of this.characters) {
      ctx.fillStyle = "#fff"
      ctx.strokeStyle = "#000"
      ctx.lineWidth = 3
      ctx.font = "bold 16px monospace"
      ctx.textAlign = "center"
      ctx.strokeText(c.def.name, c.x, c.y - 45)
      ctx.fillText(c.def.name, c.x, c.y - 45)

      // Movement line
      if (c.target_x != null) {
        ctx.strokeStyle = "rgba(255,255,255,0.15)"
        ctx.lineWidth = 1
        ctx.setLineDash([6, 6])
        ctx.beginPath()
        ctx.moveTo(c.x, c.y)
        ctx.lineTo(c.target_x, c.target_y)
        ctx.stroke()
        ctx.setLineDash([])
      }
    }
    ctx.textAlign = "left"

    ctx.restore()
  },

  animate() {
    const dt = this.clock.getDelta()
    this.updateCharacters(dt)
    this.render2D()
    this.renderer3d.render(this.scene3d, this.camera3d)
    this.rafId = requestAnimationFrame(() => this.animate())
  }
}

export default SceneView
