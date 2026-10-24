// sudamp's site: the hero player (pick a genre and it plays), Toast, the visualiser gallery, the skins, the toaster.
import { groove, BEAT, BAR, DROP } from "./groove.js";
import { Sheet, painter, drawToaster, drawSlot, glyphSVG } from "./sprites.js";

const DOWNLOAD_URL = "https://github.com/aliparr-/sudamp/releases/latest";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const mod = (a, n) => ((a % n) + n) % n;
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const media = (p) => `media/${p}`;

// ───────────── Data ─────────────

const GLOW = {
  teal: "rgba(45, 212, 191, .55)", ambient: "rgba(80, 220, 230, .5)", techno: "rgba(90, 110, 255, .6)", lofi: "rgba(255, 150, 60, .5)",
  dnb: "rgba(255, 70, 110, .5)", deep: "rgba(160, 90, 255, .6)", house: "rgba(255, 70, 180, .55)",
};

/** Every scene, with its menu section, a line about it and the glow of the colours it was rendered in. */
const SCENES = {
  toast: ["Dancing Toast", "Our mascot, in sneakers. Six routines, and the butter flips when the bass drops.", GLOW.house],
  "breakfast-band": ["Breakfast Band", "A fried egg on drums, a mug of coffee on bass, a croissant on keys. Toast sings.", GLOW.lofi],
  "pixel-dj": ["Pixel DJ", "A tiny club. Hands go up on the drop. Watch for a toast crowd-surfing the front row.", GLOW.house],
  "drumming-cat": ["Drumming Cat", "Bongos on every kick, a flurry on the drop. Falls asleep when the music stops.", GLOW.lofi],
  rally: ["Rally", "Two-paddle table tennis. The ball crosses the court in exactly one beat.", GLOW.dnb],
  demoscene: ["Demoscene", "A '90s demo: plasma, copper bars and a chrome scroller spelling out what's playing.", GLOW.dnb],

  synthwave: ["Synthwave", "A striped sun, mountains made of spectrum and a neon floor rolling in time.", GLOW.deep],
  skyline: ["Skyline", "Every building hears its own slice of the music. The drop lights every window.", GLOW.deep],
  campfire: ["Campfire", "The classic demoscene fire, fed by the spectrum. Sparks fly on every kick.", GLOW.lofi],
  aurora: ["Aurora", "Northern lights over the pines, rippling with the mids, flaring on the drop.", GLOW.ambient],
  rain: ["Rain", "Rain on a lily pond. The treble is the drizzle, the kicks are the big drops.", GLOW.ambient],
  fireworks: ["Fireworks", "A rocket on every kick, and a salvo of big shells when the bass comes back.", GLOW.house],
  starfield: ["Starfield", "Warp speed, set by how loud it is. Surges on every kick.", GLOW.techno],
  lava: ["Lava", "A lava lamp. The music is the heat, so loud songs make it bubble.", GLOW.house],

  spiral: ["Spiral", "A ride down a glass helter-skelter that speeds up with the music. Hold on.", GLOW.techno],
  tunnel: ["Tunnel", "Rings rush past, each one shaped like the spectrum at the moment it set off.", GLOW.techno],
  halo: ["Halo", "The spectrum as a ring of spokes, with a shockwave on every kick.", GLOW.dnb],
  waterfall: ["Waterfall", "A spectrogram rolling away to the horizon, the beat lined across it.", GLOW.deep],
  loops: ["Loops", "The waveform as a phase portrait: lazy ellipses for basslines, knots for busy mixes.", GLOW.ambient],
  pendulums: ["Pendulums", "A row of pendulums drifting in and out of step, thrown high together on the drop.", GLOW.deep],
  cells: ["Cells", "Conway's cellular automaton, a generation a beat, seeded by the music.", GLOW.techno],

  spectrum: ["Spectrum", "The classic: nineteen bars and their falling peak caps.", GLOW.teal],
  "vu-meters": ["VU Meters", "Two backlit needle meters. The drop slams both into the red.", GLOW.lofi],
  turntable: ["Turntable", "A record seen from above, grooves glinting with the bands. Scratches on the drop.", GLOW.deep],
  speaker: ["Speaker", "A woofer on a spring. It throws the dust on its cone into the air on every kick.", GLOW.house],
  heartbeat: ["Heartbeat", "An ECG that draws a heartbeat on every kick, with the tempo in pixel digits.", GLOW.dnb],
  leds: ["Retro LEDs", "Green, amber, red: hi-fi meter columns that hold their peaks.", GLOW.techno],
  oscilloscope: ["Oscilloscope", "The waveform, glowing like an old phosphor screen.", GLOW.ambient],
};

const SECTIONS = {
  characters: ["toast", "breakfast-band", "pixel-dj", "drumming-cat", "rally", "demoscene"],
  places: ["synthwave", "skyline", "campfire", "aurora", "rain", "fireworks", "starfield", "lava"],
  shapes: ["spiral", "tunnel", "halo", "waterfall", "loops", "pendulums", "cells"],
  meters: ["spectrum", "vu-meters", "turntable", "speaker", "heartbeat", "leds", "oscilloscope"],
};

const SOURCES = { yt: ["YouTube", "badge--yt"], sc: ["SoundCloud", ""], mc: ["Mixcloud", "badge--mc"], fm: ["Radio", "badge--fm"] };

