export const MIN_VERTEX_HEIGHT = 16
export const MAX_VERTEX_HEIGHT = 720
export const DEFAULT_VERTEX_HEIGHT = 72

export function midpoint(a, b) {
  return {
    x: (a[0] + b[0]) / 2,
    y: (a[1] + b[1]) / 2,
  }
}

export function polygonBounds(polygon) {
  if (!polygon.length) {
    return { minX: 0, minY: 0, maxX: 0, maxY: 0, width: 0, height: 0 }
  }

  let minX = Infinity
  let minY = Infinity
  let maxX = -Infinity
  let maxY = -Infinity

  for (const [x, y] of polygon) {
    minX = Math.min(minX, x)
    minY = Math.min(minY, y)
    maxX = Math.max(maxX, x)
    maxY = Math.max(maxY, y)
  }

  return {
    minX,
    minY,
    maxX,
    maxY,
    width: maxX - minX,
    height: maxY - minY,
  }
}

export function polygonCentroid(polygon) {
  if (!polygon.length) {
    return { x: 0, y: 0 }
  }

  let area = 0
  let cx = 0
  let cy = 0

  for (let i = 0; i < polygon.length; i++) {
    const [x1, y1] = polygon[i]
    const [x2, y2] = polygon[(i + 1) % polygon.length]
    const cross = x1 * y2 - x2 * y1
    area += cross
    cx += (x1 + x2) * cross
    cy += (y1 + y2) * cross
  }

  if (Math.abs(area) < 1e-6) {
    const total = polygon.reduce(
      (acc, [x, y]) => ({ x: acc.x + x, y: acc.y + y }),
      { x: 0, y: 0 },
    )

    return {
      x: total.x / polygon.length,
      y: total.y / polygon.length,
    }
  }

  const factor = 1 / (3 * area)
  return { x: cx * factor, y: cy * factor }
}

export function pointInPolygon(x, y, polygon) {
  let inside = false

  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const xi = polygon[i][0]
    const yi = polygon[i][1]
    const xj = polygon[j][0]
    const yj = polygon[j][1]

    if (((yi > y) !== (yj > y)) && (x < ((xj - xi) * (y - yi)) / (yj - yi) + xi)) {
      inside = !inside
    }
  }

  return inside
}

export function normalizePolygon(polygon) {
  return (polygon || []).map(([x, y]) => [Math.round(x), Math.round(y)])
}

export function projectPointToSegment(point, start, end) {
  const dx = end.x - start.x
  const dy = end.y - start.y
  const lengthSq = dx * dx + dy * dy

  if (lengthSq < 1e-6) {
    return {
      x: start.x,
      y: start.y,
      t: 0,
      distance: Math.hypot(point.x - start.x, point.y - start.y),
    }
  }

  const rawT = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSq
  const t = Math.max(0, Math.min(1, rawT))
  const x = start.x + dx * t
  const y = start.y + dy * t

  return {
    x,
    y,
    t,
    distance: Math.hypot(point.x - x, point.y - y),
  }
}

export function defaultVertexHeights(polygon, minHeight = 34, maxHeight = 92) {
  if (!polygon.length) return []

  const ys = polygon.map(([, y]) => y)
  const minY = Math.min(...ys)
  const maxY = Math.max(...ys)

  return polygon.map(([, y]) => {
    const t = maxY === minY ? 0.5 : (y - minY) / (maxY - minY)
    return Math.round(minHeight + (maxHeight - minHeight) * t)
  })
}

export function heightsFromDepthGuide(polygon, depth) {
  if (!polygon.length || !depth?.far || !depth?.near) return defaultVertexHeights(polygon)

  return polygon.map(([x, y]) => {
    const hit = projectPointToSegment({ x, y }, depth.far, depth.near)
    return Math.round(depth.far.height + (depth.near.height - depth.far.height) * hit.t)
  })
}

export function clampVertexHeight(value, fallback = DEFAULT_VERTEX_HEIGHT) {
  const numeric = Number(value)
  const resolved = Number.isFinite(numeric) ? numeric : fallback
  return Math.max(MIN_VERTEX_HEIGHT, Math.min(MAX_VERTEX_HEIGHT, Math.round(resolved)))
}

