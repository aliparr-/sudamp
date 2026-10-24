// Toast's theme tune, synthesised in the browser, and the clock everything on the page dances to.
//
// The visualiser clips and Toast's sprites were rendered by the app from its own preview music (SyntheticMusic in
// Sources/Shell/ModernPreview.swift): 124 bpm, sixteen bars, a breakdown with no kick in bars 9–12 and the drop on
// bar 13. This plays the same arrangement (kicks, off-beat bass, hats, a pad) with a little more polish and a flavour
// per genre, so the pictures land on the beat. Without sound the clock runs on the page's own time.

export const BPM = 124;
export const BEAT = 60 / BPM;
export const STEP = BEAT / 4;
export const BAR = BEAT * 4;
export const LOOP = BAR * 16;
export const DROP = BAR * 12;
const STEPS = 256;

const mod = (a, n) => ((a % n) + n) % n;

// Bars cycle A, A, C, G under the bass, as in the app's preview; the pad plays Am9, Am9, Cmaj7, G6.
const BASS = [55, 55, 65.41, 49];
const CHORDS = [
  [220, 261.63, 329.63, 392, 493.88],
  [220, 261.63, 329.63, 392, 493.88],
  [261.63, 329.63, 392, 493.88, 587.33],
  [196, 246.94, 293.66, 329.63, 440],
];
// A little acid line for techno (semitones above the bar's root), a sixteenth at a time; null rests.
const ACID = [0, null, 12, 0, null, 0, 15, null, 0, 12, null, 7, 0, null, 10, 12];

export const FLAVOURS = {
  "deep-house": { kick: .95, clap: .32, hat: .2, open: .16, bass: "round", pad: .3, stab: 0, keys: 0, acid: 0, reese: 0, bells: 0, crackle: 0, cutoff: 7000, verb: .28, delay: .12, pump: .55 },
  house: { kick: 1, clap: .5, hat: .24, open: .26, bass: "round", pad: .12, stab: .3, keys: 0, acid: 0, reese: 0, bells: 0, crackle: 0, cutoff: 14000, verb: .22, delay: .1, pump: .5 },
  techno: { kick: 1.12, clap: .16, hat: .3, open: .22, sixteenths: true, bass: "acid", pad: .06, stab: 0, keys: 0, acid: .32, reese: 0, bells: 0, crackle: 0, cutoff: 11000, verb: .3, delay: .16, pump: .35, rumble: .45, gain: 1.3 },
  "drum-and-bass": { kick: .95, clap: 0, snare: .55, hat: .22, open: .1, sixteenths: true, bass: "reese", pad: .1, stab: 0, keys: 0, acid: 0, reese: .3, bells: 0, crackle: 0, cutoff: 12000, verb: .22, delay: .1, pump: .4 },
  "lo-fi": { kick: .55, clap: 0, rim: .3, hat: .13, open: 0, swing: .18, bass: "round", pad: .06, stab: 0, keys: .34, acid: 0, reese: 0, bells: 0, crackle: .12, cutoff: 2600, verb: .3, delay: .18, pump: .25, soft: true },
  ambient: { kick: 0, clap: 0, hat: 0, open: 0, bass: "none", pad: .5, stab: 0, keys: 0, acid: 0, reese: 0, bells: .28, crackle: 0, cutoff: 5200, verb: .6, delay: .38, pump: 0, gain: 3.6 },
};

class Groove {
  constructor() {
    this.ctx = null;
    this.playing = false;
    this.genre = "deep-house";
    this.volume = .72;
    this.listeners = new Set();
    // Visual clock without sound: music time = now - origin.
    this.origin = performance.now() / 1000;
    this.timer = null;
  }

  on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit() { for (const fn of this.listeners) fn(this); }

  get flavour() { return FLAVOURS[this.genre] || FLAVOURS["deep-house"]; }