// Made-up mixes for the demo player, and the scenes the app's Rotate favours for each genre.
const GENRES = {
  "deep-house": {
    name: "Deep House", art: ["#2a1260", "#6a3fd0", "#e2d4ff", "#ff7ad9", "#ffb86b"],
    streams: [
      { title: "Sunset Sessions Vol. 7 (Extended Balearic Mix)", creator: "Solar Crew", src: "sc", format: "128 kbps · 48 kHz", duration: 3720, scene: "skyline" },
      { title: "Rooftop Sunrise Set", creator: "Mira Kade", src: "yt", format: "Opus · 48 kHz", duration: 3305, scene: "turntable" },
      { title: "Coastal Drive", creator: "Low Tide", src: "mc", format: "AAC · 44.1 kHz", duration: 2980, scene: "synthwave" },
    ],
  },
  house: {
    name: "House", art: ["#4a0f45", "#c0308f", "#ffd0ee", "#ff8a5c", "#ffd45c"],
    streams: [
      { title: "Warehouse Session 004", creator: "Warehouse Sessions", src: "mc", format: "AAC · 44.1 kHz", duration: 3492, scene: "pixel-dj" },
      { title: "Butter Side Up (Club Mix)", creator: "The Crumbs", src: "sc", format: "128 kbps · 48 kHz", duration: 412, scene: "toast" },
      { title: "Sunday Brunch Disco", creator: "Kofi Lane", src: "yt", format: "Opus · 48 kHz", duration: 4012, scene: "breakfast-band" },
    ],
  },
  techno: {
    name: "Techno", art: ["#0f1a5c", "#3150d6", "#c8d4ff", "#8b5cff", "#5feadb"],
    streams: [
      { title: "Concrete Cathedral (Live at Dawn)", creator: "Kollektiv Null", src: "yt", format: "Opus · 48 kHz", duration: 5400, scene: "tunnel" },
      { title: "Basement 12", creator: "Berlin Basement", src: "mc", format: "AAC · 44.1 kHz", duration: 4210, scene: "spiral" },
      { title: "Machine Hours", creator: "Ana Lua", src: "sc", format: "128 kbps · 48 kHz", duration: 3133, scene: "cells" },
    ],
  },
  "drum-and-bass": {
    name: "Drum & Bass", art: ["#4d0f22", "#c2334f", "#ffc8d2", "#ffb347", "#ff5c8d"],
    streams: [
      { title: "Liquid Hours 03", creator: "Mira Kade", src: "yt", format: "Opus · 48 kHz", duration: 3305, scene: "rally" },
      { title: "Night Bus Rollers", creator: "Afterhours", src: "sc", format: "128 kbps · 48 kHz", duration: 2711, scene: "halo" },
      { title: "Amen Brother, Again", creator: "Lagoon", src: "mc", format: "AAC · 44.1 kHz", duration: 3600, scene: "speaker" },
    ],
  },
  "lo-fi": {
    name: "Lo-fi", art: ["#5a2a0e", "#c46a2a", "#ffd9ad", "#ff7a7a", "#ffd45c"],
    streams: [
      { title: "Rainy Window Radio", creator: "24/7 beats to toast to", src: "fm", format: "AAC · 128 kbps", live: true, scene: "campfire" },
      { title: "Breakfast Beats, Side B", creator: "Kofi Lane", src: "mc", format: "AAC · 44.1 kHz", duration: 2350, scene: "drumming-cat" },
      { title: "Tape Hiss & Teacups", creator: "Low Tide", src: "yt", format: "Opus · 48 kHz", duration: 3734, scene: "rain" },
    ],
  },
  ambient: {
    name: "Ambient", art: ["#08384a", "#168f9a", "#c4fff6", "#5ac8fa", "#c9b8ff"],
    streams: [
      { title: "Slow Light, Part II", creator: "Low Tide", src: "sc", format: "128 kbps · 48 kHz", duration: 2711, scene: "aurora" },
      { title: "Fog Over the Harbour", creator: "Sunday Selections", src: "mc", format: "AAC · 44.1 kHz", duration: 3600, scene: "lava" },
      { title: "Deep Field", creator: "Mira Kade", src: "yt", format: "Opus · 48 kHz", duration: 4800, scene: "starfield" },
    ],
  },
};
const IDLE_ART = ["#0b4f4a", "#0d9488", "#a7f3e8", "#2dd4bf", "#ffd45c"];

const TINTS = [
  ["graphite", "#b4b4be"], ["red", "#ff5a5f"], ["orange", "#ff9f2e"], ["yellow", "#ffd23f"], ["green", "#3edc6e"], ["mint", "#5fead9"],
  ["teal", "#2dd4bf"], ["cyan", "#5ac8fa"], ["blue", "#4c9dff"], ["indigo", "#8b85ff"], ["purple", "#c77dff"], ["pink", "#ff5c8d"],
];

// ───────────── The frame loop ─────────────

const frameHooks = new Set();
let lastSync = 0;
const liveVideos = new Set();

function frame(now) {
  const t = groove.time();
  for (const fn of frameHooks) fn(t, now);
  if (now - lastSync > 250) { lastSync = now; for (const v of liveVideos) syncVideo(v, t); }
  requestAnimationFrame(frame);
// For poking at from the console.
window.sudamp = { groove, pick };
}

/** Keeps a 4-bar clip (bars 13–16 of the loop) on the beat while the music plays. */
function syncVideo(v, t) {
  if (!groove.playing || v.paused || !(v.duration > 0) || v.readyState < 2) { if (v.playbackRate !== 1) v.playbackRate = 1; return; }
  const span = 4 * BAR;
  const want = (mod(t - DROP, span) / span) * v.duration;
  let diff = v.currentTime - want;
  if (diff > v.duration / 2) diff -= v.duration;
  if (diff < -v.duration / 2) diff += v.duration;
  if (Math.abs(diff) > .35) { v.currentTime = want; v.playbackRate = 1; }
  else v.playbackRate = clamp(1 - diff * 1.2, .94, 1.06);
}

