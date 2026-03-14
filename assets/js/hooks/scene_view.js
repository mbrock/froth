// SceneView — pure Three.js game renderer
// Background as textured plane, characters as primitive skeletons,
// walk map as line geometry. One renderer, one coordinate system.

import * as THREE from "@/vendor/three.module.min.js"
import { createCloud, createLaraCroft } from "@/js/lib/primitive_characters.js"

const SceneView = {
  mounted() {
    this.el.innerHTML = ""
    this.clock = new THREE.Clock()

    // Scene dimensions from walkmap
    this.sceneWidth = 2048
    this.sceneHeight = 1376

    try { this.walkmap = JSON.parse(this.el.dataset.walkmap) } catch(e) {}
    if (this.walkmap && this.walkmap.dimensions) {
      this.sceneWidth = this.walkmap.dimensions.width
      this.sceneHeight = this.walkmap.dimensions.height
    }

    // Renderer
    this.renderer = new THREE.WebGLRenderer({ antialias: false })
    this.renderer.setClearColor(0x111111)
    this.renderer.domElement.style.display = "block"
    this.renderer.domElement.style.width = "100%"
    this.renderer.domElement.style.height = "100%"
    this.el.appendChild(this.renderer.domElement)

    this.scene = new THREE.Scene()

    // Orthographic camera centered on scene
    this.camera = new THREE.OrthographicCamera(
      -this.sceneWidth / 2, this.sceneWidth / 2,
      this.sceneHeight / 2, -this.sceneHeight / 2,
      -1000, 1000
    )
    this.camera.position.set(0, 0, 100)
    this.camera.lookAt(0, 0, 0)

    // Lighting — flat PS1 style
    this.scene.add(new THREE.AmbientLight(0xffffff, 0.75))
    const dir = new THREE.DirectionalLight(0xffd080, 0.4)
    dir.position.set(1, 2, 1)
    this.scene.add(dir)

    // Background plane — textured with the Flux painting
    const bgUrl = this.el.dataset.bg
    if (bgUrl) {
      const loader = new THREE.TextureLoader()
      loader.load(bgUrl, (tex) => {
        tex.minFilter = THREE.LinearFilter
        tex.magFilter = THREE.LinearFilter
        const geo = new THREE.PlaneGeometry(this.sceneWidth, this.sceneHeight)
        const mat = new THREE.MeshBasicMaterial({ map: tex })
        const plane = new THREE.Mesh(geo, mat)
        plane.position.set(0, 0, -10) // behind everything
        this.scene.add(plane)
      })
    }

    // Walk map overlay geometry
    this.buildWalkmapOverlay()

    // Characters
    this.characters = []
    this.walkablePolygons = (this.walkmap && this.walkmap.walk_polygons) || []

    const charDefs = [createCloud(), createLaraCroft()]
    const starts = [
      { x: 600, y: 950 },
      { x: 1000, y: 1000 }
    ]

    for (let i = 0; i < charDefs.length; i++) {
      const def = charDefs[i]
      const boneMap = {}
      const group = this.buildSkeleton(def.skeleton, boneMap)
      const scale = 50 / def.height
      group.scale.set(scale, scale, scale)
      this.scene.add(group)

      // Name label as sprite
      const label = this.makeLabel(def.name)
      this.scene.add(label)

      this.characters.push({
        def, group, boneMap, label,
        x: starts[i].x,
        y: starts[i].y,
        target_x: null,
        target_y: null,
        state: "idle",
        facing: Math.random() > 0.5 ? "right" : "left",
        animTime: Math.random() * 10,
        wanderCooldown: Math.random() * 2
      })
    }

    this.resize()
    window.addEventListener("resize", () => this.resize())
    this.animate()
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    this.renderer.dispose()
  },

  resize() {
    const rect = this.el.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1
    this.renderer.setSize(rect.width, rect.height)
    this.renderer.setPixelRatio(dpr)

    // Fit scene to viewport maintaining aspect ratio
    const viewAspect = rect.width / rect.height
    const sceneAspect = this.sceneWidth / this.sceneHeight

    if (viewAspect > sceneAspect) {
      // Viewport is wider — fit by height
      const half = this.sceneHeight / 2
      this.camera.top = half
      this.camera.bottom = -half
      this.camera.left = -half * viewAspect
      this.camera.right = half * viewAspect
    } else {
      // Viewport is taller — fit by width
      const half = this.sceneWidth / 2
      this.camera.left = -half
      this.camera.right = half
      this.camera.top = half / viewAspect
      this.camera.bottom = -half / viewAspect
    }
    this.camera.updateProjectionMatrix()
  },

  // Convert scene pixel coords (origin top-left, Y down)
  // to Three.js coords (origin center, Y up)
  s2t(x, y) {
    return {
      x: x - this.sceneWidth / 2,
      y: -(y - this.sceneHeight / 2)
    }
  },

  buildWalkmapOverlay() {
    if (!this.walkmap) return

    // Walk polygons — green lines, faint green fill
    for (const wp of (this.walkmap.walk_polygons || [])) {
      const pts3d = wp.vertices.map(v => {
        const t = this.s2t(v[0], v[1])
        return new THREE.Vector3(t.x, t.y, -5)
      })
      if (pts3d.length > 0) pts3d.push(pts3d[0].clone())

      // Line
      const lineGeo = new THREE.BufferGeometry().setFromPoints(pts3d)
      const lineMat = new THREE.LineBasicMaterial({ color: 0x00ff66, transparent: true, opacity: 0.35 })
      this.scene.add(new THREE.Line(lineGeo, lineMat))

      // Filled polygon (using ShapeGeometry)
      if (wp.vertices.length >= 3) {
        const shape = new THREE.Shape()
        for (let i = 0; i < wp.vertices.length; i++) {
          const t = this.s2t(wp.vertices[i][0], wp.vertices[i][1])
          if (i === 0) shape.moveTo(t.x, t.y)
          else shape.lineTo(t.x, t.y)
        }
        const fillGeo = new THREE.ShapeGeometry(shape)
        const fillMat = new THREE.MeshBasicMaterial({
          color: 0x00ff44, transparent: true, opacity: 0.08, side: THREE.DoubleSide
        })
        const fillMesh = new THREE.Mesh(fillGeo, fillMat)
        fillMesh.position.z = -5
        this.scene.add(fillMesh)
      }
    }

    // Blocked regions — red lines
    for (const br of (this.walkmap.blocked_regions || [])) {
      const pts3d = br.vertices.map(v => {
        const t = this.s2t(v[0], v[1])
        return new THREE.Vector3(t.x, t.y, -4)
      })
      if (pts3d.length > 0) pts3d.push(pts3d[0].clone())
      const lineGeo = new THREE.BufferGeometry().setFromPoints(pts3d)
      const lineMat = new THREE.LineBasicMaterial({ color: 0xff3300, transparent: true, opacity: 0.25 })
      this.scene.add(new THREE.Line(lineGeo, lineMat))
    }

    // Interactive objects — yellow spheres
    for (const obj of (this.walkmap.interactive_objects || [])) {
      const t = this.s2t(obj.x, obj.y)
      const geo = new THREE.SphereGeometry(12, 6, 4)
      const mat = new THREE.MeshBasicMaterial({ color: 0xffcc00, transparent: true, opacity: 0.4 })
      const mesh = new THREE.Mesh(geo, mat)
      mesh.position.set(t.x, t.y, -3)
      this.scene.add(mesh)
    }

    // Light sources — subtle orange spheres
    const lights = (this.walkmap.lighting || {}).light_sources || []
    for (const l of lights) {
      const t = this.s2t(l.x, l.y)
      const geo = new THREE.SphereGeometry(l.radius * 0.1, 8, 6)
      const mat = new THREE.MeshBasicMaterial({
        color: new THREE.Color(l.color || "#ffaa44"),
        transparent: true, opacity: 0.15
      })
      const mesh = new THREE.Mesh(geo, mat)
      mesh.position.set(t.x, t.y, -6)
      this.scene.add(mesh)
    }
  },

  makeLabel(text) {
    const canvas = document.createElement("canvas")
    canvas.width = 256
    canvas.height = 64
    const ctx = canvas.getContext("2d")
    ctx.font = "bold 28px monospace"
    ctx.textAlign = "center"
    ctx.strokeStyle = "#000"
    ctx.lineWidth = 4
    ctx.strokeText(text, 128, 40)
    ctx.fillStyle = "#fff"
    ctx.fillText(text, 128, 40)

    const tex = new THREE.CanvasTexture(canvas)
    const mat = new THREE.SpriteMaterial({ map: tex, transparent: true })
    const sprite = new THREE.Sprite(mat)
    sprite.scale.set(80, 20, 1)
    return sprite
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

  pickWanderTarget() {
    if (this.walkablePolygons.length === 0) return null
    const poly = this.walkablePolygons[Math.floor(Math.random() * this.walkablePolygons.length)]
    return this.randomPointInPolygon(poly.vertices)
  },

  updateCharacters(dt) {
    for (const c of this.characters) {
      if (c.state === "idle") {
        c.wanderCooldown -= dt
        if (c.wanderCooldown <= 0) {
          const target = this.pickWanderTarget()
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

      // Position in Three.js coords
      const t = this.s2t(c.x, c.y)
      c.group.position.set(t.x, t.y, 0)
      c.group.rotation.y = c.facing === "left" ? Math.PI : 0

      // Label above character
      c.label.position.set(t.x, t.y + 55, 1)

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

  animate() {
    const dt = this.clock.getDelta()
    this.updateCharacters(dt)
    this.renderer.render(this.scene, this.camera)
    this.rafId = requestAnimationFrame(() => this.animate())
  }
}

export default SceneView