  /** Music time in seconds, 0 ≤ t < LOOP, as heard (the audio clock, latency included) or as seen without sound. */
  time() {
    if (this.playing && this.ctx) {
      let now;
      if (this.ctx.getOutputTimestamp) {
        const ts = this.ctx.getOutputTimestamp();
        now = ts.contextTime > 0 ? ts.contextTime + (performance.now() - ts.performanceTime) / 1000 : this.ctx.currentTime - this.latency();
      } else {
        now = this.ctx.currentTime - this.latency();
      }
      return mod(now - this.audioStart, LOOP);
    }
    return mod(performance.now() / 1000 - this.origin, LOOP);
  }

  latency() { return (this.ctx.outputLatency || 0) + (this.ctx.baseLatency || 0); }

  /** 0…1: a kick's envelope on each beat (softer in the breakdown and for genres without one). */
  pulse(t = this.time()) {
    const bar = Math.floor(t / BAR) % 16;
    const frac = mod(t, BEAT) / BEAT;
    const breakdown = bar >= 8 && bar < 12;
    const f = this.flavour;
    if (breakdown || f.kick === 0) return .22 * Math.exp(-frac * 2.2);
    return Math.exp(-frac * 5.5) * (f.soft ? .7 : 1);
  }

  isBreakdown(t = this.time()) { const bar = Math.floor(t / BAR) % 16; return bar >= 8 && bar < 12; }

  setGenre(genre) {
    if (!FLAVOURS[genre]) return;
    this.genre = genre;
    if (this.ctx) this.applyFlavour(.25);
    this.emit();
  }

  setVolume(v) {
    this.volume = v;
    if (this.master && this.playing) this.master.gain.setTargetAtTime(v * .9, this.ctx.currentTime, .05);
  }

  /** Starts the music at music time `at` (by default where the visuals are). Call from a user gesture. */
  async start(at = this.time()) {
    if (!this.ctx) this.build();
    if (this.ctx.state !== "running") await this.ctx.resume();
    const t0 = this.ctx.currentTime + .08;
    this.audioStart = t0 - at;
    this.step = Math.ceil(at / STEP - 1e-6);
    this.master.gain.cancelScheduledValues(t0 - .08);
    this.master.gain.setValueAtTime(0, t0 - .08);
    this.master.gain.linearRampToValueAtTime(this.volume * .9, t0 + .05);
    this.applyFlavour(0);
    this.playing = true;
    clearInterval(this.timer);
    this.timer = setInterval(() => this.schedule(), 25);
    this.schedule();
    this.emit();
  }

  stop() {
    if (!this.playing) return;
    const t = this.time();
    this.playing = false;
    clearInterval(this.timer);
    const now = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(now);
    this.master.gain.setValueAtTime(this.master.gain.value, now);
    this.master.gain.linearRampToValueAtTime(0, now + .25);
    if (this.crackleSrc) this.crackleGain.gain.setTargetAtTime(0, now, .05);
    // Keep the visual clock where the music was.
    this.origin = performance.now() / 1000 - t;
    this.emit();
  }

  // ───────── The rig ─────────