function playVideo(v) {
  if (reduceMotion) return;
  if (!v.src && v.dataset.src) v.src = v.dataset.src;
  const p = v.play();
  if (p) p.catch(() => {});
  liveVideos.add(v);
}
function pauseVideo(v) { v.pause(); liveVideos.delete(v); }

const videoWatcher = new IntersectionObserver((entries) => {
  for (const e of entries) e.isIntersecting ? playVideo(e.target) : pauseVideo(e.target);
}, { rootMargin: "120px 0px", threshold: .15 });

// Whether an element is on screen (to skip drawing what can't be seen).
function visibility(el) {
  const state = { on: false };
  new IntersectionObserver(([e]) => { state.on = e.isIntersecting; }, { rootMargin: "80px 0px" }).observe(el);
  return state;
}

// ───────────── Toast ─────────────

let looks = [];
const sheets = new Map();
function sheetFor(i, kind, minAlpha) {
  const look = looks[i];
  if (!look) return null;
  const key = `${i}:${kind}:${minAlpha}`;
  if (!sheets.has(key)) {
    const s = new Sheet(media(`toast/${kind === "idle" ? look.idle : look.dance}`), {
      frames: kind === "idle" ? look.idleFrames : look.frames, columns: look.columns || 32, cell: look.cell || 46, minAlpha,
    });
    sheets.set(key, s);
  }
  return sheets.get(key);
}
/** The dance frame for music time t: frame j shows music time (j + 1) / 30. */
const danceFrame = (t, n) => mod(Math.floor(t * 30) - 1, n);

// ───────────── Hero player ─────────────

const player = $("[data-player]");
const heroEl = $("[data-hero]");
const hero = { genre: null, index: 0, paused: false, idleSince: 0, favourites: new Set(), elapsed: 0, tuning: false };
const ui = {
  genreButton: $("[data-genre-button]", player), genreLabel: $("[data-genre-label]", player), menu: $("[data-genre-menu]", player),
  title: $("[data-title]", player), creator: $("[data-creator]", player), source: $("[data-source]", player), format: $("[data-format]", player),
  progress: $("[data-progress]", player), elapsed: $("[data-elapsed]", player), duration: $("[data-duration]", player),
  play: $("[data-play]", player), fav: $("[data-fav]", player), art: $("[data-art]", player), video: $("[data-art-video]", player),
  idle: $("[data-art-idle]", player), volume: $("[data-volume]", player), bubble: $("[data-bubble]"), hint: $("[data-hint]"),
  sound: $("[data-sound-toggle]"), soundLabel: $("[data-sound-label]"),
};

function fmt(s) {
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}` : `${m}:${String(sec).padStart(2, "0")}`;
}

function setArt(el, colors) {
  const [a, b, c, d, e] = colors;
  el.style.setProperty("--art-1", a); el.style.setProperty("--art-2", b);
  el.style.setProperty("--blob-1", c); el.style.setProperty("--blob-2", d); el.style.setProperty("--blob-3", e);
}

let bubbleTimer;
function say(text, ms = 2600) {
  clearTimeout(bubbleTimer);
  ui.bubble.querySelector("span").textContent = text;
  ui.bubble.classList.remove("is-gone");
  if (ms) bubbleTimer = setTimeout(() => ui.bubble.classList.add("is-gone"), ms);
}

function fitTitle() {
  const box = ui.title.parentElement;
  ui.title.classList.remove("is-scrolling");
  const over = ui.title.scrollWidth - box.clientWidth;
  if (over > 4) {
    ui.title.style.setProperty("--scroll-by", `${-(over + 16)}px`);
    ui.title.style.setProperty("--scroll-time", `${(over + 16) / 30 + 4.8}s`);
    ui.title.classList.add("is-scrolling");
  }
}

function showStream() {
  const g = GENRES[hero.genre], s = g.streams[hero.index];
  ui.genreLabel.textContent = g.name;
  ui.title.textContent = s.title;
  ui.creator.textContent = s.creator;
  const [label, cls] = SOURCES[s.src];
  ui.source.hidden = false;
  ui.source.className = `badge ${cls}`;
  ui.source.textContent = label;
  ui.format.textContent = s.format;
  hero.elapsed = s.live ? 0 : Math.floor(s.duration * (.08 + Math.random() * .3));
  ui.duration.textContent = s.live ? "LIVE" : fmt(s.duration);
  $(".progress", player).classList.toggle("is-live", !!s.live);
  setArt(ui.art, g.art);
  for (const b of $$("[data-genre]", ui.menu)) b.classList.toggle("is-current", b.dataset.genre === hero.genre);
  // The artwork: that stream's scene, on the beat.
  const src = media(`scenes/${s.scene}.mp4`);
  if (!ui.video.src.endsWith(src)) {
    ui.video.classList.remove("is-on");
    ui.video.poster = media(`scenes/${s.scene}.jpg`);
    ui.video.src = src;
    ui.video.load();
  }
  playVideo(ui.video);
  if (reduceMotion) ui.video.classList.add("is-on"); // the poster, still
  ui.art.classList.add("is-live");
  requestAnimationFrame(fitTitle);
}
for (const v of $$(".art__video")) for (const ev of ["playing", "loadeddata"]) v.addEventListener(ev, () => v.classList.add("is-on"));

function setPlaying(on) {
  ui.play.classList.toggle("is-playing", on);
  ui.play.setAttribute("aria-label", on ? "Pause" : "Play");
  ui.sound.setAttribute("aria-pressed", String(on));
  ui.sound.setAttribute("aria-label", on ? "Turn the music off" : "Play Toast's theme tune");
  ui.soundLabel.textContent = on ? "Sound on" : "Sound off";
}

/** Picks a genre: tunes for a moment, then plays from the drop (the best bit). */
async function pick(genre, { index = 0, fromDrop = true } = {}) {
  if (genre === "surprise") {
    const keys = Object.keys(GENRES).filter((k) => k !== hero.genre);
    genre = keys[Math.floor(Math.random() * keys.length)];
  }
  if (genre === "favourites") {
    if (!hero.favourites.size) { closeMenu(); say("No favourites yet. Press ♥ while something plays!", 3400); return; }
    const favs = [...hero.favourites];
    const [g, i] = favs[Math.floor(Math.random() * favs.length)].split("#");
    genre = g; index = +i;
  }
  closeMenu();
  const first = !hero.genre;
  hero.genre = genre; hero.index = index; hero.paused = false;
  player.classList.remove("is-idle");
  ui.hint.classList.add("is-gone");
  ui.fav.setAttribute("aria-pressed", String(hero.favourites.has(`${genre}#${index}`)));
  // The app shows "tuning" while the stream resolves; here it's quick.
  ui.title.textContent = "Tuning…";
  ui.title.classList.remove("is-scrolling");
  ui.creator.textContent = GENRES[genre].name;
  groove.setGenre(genre);
  const startAt = fromDrop || !groove.playing ? DROP - .02 : groove.time();
  const wasPlaying = groove.playing;
  if (!wasPlaying || first) await groove.start(startAt);
  setPlaying(true);
  setTimeout(showStream, wasPlaying ? 260 : 120);
  say(first ? `Ooh, ${GENRES[genre].name}!` : ["Tune!", "Yes!", "Ooh, this one.", "Banger.", "Love it."][Math.floor(Math.random() * 5)], 2200);
}

