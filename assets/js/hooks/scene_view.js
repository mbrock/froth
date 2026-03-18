// SceneView — pure Three.js game renderer
// Background as textured plane, characters as primitive skeletons,
// walk map as line geometry. One renderer, one coordinate system.

import * as THREE from "@/vendor/three.module.min.js"
import { createCloud, createLaraCroft } from "@/js/lib/primitive_characters.js"
import {
  blockedRegionsFromState,
  constrainPointToWalkableRegions,
  randomWalkablePoint,
  regionAtPoint,
  regionDepthAtPoint,
  regionScaleAtPoint,
  sceneRegionsFromState,
} from "@/js/lib/scene_regions.js"

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
    this.regions = sceneRegionsFromState(this.walkmap || {})
    this.blockedRegions = blockedRegionsFromState(this.walkmap || {})

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

    const charDefs = [createCloud(), createLaraCroft()]
    const starts = [
      { x: 600, y: 950 },
      { x: 1000, y: 1000 }
    ]

    for (let i = 0; i < charDefs.length; i++) {
      const def = charDefs[i]
      const spawn =
        randomWalkablePoint(this.regions, this.blockedRegions) || {
          x: starts[i].x,
          y: starts[i].y,
          region: regionAtPoint(this.regions, starts[i].x, starts[i].y, this.blockedRegions),
        }
      const boneMap = {}
      const group = this.buildSkeleton(def.skeleton, boneMap)
      const spawnRegion = spawn.region || this.regions[0] || null
      const scale = spawnRegion ? regionScaleAtPoint(spawnRegion, spawn.x, spawn.y) / def.height : 50 / def.height
      group.scale.set(scale, scale, scale)
      this.scene.add(group)

      // Name label as sprite
      const label = this.makeLabel(def.name)
      this.scene.add(label)

      this.characters.push({
        def, group, boneMap, label,
        x: spawn.x,
        y: spawn.y,
        regionId: spawnRegion?.id || null,
        target_x: null,
        target_y: null,
        target_region_id: null,
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

    // Walk regions — green lines, faint green fill
    for (const region of this.regions) {
      const pts3d = region.polygon.map((vertex) => {
        const t = this.s2t(vertex[0], vertex[1])
        return new THREE.Vector3(t.x, t.y, -5)
      })
      if (pts3d.length > 0) pts3d.push(pts3d[0].clone())

      const lineGeo = new THREE.BufferGeometry().setFromPoints(pts3d)
      const lineMat = new THREE.LineBasicMaterial({ color: 0x00ff66, transparent: true, opacity: 0.35 })
      this.scene.add(new THREE.Line(lineGeo, lineMat))

      if (region.polygon.length >= 3) {
        const shape = new THREE.Shape()
        for (let i = 0; i < region.polygon.length; i++) {
          const t = this.s2t(region.polygon[i][0], region.polygon[i][1])
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
    for (const br of this.blockedRegions) {
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

  pickWanderTarget() {
    return randomWalkablePoint(this.regions, this.blockedRegions)
  },

  updateCharacters(dt) {
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

      if (c.state === "idle") {
        c.wanderCooldown -= dt
        if (c.wanderCooldown <= 0) {
          const target = randomWalkablePoint(this.regions, this.blockedRegions, c.regionId)
          if (target) {
            c.target_x = target.x
            c.target_y = target.y
            c.target_region_id = target.region?.id || c.regionId
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
          c.target_region_id = null
          c.wanderCooldown = 1.5 + Math.random() * 3
        } else {
          const speed = 60 * dt
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
            c.wanderCooldown = 0.8 + Math.random() * 1.6
          }
        }
      }

      const region = regionAtPoint(this.regions, c.x, c.y, this.blockedRegions) || currentPlacement.region || this.regions[0]
      const scale = region ? regionScaleAtPoint(region, c.x, c.y) / c.def.height : 50 / c.def.height
      const depth = region ? regionDepthAtPoint(region, c.x, c.y) : 0
      // Position in Three.js coords
      const t = this.s2t(c.x, c.y)
      c.group.position.set(t.x, t.y, depth * 0.8 + 0.4)
      c.group.scale.set(scale, scale, scale)
      c.group.rotation.y = c.facing === "left" ? Math.PI : 0

      // Label above character
      c.label.position.set(t.x, t.y + scale * 22, depth * 0.8 + 0.5)
      c.label.scale.set(scale * 0.95, scale * 0.24, 1)

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
