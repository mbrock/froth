import * as THREE from "@/vendor/three.module.min.js"
import { Socket } from "phoenix"

import { createCloud, createLaraCroft } from "@/js/lib/primitive_characters.js"
import {
  MAX_VERTEX_HEIGHT,
  MIN_VERTEX_HEIGHT,
  blockedRegionsFromState,
  clampVertexHeight as clampSceneVertexHeight,
  constrainPointToWalkableRegions,
  createDefaultRegion,
  findNearestEdge,
  findNearestVertex,
  insertVertexHeight,
  legacyPlaneToRegion,
  normalizeBlockedRegion,
  normalizeVertexHeights,
  polygonCentroid,
  randomWalkablePoint,
  removeVertexHeight,
  regionAtPoint,
  regionDepthAtPoint,
  regionScaleAtPoint,
  sceneRegionsFromState,
  vertexHeadPoint,
} from "@/js/lib/scene_regions.js"

const CHAR_DEFS = { cloud: createCloud, lara: createLaraCroft }
const SURFACES = ["stone", "grass", "cobblestone", "dirt", "wood", "sand", "water"]
const HANDLE_RADIUS = 18

const SceneEditor = {
  mounted() {
    this.clock = new THREE.Clock()
    this.lastSeq = 0
    this.previewEnabled = true
    this.isSpacePressed = false
    this.selectedRegion = null
    this.pointerScene = { x: 0, y: 0 }
    this.hover = { vertex: null, edge: null, height: null, regionId: null }
    this.interaction = null
    this.charStates = {}

    this.state = {
      background: null,
      dimensions: { width: 2048, height: 1376 },
      regions: [],
      blockedRegions: [],
      characters: [],
    }

    this.view = {
      x: this.state.dimensions.width / 2,
      y: this.state.dimensions.height / 2,
      zoom: 1,
    }

    this.renderShell()
    this.cacheRefs()
    this.buildRenderer()
    this.bindUi()
    this.connectChannel()

    this.resize()
    this.updateStatus()
    this.animate()
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    window.removeEventListener("resize", this.boundResize)
    window.removeEventListener("mouseup", this.boundMouseUp)
    window.removeEventListener("keydown", this.boundKeyDown)
    window.removeEventListener("keyup", this.boundKeyUp)

    if (this.channel) this.channel.leave()
    if (this.socket) this.socket.disconnect()

    this.clearGroup(this.overlayGroup)
    this.clearGroup(this.guideGroup)
    this.clearGroup(this.handleGroup)
    this.clearGroup(this.charGroup)
    if (this.bgMesh) this.disposeObject(this.bgMesh)
    if (this.renderer) this.renderer.dispose()
  },

  renderShell() {
    this.el.innerHTML = `
      <div class="relative h-[100dvh] overflow-hidden bg-[radial-gradient(circle_at_top,_rgba(251,191,36,0.2),_transparent_38%),linear-gradient(180deg,_#1c1917_0%,_#09090b_100%)] text-stone-100">
        <div class="pointer-events-none absolute inset-0 opacity-35 [background-image:linear-gradient(rgba(255,255,255,0.04)_1px,transparent_1px),linear-gradient(90deg,rgba(255,255,255,0.04)_1px,transparent_1px)] [background-size:28px_28px]"></div>
        <div class="relative grid h-full min-h-0 grid-rows-[minmax(18rem,42dvh)_minmax(0,1fr)] lg:grid-cols-[24rem_minmax(0,1fr)] lg:grid-rows-1">
          <aside class="relative min-h-0 overflow-y-auto border-b border-white/10 bg-black/35 backdrop-blur-xl overscroll-contain lg:border-b-0 lg:border-r lg:border-white/10">
            <div class="absolute inset-x-0 top-0 h-40 bg-[radial-gradient(circle_at_top,_rgba(251,191,36,0.25),_transparent_60%)]"></div>
            <div class="relative flex h-full flex-col gap-6 p-5 lg:p-6">
              <div class="space-y-3">
                <div class="inline-flex items-center gap-2 rounded-full border border-amber-300/20 bg-amber-200/10 px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.3em] text-amber-100/80">
                  Scene Geometry
                </div>
                <div class="space-y-2">
                  <h1 class="font-serif text-3xl leading-tight text-stone-50">Walk regions and corner figures</h1>
                  <p class="max-w-sm text-sm leading-6 text-stone-300/80">
                    Define where characters can move as polygons, then size a reference person at each corner until the scene feels right.
                  </p>
                  <p class="max-w-sm text-xs leading-6 text-stone-400/80">
                    Each corner stores its own person height, and the walking scale inside the region is blended from those corner values.
                  </p>
                </div>
              </div>

              <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-1">
                <button data-action="add-region" class="group rounded-3xl border border-emerald-300/20 bg-emerald-300/10 px-4 py-4 text-left transition hover:border-emerald-200/50 hover:bg-emerald-300/15">
                  <div class="text-sm font-semibold text-emerald-100">Add walk region</div>
                  <div class="mt-1 text-xs leading-5 text-emerald-50/70">Creates a polygon with corner figures you can tune immediately.</div>
                </button>
                <button data-action="fit-view" class="group rounded-3xl border border-white/10 bg-white/5 px-4 py-4 text-left transition hover:border-white/30 hover:bg-white/10">
                  <div class="text-sm font-semibold text-stone-100">Fit entire scene</div>
                  <div class="mt-1 text-xs leading-5 text-stone-300/75">Reset pan and zoom around the full background.</div>
                </button>
                <button data-action="add-cloud" class="group rounded-3xl border border-sky-300/20 bg-sky-300/10 px-4 py-4 text-left transition hover:border-sky-200/50 hover:bg-sky-300/15">
                  <div class="text-sm font-semibold text-sky-100">Add Cloud preview</div>
                  <div class="mt-1 text-xs leading-5 text-sky-50/70">Drop a roaming character into the authored geometry.</div>
                </button>
                <button data-action="add-lara" class="group rounded-3xl border border-fuchsia-300/20 bg-fuchsia-300/10 px-4 py-4 text-left transition hover:border-fuchsia-200/50 hover:bg-fuchsia-300/15">
                  <div class="text-sm font-semibold text-fuchsia-100">Add Lara preview</div>
                  <div class="mt-1 text-xs leading-5 text-fuchsia-50/70">Compare silhouettes and perceived scale in motion.</div>
                </button>
              </div>

              <section class="rounded-[28px] border border-white/10 bg-white/5 p-4 shadow-[0_30px_80px_-45px_rgba(0,0,0,0.9)]">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <h2 class="text-sm font-semibold text-stone-100">Preview</h2>
                    <p class="text-xs leading-5 text-stone-300/75">Toggle animated characters and guide markers.</p>
                  </div>
                  <label class="inline-flex cursor-pointer items-center gap-2 rounded-full border border-white/10 bg-black/20 px-3 py-2 text-xs font-medium text-stone-200">
                    <input data-field="preview" type="checkbox" checked class="size-4 rounded border-white/20 bg-black/20 text-amber-300 focus:ring-amber-300" />
                    Live preview
                  </label>
                </div>
              </section>

              <section class="flex min-h-0 flex-1 flex-col rounded-[32px] border border-white/10 bg-black/20 shadow-[0_35px_120px_-50px_rgba(0,0,0,0.9)]">
                <div class="border-b border-white/10 px-5 py-4">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <h2 class="text-sm font-semibold text-stone-100">Regions</h2>
                      <p class="text-xs leading-5 text-stone-300/75">Select a region to edit its shape and calibrate the character size at each corner.</p>
                    </div>
                    <div data-role="scene-count" class="rounded-full border border-white/10 bg-white/5 px-3 py-1 text-[11px] uppercase tracking-[0.2em] text-stone-300/80">
                      0 regions
                    </div>
                  </div>
                </div>
                <div data-role="region-list" class="min-h-[12rem] flex-1 space-y-3 overflow-y-auto px-4 py-4"></div>
              </section>

              <section class="rounded-[32px] border border-white/10 bg-black/25 p-5 shadow-[0_35px_120px_-50px_rgba(0,0,0,0.9)]">
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <div class="text-[11px] font-semibold uppercase tracking-[0.3em] text-stone-400">Inspector</div>
                    <h2 data-role="inspector-title" class="mt-2 text-lg font-semibold text-stone-100">No region selected</h2>
                    <p data-role="inspector-copy" class="mt-1 text-sm leading-6 text-stone-300/75">
                      Select a region to rename it, adjust surface metadata, or tune the reference figure at each corner.
                    </p>
                  </div>
                  <button data-action="delete-region" class="rounded-full border border-rose-300/20 bg-rose-300/10 px-3 py-2 text-xs font-semibold text-rose-100 transition hover:border-rose-200/45 hover:bg-rose-300/15 disabled:cursor-not-allowed disabled:opacity-40" disabled>
                    Delete
                  </button>
                </div>

                  <div class="mt-5 grid gap-4">
                    <label class="grid gap-2 text-sm text-stone-200">
                      <span class="text-xs font-semibold uppercase tracking-[0.25em] text-stone-400">Label</span>
                      <input data-field="label" type="text" placeholder="Courtyard" disabled class="w-full rounded-2xl border border-white/10 bg-white/5 px-4 py-3 text-sm text-stone-100 outline-none transition placeholder:text-stone-500 focus:border-amber-300/40 focus:bg-white/10" />
                    </label>

                  <label class="grid gap-2 text-sm text-stone-200">
                    <span class="text-xs font-semibold uppercase tracking-[0.25em] text-stone-400">Surface</span>
                    <select data-field="surface" disabled class="w-full rounded-2xl border border-white/10 bg-white/5 px-4 py-3 text-sm text-stone-100 outline-none transition focus:border-amber-300/40 focus:bg-white/10">
                      ${SURFACES.map((surface) => `<option value="${surface}">${surface}</option>`).join("")}
                    </select>
                  </label>

                  <div class="grid gap-3 rounded-[24px] border border-white/10 bg-black/20 p-4">
                    <div class="flex items-center justify-between gap-3">
                      <div>
                        <div class="text-xs font-semibold uppercase tracking-[0.25em] text-stone-400">Corner Figures</div>
                        <p data-role="vertex-copy" class="mt-1 text-xs leading-5 text-stone-300/70">
                          Drag the top of a figure on the canvas or use the controls here for exact adjustments.
                        </p>
                      </div>
                      <div data-role="vertex-summary" class="rounded-full border border-white/10 bg-white/5 px-3 py-1 text-[11px] uppercase tracking-[0.2em] text-stone-300/80">
                        0 corners
                      </div>
                    </div>
                    <div data-role="vertex-heights" class="grid gap-3"></div>
                  </div>

                  <div class="grid gap-2">
                    <div class="flex items-center justify-between gap-3 text-xs font-semibold uppercase tracking-[0.25em] text-stone-400">
                      <span>Elevation</span>
                      <span data-role="elevation-value">0</span>
                    </div>
                    <input data-field="elevation" type="range" min="-10" max="10" value="0" disabled class="w-full accent-emerald-300" />
                  </div>
                </div>
              </section>

              <section class="rounded-[28px] border border-white/10 bg-black/20 p-4 text-xs leading-6 text-stone-300/75">
                <div class="font-semibold uppercase tracking-[0.3em] text-stone-400">Editing tips</div>
                <div class="mt-3 space-y-1">
                  <p>Left drag white points to reshape the polygon.</p>
                  <p>Each corner shows a reference person whose size you can tune directly.</p>
                  <p>Double click an edge to insert a corner. Alt-click a corner to remove it.</p>
                  <p>Hold space and drag to pan, or use middle mouse if you prefer.</p>
                  <p>Zoom is intentionally slower and only available through the buttons or a modifier-assisted wheel.</p>
                </div>
              </section>
            </div>
          </aside>

          <section class="relative min-h-0">
            <div class="absolute inset-0 bg-[radial-gradient(circle_at_top_right,_rgba(253,224,71,0.15),_transparent_30%),radial-gradient(circle_at_bottom_left,_rgba(56,189,248,0.12),_transparent_30%)]"></div>
            <div class="relative h-full p-4 lg:p-6">
              <div class="relative h-full min-h-0 overflow-hidden rounded-[34px] border border-white/10 bg-black/35 shadow-[0_50px_140px_-50px_rgba(0,0,0,0.95)]">
                <div class="pointer-events-none absolute inset-x-0 top-0 h-28 bg-[linear-gradient(180deg,_rgba(0,0,0,0.45),_transparent)]"></div>
                <div class="pointer-events-none absolute inset-0 opacity-20 [background-image:radial-gradient(circle_at_1px_1px,rgba(255,255,255,0.6)_1px,transparent_0)] [background-size:24px_24px]"></div>

                <div class="pointer-events-none absolute left-5 top-5 z-10 flex flex-wrap gap-2">
                  <div data-role="scene-size" class="rounded-full border border-white/10 bg-black/30 px-3 py-1 text-[11px] uppercase tracking-[0.2em] text-stone-200/80">
                    2048 x 1376
                  </div>
                  <div data-role="scene-zoom" class="rounded-full border border-white/10 bg-black/30 px-3 py-1 text-[11px] uppercase tracking-[0.2em] text-stone-200/80">
                    Zoom 100%
                  </div>
                </div>

                <div class="absolute right-5 top-5 z-10 flex items-center gap-2 rounded-full border border-white/10 bg-black/35 px-2 py-2 backdrop-blur-md">
                  <button data-action="zoom-out" class="rounded-full border border-white/10 bg-white/5 px-3 py-2 text-xs font-semibold text-stone-100 transition hover:border-white/30 hover:bg-white/10">
                    -
                  </button>
                  <button data-action="zoom-reset" class="rounded-full border border-white/10 bg-white/5 px-3 py-2 text-[11px] font-semibold uppercase tracking-[0.2em] text-stone-200 transition hover:border-white/30 hover:bg-white/10">
                    100%
                  </button>
                  <button data-action="zoom-in" class="rounded-full border border-white/10 bg-white/5 px-3 py-2 text-xs font-semibold text-stone-100 transition hover:border-white/30 hover:bg-white/10">
                    +
                  </button>
                </div>

                <div data-role="viewport" class="absolute inset-0"></div>

                <div class="absolute inset-x-4 bottom-4 z-10 rounded-full border border-white/10 bg-black/45 px-4 py-3 text-xs text-stone-200/80 backdrop-blur-md lg:inset-x-6">
                  <div data-role="status">Loading scene editor...</div>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    `
  },

  cacheRefs() {
    const query = (selector) => this.el.querySelector(selector)

    this.refs = {
      viewport: query("[data-role='viewport']"),
      status: query("[data-role='status']"),
      regionList: query("[data-role='region-list']"),
      sceneCount: query("[data-role='scene-count']"),
      sceneSize: query("[data-role='scene-size']"),
      sceneZoom: query("[data-role='scene-zoom']"),
      inspectorTitle: query("[data-role='inspector-title']"),
      inspectorCopy: query("[data-role='inspector-copy']"),
      vertexCopy: query("[data-role='vertex-copy']"),
      vertexSummary: query("[data-role='vertex-summary']"),
      vertexHeights: query("[data-role='vertex-heights']"),
      elevationValue: query("[data-role='elevation-value']"),
      deleteButton: query("[data-action='delete-region']"),
      labelInput: query("[data-field='label']"),
      surfaceInput: query("[data-field='surface']"),
      elevationInput: query("[data-field='elevation']"),
      previewToggle: query("[data-field='preview']"),
      actionButtons: [...this.el.querySelectorAll("[data-action]")],
    }
  },

  buildRenderer() {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
    this.renderer.setClearColor(0x000000, 0)
    this.renderer.setPixelRatio(window.devicePixelRatio || 1)
    this.renderer.domElement.className = "block size-full cursor-crosshair touch-none"
    this.refs.viewport.appendChild(this.renderer.domElement)

    this.scene = new THREE.Scene()
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, -1000, 1000)
    this.camera.position.set(0, 0, 100)
    this.camera.lookAt(0, 0, 0)

    this.scene.add(new THREE.AmbientLight(0xffffff, 0.8))
    const light = new THREE.DirectionalLight(0xfff2c1, 0.45)
    light.position.set(0.5, 1.2, 1)
    this.scene.add(light)

    this.overlayGroup = new THREE.Group()
    this.guideGroup = new THREE.Group()
    this.handleGroup = new THREE.Group()
    this.charGroup = new THREE.Group()

    this.scene.add(this.overlayGroup)
    this.scene.add(this.guideGroup)
    this.scene.add(this.handleGroup)
    this.scene.add(this.charGroup)

    this.boundResize = () => this.resize()
    this.boundMouseUp = (event) => this.onMouseUp(event)
    this.boundKeyDown = (event) => this.onKeyDown(event)
    this.boundKeyUp = (event) => this.onKeyUp(event)

    window.addEventListener("resize", this.boundResize)
    window.addEventListener("mouseup", this.boundMouseUp)
    window.addEventListener("keydown", this.boundKeyDown)
    window.addEventListener("keyup", this.boundKeyUp)

    this.renderer.domElement.addEventListener("mousedown", (event) => this.onMouseDown(event))
    this.renderer.domElement.addEventListener("mousemove", (event) => this.onMouseMove(event))
    this.renderer.domElement.addEventListener("wheel", (event) => this.onWheel(event), { passive: false })
    this.renderer.domElement.addEventListener("dblclick", (event) => this.onDoubleClick(event))
    this.renderer.domElement.addEventListener("contextmenu", (event) => event.preventDefault())
  },

  bindUi() {
    for (const button of this.refs.actionButtons) {
      button.addEventListener("click", () => this.handleAction(button.dataset.action))
    }

    this.refs.regionList.addEventListener("click", (event) => {
      const row = event.target.closest("[data-region-id]")
      if (!row) return
      this.selectRegion(row.dataset.regionId)
    })

    this.refs.previewToggle.addEventListener("change", () => {
      this.previewEnabled = this.refs.previewToggle.checked
      this.rebuildOverlay()
      this.updatePreviewVisibility()
    })

    this.refs.labelInput.addEventListener("input", () => {
      const region = this.selectedRegionRecord()
      if (!region) return
      region.label = this.refs.labelInput.value
      this.updateInspector(region)
      this.renderRegionList()
      this.rebuildOverlay()
    })

    this.refs.labelInput.addEventListener("change", () => {
      const region = this.selectedRegionRecord()
      if (!region) return
      this.emit("update_region", { id: region.id, label: region.label })
    })

    this.refs.surfaceInput.addEventListener("change", () => {
      const region = this.selectedRegionRecord()
      if (!region) return
      region.surface = this.refs.surfaceInput.value
      this.renderRegionList()
      this.emit("update_region", { id: region.id, surface: region.surface })
    })

    this.refs.vertexHeights.addEventListener("input", (event) => {
      const control = event.target.closest("[data-vertex-index]")
      if (!control || control.tagName === "BUTTON") return

      const region = this.selectedRegionRecord()
      if (!region) return

      const index = parseInt(control.dataset.vertexIndex, 10)
      const nextValue = this.readVertexHeightValue(control.value, region.vertexHeights[index])
      this.setVertexHeight(region, index, nextValue)
    })

    this.refs.vertexHeights.addEventListener("change", (event) => {
      const control = event.target.closest("[data-vertex-index]")
      if (!control || control.tagName === "BUTTON") return

      const region = this.selectedRegionRecord()
      if (!region) return

      const index = parseInt(control.dataset.vertexIndex, 10)
      const nextValue = this.readVertexHeightValue(control.value, region.vertexHeights[index])
      this.setVertexHeight(region, index, nextValue)
      this.commitVertexHeights(region)
    })

    this.refs.vertexHeights.addEventListener("click", (event) => {
      const button = event.target.closest("[data-vertex-nudge]")
      if (!button) return

      event.preventDefault()

      const region = this.selectedRegionRecord()
      if (!region) return

      const index = parseInt(button.dataset.vertexIndex, 10)
      const delta = parseInt(button.dataset.vertexNudge, 10)
      this.setVertexHeight(region, index, region.vertexHeights[index] + delta)
      this.commitVertexHeights(region)
    })

    this.refs.elevationInput.addEventListener("input", () => {
      const region = this.selectedRegionRecord()
      if (!region) return
      region.elevation = parseInt(this.refs.elevationInput.value, 10)
      this.updateInspector(region)
    })

    this.refs.elevationInput.addEventListener("change", () => {
      const region = this.selectedRegionRecord()
      if (!region) return
      this.emit("update_region", { id: region.id, elevation: region.elevation })
    })
  },

  connectChannel() {
    this.sceneId = this.el.dataset.sceneId || "default"
    this.bgUrl = this.el.dataset.bgUrl
    this.socket = new Socket("/froth/socket")
    this.socket.connect()

    this.channel = this.socket.channel(`scene:${this.sceneId}`, {})
    this.channel
      .join()
      .receive("ok", (response) => {
        this.state = this.migrateState(response.state)
        this.lastSeq = response.last_seq
        this.fitView(false)

        if (!this.state.background && this.bgUrl) {
          this.emit("set_background", { url: this.bgUrl })
        }

        this.rebuildScene()
      })

    this.channel.on("event", (event) => {
      this.lastSeq = event.seq
      this.applyEvent(event)
    })
  },

  migrateState(state) {
    const dimensions = state.dimensions || { width: 2048, height: 1376 }

    return {
      background: state.background || null,
      dimensions,
      regions: sceneRegionsFromState(state),
      blockedRegions: blockedRegionsFromState(state),
      characters: (state.characters || []).map((character) => ({
        id: character.id,
        type: character.type || "cloud",
        x: character.x ?? Math.round(dimensions.width / 2),
        y: character.y ?? Math.round(dimensions.height * 0.7),
      })),
    }
  },

  normalizeRegion(region) {
    const polygon = (region.polygon || region.vertices || []).map(([x, y]) => [
      Math.round(x),
      Math.round(y),
    ])
    const vertexHeights = normalizeVertexHeights(polygon, region.vertex_heights || region.vertexHeights, region.depth)

    return {
      id: region.id,
      label: region.label || `Region ${region.id.replace(/^region_/, "")}`,
      surface: region.surface || "stone",
      elevation: region.elevation ?? 0,
      polygon,
      vertexHeights,
    }
  },

  applyEvent(event) {
    const payload = event.payload

    switch (event.type) {
      case "set_background":
        this.state.background = payload.url
        this.loadBackground(payload.url)
        break

      case "add_region":
        this.upsertRegion({ ...payload, id: payload.id })
        break

      case "update_region":
        this.patchRegion(payload.id, payload)
        break

      case "remove_region":
        this.state.regions = this.state.regions.filter((region) => region.id !== payload.id)
        if (this.selectedRegion === payload.id) this.selectedRegion = null
        this.rebuildOverlay()
        this.renderRegionList()
        this.updateInspector()
        break

      case "add_plane":
        if (!this.state.regions.find((region) => region.id === payload.id)) {
          this.upsertRegion(legacyPlaneToRegion({ ...payload, id: payload.id }))
        }
        break

      case "update_plane":
        if (!this.state.regions.find((region) => region.id === payload.id)) {
          this.upsertRegion(legacyPlaneToRegion({ ...payload, id: payload.id }))
        }
        break

      case "remove_plane":
        this.state.regions = this.state.regions.filter((region) => region.id !== payload.id)
        if (this.selectedRegion === payload.id) this.selectedRegion = null
        this.rebuildOverlay()
        this.renderRegionList()
        this.updateInspector()
        break

      case "add_character":
        this.state.characters.push({
          id: payload.id,
          type: payload.type || "cloud",
          x: payload.x ?? Math.round(this.state.dimensions.width / 2),
          y: payload.y ?? Math.round(this.state.dimensions.height * 0.7),
        })
        this.rebuildCharacters()
        break

      case "add_blocked_region":
        this.state.blockedRegions.push(normalizeBlockedRegion(payload, this.state.blockedRegions.length))
        break

      case "remove_blocked_region":
        this.state.blockedRegions = this.state.blockedRegions.filter((region) => region.id !== payload.id)
        break

      default:
        break
    }
  },

  upsertRegion(region) {
    const next = this.normalizeRegion(region)
    const existing = this.state.regions.findIndex((item) => item.id === next.id)

    if (existing >= 0) {
      this.state.regions.splice(existing, 1, next)
    } else {
      this.state.regions.push(next)
    }

    this.selectedRegion = next.id
    this.rebuildOverlay()
    this.renderRegionList()
    this.updateInspector(next)
  },

  patchRegion(id, patch) {
    const region = this.state.regions.find((item) => item.id === id)
    if (!region) return

    if (patch.polygon) {
      region.polygon = patch.polygon.map(([x, y]) => [Math.round(x), Math.round(y)])
    }
    if (patch.label !== undefined) region.label = patch.label
    if (patch.surface !== undefined) region.surface = patch.surface
    if (patch.elevation !== undefined) region.elevation = patch.elevation

    region.vertexHeights = normalizeVertexHeights(
      region.polygon,
      patch.vertex_heights || patch.vertexHeights || region.vertexHeights,
      patch.depth,
    )

    this.rebuildOverlay()
    this.renderRegionList()
    this.updateInspector(this.selectedRegionRecord())
  },

  readVertexHeightValue(value, fallback = 72) {
    const parsed = parseInt(value, 10)
    return Number.isFinite(parsed) ? parsed : fallback
  },

  clampVertexHeight(value) {
    return clampSceneVertexHeight(value)
  },

  setVertexHeight(region, index, value) {
    if (!region || index < 0 || index >= region.vertexHeights.length) return

    region.vertexHeights[index] = this.clampVertexHeight(value)
    this.updateInspector(region)
    this.rebuildOverlay()
    this.renderRegionList()
  },

  commitVertexHeights(region) {
    if (!region) return
    this.emit("update_region", { id: region.id, vertex_heights: region.vertexHeights })
  },

  handleAction(action) {
    switch (action) {
      case "add-region":
        this.addRegion()
        break
      case "fit-view":
        this.fitView(true)
        break
      case "zoom-in":
        this.changeZoom(1.08)
        break
      case "zoom-out":
        this.changeZoom(1 / 1.08)
        break
      case "zoom-reset":
        this.fitView(true)
        break
      case "add-cloud":
        this.addCharacter("cloud")
        break
      case "add-lara":
        this.addCharacter("lara")
        break
      case "delete-region":
        this.deleteSelectedRegion()
        break
      default:
        break
    }
  },

  addRegion() {
    const id = `region_${Date.now()}`
    const region = createDefaultRegion(this.state.dimensions, id)
    this.selectedRegion = id
    this.emit("add_region", region)
  },

  addCharacter(type) {
    const id = `${type}_${Date.now()}`
    const dimensions = this.state.dimensions
    const fallbackRegion = this.selectedRegionRecord() || this.state.regions[0]
    const point =
      randomWalkablePoint(this.state.regions, this.state.blockedRegions, fallbackRegion?.id) || {
        x: dimensions.width / 2,
        y: dimensions.height * 0.7,
        region: fallbackRegion || null,
      }

    this.emit("add_character", {
      id,
      type,
      x: Math.round(point.x),
      y: Math.round(point.y),
    })
  },

  deleteSelectedRegion() {
    const region = this.selectedRegionRecord()
    if (!region) return

    this.selectedRegion = null
    this.emit("remove_region", { id: region.id })
    this.emit("remove_plane", { id: region.id })
  },

  selectedRegionRecord() {
    return this.state.regions.find((region) => region.id === this.selectedRegion) || null
  },

  selectRegion(regionId) {
    this.selectedRegion = regionId
    this.rebuildOverlay()
    this.renderRegionList()
    this.updateInspector(this.selectedRegionRecord())
  },

  renderRegionList() {
    this.refs.sceneCount.textContent = `${this.state.regions.length} region${this.state.regions.length === 1 ? "" : "s"}`
    this.refs.regionList.innerHTML = ""

    for (const region of this.state.regions) {
      const active = region.id === this.selectedRegion
      const heights = region.vertexHeights.length ? region.vertexHeights : [72]
      const row = document.createElement("button")
      row.type = "button"
      row.dataset.regionId = region.id
      row.className = [
        "group w-full rounded-[24px] border px-4 py-4 text-left transition",
        active
          ? "border-amber-300/45 bg-amber-300/12 shadow-[0_20px_60px_-40px_rgba(251,191,36,0.9)]"
          : "border-white/10 bg-white/5 hover:border-white/25 hover:bg-white/10",
      ].join(" ")

      row.innerHTML = `
        <div class="flex items-start justify-between gap-3">
          <div>
            <div class="text-sm font-semibold ${active ? "text-amber-50" : "text-stone-100"}">${this.escapeHtml(region.label)}</div>
            <div class="mt-1 text-xs uppercase tracking-[0.2em] ${active ? "text-amber-100/70" : "text-stone-400"}">${region.surface}</div>
          </div>
          <div class="rounded-full border ${active ? "border-amber-200/35 bg-amber-100/10 text-amber-50/80" : "border-white/10 bg-black/20 text-stone-300/70"} px-3 py-1 text-[11px] uppercase tracking-[0.2em]">
            ${region.polygon.length} pts
          </div>
        </div>
        <div class="mt-3 flex items-center gap-2 text-xs ${active ? "text-amber-50/80" : "text-stone-300/70"}">
          <span>${Math.min(...heights)}-${Math.max(...heights)} px</span>
          <span class="text-stone-500">/</span>
          <span>${region.vertexHeights.length} corners</span>
        </div>
      `

      this.refs.regionList.appendChild(row)
    }
  },

  updateInspector(region = this.selectedRegionRecord()) {
    const hasRegion = Boolean(region)

    this.refs.deleteButton.disabled = !hasRegion
    this.refs.labelInput.disabled = !hasRegion
    this.refs.surfaceInput.disabled = !hasRegion
    this.refs.elevationInput.disabled = !hasRegion

    if (!region) {
      this.refs.inspectorTitle.textContent = "No region selected"
      this.refs.inspectorCopy.textContent =
        "Select a region to rename it, adjust surface metadata, and set how tall the reference person should be at each corner."
      this.refs.labelInput.value = ""
      this.refs.surfaceInput.value = SURFACES[0]
      this.refs.elevationInput.value = "0"
      this.refs.vertexSummary.textContent = "0 corners"
      this.refs.vertexCopy.textContent =
        "The editor blends the corner figure heights across the region so walking characters inherit the size between them."
      this.refs.vertexHeights.innerHTML = ""
      this.refs.elevationValue.textContent = "0"
      return
    }

    this.refs.inspectorTitle.textContent = region.label
    this.refs.inspectorCopy.textContent =
      "Shape the polygon with corner handles, then size the person at each corner until the whole region feels believable."
    this.refs.labelInput.value = region.label
    this.refs.surfaceInput.value = region.surface
    this.refs.elevationInput.value = String(region.elevation)
    this.refs.vertexSummary.textContent = `${region.vertexHeights.length} corners`
    this.refs.vertexCopy.textContent =
      "Each numbered control matches the same numbered corner in the scene, and the in-between walking scale is blended automatically."
    this.refs.vertexHeights.innerHTML = region.vertexHeights
      .map(
        (height, index) => {
          const [x, y] = region.polygon[index]

          return `
            <div class="grid gap-3 rounded-[22px] border border-white/10 bg-white/[0.04] p-3">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <div class="text-xs font-semibold uppercase tracking-[0.22em] text-stone-400">Corner ${index + 1}</div>
                  <div class="mt-1 text-[11px] uppercase tracking-[0.2em] text-stone-500">${x}, ${y}</div>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    data-vertex-index="${index}"
                    data-vertex-nudge="-4"
                    class="rounded-full border border-white/10 bg-black/25 px-2.5 py-1.5 text-sm font-semibold text-stone-200 transition hover:border-white/25 hover:bg-white/10"
                  >
                    -
                  </button>
                  <input
                    data-vertex-index="${index}"
                    type="number"
                    min="${MIN_VERTEX_HEIGHT}"
                    max="${MAX_VERTEX_HEIGHT}"
                    step="1"
                    value="${Math.round(height)}"
                    class="w-20 rounded-2xl border border-white/10 bg-black/25 px-3 py-2 text-center text-sm text-stone-100 outline-none transition focus:border-amber-300/40 focus:bg-white/10"
                  />
                  <button
                    type="button"
                    data-vertex-index="${index}"
                    data-vertex-nudge="4"
                    class="rounded-full border border-white/10 bg-black/25 px-2.5 py-1.5 text-sm font-semibold text-stone-200 transition hover:border-white/25 hover:bg-white/10"
                  >
                    +
                  </button>
                </div>
              </div>
              <div class="flex items-center gap-3">
                <input
                  data-vertex-index="${index}"
                  type="range"
                  min="${MIN_VERTEX_HEIGHT}"
                  max="${MAX_VERTEX_HEIGHT}"
                  value="${Math.round(height)}"
                  class="w-full accent-amber-300"
                />
                <div class="min-w-14 text-right text-xs font-semibold uppercase tracking-[0.18em] text-stone-400">${Math.round(height)} px</div>
              </div>
            </div>
          `
        },
      )
      .join("")
    this.refs.elevationValue.textContent = `${region.elevation}`
  },

  updateStatus() {
    const region = this.selectedRegionRecord()
    const selectedText = region ? `${region.label} selected` : "No selection"
    this.refs.status.textContent = `${Math.round(this.pointerScene.x)}, ${Math.round(this.pointerScene.y)} | ${selectedText} | ${this.state.characters.length} preview characters`
    this.refs.sceneSize.textContent = `${this.state.dimensions.width} x ${this.state.dimensions.height}`
    this.refs.sceneZoom.textContent = `Zoom ${Math.round(this.view.zoom * 100)}%`
  },

  emit(type, payload) {
    if (this.channel) this.channel.push("event", { type, payload })
  },

  resize() {
    if (!this.renderer) return

    const rect = this.refs.viewport.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1

    this.renderer.setSize(rect.width, rect.height)
    this.renderer.setPixelRatio(dpr)

    const width = this.state.dimensions.width
    const height = this.state.dimensions.height
    const viewAspect = rect.width / Math.max(rect.height, 1)
    const sceneAspect = width / height

    if (viewAspect > sceneAspect) {
      const half = height / 2
      this.baseFrustum = {
        left: -half * viewAspect,
        right: half * viewAspect,
        top: half,
        bottom: -half,
      }
    } else {
      const half = width / 2
      this.baseFrustum = {
        left: -half,
        right: half,
        top: half / viewAspect,
        bottom: -half / viewAspect,
      }
    }

    this.applyCamera()
  },

  fitView(renderNow = true) {
    this.view = {
      x: this.state.dimensions.width / 2,
      y: this.state.dimensions.height / 2,
      zoom: 1,
    }

    this.applyCamera()
    if (renderNow) this.renderer.render(this.scene, this.camera)
  },

  changeZoom(multiplier) {
    this.view.zoom = Math.max(0.7, Math.min(3, this.view.zoom * multiplier))
    this.applyCamera()
  },

  clampView() {
    if (!this.baseFrustum) return

    const visibleWidth = (this.baseFrustum.right - this.baseFrustum.left) / this.view.zoom
    const visibleHeight = (this.baseFrustum.top - this.baseFrustum.bottom) / this.view.zoom
    const halfVisibleWidth = visibleWidth / 2
    const halfVisibleHeight = visibleHeight / 2
    const width = this.state.dimensions.width
    const height = this.state.dimensions.height

    const minX = halfVisibleWidth >= width / 2 ? width / 2 : halfVisibleWidth
    const maxX = halfVisibleWidth >= width / 2 ? width / 2 : width - halfVisibleWidth
    const minY = halfVisibleHeight >= height / 2 ? height / 2 : halfVisibleHeight
    const maxY = halfVisibleHeight >= height / 2 ? height / 2 : height - halfVisibleHeight

    this.view.x = Math.min(maxX, Math.max(minX, this.view.x))
    this.view.y = Math.min(maxY, Math.max(minY, this.view.y))
  },

  applyCamera() {
    if (!this.baseFrustum) return

    this.clampView()

    this.camera.left = this.baseFrustum.left
    this.camera.right = this.baseFrustum.right
    this.camera.top = this.baseFrustum.top
    this.camera.bottom = this.baseFrustum.bottom
    this.camera.zoom = this.view.zoom

    const offsetX = this.view.x - this.state.dimensions.width / 2
    const offsetY = -(this.view.y - this.state.dimensions.height / 2)

    this.camera.position.set(offsetX, offsetY, 100)
    this.camera.updateProjectionMatrix()
    this.updateStatus()
  },

  s2t(x, y) {
    return {
      x: x - this.state.dimensions.width / 2,
      y: -(y - this.state.dimensions.height / 2),
    }
  },

  screenToScene(clientX, clientY) {
    const rect = this.renderer.domElement.getBoundingClientRect()
    const nx = ((clientX - rect.left) / rect.width) * 2 - 1
    const ny = -((clientY - rect.top) / rect.height) * 2 + 1
    const vector = new THREE.Vector3(nx, ny, 0)
    vector.unproject(this.camera)

    return {
      x: vector.x + this.state.dimensions.width / 2,
      y: -vector.y + this.state.dimensions.height / 2,
    }
  },

  onKeyDown(event) {
    if (event.code !== "Space") return

    const target = event.target
    const editing =
      target instanceof HTMLElement &&
      (target.closest("input, textarea, select, button") || target.isContentEditable)

    if (editing) return

    this.isSpacePressed = true
    this.updateCursor()
  },

  onKeyUp(event) {
    if (event.code !== "Space") return
    this.isSpacePressed = false
    this.updateCursor()
  },

  onMouseDown(event) {
    const scenePoint = this.screenToScene(event.clientX, event.clientY)
    this.pointerScene = scenePoint
    this.updateStatus()

    if (event.button === 1 || (event.button === 0 && this.isSpacePressed)) {
      event.preventDefault()
      this.interaction = {
        type: "pan",
        startClientX: event.clientX,
        startClientY: event.clientY,
        startView: { ...this.view },
      }
      this.renderer.domElement.style.cursor = "grabbing"
      return
    }

    const region = this.selectedRegionRecord()

    if (event.altKey && region) {
      const hit = findNearestVertex(region.polygon, scenePoint.x, scenePoint.y, HANDLE_RADIUS)
      if (hit && region.polygon.length > 3) {
        region.polygon.splice(hit.index, 1)
        region.vertexHeights = removeVertexHeight(region.vertexHeights, hit.index)
        this.rebuildOverlay()
        this.updateInspector(region)
        this.emit("update_region", {
          id: region.id,
          polygon: region.polygon,
          vertex_heights: region.vertexHeights,
        })
        return
      }
    }

    const heightHit = this.hitHeightHandle(scenePoint)
    if (heightHit) {
      this.selectRegion(heightHit.regionId)
      this.interaction = {
        type: "height",
        regionId: heightHit.regionId,
        index: heightHit.index,
        startHeight: heightHit.height,
        startSceneY: scenePoint.y,
      }
      this.renderer.domElement.style.cursor = "grabbing"
      return
    }

    const vertexHit = this.hitVertex(scenePoint)
    if (vertexHit) {
      this.selectRegion(vertexHit.regionId)
      this.interaction = {
        type: "vertex",
        regionId: vertexHit.regionId,
        index: vertexHit.index,
      }
      this.renderer.domElement.style.cursor = "grabbing"
      return
    }

    const hitRegion = this.regionAt(scenePoint.x, scenePoint.y)
    if (hitRegion) {
      this.selectRegion(hitRegion.id)
      return
    }

    this.selectedRegion = null
    this.rebuildOverlay()
    this.renderRegionList()
    this.updateInspector()
    this.updateCursor()
  },

  onMouseMove(event) {
    const scenePoint = this.screenToScene(event.clientX, event.clientY)
    this.pointerScene = scenePoint
    this.updateStatus()

    if (!this.interaction) {
      this.hover = this.computeHover(scenePoint)
      this.updateCursor()
      return
    }

    if (this.interaction.type === "pan") {
      const dx = (event.clientX - this.interaction.startClientX) / this.view.zoom
      const dy = (event.clientY - this.interaction.startClientY) / this.view.zoom
      this.view.x = this.interaction.startView.x - dx
      this.view.y = this.interaction.startView.y - dy
      this.applyCamera()
      return
    }

    const region = this.state.regions.find((item) => item.id === this.interaction.regionId)
    if (!region) return

    if (this.interaction.type === "vertex") {
      region.polygon[this.interaction.index] = [Math.round(scenePoint.x), Math.round(scenePoint.y)]
      this.rebuildOverlay()
      this.updateInspector(region)
      this.renderRegionList()
      return
    }

    if (this.interaction.type === "height") {
      const delta = this.interaction.startSceneY - scenePoint.y
      this.setVertexHeight(region, this.interaction.index, this.interaction.startHeight + delta)
    }
  },

  onMouseUp() {
    if (!this.interaction) return

    const interaction = this.interaction
    this.interaction = null

    if (interaction.type === "vertex") {
      const region = this.state.regions.find((item) => item.id === interaction.regionId)
      if (region) {
        this.emit("update_region", { id: region.id, polygon: region.polygon })
      }
    }

    if (interaction.type === "height") {
      const region = this.state.regions.find((item) => item.id === interaction.regionId)
      if (region) {
        this.commitVertexHeights(region)
      }
    }

    this.hover = this.computeHover(this.pointerScene)
    this.updateCursor()
  },

  onDoubleClick(event) {
    if (event.button !== 0) return

    const region = this.selectedRegionRecord()
    if (!region) return

    const scenePoint = this.screenToScene(event.clientX, event.clientY)
    const edge = findNearestEdge(region.polygon, scenePoint.x, scenePoint.y, HANDLE_RADIUS)
    if (!edge) return

    region.polygon.splice(edge.insertIndex, 0, edge.point)
    region.vertexHeights = insertVertexHeight(region.vertexHeights, edge.insertIndex)
    this.rebuildOverlay()
    this.renderRegionList()
    this.updateInspector(region)
    this.emit("update_region", {
      id: region.id,
      polygon: region.polygon,
      vertex_heights: region.vertexHeights,
    })
  },

  onWheel(event) {
    if (!(event.ctrlKey || event.metaKey || event.altKey)) return

    event.preventDefault()
    this.changeZoom(event.deltaY > 0 ? 1 / 1.04 : 1.04)
  },

  computeHover(scenePoint) {
    const height = this.hitHeightHandle(scenePoint)
    if (height) return { height, vertex: null, edge: null, regionId: height.regionId }

    const vertex = this.hitVertex(scenePoint)
    if (vertex) return { height: null, vertex, edge: null, regionId: vertex.regionId }

    const region = this.selectedRegionRecord()
    const edge = region
      ? findNearestEdge(region.polygon, scenePoint.x, scenePoint.y, HANDLE_RADIUS)
      : null

    if (edge) {
      return { height: null, vertex: null, edge, regionId: region.id }
    }

    const hitRegion = this.regionAt(scenePoint.x, scenePoint.y)
    return { height: null, vertex: null, edge: null, regionId: hitRegion?.id || null }
  },

  hitVertex(scenePoint) {
    const selected = this.selectedRegionRecord()

    if (selected) {
      const hit = findNearestVertex(selected.polygon, scenePoint.x, scenePoint.y, HANDLE_RADIUS)
      if (hit) return { ...hit, regionId: selected.id }
    }

    for (const region of this.state.regions) {
      if (region.id === this.selectedRegion) continue
      const hit = findNearestVertex(region.polygon, scenePoint.x, scenePoint.y, 12)
      if (hit) return { ...hit, regionId: region.id }
    }

    return null
  },

  hitHeightHandle(scenePoint) {
    const region = this.selectedRegionRecord()
    if (!region) return null

    for (let index = 0; index < region.polygon.length; index++) {
      const point = vertexHeadPoint(region, index)
      if (Math.hypot(scenePoint.x - point.x, scenePoint.y - point.y) <= HANDLE_RADIUS) {
        return { index, regionId: region.id, height: region.vertexHeights[index] }
      }
    }

    return null
  },

  regionAt(x, y) {
    return regionAtPoint(this.state.regions, x, y, this.state.blockedRegions)
  },

  rebuildScene() {
    this.loadBackground(this.state.background)
    this.rebuildOverlay()
    this.rebuildCharacters()
    this.renderRegionList()
    this.updateInspector(this.selectedRegionRecord())
    this.resize()
  },

  loadBackground(url) {
    if (this.bgMesh) {
      this.scene.remove(this.bgMesh)
      this.disposeObject(this.bgMesh)
      this.bgMesh = null
    }

    if (!url) return

    new THREE.TextureLoader().load(url, (texture) => {
      texture.minFilter = THREE.LinearFilter
      texture.magFilter = THREE.LinearFilter

      const width = this.state.dimensions.width
      const height = this.state.dimensions.height
      const geometry = new THREE.PlaneGeometry(width, height)
      const material = new THREE.MeshBasicMaterial({ map: texture })
      const mesh = new THREE.Mesh(geometry, material)
      mesh.position.z = -10
      this.bgMesh = mesh
      this.scene.add(mesh)
    })
  },

  rebuildOverlay() {
    this.clearGroup(this.overlayGroup)
    this.clearGroup(this.guideGroup)
    this.clearGroup(this.handleGroup)

    for (const region of this.state.regions) {
      const active = region.id === this.selectedRegion
      this.drawPolygon(region, active)

      if (active) {
        this.drawReferenceFigures(region)
        this.drawHandles(region)
      } else {
        this.drawHandles(region, true)
      }
    }
  },

  drawPolygon(region, active) {
    if (region.polygon.length < 3) return

    const shape = new THREE.Shape()
    region.polygon.forEach(([x, y], index) => {
      const point = this.s2t(x, y)
      if (index === 0) shape.moveTo(point.x, point.y)
      else shape.lineTo(point.x, point.y)
    })

    const fill = new THREE.Mesh(
      new THREE.ShapeGeometry(shape),
      new THREE.MeshBasicMaterial({
        color: active ? 0xf59e0b : 0x22c55e,
        opacity: active ? 0.16 : 0.08,
        transparent: true,
        side: THREE.DoubleSide,
      }),
    )
    fill.position.z = -3.5
    this.overlayGroup.add(fill)

    const outlinePoints = [...region.polygon, region.polygon[0]].map(([x, y]) => {
      const point = this.s2t(x, y)
      return new THREE.Vector3(point.x, point.y, -3.25)
    })

    const outline = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints(outlinePoints),
      new THREE.LineBasicMaterial({
        color: active ? 0xfbbf24 : 0x34d399,
        opacity: active ? 0.95 : 0.45,
        transparent: true,
      }),
    )

    this.overlayGroup.add(outline)

    const centroid = polygonCentroid(region.polygon)
    const label = this.makeLabel(region.label, active ? "#fde68a" : "#bbf7d0", 196, 46)
    const labelPos = this.s2t(centroid.x, centroid.y)
    label.position.set(labelPos.x, labelPos.y + 18, -2.75)
    this.guideGroup.add(label)
  },

  drawReferenceFigures(region) {
    region.polygon.forEach(([x, y], index) => {
      const foot = this.s2t(x, y)
      const height = region.vertexHeights[index]
      const headTop = this.s2t(x, y - height)
      const headRadius = Math.max(6, Math.min(13, height * 0.12))
      const headCenter = this.s2t(x, y - height + headRadius)
      const shoulderY = y - height * 0.66
      const hipY = y - height * 0.38
      const handReach = Math.max(10, height * 0.16)
      const stride = Math.max(10, height * 0.12)
      const shoulder = this.s2t(x, shoulderY)
      const hips = this.s2t(x, hipY)
      const leftHand = this.s2t(x - handReach, shoulderY + height * 0.05)
      const rightHand = this.s2t(x + handReach, shoulderY + height * 0.05)
      const leftFoot = this.s2t(x - stride, y)
      const rightFoot = this.s2t(x + stride, y)
      const hoverHeight = this.hover.height?.regionId === region.id && this.hover.height.index === index
      const draggingHeight =
        this.interaction?.type === "height" &&
        this.interaction.regionId === region.id &&
        this.interaction.index === index
      const active = hoverHeight || draggingHeight

      const bodySegments = [
        [new THREE.Vector3(foot.x, foot.y, -2.78), new THREE.Vector3(headTop.x, headTop.y, -2.78)],
        [new THREE.Vector3(shoulder.x, shoulder.y, -2.7), new THREE.Vector3(hips.x, hips.y, -2.7)],
        [new THREE.Vector3(leftHand.x, leftHand.y, -2.7), new THREE.Vector3(rightHand.x, rightHand.y, -2.7)],
        [new THREE.Vector3(hips.x, hips.y, -2.7), new THREE.Vector3(leftFoot.x, leftFoot.y, -2.7)],
        [new THREE.Vector3(hips.x, hips.y, -2.7), new THREE.Vector3(rightFoot.x, rightFoot.y, -2.7)],
      ]

      for (const [start, finish] of bodySegments) {
        const line = new THREE.Line(
          new THREE.BufferGeometry().setFromPoints([start, finish]),
          new THREE.LineBasicMaterial({
            color: active ? 0xfbbf24 : 0xe7e5e4,
            opacity: active ? 0.98 : 0.74,
            transparent: true,
          }),
        )
        this.guideGroup.add(line)
      }

      const rulerHandle = new THREE.Mesh(
        new THREE.CircleGeometry(active ? 5 : 4, 18),
        new THREE.MeshBasicMaterial({
          color: active ? 0xfbbf24 : 0xf8fafc,
          opacity: 0.98,
          transparent: true,
        }),
      )
      rulerHandle.position.set(headTop.x, headTop.y, -2.66)
      this.guideGroup.add(rulerHandle)

      const head = new THREE.Mesh(
        new THREE.CircleGeometry(headRadius, 22),
        new THREE.MeshBasicMaterial({
          color: active ? 0xfbbf24 : 0xffffff,
          opacity: 0.9,
          transparent: true,
        }),
      )
      head.position.set(headCenter.x, headCenter.y, -2.65)
      this.guideGroup.add(head)

      const footMarker = new THREE.Line(
        new THREE.BufferGeometry().setFromPoints([
          new THREE.Vector3(foot.x - 7, foot.y, -2.65),
          new THREE.Vector3(foot.x + 7, foot.y, -2.65),
        ]),
        new THREE.LineBasicMaterial({
          color: 0x94a3b8,
          opacity: 0.55,
          transparent: true,
        }),
      )
      this.guideGroup.add(footMarker)

      const label = this.makeLabel(`${index + 1}: ${Math.round(height)}px`, active ? "#fde68a" : "#e7e5e4", 126, 28)
      label.position.set(headTop.x, headTop.y + 18, -2.6)
      this.guideGroup.add(label)
    })
  },

  drawHandles(region, dim = false) {
    region.polygon.forEach(([x, y], index) => {
      const point = this.s2t(x, y)
      const handle = new THREE.Mesh(
        new THREE.CircleGeometry(dim ? 6 : 9, 18),
        new THREE.MeshBasicMaterial({
          color: dim ? 0x86efac : 0xffffff,
          opacity: dim ? 0.5 : 0.92,
          transparent: true,
        }),
      )
      handle.position.set(point.x, point.y, -2.2)
      this.handleGroup.add(handle)

      if (!dim) {
        const label = this.makeLabel(String(index + 1), "#ffffff", 40, 28)
        label.position.set(point.x, point.y + 18, -2.1)
        this.handleGroup.add(label)
      }
    })

  },

  rebuildCharacters() {
    this.clearGroup(this.charGroup)
    this.charStates = {}

    for (const character of this.state.characters) {
      const factory = CHAR_DEFS[character.type]
      if (!factory) continue

      const def = factory()
      const boneMap = {}
      const group = this.buildSkeleton(def.skeleton, boneMap)
      const label = this.makeLabel(def.name, "#ffffff", 220, 54)

      this.charGroup.add(group)
      this.charGroup.add(label)

      this.charStates[character.id] = {
        id: character.id,
        def,
        boneMap,
        group,
        label,
        x: character.x,
        y: character.y,
        regionId: this.regionAt(character.x, character.y)?.id || this.state.regions[0]?.id || null,
        targetX: null,
        targetY: null,
        targetRegionId: null,
        state: "idle",
        facing: Math.random() > 0.5 ? "right" : "left",
        animTime: Math.random() * 10,
        wanderCooldown: 0.8 + Math.random() * 2.4,
      }
    }

    this.updatePreviewVisibility()
  },

  updatePreviewVisibility() {
    this.charGroup.visible = this.previewEnabled
  },

  updateCharacters(dt) {
    if (!this.previewEnabled) return

    const regions = this.state.regions
    if (!regions.length) return
    const blockedRegions = this.state.blockedRegions

    for (const character of Object.values(this.charStates)) {
      const currentPlacement = constrainPointToWalkableRegions(
        regions,
        blockedRegions,
        character.x,
        character.y,
        character.regionId,
      )
      character.x = currentPlacement.x
      character.y = currentPlacement.y
      character.regionId = currentPlacement.region?.id || character.regionId

      if (character.state === "idle") {
        character.wanderCooldown -= dt
        if (character.wanderCooldown <= 0) {
          const target = randomWalkablePoint(regions, blockedRegions, character.regionId)

          if (target) {
            character.targetX = target.x
            character.targetY = target.y
            character.targetRegionId = target.region?.id || character.regionId
            character.state = "walking"
          }

          character.wanderCooldown = 1.5 + Math.random() * 2.5
        }
      }

      if (character.state === "walking" && character.targetX != null && character.targetY != null) {
        const dx = character.targetX - character.x
        const dy = character.targetY - character.y
        const distance = Math.hypot(dx, dy)

        if (distance < 5) {
          character.state = "idle"
          character.targetX = null
          character.targetY = null
          character.targetRegionId = null
        } else {
          const speed = 90 * dt
          const nextX = character.x + (dx / distance) * speed
          const nextY = character.y + (dy / distance) * speed
          const nextPlacement = constrainPointToWalkableRegions(
            regions,
            blockedRegions,
            nextX,
            nextY,
            character.targetRegionId || character.regionId,
          )
          const hitBoundary = Math.hypot(nextPlacement.x - nextX, nextPlacement.y - nextY) > 0.75

          character.x = nextPlacement.x
          character.y = nextPlacement.y
          character.regionId = nextPlacement.region?.id || character.regionId
          character.facing = dx < 0 ? "left" : "right"

          if (hitBoundary) {
            character.state = "idle"
            character.targetX = null
            character.targetY = null
            character.targetRegionId = null
            character.wanderCooldown = 0.9 + Math.random() * 1.5
          }
        }
      }

      const region = this.regionAt(character.x, character.y) || currentPlacement.region || regions[0]
      const scale = region ? regionScaleAtPoint(region, character.x, character.y) / character.def.height : 3.5
      const depth = region ? regionDepthAtPoint(region, character.x, character.y) : 0
      const point = this.s2t(character.x, character.y)

      character.group.position.set(point.x, point.y, depth * 0.8 + 0.4)
      character.group.scale.set(scale, scale, scale)
      character.group.rotation.y = character.facing === "left" ? Math.PI : 0

      character.label.position.set(point.x, point.y + scale * 22, depth * 0.8 + 0.5)
      character.label.scale.set(scale * 0.95, scale * 0.24, 1)

      this.applyBoneAnimation(character, dt)
    }
  },

  applyBoneAnimation(character, dt) {
    const animationName = character.state === "walking" ? "walk" : "idle"
    const animation = character.def.animations[animationName]
    if (!animation) return

    character.animTime += dt
    const t = (character.animTime % animation.duration) / animation.duration

    for (const [boneName, keyframes] of Object.entries(animation.keyframes)) {
      const bone = character.boneMap[boneName]
      if (!bone) continue

      const next = this.interpolateKeyframes(keyframes, t)
      if (!next) continue

      if (next.type === "rotation") {
        bone.rotation.set(
          bone.userData.baseRotation.x + next.value[0],
          bone.userData.baseRotation.y + next.value[1],
          bone.userData.baseRotation.z + next.value[2],
        )
      } else {
        bone.position.set(next.value[0], next.value[1], next.value[2])
      }
    }
  },

  interpolateKeyframes(keyframes, t) {
    if (!keyframes?.length) return null

    let previous = keyframes[0]
    let next = keyframes[keyframes.length - 1]

    for (let index = 0; index < keyframes.length - 1; index++) {
      if (t >= keyframes[index].t && t <= keyframes[index + 1].t) {
        previous = keyframes[index]
        next = keyframes[index + 1]
        break
      }
    }

    const range = next.t - previous.t
    const factor = range > 0 ? (t - previous.t) / range : 0

    if (previous.rotation) {
      return {
        type: "rotation",
        value: previous.rotation.map((value, index) => value + (next.rotation[index] - value) * factor),
      }
    }

    if (previous.position) {
      return {
        type: "position",
        value: previous.position.map((value, index) => value + (next.position[index] - value) * factor),
      }
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
      const mesh = new THREE.Mesh(
        this.createGeometry(bone.shape, bone.size),
        new THREE.MeshLambertMaterial({
          color: bone.color || 0x888888,
          flatShading: true,
        }),
      )
      group.add(mesh)
    }

    boneMap[name] = group

    if (bone.children) {
      for (const [childName, childBone] of Object.entries(bone.children)) {
        group.add(this.buildBone(childName, childBone, boneMap))
      }
    }

    return group
  },

  createGeometry(shape, size) {
    switch (shape) {
      case "box":
        return new THREE.BoxGeometry(size[0], size[1], size[2] || size[0])
      case "sphere":
        return new THREE.SphereGeometry(size[0], 6, 4)
      case "cylinder":
        return new THREE.CylinderGeometry(size[0], size[1], size[2], 6)
      case "cone":
        return new THREE.ConeGeometry(size[0], size[1], 6)
      default:
        return new THREE.BoxGeometry(1, 1, 1)
    }
  },

  makeLabel(text, fill = "#ffffff", width = 180, height = 44) {
    const canvas = document.createElement("canvas")
    canvas.width = width
    canvas.height = height

    const ctx = canvas.getContext("2d")
    ctx.font = "600 22px ui-monospace, SFMono-Regular, monospace"
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.strokeStyle = "rgba(0, 0, 0, 0.85)"
    ctx.lineWidth = 6
    ctx.strokeText(text, width / 2, height / 2)
    ctx.fillStyle = fill
    ctx.fillText(text, width / 2, height / 2)

    const texture = new THREE.CanvasTexture(canvas)
    const material = new THREE.SpriteMaterial({ map: texture, transparent: true })
    const sprite = new THREE.Sprite(material)
    sprite.scale.set(width * 0.36, height * 0.36, 1)
    return sprite
  },

  updateCursor() {
    if (this.interaction) {
      this.renderer.domElement.style.cursor = this.interaction.type === "pan" ? "grabbing" : "grabbing"
      return
    }

    if (this.hover.height) {
      this.renderer.domElement.style.cursor = "ns-resize"
      return
    }

    if (this.hover.vertex) {
      this.renderer.domElement.style.cursor = "grab"
      return
    }

    if (this.hover.edge) {
      this.renderer.domElement.style.cursor = "copy"
      return
    }

    if (this.hover.regionId) {
      this.renderer.domElement.style.cursor = "pointer"
      return
    }

    if (this.isSpacePressed) {
      this.renderer.domElement.style.cursor = "grab"
      return
    }

    this.renderer.domElement.style.cursor = "crosshair"
  },

  disposeObject(object) {
    object.traverse((child) => {
      if (child.geometry) child.geometry.dispose()

      if (child.material) {
        const materials = Array.isArray(child.material) ? child.material : [child.material]
        for (const material of materials) {
          for (const value of Object.values(material)) {
            if (value?.isTexture) value.dispose()
          }
          material.dispose()
        }
      }
    })
  },

  clearGroup(group) {
    while (group.children.length > 0) {
      const child = group.children[0]
      group.remove(child)
      this.disposeObject(child)
    }
  },

  escapeHtml(value) {
    return value
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  },

  animate() {
    const dt = this.clock.getDelta()
    this.updateCharacters(dt)
    this.renderer.render(this.scene, this.camera)
    this.rafId = requestAnimationFrame(() => this.animate())
  },
}

export default SceneEditor