function pause() {
  groove.stop();
  hero.paused = true;
  hero.idleSince = performance.now();
  setPlaying(false);
  ui.video.pause();
  say("Hey! I was dancing.", 2000);
}

async function resume() {
  if (!hero.genre) return pick("deep-house");
  hero.paused = false;
  await groove.start(groove.time());
  setPlaying(true);
  playVideo(ui.video);
}

function openMenu() {
  ui.menu.hidden = false;
  ui.genreButton.setAttribute("aria-expanded", "true");
  const current = $(`[data-genre="${hero.genre}"]`, ui.menu) || $("[data-genre]", ui.menu);
  current.focus({ preventScroll: true });
}
function closeMenu() {
  ui.menu.hidden = true;
  ui.genreButton.setAttribute("aria-expanded", "false");
}

function initPlayer() {
  player.classList.add("is-idle");
  setArt(ui.art, IDLE_ART);
  ui.genreButton.addEventListener("click", (e) => { e.stopPropagation(); ui.menu.hidden ? openMenu() : closeMenu(); });
  ui.menu.addEventListener("click", (e) => { const b = e.target.closest("[data-genre]"); if (b) pick(b.dataset.genre); });
  ui.menu.addEventListener("keydown", (e) => {
    const items = $$("[data-genre]", ui.menu), i = items.indexOf(document.activeElement);
    if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
    if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
    if (e.key === "Escape") { closeMenu(); ui.genreButton.focus(); }
    if (e.key === "Tab") closeMenu();
  });
  document.addEventListener("click", (e) => { if (!ui.menu.hidden && !ui.menu.contains(e.target)) closeMenu(); });
  // While the menu is open, 1–6 (or ⌘1–⌘6, as in the app) pick a genre and 0 surprises. Closed, the browser keeps
  // its own ⌘-number shortcuts.
  document.addEventListener("keydown", (e) => {
    if (ui.menu.hidden || e.shiftKey || e.altKey) return;
    const keys = Object.keys(GENRES), n = Number(e.key);
    if (e.key === "0") { e.preventDefault(); pick("surprise"); }
    else if (n >= 1 && n <= keys.length) { e.preventDefault(); pick(keys[n - 1]); }
  });

  ui.play.addEventListener("click", () => {
    if (!hero.genre) { openMenu(); say("Pick a genre first!", 2000); return; }
    groove.playing ? pause() : resume();
  });
  ui.sound.addEventListener("click", () => (groove.playing ? pause() : resume()));
  $("[data-next]", player).addEventListener("click", () => {
    if (!hero.genre) return pick("deep-house");
    pick(hero.genre, { index: (hero.index + 1) % GENRES[hero.genre].streams.length, fromDrop: false });
  });
  $("[data-prev]", player).addEventListener("click", () => {
    if (!hero.genre) return pick("deep-house");
    pick(hero.genre, { index: (hero.index + 2) % GENRES[hero.genre].streams.length, fromDrop: false });
  });
  $("[data-shuffle]", player).addEventListener("click", () => pick("surprise", { fromDrop: false }));
  ui.fav.addEventListener("click", () => {
    if (!hero.genre) { say("Nothing to love yet!", 1800); return; }
    const key = `${hero.genre}#${hero.index}`;
    hero.favourites.has(key) ? hero.favourites.delete(key) : hero.favourites.add(key);
    const on = hero.favourites.has(key);
    ui.fav.setAttribute("aria-pressed", String(on));
    if (on) say("Saved to ★ Favourites.", 1800);
  });
  const setVol = () => { ui.volume.style.setProperty("--v", `${ui.volume.value}%`); groove.setVolume(ui.volume.value / 100); };
  ui.volume.addEventListener("input", setVol);
  setVol();
  $("[data-try]").addEventListener("click", (e) => {
    e.preventDefault();
    ui.genreButton.scrollIntoView({ behavior: reduceMotion ? "auto" : "smooth", block: "center" });
    setTimeout(openMenu, reduceMotion ? 0 : 450);
  });

  // Ticking time.
  setInterval(() => {
    if (!groove.playing || !hero.genre) return;
    const s = GENRES[hero.genre].streams[hero.index];
    if (s.live) { ui.elapsed.textContent = fmt(hero.elapsed++); return; }
    hero.elapsed = (hero.elapsed + 1) % s.duration;
    ui.elapsed.textContent = fmt(hero.elapsed);
    ui.progress.style.width = `${(hero.elapsed / s.duration) * 100}%`;
  }, 1000);
}