export function normalizeVertexHeights(polygon, vertexHeights, depth = null) {
  if (!polygon.length) return []

  let heights

  if (Array.isArray(vertexHeights) && vertexHeights.length === polygon.length) {
    heights = vertexHeights
  } else if (depth?.far && depth?.near) {
    heights = heightsFromDepthGuide(polygon, depth)
  } else if (Array.isArray(vertexHeights) && vertexHeights.length > 0) {
    const existing = vertexHeights.map((value) => Number(value)).filter((value) => Number.isFinite(value))
    const fallback =
      existing.length > 0 ? existing.reduce((sum, value) => sum + value, 0) / existing.length : 72

    heights = polygon.map((_, index) => existing[index] ?? fallback)
  } else {
    heights = defaultVertexHeights(polygon)
  }

  return heights.map((value) => clampVertexHeight(value))
}

export function insertVertexHeight(vertexHeights, insertIndex) {
  if (!vertexHeights.length) return [72]

  const previous = vertexHeights[(insertIndex - 1 + vertexHeights.length) % vertexHeights.length]
  const next = vertexHeights[insertIndex % vertexHeights.length]
  const value = Math.round((previous + next) / 2)

  return [...vertexHeights.slice(0, insertIndex), value, ...vertexHeights.slice(insertIndex)]
}

export function removeVertexHeight(vertexHeights, index) {
  return vertexHeights.filter((_, currentIndex) => currentIndex !== index)
}

export function vertexHeadPoint(region, index) {
  return {
    x: region.polygon[index][0],
    y: region.polygon[index][1] - region.vertexHeights[index],
  }
}

function inverseDistanceWeights(polygon, x, y) {
  const weights = []
  let sum = 0

  for (let index = 0; index < polygon.length; index++) {
    const [vx, vy] = polygon[index]
    const distance = Math.hypot(x - vx, y - vy)

    if (distance < 1e-3) {
      return polygon.map((_, currentIndex) => (currentIndex === index ? 1 : 0))
    }

    const weight = 1 / (distance * distance)
    weights.push(weight)
    sum += weight
  }

  return sum > 0 ? weights.map((weight) => weight / sum) : polygon.map(() => 1 / polygon.length)
}

function edgeBlendWeights(polygon, x, y, epsilon = 1e-3) {
  if (polygon.length < 2) return null

  const point = { x, y }

  for (let index = 0; index < polygon.length; index++) {
    const nextIndex = (index + 1) % polygon.length
    const start = { x: polygon[index][0], y: polygon[index][1] }
    const end = { x: polygon[nextIndex][0], y: polygon[nextIndex][1] }
    const hit = projectPointToSegment(point, start, end)

    if (hit.distance <= epsilon) {
      return polygon.map((_, currentIndex) => {
        if (currentIndex === index) return 1 - hit.t
        if (currentIndex === nextIndex) return hit.t
        return 0
      })
    }
  }

  return null
}

function meanValueWeights(polygon, x, y) {
  const count = polygon.length
  if (!count) return []
  if (count === 1) return [1]
  if (count === 2) return edgeBlendWeights(polygon, x, y, Infinity) || [0.5, 0.5]

  const edgeWeights = edgeBlendWeights(polygon, x, y)
  if (edgeWeights) return edgeWeights

  const vectors = polygon.map(([vx, vy]) => ({ x: vx - x, y: vy - y }))
  const distances = vectors.map((vector) => Math.hypot(vector.x, vector.y))

  for (let index = 0; index < distances.length; index++) {
    if (distances[index] < 1e-3) {
      return polygon.map((_, currentIndex) => (currentIndex === index ? 1 : 0))
    }
  }

  const halfAngleTangents = new Array(count).fill(0)

  for (let index = 0; index < count; index++) {
    const nextIndex = (index + 1) % count
    const current = vectors[index]
    const next = vectors[nextIndex]
    const cross = current.x * next.y - current.y * next.x
    const dot = current.x * next.x + current.y * next.y
    const denom = distances[index] * distances[nextIndex] + dot

    if (Math.abs(denom) < 1e-8) {
      return edgeBlendWeights(polygon, x, y, 0.5) || inverseDistanceWeights(polygon, x, y)
    }

    halfAngleTangents[index] = cross / denom
  }

  const weights = new Array(count).fill(0)
  let sum = 0

  for (let index = 0; index < count; index++) {
    const previous = halfAngleTangents[(index - 1 + count) % count]
    const next = halfAngleTangents[index]
    const weight = (previous + next) / distances[index]
    weights[index] = weight
    sum += weight
  }

  if (!Number.isFinite(sum) || Math.abs(sum) < 1e-8) {
    return inverseDistanceWeights(polygon, x, y)
  }

  return weights.map((weight) => weight / sum)
}

