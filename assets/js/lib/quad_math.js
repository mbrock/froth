// Quad-based walking plane math
// A quad is four screen-space points [tl, tr, br, bl] that define
// the projection of a rectangle in world space.
//
// Bilinear interpolation maps UV (0-1, 0-1) to screen position.
// The character's scale at any point is derived from the local
// width of the quad at that V coordinate.

export function bilinearInterpolate(quad, u, v) {
  // quad = [tl, tr, br, bl] where each is [x, y]
  const [tl, tr, br, bl] = quad

  // Top edge at v, bottom edge at v
  const topX = tl[0] + (tr[0] - tl[0]) * u
  const topY = tl[1] + (tr[1] - tl[1]) * u
  const botX = bl[0] + (br[0] - bl[0]) * u
  const botY = bl[1] + (br[1] - bl[1]) * u

  // Interpolate between top and bottom
  return {
    x: topX + (botX - topX) * v,
    y: topY + (botY - topY) * v
  }
}

export function quadWidthAtV(quad, v) {
  const [tl, tr, br, bl] = quad
  // Width of top edge
  const topW = Math.sqrt((tr[0] - tl[0]) ** 2 + (tr[1] - tl[1]) ** 2)
  // Width of bottom edge
  const botW = Math.sqrt((br[0] - bl[0]) ** 2 + (br[1] - bl[1]) ** 2)
  return topW + (botW - topW) * v
}

export function quadHeightAtU(quad, u) {
  const [tl, tr, br, bl] = quad
  const topX = tl[0] + (tr[0] - tl[0]) * u
  const topY = tl[1] + (tr[1] - tl[1]) * u
  const botX = bl[0] + (br[0] - bl[0]) * u
  const botY = bl[1] + (br[1] - bl[1]) * u
  return Math.sqrt((botX - topX) ** 2 + (botY - topY) ** 2)
}

// Scale factor: how big should a character be at this V position?
// Normalized so v=1 (bottom/foreground) = 1.0
export function scaleAtV(quad, v) {
  const botWidth = quadWidthAtV(quad, 1.0)
  const localWidth = quadWidthAtV(quad, v)
  return botWidth > 0 ? localWidth / botWidth : 1
}

// Inverse: given a screen point, find UV coordinates
// Uses iterative Newton's method on the bilinear system
export function screenToUV(quad, sx, sy) {
  // Start with a guess
  let u = 0.5, v = 0.5
  for (let iter = 0; iter < 20; iter++) {
    const p = bilinearInterpolate(quad, u, v)
    const dx = sx - p.x
    const dy = sy - p.y
    if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) break

    // Jacobian: dp/du, dp/dv
    const eps = 0.001
    const pu = bilinearInterpolate(quad, u + eps, v)
    const pv = bilinearInterpolate(quad, u, v + eps)
    const dudx = (pu.x - p.x) / eps
    const dudy = (pu.y - p.y) / eps
    const dvdx = (pv.x - p.x) / eps
    const dvdy = (pv.y - p.y) / eps

    // Solve 2x2 system
    const det = dudx * dvdy - dvdx * dudy
    if (Math.abs(det) < 1e-10) break
    u += (dvdy * dx - dvdx * dy) / det
    v += (-dudy * dx + dudx * dy) / det

    u = Math.max(0, Math.min(1, u))
    v = Math.max(0, Math.min(1, v))
  }
  return { u, v }
}

// Check if a screen point is inside the quad
export function pointInQuad(quad, sx, sy) {
  const uv = screenToUV(quad, sx, sy)
  // Verify by forward mapping
  const p = bilinearInterpolate(quad, uv.u, uv.v)
  const dist = Math.sqrt((p.x - sx) ** 2 + (p.y - sy) ** 2)
  return dist < 5 && uv.u >= -0.02 && uv.u <= 1.02 && uv.v >= -0.02 && uv.v <= 1.02
}

// Generate a grid of points for debug visualization
export function generateGrid(quad, rows, cols) {
  const points = []
  for (let r = 0; r <= rows; r++) {
    for (let c = 0; c <= cols; c++) {
      const u = c / cols
      const v = r / rows
      const p = bilinearInterpolate(quad, u, v)
      const s = scaleAtV(quad, v)
      points.push({ x: p.x, y: p.y, u, v, scale: s })
    }
  }
  return points
}

// Generate grid lines for debug overlay
export function generateGridLines(quad, rows, cols) {
  const lines = []
  // Horizontal lines (constant v)
  for (let r = 0; r <= rows; r++) {
    const v = r / rows
    const line = []
    for (let c = 0; c <= cols * 4; c++) {
      const u = c / (cols * 4)
      line.push(bilinearInterpolate(quad, u, v))
    }
    lines.push(line)
  }
  // Vertical lines (constant u)
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
  bilinearInterpolate, quadWidthAtV, quadHeightAtU,
  scaleAtV, screenToUV, pointInQuad,
  generateGrid, generateGridLines
}