  build() {
    const AC = window.AudioContext || window.webkitAudioContext;
    const ctx = this.ctx = new AC({ latencyHint: "interactive" });
    this.master = ctx.createGain();
    this.master.gain.value = 0;
    this.comp = ctx.createDynamicsCompressor();
    this.comp.threshold.value = -16; this.comp.ratio.value = 3.5; this.comp.attack.value = .004; this.comp.release.value = .18; this.comp.knee.value = 8;
    this.tone = ctx.createBiquadFilter();
    this.tone.type = "lowpass"; this.tone.frequency.value = 9000; this.tone.Q.value = .5;
    this.analyser = ctx.createAnalyser();
    this.analyser.fftSize = 2048;
    this.analyser.smoothingTimeConstant = .55;
    // Each genre's overall level, so switching doesn't jump in loudness.
    this.level = ctx.createGain();
    this.tone.connect(this.level).connect(this.comp).connect(this.master);
    this.master.connect(this.analyser);
    this.analyser.connect(ctx.destination);

    this.drums = ctx.createGain(); this.drums.connect(this.tone);
    // Pads, chords and bass duck under each kick, the deep-house pump.
    this.duck = ctx.createGain(); this.duck.connect(this.tone);
    this.bassBus = ctx.createGain(); this.bassBus.connect(this.duck);
    this.music = ctx.createGain(); this.music.connect(this.duck);

    this.verb = ctx.createConvolver();
    this.verb.buffer = this.impulse(2.6, 2.4);
    this.verbIn = ctx.createGain();
    this.verbOut = ctx.createGain();
    this.verbIn.connect(this.verb).connect(this.verbOut).connect(this.tone);

    this.delay = ctx.createDelay(1);
    this.delay.delayTime.value = BEAT * .75;
    this.delayFb = ctx.createGain(); this.delayFb.gain.value = .38;
    this.delayTone = ctx.createBiquadFilter(); this.delayTone.type = "lowpass"; this.delayTone.frequency.value = 3200;
    this.delayIn = ctx.createGain();
    this.delayIn.connect(this.delay).connect(this.delayTone).connect(this.delayFb).connect(this.delay);
    this.delayTone.connect(this.verbIn);
    this.delayTone.connect(this.tone);

    this.noise = this.noiseBuffer(2);
    this.crackleBuf = this.crackleBuffer(4);
  }

  applyFlavour(glide) {
    const f = this.flavour, now = this.ctx.currentTime;
    this.tone.frequency.setTargetAtTime(f.cutoff, now, glide || .01);
    this.level.gain.setTargetAtTime(f.gain || 1, now, glide || .01);
    this.verbOut.gain.setTargetAtTime(f.verb, now, glide || .01);
    this.delayIn.gain.setTargetAtTime(f.delay, now, glide || .01);
    if (f.crackle && !this.crackleSrc) {
      this.crackleGain = this.ctx.createGain();
      this.crackleGain.gain.value = 0;
      this.crackleSrc = this.ctx.createBufferSource();
      this.crackleSrc.buffer = this.crackleBuf; this.crackleSrc.loop = true;
      this.crackleSrc.connect(this.crackleGain).connect(this.tone);
      this.crackleSrc.start();
    }
    if (this.crackleSrc) this.crackleGain.gain.setTargetAtTime(this.playing || glide === 0 ? f.crackle : 0, now, .2);
  }

  impulse(seconds, decay) {
    const rate = this.ctx.sampleRate, n = Math.floor(rate * seconds);
    const buf = this.ctx.createBuffer(2, n, rate);
    for (let c = 0; c < 2; c++) {
      const d = buf.getChannelData(c);
      for (let i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / n, decay) * (i < rate * .012 ? i / (rate * .012) : 1);
    }
    return buf;
  }

  noiseBuffer(seconds) {
    const rate = this.ctx.sampleRate, n = Math.floor(rate * seconds);
    const buf = this.ctx.createBuffer(1, n, rate);
    const d = buf.getChannelData(0);
    for (let i = 0; i < n; i++) d[i] = Math.random() * 2 - 1;
    return buf;
  }

  crackleBuffer(seconds) {
    const rate = this.ctx.sampleRate, n = Math.floor(rate * seconds);
    const buf = this.ctx.createBuffer(1, n, rate);
    const d = buf.getChannelData(0);
    let hum = 0;
    for (let i = 0; i < n; i++) {
      hum = hum * .995 + (Math.random() * 2 - 1) * .005;
      d[i] = hum * 1.8 + (Math.random() < .00035 ? (Math.random() * 2 - 1) * .9 : 0) + (Math.random() * 2 - 1) * .012;
    }
    return buf;
  }

  // ───────── The sequencer ─────────