export function vertexWeightsAtPoint(polygon, x, y) {
  if (!polygon.length) return []

  const edgeWeights = edgeBlendWeights(polygon, x, y)
  if (edgeWeights) return edgeWeights

  if (!pointInPolygon(x, y, polygon)) {
    return inverseDistanceWeights(polygon, x, y)
  }

  return meanValueWeights(polygon, x, y)
}

export function regionScaleAtPoint(region, x, y) {
  const heights = normalizeVertexHeights(region.polygon, region.vertexHeights)

  if (!heights.length) return 72

  const weights = vertexWeightsAtPoint(region.polygon, x, y)
  return heights.reduce((total, height, index) => total + height * (weights[index] || 0), 0)
}

export function regionDepthAtPoint(region, x, y) {
  const heights = normalizeVertexHeights(region.polygon, region.vertexHeights)
  if (!heights.length) return 0.5

  const minHeight = Math.min(...heights)
  const maxHeight = Math.max(...heights)
  if (maxHeight <= minHeight) return 0.5

  const height = regionScaleAtPoint(region, x, y)
  return Math.max(0, Math.min(1, (height - minHeight) / (maxHeight - minHeight)))
}

export function randomPointInPolygon(polygon, fallback = polygonCentroid(polygon)) {
  if (!polygon.length) {
    return fallback
  }

  const bounds = polygonBounds(polygon)

  for (let attempt = 0; attempt < 120; attempt++) {
    const x = bounds.minX + Math.random() * bounds.width
    const y = bounds.minY + Math.random() * bounds.height

    if (pointInPolygon(x, y, polygon)) {
      return { x, y }
    }
  }

  return fallback
}

export function findNearestVertex(polygon, x, y, threshold = 18) {
  let best = null

  for (let index = 0; index < polygon.length; index++) {
    const [vx, vy] = polygon[index]
    const distance = Math.hypot(x - vx, y - vy)

    if (distance <= threshold && (!best || distance < best.distance)) {
      best = { index, distance, x: vx, y: vy }
    }
  }

  return best
}

export function findNearestEdge(polygon, x, y, threshold = 18) {
  if (polygon.length < 2) {
    return null
  }

  let best = null
  const point = { x, y }

  for (let index = 0; index < polygon.length; index++) {
    const startRaw = polygon[index]
    const endRaw = polygon[(index + 1) % polygon.length]
    const start = { x: startRaw[0], y: startRaw[1] }
    const end = { x: endRaw[0], y: endRaw[1] }
    const hit = projectPointToSegment(point, start, end)

    if (hit.distance <= threshold && (!best || hit.distance < best.distance)) {
      best = {
        index,
        insertIndex: index + 1,
        point: [Math.round(hit.x), Math.round(hit.y)],
        distance: hit.distance,
      }
    }
  }

  return best
}

export function nearestPointOnPolygon(polygon, x, y) {
  if (!polygon.length) return null

  let best = null
  const point = { x, y }

  for (let index = 0; index < polygon.length; index++) {
    const start = { x: polygon[index][0], y: polygon[index][1] }
    const end = { x: polygon[(index + 1) % polygon.length][0], y: polygon[(index + 1) % polygon.length][1] }
    const hit = projectPointToSegment(point, start, end)

    if (!best || hit.distance < best.distance) {
      best = { ...hit, index }
    }
  }

  return best
}

function movePointTowardCentroidInside(polygon, point, inset = 1) {
  if (pointInPolygon(point.x, point.y, polygon)) return point

  const centroid = polygonCentroid(polygon)
  const dx = centroid.x - point.x
  const dy = centroid.y - point.y
  const length = Math.hypot(dx, dy)

  if (length < 1e-6) return point

  for (const step of [inset, inset * 2, inset * 4, inset * 8]) {
    const candidate = {
      x: point.x + (dx / length) * step,
      y: point.y + (dy / length) * step,
    }

    if (pointInPolygon(candidate.x, candidate.y, polygon)) return candidate
  }

  return point
}