// ───────────── Hero: Toast, the floor, the light ─────────────

const heroVisible = visibility(heroEl);
const grid = $(".hero__grid");

function initHeroToast() {
  const canvas = $("[data-toast-canvas]");
  const paint = painter(canvas);
  const idleArt = painter(ui.idle);
  frameHooks.add((t, now) => {
    if (!heroVisible.on) return;
    const pulse = groove.playing ? groove.pulse(t) : hero.paused ? 0 : groove.pulse(t) * .45;
    heroEl.style.setProperty("--beat", pulse.toFixed(3));
    if (!hero.paused && !reduceMotion) grid.style.setProperty("--roll", mod(t / BEAT, 1).toFixed(3));
    const dance = sheetFor(0, "dance", .5), idle = sheetFor(0, "idle", .5);
    if (reduceMotion || hero.paused) {
      // It settles from its last move into a smile, then holds still.
      if (idle?.source) paint(idle, reduceMotion ? idle.frames - 1 : Math.min(idle.frames - 1, Math.floor(((now - hero.idleSince) / 1000) * 30)));
    } else if (dance?.source) paint(dance, danceFrame(t, dance.frames));
    // The artwork before a genre is picked: a tiny Toast, waiting.
    if (!hero.genre && idle?.source) idleArt(idle, idle.frames - 1);
  });
  // Nav sound bars follow the music.
  const bars = $$(".sound__bars i");
  frameHooks.add((t) => {
    if (!groove.playing) return;
    const p = groove.pulse(t);
    bars.forEach((b, i) => b.style.setProperty("--b", clamp(p * (1 - i * .18) + .25 * Math.abs(Math.sin(t * (3 + i * 2.3))), 0, 1).toFixed(2)));
  });
}

// ───────────── Visualiser gallery ─────────────

function renderTab(key) {
  const gridEl = $("[data-vis-grid]");
  for (const v of $$("video", gridEl)) { videoWatcher.unobserve(v); pauseVideo(v); v.removeAttribute("src"); v.load(); }
  gridEl.innerHTML = "";
  SECTIONS[key].forEach((id, i) => {
    const [name, line, glow] = SCENES[id];
    const fig = document.createElement("figure");
    fig.className = `tile${i === 0 ? " tile--big" : ""}`;
    fig.style.setProperty("--i", i);
    fig.style.setProperty("--glow", glow);
    fig.innerHTML = `<div class="tile__screen"><video muted playsinline loop preload="none" poster="${media(`scenes/${id}.jpg`)}" data-src="${media(`scenes/${id}.mp4`)}" aria-label="${name} visualiser"></video></div>
      <figcaption><h4>${name}${i === 0 ? "<small>Featured</small>" : ""}</h4><p>${line}</p></figcaption>`;
    gridEl.appendChild(fig);
    videoWatcher.observe($("video", fig));
  });
}

function initGallery() {
  const tabs = $$("[data-vis-tabs] [data-tab]");
  for (const tab of tabs) {
    tab.addEventListener("click", () => {
      for (const t of tabs) t.setAttribute("aria-selected", String(t === tab));
      renderTab(tab.dataset.tab);
    });
  }
  $("[data-vis-tabs]").addEventListener("keydown", (e) => {
    const i = tabs.indexOf(document.activeElement);
    if (i < 0 || (e.key !== "ArrowRight" && e.key !== "ArrowLeft")) return;
    const next = tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
    next.focus(); next.click();
  });
  renderTab("characters");

  // Effects.
  const fxVideo = $("[data-fx-video]");
  const fxSrc = { none: "synthwave", vhs: "synthwave-vhs", kaleidoscope: "synthwave-kaleidoscope" };
  fxVideo.dataset.src = media("scenes/synthwave.mp4");
  videoWatcher.observe(fxVideo);
  for (const b of $$("[data-fx] button")) {
    b.addEventListener("click", () => {
      for (const o of $$("[data-fx] button")) o.setAttribute("aria-checked", String(o === b));
      const name = fxSrc[b.dataset.fxName];
      fxVideo.poster = media(`scenes/${name}.jpg`);
      fxVideo.src = fxVideo.dataset.src = media(`scenes/${name}.mp4`);
      playVideo(fxVideo);
    });
  }
}

// ───────────── Skins ─────────────

