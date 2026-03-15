// Quad-based walking plane math
// A quad is four screen-space points [tl, tr, br, bl] that define
// the projection of a rectangle in world space.
//
// reference_scale: pixel height of a 1.8m character at BL corner.
// grid_spacing: real-world meters between grid characters (default 2.5m).
// The scale at any UV position = reference_scale * localWidth / blWidth.

export function bilinearInterpolate(quad, u, v) {
  const [tl, tr, br, bl] = quad
  const topX = tl[0] + (tr[0] - tl[0]) * u
  const topY = tl[1] + (tr[1] - tl[1]) * u
  const botX = bl[0] + (br[0] - bl[0]) * u
  const botY = bl[1] + (br[1] - bl[1]) * u
  return {
    x: topX + (botX - topX) * v,
    y: topY + (botY - topY) * v
  }
}

export function quadWidthAtV(quad, v) {
  const [tl, tr, br, bl] = quad
  const topW = Math.sqrt((tr[0] - tl[0]) ** 2 + (tr[1] - tl[1]) ** 2)
  const botW = Math.sqrt((br[0] - bl[0]) ** 2 + (br[1] - bl[1]) ** 2)
  return topW + (botW - topW) * v
}

export function scaleAtV(quad, v) {
  const botWidth = quadWidthAtV(quad, 1.0)
  const localWidth = quadWidthAtV(quad, v)
  return botWidth > 0 ? localWidth / botWidth : 1
}

// Character pixel height at UV position given reference_scale at BL
export function charPixelHeight(quad, v, referenceScale) {
  return referenceScale * scaleAtV(quad, v)
}

// Inverse: screen point to UV via Newton
export function screenToUV(quad, sx, sy) {
  let u = 0.5, v = 0.5
  for (let iter = 0; iter < 20; iter++) {
    const p = bilinearInterpolate(quad, u, v)
    const dx = sx - p.x, dy = sy - p.y
    if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) break
    const eps = 0.001
    const pu = bilinearInterpolate(quad, u + eps, v)
    const pv = bilinearInterpolate(quad, u, v + eps)
    const dudx = (pu.x - p.x) / eps, dudy = (pu.y - p.y) / eps
    const dvdx = (pv.x - p.x) / eps, dvdy = (pv.y - p.y) / eps
    const det = dudx * dvdy - dvdx * dudy
    if (Math.abs(det) < 1e-10) break
    u += (dvdy * dx - dvdx * dy) / det
    v += (-dudy * dx + dudx * dy) / det
    u = Math.max(0, Math.min(1, u))
    v = Math.max(0, Math.min(1, v))
  }
  return { u, v }
}

export function pointInQuad(quad, sx, sy) {
  const uv = screenToUV(quad, sx, sy)
  const p = bilinearInterpolate(quad, uv.u, uv.v)
  const dist = Math.sqrt((p.x - sx) ** 2 + (p.y - sy) ** 2)
  return dist < 5 && uv.u >= -0.02 && uv.u <= 1.02 && uv.v >= -0.02 && uv.v <= 1.02
}

// Generate grid of character positions
// gridSpacing = meters between characters
// referenceScale = pixel height of 1.8m person at BL
// Returns array of { x, y, u, v, pixelHeight }
export function generateCharacterGrid(quad, rows, cols, referenceScale) {
  const points = []
  for (let r = 0; r <= rows; r++) {
    for (let c = 0; c <= cols; c++) {
      const u = c / cols
      const v = r / rows
      const p = bilinearInterpolate(quad, u, v)
      const h = charPixelHeight(quad, v, referenceScale)
      points.push({ x: p.x, y: p.y, u, v, pixelHeight: h })
    }
  }
  return points
}

// Grid lines for overlay
export function generateGridLines(quad, rows, cols) {
  const lines = []
  for (let r = 0; r <= rows; r++) {
    const v = r / rows
    const line = []
    for (let c = 0; c <= cols * 4; c++) {
      const u = c / (cols * 4)
      line.push(bilinearInterpolate(quad, u, v))
    }
    lines.push(line)
  }
  for (let c = 0; c <= cols; c++) {
    const u = c / cols
    const line = []
    for (let r = 0; r <= rows * 4; r++) {
      const v = r / (rows * 4)
      line.push(bilinearInterpolate(quad, u, v))
    }
    lines.push(line)
  }
  return lines
}

export default {
  bilinearInterpolate, quadWidthAtV, scaleAtV, charPixelHeight,
  screenToUV, pointInQuad, generateCharacterGrid, generateGridLines
}