  schedule() {
    const ahead = document.hidden ? 1.6 : .16;
    const horizon = this.ctx.currentTime + ahead;
    while (this.audioStart + this.step * STEP < horizon) {
      const time = this.audioStart + this.step * STEP;
      if (time >= this.ctx.currentTime - .01) this.play(mod(this.step, STEPS), time);
      this.step++;
    }
  }

  play(s, t) {
    const f = this.flavour;
    const bar = s >> 4, i = s & 15;
    const breakdown = bar >= 8 && bar < 12;
    const chord = CHORDS[bar % 4];
    const root = BASS[bar % 4];
    const sw = f.swing && i % 2 === 1 ? f.swing * STEP : 0;

    // Drop: a crash and everything back in.
    if (bar === 12 && i === 0) this.crash(t, .5);
    // A riser through the breakdown's last bar.
    if (bar === 11 && i === 0) this.riser(t, BAR, f.kick ? .2 : .1);

    if (!breakdown && f.kick && i % 4 === 0) {
      this.kick(t, f.kick, f.soft);
      if (f.pump) this.pump(t, f.pump);
      if (f.rumble) this.rumble(t, f.rumble, root);
    }
    if (breakdown && f.kick && bar === 11 && i % 2 === 0 && i >= 8) this.kick(t, f.kick * (.25 + i / 40), true);
    if (!breakdown && f.clap && (i === 4 || i === 12)) this.clap(t, f.clap);
    if (!breakdown && f.snare && (i === 4 || i === 12)) this.snare(t, f.snare);
    if (!breakdown && f.snare && (i === 10 || i === 15) && bar % 2 === 1) this.snare(t, f.snare * .35);
    if (f.rim && (i === 4 || i === 12)) this.rim(t, f.rim);

    if (f.hat) {
      const every = f.sixteenths ? 1 : 2;
      if (i % every === 0) this.hat(t + sw, f.hat * (i % 4 === 2 ? 1 : .55) * (breakdown ? .6 : 1), false);
    }
    if (f.open && i % 4 === 2 && !breakdown) this.hat(t, f.open, true);

    // Bass on the off-beat, as in the preview.
    if (f.bass === "round" && i % 4 === 2) this.bass(t + sw, root, BEAT * .45, breakdown ? .3 : .42);
    if (f.bass === "reese" && i === 0) this.reese(t, root, BAR, f.reese * (breakdown ? .6 : 1));
    if (f.bass === "acid" && !breakdown) {
      const n = ACID[i];
      if (n !== null) this.acid(t, root * 2 * Math.pow(2, n / 12), f.acid * (i % 4 === 0 ? 1 : .75), i % 4 === 0);
    }
    if (f.bass === "acid" && breakdown && i % 4 === 2) this.bass(t, root, BEAT * .4, .3);

    // The pad, a bar at a time, up in the breakdown.
    if (f.pad && i === 0) this.pad(t, chord, BAR, f.pad * (breakdown ? 1.9 : 1), breakdown);
    if (f.stab && !breakdown && (i === 3 || i === 6 || i === 11)) this.stab(t, chord, f.stab);
    if (f.keys && (i === 0 || i === 7 || (i === 10 && bar % 2 === 1))) this.keys(t + sw, chord, f.keys * (i === 0 ? 1 : .7));
    if (f.bells && i % 2 === 0 && Math.random() < (breakdown ? .5 : .32)) {
      const note = chord[Math.floor(Math.random() * chord.length)] * (Math.random() < .5 ? 2 : 4);
      this.bell(t, note, f.bells * (.5 + Math.random() * .5));
    }
  }

  // ───────── Voices ─────────

  env(param, t, peak, attack, decay, floor = .0001) {
    param.setValueAtTime(floor, t);
    param.exponentialRampToValueAtTime(Math.max(peak, floor * 2), t + attack);
    param.exponentialRampToValueAtTime(floor, t + attack + decay);
  }

  noiseSrc(t, dur) {
    const src = this.ctx.createBufferSource();
    src.buffer = this.noise;
    src.start(t, Math.random() * 1.2, dur + .05);
    return src;
  }