export function constrainPointToRegion(region, x, y, inset = 1) {
  if (!region?.polygon?.length) return { x, y }
  if (pointInPolygon(x, y, region.polygon)) return { x, y }

  const nearest = nearestPointOnPolygon(region.polygon, x, y)
  if (!nearest) return polygonCentroid(region.polygon)

  const nudged = movePointTowardCentroidInside(region.polygon, { x: nearest.x, y: nearest.y }, inset)
  return pointInPolygon(nudged.x, nudged.y, region.polygon) ? nudged : { x: nearest.x, y: nearest.y }
}

export function normalizeRegion(region, index = 0) {
  const polygon = normalizePolygon(region?.polygon || region?.vertices || region?.corners || [])
  const rawId = region?.id || `region_${index + 1}`

  return {
    id: rawId,
    label: region?.label || `Region ${String(rawId).replace(/^region_/, "")}`,
    surface: region?.surface || "stone",
    elevation: region?.elevation ?? 0,
    polygon,
    vertexHeights: normalizeVertexHeights(polygon, region?.vertex_heights || region?.vertexHeights, region?.depth),
  }
}

export function walkPolygonToRegion(walkPolygon, index = 0) {
  return normalizeRegion(
    {
      id: walkPolygon?.id || `walk_${index + 1}`,
      label: walkPolygon?.label || `Walk ${index + 1}`,
      surface: walkPolygon?.surface || "stone",
      elevation: walkPolygon?.elevation ?? 0,
      polygon: walkPolygon?.vertices || walkPolygon?.polygon || [],
      vertex_heights: walkPolygon?.vertex_heights || walkPolygon?.vertexHeights,
      depth: walkPolygon?.depth,
    },
    index,
  )
}

export function normalizeBlockedRegion(region, index = 0) {
  return {
    id: region?.id || `blocked_${index + 1}`,
    type: region?.type || "wall",
    vertices: normalizePolygon(region?.vertices || region?.polygon || []),
  }
}

export function sceneRegionsFromState(state = {}) {
  if (Array.isArray(state.regions) && state.regions.length > 0) {
    return state.regions.map((region, index) => normalizeRegion(region, index))
  }

  if (Array.isArray(state.planes) && state.planes.length > 0) {
    return state.planes.map((plane, index) => normalizeRegion(legacyPlaneToRegion(plane), index))
  }

  if (Array.isArray(state.walk_polygons) && state.walk_polygons.length > 0) {
    return state.walk_polygons.map((polygon, index) => walkPolygonToRegion(polygon, index))
  }

  return []
}

export function blockedRegionsFromState(state = {}) {
  return Array.isArray(state.blocked_regions)
    ? state.blocked_regions.map((region, index) => normalizeBlockedRegion(region, index))
    : []
}

export function pointInBlockedRegions(blockedRegions, x, y) {
  return blockedRegions.some((region) => pointInPolygon(x, y, region.vertices))
}

export function regionAtPoint(regions, x, y, blockedRegions = []) {
  if (pointInBlockedRegions(blockedRegions, x, y)) return null

  for (let index = regions.length - 1; index >= 0; index--) {
    const region = regions[index]
    if (pointInPolygon(x, y, region.polygon)) return region
  }

  return null
}

export function isPointWalkable(regions, blockedRegions, x, y) {
  return Boolean(regionAtPoint(regions, x, y, blockedRegions))
}

export function constrainPointToWalkableRegions(regions, blockedRegions = [], x, y, preferredRegionId = null) {
  const currentRegion = regionAtPoint(regions, x, y, blockedRegions)
  if (currentRegion) {
    return { x, y, region: currentRegion }
  }

  const preferredRegion = preferredRegionId ? regions.find((region) => region.id === preferredRegionId) : null
  const candidates = preferredRegion
    ? [preferredRegion, ...regions.filter((region) => region.id !== preferredRegion.id)]
    : regions

  let best = null

  for (const region of candidates) {
    let point = constrainPointToRegion(region, x, y)

    if (pointInBlockedRegions(blockedRegions, point.x, point.y)) {
      const centroid = polygonCentroid(region.polygon)
      point = constrainPointToRegion(region, (point.x + centroid.x) / 2, (point.y + centroid.y) / 2, 2)

      if (pointInBlockedRegions(blockedRegions, point.x, point.y)) continue
    }

    const distance = Math.hypot(point.x - x, point.y - y)
    if (!best || distance < best.distance) {
      best = { x: point.x, y: point.y, region, distance }
    }
  }

  if (best) return best

  if (preferredRegion) {
    const centroid = polygonCentroid(preferredRegion.polygon)
    return { x: centroid.x, y: centroid.y, region: preferredRegion }
  }

  return { x, y, region: null }
}

