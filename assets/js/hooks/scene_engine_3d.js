// SceneEngine3D — Three.js renderer for pre-rendered RPG scenes
// with FF7-style primitive polygon characters
//
// Architecture:
// - Background: 2D plane textured with the Flux painting
// - Characters: hierarchical skeleton meshes from parametric definitions
// - Walk map: invisible collision polygons from Gemini extraction
// - Foreground: depth-sorted planes rendered in front of characters
// - Camera: orthographic, CRPG three-quarter perspective

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

const SceneEngine3D = {
  mounted() {
    this.el.innerHTML = ""
    this.clock = new THREE.Clock()

    // Scene dimensions from walkmap
    this.sceneWidth = 2048
    this.sceneHeight = 1376

    // Parse data from element
    try { this.walkmap = JSON.parse(this.el.dataset.walkmap) } catch(e) { this.walkmap = null }
    if (this.walkmap && this.walkmap.dimensions) {
      this.sceneWidth = this.walkmap.dimensions.width
      this.sceneHeight = this.walkmap.dimensions.height
    }
    this.regions = sceneRegionsFromState(this.walkmap || {})
    this.blockedRegions = blockedRegionsFromState(this.walkmap || {})

    // Three.js setup
    this.renderer = new THREE.WebGLRenderer({ antialias: false, alpha: true })
    this.renderer.setPixelRatio(window.devicePixelRatio)
    this.renderer.setClearColor(0x000000, 0)
    this.renderer.sortObjects = true
    this.el.appendChild(this.renderer.domElement)
    this.renderer.domElement.style.position = "absolute"
    this.renderer.domElement.style.top = "0"
    this.renderer.domElement.style.left = "0"
    this.renderer.domElement.style.pointerEvents = "none" // let canvas2d handle clicks

    this.scene = new THREE.Scene()

    // Orthographic camera — looking down at ~30° like a CRPG
    const aspect = this.sceneWidth / this.sceneHeight
    const frustum = this.sceneHeight / 2
    this.camera = new THREE.OrthographicCamera(
      -frustum * aspect, frustum * aspect,
      frustum, -frustum,
      -1000, 1000
    )
    this.camera.position.set(0, 0, 100)
    this.camera.lookAt(0, 0, 0)

    // Lighting — flat PS1 style
    const ambient = new THREE.AmbientLight(0xffffff, 0.7)
    this.scene.add(ambient)

    const dirLight = new THREE.DirectionalLight(0xffd080, 0.5)
    dirLight.position.set(1, 2, 1)
    this.scene.add(dirLight)

    // Build characters from definitions
    this.characters = []
    this.boneRefs = {} // name -> THREE.Group for animation

    const charDefs = [createCloud(), createLaraCroft()]
    const spawns = (this.walkmap && this.walkmap.spawn_points) || [
      { x: 600, y: 900, facing: "right" },
      { x: 900, y: 900, facing: "left" }
    ]

    for (let i = 0; i < charDefs.length; i++) {
      const def = charDefs[i]
      const fallbackSpawn = spawns[i % spawns.length]
      const spawn =
        randomWalkablePoint(this.regions, this.blockedRegions) || {
          x: fallbackSpawn.x,
          y: fallbackSpawn.y,
          region: regionAtPoint(this.regions, fallbackSpawn.x, fallbackSpawn.y, this.blockedRegions),
        }
      const boneMap = {}
      const group = this.buildSkeleton(def.skeleton, boneMap)

      const spawnRegion = spawn.region || this.regions[0] || null
      const scale = spawnRegion ? regionScaleAtPoint(spawnRegion, spawn.x, spawn.y) / def.height : 80 / def.height
      group.scale.set(scale, scale, scale)

      // Position in scene space — Y is inverted (screen coords: Y down, Three.js: Y up)
      const sx = spawn.x - this.sceneWidth / 2
      const sy = -(spawn.y - this.sceneHeight / 2)
      const depth = spawnRegion ? regionDepthAtPoint(spawnRegion, spawn.x, spawn.y) : 0
      group.position.set(sx, sy, depth * 0.8 + 0.4)

      this.scene.add(group)

      const char = {
        def,
        group,
        boneMap,
        x: spawn.x,
        y: spawn.y,
        regionId: spawnRegion?.id || null,
        target_x: null,
        target_y: null,
        target_region_id: null,
        state: "idle",
        facing: fallbackSpawn.facing || "right",
        animTime: Math.random() * 10,
        id: `char_${i}`
      }

      this.characters.push(char)
      this.boneRefs[def.name] = boneMap
    }

    // Show walkmap toggle
    this.showWalkmap = false
    this.walkmapMeshes = []

    // Handle resize
    this._resizeHandler = () => this.resize()
    window.addEventListener("resize", this._resizeHandler)
    this.resize()

    // Listen for camera updates from the 2D canvas engine
    this.handleEvent("camera-update", ({ x, y, zoom }) => {
      this.syncCamera(x, y, zoom)
    })

    // Listen for move events
    this.handleEvent("move-character", ({ id, x, y }) => {
      const char = this.characters.find(c => c.id === id)
      if (char) {
        char.target_x = x
        char.target_y = y
        char.target_region_id = regionAtPoint(this.regions, x, y, this.blockedRegions)?.id || char.regionId
        char.state = "walking"
      }
    })

    // Start
    this.animate()
  },

  updated() {
    const show = this.el.dataset.showWalkmap === "true"
    if (show !== this.showWalkmap) {
      this.showWalkmap = show
      this.updateWalkmapViz()
    }

    // Sync character state from server
    try {
      const serverChars = JSON.parse(this.el.dataset.characters)
      for (const sc of serverChars) {
        const c = this.characters.find(ch => ch.id === sc.id)
        if (c) {
          c.x = sc.x ?? c.x
          c.y = sc.y ?? c.y
          c.regionId = regionAtPoint(this.regions, c.x, c.y, this.blockedRegions)?.id || c.regionId

          if (sc.target_x != null) {
            c.target_x = sc.target_x
            c.target_y = sc.target_y
            c.target_region_id = regionAtPoint(this.regions, sc.target_x, sc.target_y, this.blockedRegions)?.id || c.regionId
            c.state = "walking"
          }
        }
      }
    } catch(e) {}
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    window.removeEventListener("resize", this._resizeHandler)
    this.renderer.dispose()
  },

  buildSkeleton(skeleton, boneMap) {
    const root = new THREE.Group()
    for (const [name, bone] of Object.entries(skeleton)) {
      const boneGroup = this.buildBone(name, bone, boneMap)
      root.add(boneGroup)
    }
    return root
  },

  buildBone(name, bone, boneMap) {
    const group = new THREE.Group()
    group.name = name

    // Position
    if (bone.position) {
      group.position.set(bone.position[0], bone.position[1], bone.position[2])
    }

    // Rotation
    if (bone.rotation) {
      group.rotation.set(bone.rotation[0], bone.rotation[1], bone.rotation[2])
    }

    // Store initial values for animation
    group.userData.basePosition = group.position.clone()
    group.userData.baseRotation = group.rotation.clone()

    // Create mesh for this bone's shape
    if (bone.shape) {
      const geo = this.createGeometry(bone.shape, bone.size)
      const mat = new THREE.MeshLambertMaterial({
        color: bone.color || 0x888888,
        flatShading: true // PS1 flat shading
      })
      const mesh = new THREE.Mesh(geo, mat)
      group.add(mesh)
    }

    // Store reference for animation
    boneMap[name] = group

    // Recurse children
    if (bone.children) {
      for (const [childName, childBone] of Object.entries(bone.children)) {
        const childGroup = this.buildBone(childName, childBone, boneMap)
        group.add(childGroup)
      }
    }

    return group
  },

  createGeometry(shape, size) {
    switch (shape) {
      case "box":
        return new THREE.BoxGeometry(size[0], size[1], size[2] || size[0])
      case "sphere":
        return new THREE.SphereGeometry(size[0], 6, 4) // Low poly sphere
      case "cylinder":
        return new THREE.CylinderGeometry(size[0], size[1], size[2], 6)
      case "cone":
        return new THREE.ConeGeometry(size[0], size[1], 6)
      default:
        return new THREE.BoxGeometry(1, 1, 1)
    }
  },

  // Interpolate between keyframes
  interpolateKeyframes(keyframes, t) {
    // t is normalized 0-1
    if (!keyframes || keyframes.length === 0) return null

    // Find surrounding keyframes
    let prev = keyframes[0]
    let next = keyframes[keyframes.length - 1]

    for (let i = 0; i < keyframes.length - 1; i++) {
      if (t >= keyframes[i].t && t <= keyframes[i + 1].t) {
        prev = keyframes[i]
        next = keyframes[i + 1]
        break
      }
    }

    // Lerp factor
    const range = next.t - prev.t
    const frac = range > 0 ? (t - prev.t) / range : 0

    // Interpolate rotation or position
    if (prev.rotation) {
      return {
        type: "rotation",
        value: [
          prev.rotation[0] + (next.rotation[0] - prev.rotation[0]) * frac,
          prev.rotation[1] + (next.rotation[1] - prev.rotation[1]) * frac,
          prev.rotation[2] + (next.rotation[2] - prev.rotation[2]) * frac
        ]
      }
    }
    if (prev.position) {
      return {
        type: "position",
        value: [
          prev.position[0] + (next.position[0] - prev.position[0]) * frac,
          prev.position[1] + (next.position[1] - prev.position[1]) * frac,
          prev.position[2] + (next.position[2] - prev.position[2]) * frac
        ]
      }
    }
    return null
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

      // Movement
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
          const speed = 120 * dt // pixels per second
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

      const region = regionAtPoint(this.regions, c.x, c.y, this.blockedRegions) || currentPlacement.region || this.regions[0]
      const scale = region ? regionScaleAtPoint(region, c.x, c.y) / c.def.height : 80 / c.def.height
      const depth = region ? regionDepthAtPoint(region, c.x, c.y) : 0
      // Update Three.js position (scene coords -> Three.js coords)
      const sx = c.x - this.sceneWidth / 2
      const sy = -(c.y - this.sceneHeight / 2)
      c.group.position.set(sx, sy, depth * 0.8 + 0.4)
      c.group.scale.set(scale, scale, scale)

      // Face direction
      c.group.rotation.y = c.facing === "left" ? Math.PI : 0

      // Apply skeleton animation
      this.applyAnimation(c, dt)
    }
  },

  syncCamera(x, y, zoom) {
    // Sync with the 2D canvas camera
    const frustum = this.sceneHeight / (2 * zoom)
    const aspect = this.el.clientWidth / this.el.clientHeight
    this.camera.left = -frustum * aspect
    this.camera.right = frustum * aspect
    this.camera.top = frustum
    this.camera.bottom = -frustum
    this.camera.position.set(
      x - this.sceneWidth / 2,
      -(y - this.sceneHeight / 2),
      100
    )
    this.camera.updateProjectionMatrix()
  },

  updateWalkmapViz() {
    // Remove old
    for (const m of this.walkmapMeshes) {
      this.scene.remove(m)
      m.geometry.dispose()
      m.material.dispose()
    }
    this.walkmapMeshes = []

    if (!this.showWalkmap || !this.walkmap) return

    // Walk regions — green wireframe
    for (const region of this.regions) {
      const points = region.polygon.map(v =>
        new THREE.Vector3(v[0] - this.sceneWidth/2, -(v[1] - this.sceneHeight/2), 5)
      )
      if (points.length > 0) points.push(points[0].clone()) // close loop
      const geo = new THREE.BufferGeometry().setFromPoints(points)
      const mat = new THREE.LineBasicMaterial({ color: 0x00ff00, transparent: true, opacity: 0.5 })
      const line = new THREE.Line(geo, mat)
      this.scene.add(line)
      this.walkmapMeshes.push(line)
    }

    // Blocked — red wireframe
    for (const b of this.blockedRegions) {
      const points = b.vertices.map(v =>
        new THREE.Vector3(v[0] - this.sceneWidth/2, -(v[1] - this.sceneHeight/2), 5)
      )
      if (points.length > 0) points.push(points[0].clone())
      const geo = new THREE.BufferGeometry().setFromPoints(points)
      const mat = new THREE.LineBasicMaterial({ color: 0xff0000, transparent: true, opacity: 0.5 })
      const line = new THREE.Line(geo, mat)
      this.scene.add(line)
      this.walkmapMeshes.push(line)
    }
  },

  resize() {
    const rect = this.el.getBoundingClientRect()
    this.renderer.setSize(rect.width, rect.height)
    const aspect = rect.width / rect.height
    const frustum = this.sceneHeight / 2
    this.camera.left = -frustum * aspect
    this.camera.right = frustum * aspect
    this.camera.top = frustum
    this.camera.bottom = -frustum
    this.camera.updateProjectionMatrix()
  },

  animate() {
    const dt = this.clock.getDelta()
    this.updateCharacters(dt)
    this.renderer.render(this.scene, this.camera)
    this.rafId = requestAnimationFrame(() => this.animate())
  }
}

export default SceneEngine3D