  kick(t, amt, soft) {
    const ctx = this.ctx, o = ctx.createOscillator(), g = ctx.createGain();
    o.frequency.setValueAtTime(soft ? 120 : 165, t);
    o.frequency.exponentialRampToValueAtTime(46, t + (soft ? .09 : .12));
    this.env(g.gain, t, amt * .95, .003, soft ? .32 : .44);
    o.connect(g).connect(this.drums);
    o.start(t); o.stop(t + .5);
    if (!soft) {
      const n = this.noiseSrc(t, .01), hp = ctx.createBiquadFilter(), ng = ctx.createGain();
      hp.type = "highpass"; hp.frequency.value = 2500;
      this.env(ng.gain, t, amt * .22, .001, .012);
      n.connect(hp).connect(ng).connect(this.drums);
    }
  }

  rumble(t, amt, root) {
    const ctx = this.ctx, o = ctx.createOscillator(), lp = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = "triangle"; o.frequency.value = root;
    lp.type = "lowpass"; lp.frequency.value = 160;
    g.gain.setValueAtTime(.0001, t + .06);
    g.gain.exponentialRampToValueAtTime(amt * .5, t + .12);
    g.gain.exponentialRampToValueAtTime(.0001, t + BEAT * .95);
    o.connect(lp).connect(g).connect(this.verbIn);
    g.connect(this.drums);
    o.start(t + .05); o.stop(t + BEAT);
  }

  pump(t, depth) {
    const g = this.duck.gain;
    g.cancelScheduledValues(t);
    g.setValueAtTime(1 - depth * .75, t);
    g.linearRampToValueAtTime(1, t + BEAT * .62);
  }

  hat(t, amt, open) {
    const ctx = this.ctx, n = this.noiseSrc(t, open ? .3 : .06);
    const hp = ctx.createBiquadFilter(), bp = ctx.createBiquadFilter(), g = ctx.createGain();
    hp.type = "highpass"; hp.frequency.value = 7200;
    bp.type = "peaking"; bp.frequency.value = 10500; bp.gain.value = 6;
    this.env(g.gain, t, amt * .5, .001, open ? .24 : .045);
    n.connect(hp).connect(bp).connect(g).connect(this.drums);
    if (open) g.connect(this.verbIn);
  }

  clap(t, amt) {
    const ctx = this.ctx, n = this.noiseSrc(t, .3);
    const bp = ctx.createBiquadFilter(), g = ctx.createGain();
    bp.type = "bandpass"; bp.frequency.value = 1500; bp.Q.value = .9;
    g.gain.setValueAtTime(.0001, t);
    for (const k of [0, .011, .022]) {
      g.gain.exponentialRampToValueAtTime(amt * .9, t + k + .001);
      g.gain.exponentialRampToValueAtTime(amt * .15, t + k + .009);
    }
    g.gain.exponentialRampToValueAtTime(.0001, t + .22);
    n.connect(bp).connect(g);
    g.connect(this.drums); g.connect(this.verbIn);
  }

  snare(t, amt) {
    const ctx = this.ctx, n = this.noiseSrc(t, .2), bp = ctx.createBiquadFilter(), g = ctx.createGain();
    bp.type = "bandpass"; bp.frequency.value = 2200; bp.Q.value = .7;
    this.env(g.gain, t, amt * .8, .001, .16);
    n.connect(bp).connect(g);
    g.connect(this.drums); g.connect(this.verbIn);
    const o = ctx.createOscillator(), og = ctx.createGain();
    o.frequency.setValueAtTime(220, t); o.frequency.exponentialRampToValueAtTime(160, t + .08);
    this.env(og.gain, t, amt * .5, .001, .1);
    o.connect(og).connect(this.drums);
    o.start(t); o.stop(t + .15);
  }

