// Pixel sprites: Toast's dance and idle sheets (rendered by the app's own ToastScene, one 46×46 frame per cell), a
// toaster drawn on the same grid, and the menu bar's toast glyph.

/** A sprite sheet of `frames` square cells, `columns` across. `minAlpha` drops faint pixels (the scene's stage
 *  light and floor spot) so Toast can stand on our own stage. */
export class Sheet {
  constructor(url, { frames, columns = 32, cell = 46, minAlpha = 0 } = {}) {
    Object.assign(this, { url, frames, columns, cell, minAlpha });
    this.ready = this.load();
  }

  async load() {
    const img = new Image();
    img.decoding = "async";
    img.src = this.url;
    await img.decode();
    if (!this.frames) this.frames = Math.floor(img.width / this.cell) * Math.floor(img.height / this.cell);
    if (!this.minAlpha) { this.source = img; return this; }
    const c = document.createElement("canvas");
    c.width = img.width; c.height = img.height;
    const g = c.getContext("2d", { willReadFrequently: true });
    g.drawImage(img, 0, 0);
    const data = g.getImageData(0, 0, c.width, c.height);
    const px = data.data, cut = this.minAlpha * 255;
    for (let i = 3; i < px.length; i += 4) if (px[i] < cut) px[i] = 0;
    g.putImageData(data, 0, 0);
    this.source = c;
    return this;
  }

  draw(ctx, frame, dx = 0, dy = 0) {
    if (!this.source) return;
    const f = ((frame % this.frames) + this.frames) % this.frames;
    const sx = (f % this.columns) * this.cell, sy = Math.floor(f / this.columns) * this.cell;
    ctx.drawImage(this.source, sx, sy, this.cell, this.cell, dx, dy, this.cell, this.cell);
  }
}

/** Draws a frame into a 46×46 canvas, skipping repeats. */
export function painter(canvas) {
  const ctx = canvas.getContext("2d");
  ctx.imageSmoothingEnabled = false;
  let last = null;
  return (sheet, frame) => {
    const key = sheet && sheet.source ? `${sheet.url}#${frame}` : null;
    if (key === last || !key) return;
    last = key;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    sheet.draw(ctx, frame);
  };
}

// ───────── The toaster ─────────

const INK = "#1d1128";
const P = {
  O: INK,
  T: "#2dd4bf", t: "#14b8a6", u: "#0e8f82", v: "#0b6f66",
  W: "#ffffff", w: "#d9fff8",
  C: "#f3f5f9", c: "#c7cdd8", d: "#8f97a8",
  S: "#3a2340", s: "#24142b",
  L: "#ff5c8d", l: "#c93c6a",
  K: "#ffd45c", k: "#d99a20",
  G: "#4dff9a", R: "#ff5c5c",
};

function px(ctx, x, y, color, w = 1, h = 1) { ctx.fillStyle = P[color] || color; ctx.fillRect(x, y, w, h); }