function initSkins() {
  const section = $("[data-skins]");
  const panes = { modern: $("[data-pane=modern]"), classic: $("[data-pane=classic]") };
  const radios = $$("[data-skin-mode]");
  const set = (mode) => {
    section.dataset.mode = mode;
    for (const r of radios) r.setAttribute("aria-checked", String(r.dataset.skinMode === mode));
    for (const [k, p] of Object.entries(panes)) p.hidden = k !== mode;
  };
  for (const r of radios) r.addEventListener("click", () => set(r.dataset.skinMode));
  const skinsVisible = visibility(section);
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "m" && skinsVisible.on) {
      e.preventDefault();
      set(section.dataset.mode === "modern" ? "classic" : "modern");
    }
  });

  // Modern: tints and appearance.
  const stack = $("[data-modern-stack]");
  const tints = $("[data-tints]");
  for (const [name, color] of TINTS) {
    const b = document.createElement("button");
    b.type = "button"; b.setAttribute("role", "radio"); b.setAttribute("aria-label", name[0].toUpperCase() + name.slice(1));
    b.title = b.getAttribute("aria-label");
    b.style.setProperty("--sw", color);
    b.setAttribute("aria-checked", String(name === stack.dataset.tint));
    b.addEventListener("click", () => {
      stack.dataset.tint = name;
      for (const o of tints.children) o.setAttribute("aria-checked", String(o === b));
    });
    tints.appendChild(b);
  }
  for (const b of $$("[data-appearance-toggle] button")) {
    b.addEventListener("click", () => {
      stack.dataset.appearance = b.dataset.appearance;
      for (const o of $$("[data-appearance-toggle] button")) o.setAttribute("aria-checked", String(o === b));
    });
  }
  for (const v of $$("[data-lazy-video]")) videoWatcher.observe(v);
  setArt($(".art", stack), GENRES["lo-fi"].art);

  // The equalizer: preamp and ten bands (the preview's Club curve) and the response through them.
  const bands = [2, 4.5, 3.2, 1.5, 0, -1.2, -.5, 1.4, 3.1, 4.2, 5];
  const labels = ["PRE", "60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"];
  const bandsEl = $("[data-eq-bands]");
  bands.forEach((db, i) => {
    const d = document.createElement("div");
    d.className = "eq__band";
    d.style.setProperty("--y", ((12 - db) / 24).toFixed(3));
    d.innerHTML = `${i ? "<b></b>" : ""}<i></i><span>${labels[i]}</span>`;
    bandsEl.appendChild(d);
  });
  // x of each band's centre in the plot (11 equal columns, the preamp's a little narrower).
  const pts = bands.slice(1).map((db, i) => [((i + 1.5) / 11) * 300, ((12 - db) / 24) * 100]);
  const ext = [[(1.1 / 11) * 300, pts[0][1]], ...pts, [300, pts[pts.length - 1][1]]];
  let d = `M${ext[0][0].toFixed(1)} ${ext[0][1].toFixed(1)}`;
  for (let i = 0; i < ext.length - 1; i++) {
    const p0 = ext[Math.max(0, i - 1)], p1 = ext[i], p2 = ext[i + 1], p3 = ext[Math.min(ext.length - 1, i + 2)];
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6], c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C${c1[0].toFixed(1)} ${c1[1].toFixed(1)} ${c2[0].toFixed(1)} ${c2[1].toFixed(1)} ${p2[0].toFixed(1)} ${p2[1].toFixed(1)}`;
  }
  $("[data-eq-curve]").innerHTML = `<line x1="${ext[0][0]}" x2="300" y1="50" y2="50"/><path class="fill" d="${d} L300 50 L${ext[0][0].toFixed(1)} 50 Z"/><path d="${d}"/>`;

  initClassic(section);
}

async function initClassic(section) {
  let manifest;
  try { manifest = await (await fetch(media("classic/manifest.json"))).json(); } catch { return; }
  const skins = manifest.skins || [];
  if (!skins.length) return;
  const chips = $("[data-classic-skins]");
  const imgs = { main: $("[data-classic-img=main]"), equalizer: $("[data-classic-img=equalizer]"), playlist: $("[data-classic-img=playlist]") };
  const vis = $("[data-classic-vis]");
  const ctx = vis.getContext("2d");
  let skin = skins[0];
  const apply = (s) => {
    skin = s;
    for (const [w, img] of Object.entries(imgs)) {
      const file = s.files?.[w] || `${s.id}-${w}.png`;
      img.src = media(`classic/${file}`);
      const size = s.sizes?.[w];
      if (size) { img.style.width = `calc(${size.w}px * var(--s))`; img.width = size.w; img.height = size.h; }
    }
    const r = s.visualizer || s.vis || manifest.spectrum?.rect;
    vis.width = r.w; vis.height = r.h;
    Object.assign(vis.style, { left: `calc(${r.x}px * var(--s))`, top: `calc(${r.y}px * var(--s))`, width: `calc(${r.w}px * var(--s))`, height: `calc(${r.h}px * var(--s))` });
    for (const c of chips.children) c.setAttribute?.("aria-checked", String(c.dataset.id === s.id));
  };
  for (const s of skins) {
    const b = document.createElement("button");
    b.type = "button"; b.setAttribute("role", "radio"); b.dataset.id = s.id; b.textContent = s.name;
    b.addEventListener("click", () => apply(s));
    chips.appendChild(b);
  }
  const note = document.createElement("small");
  note.textContent = "Plus 100 skins from the Winamp Skin Museum in the app.";
  chips.appendChild(note);
  apply(skin);

  // The classic spectrum, redrawn live: 19 bars, 3 pixels wide with a gap, coloured by row like Winamp's.
  const freq = new Uint8Array(1024);
  const bars = new Float32Array(19), peaks = new Float32Array(19), peakV = new Float32Array(19);
  const visible = visibility(section);
  let last = 0;
  frameHooks.add((t, now) => {
    if (!visible.on || section.dataset.mode !== "classic") return;
    if (now - last < 33) return;
    last = now;
    const target = new Float32Array(19);
    if (groove.playing && groove.analyser) {
      groove.analyser.getByteFrequencyData(freq);
      const nyq = groove.ctx.sampleRate / 2;
      for (let i = 0; i < 19; i++) {
        const lo = 40 * Math.pow(16000 / 40, i / 19), hi = 40 * Math.pow(16000 / 40, (i + 1) / 19);
        let a = Math.floor((lo / nyq) * 1024), b = Math.max(a + 1, Math.ceil((hi / nyq) * 1024)), m = 0;
        for (let k = a; k < b && k < 1024; k++) m = Math.max(m, freq[k]);
        target[i] = clamp((m / 255 - .25) / .7, 0, 1);
      }
    } else if (!reduceMotion) {
      const p = groove.pulse(t), h = Math.exp(-mod(t, BEAT / 2) / (BEAT / 2) * 6);
      for (let i = 0; i < 19; i++) {
        const low = Math.max(0, 1 - i / 6), high = Math.max(0, (i - 9) / 10);
        target[i] = clamp(.18 + .7 * p * low + .45 * h * high + .22 * Math.abs(Math.sin(t * 1.7 + i * .9)) * (1 - low), 0, 1);
      }
    }
    // Winamp's ballistics, per 30 Hz frame: bars fall 0.75 rows; a peak falls from 3/256 row, 1.1 times faster each frame.
    for (let i = 0; i < 19; i++) {
      const rows = target[i] * 16;
      bars[i] = rows > bars[i] ? rows : Math.max(rows, bars[i] - .75);
      if (bars[i] >= peaks[i]) { peaks[i] = bars[i]; peakV[i] = 3 / 256; }
      else { peaks[i] = Math.max(0, peaks[i] - peakV[i]); peakV[i] *= 1.1; }
    }
    drawClassicSpectrum(ctx, vis.width, vis.height, bars, peaks, skin.viscolors || manifest.viscolors);
  });
}

/** sudamp's classic spectrum (SkinKit's VisualizerRenderer, after Webamp): grid dots on even columns of odd rows,
 *  19 bars 3 px wide at a 4 px pitch, each row in its own viscolor (2 at the top … 17 at the bottom), peaks in 23. */
function drawClassicSpectrum(ctx, w, h, bars, peaks, colors) {
  if (!colors) return;
  ctx.fillStyle = colors[0];
  ctx.fillRect(0, 0, w, h);
  ctx.fillStyle = colors[1];
  for (let y = 1; y < h; y += 2) for (let x = 0; x < w; x += 2) ctx.fillRect(x, y, 1, 1);
  for (let i = 0; i < 19; i++) {
    const rows = Math.round(bars[i]);
    for (let r = 16 - rows; r < 16; r++) { ctx.fillStyle = colors[2 + r]; ctx.fillRect(i * 4, r, 3, 1); }
    const p = Math.round(peaks[i]);
    if (p > 0) { ctx.fillStyle = colors[23]; ctx.fillRect(i * 4, 16 - p, 3, 1); }
  }
}

// ───────────── Meet Toast ─────────────

function initMeet() {
  const canvas = $("[data-meet-toast]");
  const paint = painter(canvas);
  const visible = visibility(canvas);
  const label = $("[data-look]");
  let current = 0;
  const show = () => {
    const look = looks[current];
    if (!look) return;
    // "golden, jam, sunglasses" → "Golden, with jam and sunglasses"
    const [doneness, ...extras] = look.look.split(/,\s*/);
    const text = extras.length ? `${doneness}, with ${extras.join(" and ")}` : doneness;
    label.textContent = text[0].toUpperCase() + text.slice(1);
  };
  const retoast = () => {
    if (!looks.length) return;
    current = (current + 1) % looks.length;
    sheetFor(current, "dance", .5);
    canvas.animate([{ transform: "scale(1, 1)" }, { transform: "scale(1.12, .82) translateY(8%)" }, { transform: "scale(.94, 1.1) translateY(-6%)" }, { transform: "scale(1, 1)" }],
      { duration: 520, easing: "cubic-bezier(.34,1.56,.64,1)" });
    show();
  };
  $("[data-retoast]").addEventListener("click", retoast);
  canvas.addEventListener("click", retoast);
  frameHooks.add((t, now) => {
    if (!visible.on) return;
    const s = sheetFor(current, "dance", .5);
    if (s?.source) paint(s, reduceMotion ? 0 : danceFrame(t, s.frames));
  });
  show();

  const card = $(".card");
  card.addEventListener("pointermove", (e) => {
    const r = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${((e.clientX - r.left) / r.width) * 100}%`);
    card.style.setProperty("--my", `${((e.clientY - r.top) / r.height) * 100}%`);
  });
}