  rim(t, amt) {
    const ctx = this.ctx, o = ctx.createOscillator(), bp = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = "square"; o.frequency.value = 1750;
    bp.type = "bandpass"; bp.frequency.value = 1900; bp.Q.value = 4;
    this.env(g.gain, t, amt * .4, .001, .035);
    o.connect(bp).connect(g);
    g.connect(this.drums); g.connect(this.verbIn);
    o.start(t); o.stop(t + .06);
  }

  bass(t, f, len, amt) {
    const ctx = this.ctx, a = ctx.createOscillator(), b = ctx.createOscillator(), lp = ctx.createBiquadFilter(), g = ctx.createGain();
    a.type = "sawtooth"; a.frequency.value = f;
    b.type = "sine"; b.frequency.value = f;
    lp.type = "lowpass"; lp.Q.value = 4;
    lp.frequency.setValueAtTime(900, t); lp.frequency.exponentialRampToValueAtTime(240, t + len);
    const mix = ctx.createGain(); mix.gain.value = .35;
    a.connect(mix).connect(lp); b.connect(lp);
    g.gain.setValueAtTime(.0001, t);
    g.gain.exponentialRampToValueAtTime(amt, t + .006);
    g.gain.setTargetAtTime(.0001, t + len * .6, len * .25);
    lp.connect(g).connect(this.bassBus);
    a.start(t); b.start(t); a.stop(t + len + .3); b.stop(t + len + .3);
  }

  acid(t, f, amt, accent) {
    const ctx = this.ctx, o = ctx.createOscillator(), lp = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = "sawtooth"; o.frequency.value = f;
    lp.type = "lowpass"; lp.Q.value = 13;
    lp.frequency.setValueAtTime(260, t);
    lp.frequency.exponentialRampToValueAtTime(accent ? 3200 : 1800, t + .02);
    lp.frequency.exponentialRampToValueAtTime(240, t + .16);
    this.env(g.gain, t, amt * .5, .004, .16);
    o.connect(lp).connect(g);
    g.connect(this.bassBus); g.connect(this.delayIn);
    o.start(t); o.stop(t + .25);
  }

  reese(t, f, len, amt) {
    const ctx = this.ctx, lp = ctx.createBiquadFilter(), g = ctx.createGain();
    lp.type = "lowpass"; lp.frequency.value = 650; lp.Q.value = 2;
    const oscs = [-14, 14].map((cents) => { const o = ctx.createOscillator(); o.type = "sawtooth"; o.frequency.value = f; o.detune.value = cents; return o; });
    const sub = ctx.createOscillator(); sub.frequency.value = f;
    for (const o of oscs) o.connect(lp);
    const sg = ctx.createGain(); sg.gain.value = 2.2; sub.connect(sg).connect(g);
    lp.connect(g);
    g.gain.setValueAtTime(.0001, t);
    g.gain.exponentialRampToValueAtTime(amt * .35, t + .02);
    g.gain.setValueAtTime(amt * .35, t + len - .08);
    g.gain.exponentialRampToValueAtTime(.0001, t + len);
    g.connect(this.bassBus);
    for (const o of [...oscs, sub]) { o.start(t); o.stop(t + len + .05); }
  }

  pad(t, chord, len, amt, open) {
    const ctx = this.ctx, lp = ctx.createBiquadFilter(), g = ctx.createGain();
    lp.type = "lowpass"; lp.Q.value = .8;
    lp.frequency.setValueAtTime(open ? 700 : 600, t);
    lp.frequency.linearRampToValueAtTime(open ? 2600 : 1300, t + len * .6);
    lp.frequency.linearRampToValueAtTime(open ? 1400 : 800, t + len + .6);
    const voices = [];
    for (const f of chord) for (const d of [-7, 7]) {
      const o = ctx.createOscillator(); o.type = "sawtooth"; o.frequency.value = f; o.detune.value = d + (Math.random() * 4 - 2);
      o.connect(lp); voices.push(o);
    }
    const level = amt * .16 / chord.length;
    g.gain.setValueAtTime(.0001, t);
    g.gain.linearRampToValueAtTime(level, t + .35);
    g.gain.setValueAtTime(level, t + len - .1);
    g.gain.linearRampToValueAtTime(.0001, t + len + .7);
    lp.connect(g);
    g.connect(this.music); g.connect(this.verbIn);
    for (const o of voices) { o.start(t); o.stop(t + len + .8); }
  }