/** The toaster's front, 46×30, with the slot left clear so the toast shows through; `lever` 0 (down) to 1 (up). */
export function drawToaster(canvas, lever = 0, glow = 0) {
  const ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, 46, 30);
  const L = 5, R = 40, T = 3, B = 26; // body box, inclusive edges at L..R, T..B
  // Body with rounded corners (radius 3).
  for (let y = T; y <= B; y++) {
    const inset = y === T || y === B ? 3 : y === T + 1 || y === B - 1 ? 1 : 0;
    const top = y < T + 9, low = y > B - 6;
    for (let x = L + inset; x <= R - inset; x++) {
      const edge = x === L + inset || x === R - inset || y === T || y === B;
      let c = top ? "T" : low ? "u" : "t";
      if (y === B - 1 || x === R - inset - 1) c = "v";
      if (edge) c = "O";
      px(ctx, x, y, c);
    }
  }
  // The corners' outline pixels.
  for (const [x, y] of [[L + 1, T + 1], [L + 2, T + 1], [R - 1, T + 1], [R - 2, T + 1], [L + 1, B - 1], [L + 2, B - 1], [R - 1, B - 1], [R - 2, B - 1]]) px(ctx, x, y, "O");
  for (const [x, y] of [[L, T + 2], [R, T + 2], [L, B - 2], [R, B - 2]]) px(ctx, x, y, "O");
  // Top plate in chrome, with the slot cut out (transparent: the slot's inside is drawn behind the toast).
  for (let x = L + 3; x <= R - 3; x++) px(ctx, x, T, x < 12 || x > 34 ? "O" : "O");
  for (let x = L + 2; x <= R - 2; x++) px(ctx, x, T + 1, "c");
  for (let x = L + 1; x <= R - 1; x++) px(ctx, x, T + 2, "C");
  ctx.clearRect(13, T, 20, 2);
  px(ctx, 12, T, "O"); px(ctx, 33, T, "O");
  for (let x = 13; x <= 32; x++) px(ctx, x, T + 2, "d");
  // Gloss.
  for (let y = T + 4; y <= T + 12; y++) px(ctx, L + 3, y, y > T + 10 ? "w" : "W");
  for (let y = T + 4; y <= T + 7; y++) px(ctx, L + 4, y, "w");
  px(ctx, L + 6, T + 4, "w");
  // Chrome band.
  for (let x = L + 1; x <= R - 1; x++) { px(ctx, x, 16, "C"); px(ctx, x, 17, "c"); px(ctx, x, 18, "d"); }
  for (let x = L + 4; x <= R - 4; x += 4) px(ctx, x, 17, "W");
  // A dial and two lamps.
  for (const [x, y, c] of [[31, 20, "k"], [32, 20, "K"], [33, 20, "K"], [30, 21, "k"], [31, 21, "K"], [32, 21, "O"], [33, 21, "K"], [34, 21, "K"], [30, 22, "k"], [31, 22, "K"], [32, 22, "K"], [33, 22, "K"], [34, 22, "k"], [31, 23, "k"], [32, 23, "k"], [33, 23, "k"]]) px(ctx, x, y, c);
  px(ctx, 10, 21, glow > .5 ? "R" : "G"); px(ctx, 10, 22, glow > .5 ? "l" : "#1f9e5e");
  px(ctx, 13, 21, "G"); px(ctx, 13, 22, "#1f9e5e");
  // The lever's track on the side, and the lever.
  for (let y = 7; y <= 22; y++) px(ctx, R - 3, y, "v");
  const ly = Math.round(20 - lever * 12);
  for (const [x, y, c] of [[R - 4, ly, "O"], [R - 3, ly, "O"], [R - 2, ly, "O"], [R - 1, ly, "O"], [R, ly, "O"], [R + 1, ly, "O"], [R + 2, ly, "O"], [R + 3, ly, "O"],
    [R + 1, ly + 1, "L"], [R + 2, ly + 1, "L"], [R + 3, ly + 1, "l"], [R + 4, ly + 1, "O"], [R + 1, ly - 1, "O"], [R + 4, ly - 1, "O"], [R + 4, ly, "O"],
    [R + 1, ly + 2, "O"], [R + 2, ly + 2, "O"], [R + 3, ly + 2, "O"], [R + 4, ly + 2, "O"], [R + 1, ly, "L"], [R + 2, ly, "L"], [R + 3, ly, "L"], [R + 2, ly - 1, "O"], [R + 3, ly - 1, "O"]]) px(ctx, x, y, c);
  // Feet.
  for (const x0 of [9, 32]) { px(ctx, x0, 27, "O", 5, 1); px(ctx, x0 + 1, 28, "O", 3, 1); }
}

/** The inside of the slot, drawn behind the toast. */
export function drawSlot(canvas) {
  const ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, 46, 30);
  px(ctx, 13, 3, "s", 20, 1);
  px(ctx, 13, 4, "S", 20, 1);
}

// ───────── The menu bar glyph (ModernUI/ToastGlyph's 1x pixel map) ─────────

const GLYPH = [
  "....########....",
  "..##........##..",
  ".#............#.",
  "#..............#",
  "##............##",
  "..#..........#..",
  "..#..#....#..#..",
  "..#..#....#..#..",
  "..#..........#..",
  "..#..#....#..#..",
  "..#...####...#..",
  "..#..........#..",
  "...##########...",
  ".....#....#.....",
  ".....#....#.....",
  "....##....##....",
];

export function glyphSVG(svg) {
  const ns = "http://www.w3.org/2000/svg";
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("shape-rendering", "crispEdges");
  let d = "";
  GLYPH.forEach((row, y) => [...row].forEach((ch, x) => { if (ch === "#") d += `M${x} ${y}h1v1h-1z`; }));
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", d);
  svg.appendChild(path);
}