// ───────────── The toaster ─────────────

function initToaster() {
  const box = $("[data-toaster]");
  const body = $("[data-toaster-body]");
  const toast = $("[data-toaster-toast]");
  const slot = document.createElement("canvas");
  slot.width = 46; slot.height = 30; slot.className = "pixel toaster__slot";
  box.insertBefore(slot, toast);
  drawSlot(slot);
  let lever = 0, leverTo = 0;
  drawToaster(body, 0);
  const paint = painter(toast);
  const visible = visibility(box);
  frameHooks.add((t, now) => {
    if (!visible.on) return;
    const s = sheetFor(0, "idle", .5);
    if (s?.source) paint(s, s.frames - 1);
    if (Math.abs(lever - leverTo) > .01) { lever += (leverTo - lever) * .25; drawToaster(body, lever, 1 - lever); }
  });
  const button = $("[data-download-button]");
  const peek = (on) => { box.classList.toggle("is-peek", on); leverTo = on ? .45 : 0; };
  for (const el of [button, box]) {
    el.addEventListener("pointerenter", () => peek(true));
    el.addEventListener("pointerleave", () => peek(false));
  }
  button.addEventListener("focus", () => peek(true));
  button.addEventListener("blur", () => peek(false));
  button.addEventListener("click", (e) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0 || reduceMotion) return;
    e.preventDefault();
    box.classList.remove("is-pop");
    void box.offsetWidth;
    box.classList.add("is-pop");
    leverTo = 1;
    setTimeout(() => { leverTo = .45; }, 500);
    setTimeout(() => { window.location.href = button.href; }, 750);
  });
}