  stab(t, chord, amt) {
    const ctx = this.ctx, lp = ctx.createBiquadFilter(), g = ctx.createGain();
    lp.type = "lowpass"; lp.frequency.setValueAtTime(3400, t); lp.frequency.exponentialRampToValueAtTime(900, t + .18); lp.Q.value = 2;
    const oscs = chord.slice(0, 4).map((f) => { const o = ctx.createOscillator(); o.type = "square"; o.frequency.value = f * 2; o.connect(lp); return o; });
    this.env(g.gain, t, amt * .12, .003, .2);
    lp.connect(g);
    g.connect(this.music); g.connect(this.verbIn); g.connect(this.delayIn);
    for (const o of oscs) { o.start(t); o.stop(t + .3); }
  }

  keys(t, chord, amt) {
    const ctx = this.ctx, g = ctx.createGain();
    for (const f of chord.slice(0, 4)) {
      const o = ctx.createOscillator(), h = ctx.createOscillator(), hg = ctx.createGain();
      o.type = "sine"; o.frequency.value = f; o.detune.value = Math.random() * 10 - 5;
      h.type = "sine"; h.frequency.value = f * 2; hg.gain.value = .18;
      o.connect(g); h.connect(hg).connect(g);
      o.start(t); h.start(t); o.stop(t + 1.8); h.stop(t + 1.8);
    }
    g.gain.setValueAtTime(.0001, t);
    g.gain.exponentialRampToValueAtTime(amt * .09, t + .008);
    g.gain.exponentialRampToValueAtTime(.0001, t + 1.7);
    g.connect(this.music); g.connect(this.verbIn); g.connect(this.delayIn);
  }

  bell(t, f, amt) {
    const ctx = this.ctx, o = ctx.createOscillator(), p = ctx.createOscillator(), pg = ctx.createGain(), g = ctx.createGain();
    o.type = "sine"; o.frequency.value = f;
    p.type = "sine"; p.frequency.value = f * 2.76; pg.gain.value = .25;
    o.connect(g); p.connect(pg).connect(g);
    this.env(g.gain, t, amt * .11, .004, 1.9);
    g.connect(this.delayIn); g.connect(this.verbIn); g.connect(this.music);
    o.start(t); p.start(t); o.stop(t + 2); p.stop(t + 2);
  }

  crash(t, amt) {
    const ctx = this.ctx, n = this.noiseSrc(t, 2), hp = ctx.createBiquadFilter(), g = ctx.createGain();
    hp.type = "highpass"; hp.frequency.value = 5200;
    this.env(g.gain, t, amt * .35, .002, 1.8);
    n.connect(hp).connect(g);
    g.connect(this.drums); g.connect(this.verbIn);
  }

  riser(t, len, amt) {
    const ctx = this.ctx, n = ctx.createBufferSource(), bp = ctx.createBiquadFilter(), g = ctx.createGain();
    n.buffer = this.noise; n.loop = true;
    bp.type = "bandpass"; bp.Q.value = 3;
    bp.frequency.setValueAtTime(300, t); bp.frequency.exponentialRampToValueAtTime(7000, t + len);
    g.gain.setValueAtTime(.0001, t); g.gain.exponentialRampToValueAtTime(amt, t + len - .02); g.gain.linearRampToValueAtTime(.0001, t + len);
    n.connect(bp).connect(g);
    g.connect(this.drums); g.connect(this.verbIn);
    n.start(t); n.stop(t + len + .05);
  }
}

export const groove = new Groove();