export function randomWalkablePoint(regions, blockedRegions = [], preferredRegionId = null) {
  if (!regions.length) return null

  const startIndex = preferredRegionId
    ? Math.max(
        0,
        regions.findIndex((region) => region.id === preferredRegionId),
      )
    : Math.floor(Math.random() * regions.length)

  for (let offset = 0; offset < regions.length; offset++) {
    const region = regions[(startIndex + offset) % regions.length]

    for (let attempt = 0; attempt < 80; attempt++) {
      const point = randomPointInPolygon(region.polygon)
      if (!pointInBlockedRegions(blockedRegions, point.x, point.y)) {
        return { ...point, region }
      }
    }
  }

  const fallbackRegion = preferredRegionId ? regions.find((region) => region.id === preferredRegionId) || regions[0] : regions[0]
  const fallbackPoint = constrainPointToWalkableRegions(
    regions,
    blockedRegions,
    polygonCentroid(fallbackRegion.polygon).x,
    polygonCentroid(fallbackRegion.polygon).y,
    fallbackRegion.id,
  )

  return fallbackPoint.region ? fallbackPoint : null
}

export function createDefaultRegion(dimensions, id) {
  const width = dimensions.width || 2048
  const height = dimensions.height || 1376
  const cx = width / 2
  const cy = height / 2
  const bounds = {
    x: width * 0.18,
    y: height * 0.14,
  }

  const polygon = [
    [Math.round(cx - bounds.x), Math.round(cy - bounds.y)],
    [Math.round(cx + bounds.x * 0.85), Math.round(cy - bounds.y * 1.05)],
    [Math.round(cx + bounds.x * 1.15), Math.round(cy + bounds.y * 0.15)],
    [Math.round(cx + bounds.x * 0.7), Math.round(cy + bounds.y * 1.15)],
    [Math.round(cx - bounds.x * 0.75), Math.round(cy + bounds.y * 1.25)],
    [Math.round(cx - bounds.x * 1.15), Math.round(cy + bounds.y * 0.2)],
  ]

  return {
    id,
    label: `Region ${id.replace(/^region_/, "")}`,
    surface: "stone",
    elevation: 0,
    polygon,
    vertex_heights: defaultVertexHeights(polygon),
  }
}

export function legacyPlaneToRegion(plane) {
  const polygon = plane.corners || []

  if (polygon.length === 4) {
    const far = midpoint(polygon[0], polygon[1])
    const near = midpoint(polygon[3], polygon[2])
    const topWidth = Math.hypot(polygon[1][0] - polygon[0][0], polygon[1][1] - polygon[0][1])
    const bottomWidth = Math.hypot(polygon[2][0] - polygon[3][0], polygon[2][1] - polygon[3][1])
    const ratio = bottomWidth > 0 ? Math.max(0.2, Math.min(0.95, topWidth / bottomWidth)) : 0.45
    const nearHeight = plane.reference_scale || 72

    return {
      id: plane.id,
      label: plane.label || `Region ${plane.id.replace(/^plane_/, "")}`,
      surface: plane.surface || "stone",
      elevation: plane.elevation || 0,
      polygon,
      vertex_heights: heightsFromDepthGuide(polygon, {
        far: { x: far.x, y: far.y, height: Math.round(nearHeight * ratio) },
        near: { x: near.x, y: near.y, height: nearHeight },
      }),
    }
  }

  return {
    id: plane.id,
    label: plane.label || `Region ${plane.id.replace(/^plane_/, "")}`,
    surface: plane.surface || "stone",
    elevation: plane.elevation || 0,
    polygon,
    vertex_heights: defaultVertexHeights(polygon),
  }
}