// ───────────── How it works: the spreadsheet that fills itself ─────────────

function initSheet() {
  glyphSVG($("[data-glyph]"));
  const el = $("[data-sheet]");
  const cols = ["", "A", "B", "C", "D"];
  const rows = [
    ["Item", "Q1", "Q2", "Q3"],
    ["Toast", "£40", "£42", "£45"],
    ["Butter", "£12", "£12", "£19"],
    ["Jam", "£8", "£9", "£9"],
    ["Coffee", "£96", "£104", "£131"],
    ["Total", "£156", "£167", "£204"],
  ];
  const cells = [];
  cols.forEach((c) => { const s = document.createElement("span"); s.className = "hd"; s.textContent = c; el.appendChild(s); });
  rows.forEach((r, y) => {
    const h = document.createElement("span"); h.className = "hd"; h.textContent = y + 1; el.appendChild(h);
    r.forEach((v) => { const s = document.createElement("span"); s.dataset.v = v; el.appendChild(s); cells.push(s); });
  });
  const visible = visibility(el);
  let i = 0;
  setInterval(() => {
    if (!visible.on || reduceMotion) return;
    if (i >= cells.length) { for (const c of cells) { c.textContent = ""; c.classList.remove("is-typing"); } i = 0; return; }
    for (const c of cells) c.classList.remove("is-typing");
    const c = cells[i++];
    c.textContent = c.dataset.v; c.classList.add("is-typing", "is-new");
    setTimeout(() => c.classList.remove("is-new"), 600);
  }, 520);
  if (reduceMotion) for (const c of cells) c.textContent = c.dataset.v;
}

// ───────────── Words that rise, things that slide in, tapes that scroll ─────────────

function splitWords(el) {
  const text = el.textContent;
  el.textContent = "";
  el.setAttribute("aria-label", text);
  text.split(/(\s+)/).forEach((part, i) => {
    if (/^\s+$/.test(part)) { el.appendChild(document.createTextNode(" ")); return; }
    const w = document.createElement("span"); w.className = "w"; w.setAttribute("aria-hidden", "true");
    const inner = document.createElement("span"); inner.textContent = part; inner.style.setProperty("--i", i / 2);
    w.appendChild(inner); el.appendChild(w);
  });
}

function initReveals() {
  for (const el of $$("[data-split]")) splitWords(el);
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
  }, { threshold: .18, rootMargin: "0px 0px -6% 0px" });
  for (const el of $$("[data-reveal], .section__head, .download__title, .hero__title")) io.observe(el);
}

function initTapes() {
  for (const track of $$("[data-marquee]")) {
    const kids = [...track.children];
    for (const k of kids) { const c = k.cloneNode(true); c.setAttribute("aria-hidden", "true"); track.appendChild(c); }
    requestAnimationFrame(() => track.style.setProperty("--tape-time", `${Math.max(20, track.scrollWidth / 2 / 70)}s`));
  }
}

/** The hero drifts apart a little as you scroll away: the words slower, the stage faster. */
function initParallax() {
  if (reduceMotion) return;
  const copy = $(".hero__copy"), stage = $(".hero__stage");
  let queued = false;
  const apply = () => {
    queued = false;
    const y = Math.min(scrollY, innerHeight * 1.2);
    copy.style.transform = `translate3d(0, ${(y * .18).toFixed(1)}px, 0)`;
    stage.style.transform = `translate3d(0, ${(y * -.06).toFixed(1)}px, 0)`;
  };
  addEventListener("scroll", () => { if (!queued) { queued = true; requestAnimationFrame(apply); } }, { passive: true });
}

function initNav() {
  const nav = $("[data-nav]");
  let lastY = scrollY;
  addEventListener("scroll", () => {
    const y = scrollY;
    nav.classList.toggle("is-hidden", y > 400 && y > lastY + 4 && ui.menu.hidden);
    if (y < lastY - 4 || y < 400) nav.classList.remove("is-hidden");
    lastY = y;
  }, { passive: true });
  for (const a of $$("[data-download-link]")) a.addEventListener("click", () => {});
  $("[data-download-button]").href = DOWNLOAD_URL;
}

// ───────────── Go ─────────────

async function loadLooks() {
  try { looks = await (await fetch(media("toast/manifest.json"))).json(); } catch { looks = []; }
  if (!Array.isArray(looks)) looks = looks.looks || [];
  // The hero's sheets now; the other looks only as Meet Toast comes near.
  sheetFor(0, "dance", .5); sheetFor(0, "idle", .5);
  const near = new IntersectionObserver(([e]) => {
    if (!e.isIntersecting) return;
    near.disconnect();
    looks.forEach((_, i) => sheetFor(i, "dance", .5));
  }, { rootMargin: "1200px 0px" });
  near.observe($("#toast"));
}

initReveals();
initTapes();
initNav();
initParallax();
initPlayer();
initHeroToast();
initGallery();
initSkins();
initSheet();
initToaster();
loadLooks().then(initMeet);
// The buttons follow the music, however it was started or stopped.
groove.on(() => {
  setPlaying(groove.playing);
  if (!groove.playing) for (const v of liveVideos) v.playbackRate = 1;
});
requestAnimationFrame(frame);
// For poking at from the console.
window.sudamp = { groove, pick };
