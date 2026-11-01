// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Canvas painter for the hero. Hills are painted once into textured layers and move with
// parallax; grass blades are simulated every frame with travelling wind waves and part around
// the pointer. Sky colors, the sun and the moon come from sky.ts. Pauses when off screen.

import type { SkyState } from "./sky";
import { hills, meadowTop, roadPath, SCENE_HEIGHT, SCENE_WIDTH } from "./terrain";

interface Blade {
  x: number;
  y: number;
  height: number;
  width: number;
  color: string;
  phase: number;
  bend: number; // current pointer bend, eased
  flower: string | null;
}

interface Firefly {
  x: number;
  y: number;
  speed: number;
  phase: number;
}

interface Bird {
  x: number;
  y: number;
  speed: number;
  phase: number;
}

const bladeShades = ["#4f8a2c", "#5c9733", "#6aa53b", "#3f7726", "#7cb247", "#8fbf55"];
const flowerShades = ["#f7d54a", "#f6f2e4", "#ea8fb4", "#b39be2", "#f2a65a"];

function seeded(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state * 1664525 + 1013904223) % 4294967296;
    return state / 4294967296;
  };
}

// Smooth 1D value noise for wind.
function noise(x: number): number {
  const i = Math.floor(x);
  const f = x - i;
  const hash = (n: number) => {
    const s = Math.sin(n * 127.1) * 43758.5453;
    return s - Math.floor(s);
  };
  const u = f * f * (3 - 2 * f);
  return hash(i) * (1 - u) + hash(i + 1) * u;
}

function makeBlades(count: number): Blade[] {
  const next = seeded(7);
  const blades: Blade[] = [];
  for (let index = 0; index < count; index += 1) {
    const x = -40 + next() * (SCENE_WIDTH + 80);
    const top = meadowTop(x);
    const depth = next() ** 1.6; // more blades far away
    const y = top + 6 + depth * (SCENE_HEIGHT - top);
    const nearness = (y - top) / (SCENE_HEIGHT - top);
    blades.push({
      x,
      y,
      height: 10 + nearness * 85 * (0.6 + next() * 0.7),
      width: 1.6 + nearness * 4.5 * (0.6 + next() * 0.6),
      color: bladeShades[Math.floor(next() * bladeShades.length)],
      phase: next() * Math.PI * 2,
      bend: 0,
      flower: next() < 0.07 ? flowerShades[Math.floor(next() * flowerShades.length)] : null,
    });
  }
  return blades.sort((a, b) => a.y - b.y);
}

// Paints one hill into its own canvas: gradient body, brush strokes along the slope, soft edge.
function paintHill(
  path: Path2D,
  top: string,
  bottom: string,
  scale: number,
  seed: number,
): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil((SCENE_WIDTH + 160) * scale);
  canvas.height = Math.ceil(SCENE_HEIGHT * scale);
  const context = canvas.getContext("2d");
  if (!context) return canvas;
  context.scale(scale, scale);
  context.translate(80, 0);
  const gradient = context.createLinearGradient(0, 380, 0, SCENE_HEIGHT);
  gradient.addColorStop(0, top);
  gradient.addColorStop(1, bottom);
  context.fillStyle = gradient;
  context.fill(path);
  context.save();
  context.clip(path);
  const next = seeded(seed);
  context.lineCap = "round";
  for (let index = 0; index < 1400; index += 1) {
    const x = -80 + next() * (SCENE_WIDTH + 160);
    const y = 380 + next() * 520;
    const length = 14 + next() * 46;
    const tilt = (next() - 0.5) * 0.5;
    const light = next() < 0.5;
    context.strokeStyle = light ? "rgba(255,255,230,0.07)" : "rgba(20,50,20,0.08)";
    context.lineWidth = 2 + next() * 5;
    context.beginPath();
    context.moveTo(x, y);
    context.quadraticCurveTo(x + length * 0.5, y + tilt * 10 - 3, x + length, y + tilt * 20);
    context.stroke();
  }
  context.restore();
  return canvas;
}

export function startScene(
  canvas: HTMLCanvasElement,
  initial: SkyState,
): (state: SkyState) => void {
  const context = canvas.getContext("2d");
  if (!context) return () => {};
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let sky = initial;
  let width = 0;
  let height = 0;
  let scale = 1;
  let offsetX = 0;
  let offsetY = 0;
  let pixelRatio = 1;
  let hillLayers: HTMLCanvasElement[] = [];
  const blades = makeBlades(window.innerWidth < 700 ? 1400 : 3200);
  const randomFly = seeded(21);
  const fireflies: Firefly[] = Array.from({ length: 40 }, () => ({
    x: randomFly() * SCENE_WIDTH,
    y: 640 + randomFly() * 220,
    speed: 0.2 + randomFly() * 0.5,
    phase: randomFly() * Math.PI * 2,
  }));
  const randomStar = seeded(42);
  const stars = Array.from({ length: 140 }, () => ({
    x: randomStar() * SCENE_WIDTH,
    y: randomStar() * 470,
    r: 0.5 + randomStar() * 1.3,
    phase: randomStar() * Math.PI * 2,
  }));
  const birds: Bird[] = [];
  let shootingStar: { x: number; y: number; life: number } | null = null;
  const pointer = { x: -9999, y: -9999, targetX: 0, targetY: 0, parallaxX: 0, parallaxY: 0 };
  let visible = true;
  let frame = 0;
  const road = new Path2D(roadPath);
  // Night tint layer: the union of every hill filled with the current tint color. Filling
  // the paths one by one unions them; a combined Path2D would cancel where windings differ.
  let tintLayer: HTMLCanvasElement | null = null;
  let tintValue = -1;

  const toScene = (clientX: number, clientY: number) => {
    const bounds = canvas.getBoundingClientRect();
    return {
      x: (clientX - bounds.left - offsetX) / scale,
      y: (clientY - bounds.top - offsetY) / scale,
    };
  };

  const resize = () => {
    const bounds = canvas.getBoundingClientRect();
    pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
    width = bounds.width;
    height = bounds.height;
    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);
    // Cover the frame like the SVG's xMidYMax slice: fill it, anchored to the bottom.
    scale = Math.max(width / SCENE_WIDTH, height / SCENE_HEIGHT);
    offsetX = (width - SCENE_WIDTH * scale) / 2;
    offsetY = height - SCENE_HEIGHT * scale;
    tintLayer = null;
    hillLayers = hills.map((hill, index) =>
      paintHill(new Path2D(hill.path), hill.top, hill.bottom, scale * pixelRatio, 11 + index),
    );
  };

  const drawSky = (time: number) => {
    const gradient = context.createLinearGradient(0, 0, 0, SCENE_HEIGHT * 0.75);
    gradient.addColorStop(0, sky.top);
    gradient.addColorStop(0.6, sky.middle);
    gradient.addColorStop(1, sky.bottom);
    context.fillStyle = gradient;
    context.fillRect(-200, -200, SCENE_WIDTH + 400, SCENE_HEIGHT + 400);
    if (sky.stars > 0.01) {
      for (const star of stars) {
        const twinkle = 0.55 + 0.45 * Math.sin(time * 0.0015 + star.phase);
        context.globalAlpha = sky.stars * twinkle;
        context.fillStyle = "#fdfbf1";
        context.beginPath();
        context.arc(star.x, star.y, star.r, 0, Math.PI * 2);
        context.fill();
      }
      context.globalAlpha = 1;
    }
  };

  const drawGlowBody = (
    point: { x: number; y: number },
    radius: number,
    glow: string,
    body: string,
    alpha: number,
  ) => {
    if (alpha <= 0.01) return;
    context.globalAlpha = alpha;
    const halo = context.createRadialGradient(
      point.x,
      point.y,
      radius * 0.6,
      point.x,
      point.y,
      radius * 3.2,
    );
    halo.addColorStop(0, glow);
    halo.addColorStop(1, "rgba(255,255,255,0)");
    context.fillStyle = halo;
    context.fillRect(point.x - radius * 4, point.y - radius * 4, radius * 8, radius * 8);
    context.fillStyle = body;
    context.beginPath();
    context.arc(point.x, point.y, radius, 0, Math.PI * 2);
    context.fill();
    context.globalAlpha = 1;
  };

  const drawCelestial = () => {
    drawGlowBody(sky.sun, 56, "rgba(255,244,190,0.75)", "#f8cf3d", Math.min(1, sky.day * 1.4));
    if (sky.stars > 0.05) {
      const moon = { x: Math.min(1400, Math.max(1050, sky.moon.x)), y: Math.max(240, sky.moon.y) };
      drawGlowBody(moon, 42, "rgba(220,228,255,0.35)", "#f3f1e4", Math.min(1, sky.stars * 1.2));
      // Crescent: cut the disc with the sky color.
      context.globalAlpha = Math.min(1, sky.stars * 1.2);
      context.fillStyle = sky.top;
      context.beginPath();
      context.arc(moon.x + 18, moon.y - 12, 38, 0, Math.PI * 2);
      context.fill();
      context.globalAlpha = 1;
    }
  };

  const drawClouds = (time: number) => {
    const drift = (time * 0.006) % (SCENE_WIDTH + 600);
    context.fillStyle = `rgba(255,255,255,${0.12 + 0.6 * sky.day})`;
    context.filter = "blur(10px)";
    for (const [baseX, y, size] of [
      [160, 150, 1],
      [820, 92, 0.8],
      [1300, 190, 1.15],
    ] as const) {
      const x = ((baseX + drift * size + 300) % (SCENE_WIDTH + 600)) - 300;
      context.beginPath();
      context.ellipse(x, y, 120 * size, 24 * size, 0, 0, Math.PI * 2);
      context.ellipse(x - 50 * size, y - 14 * size, 62 * size, 30 * size, 0, 0, Math.PI * 2);
      context.ellipse(x + 40 * size, y - 20 * size, 72 * size, 36 * size, 0, 0, Math.PI * 2);
      context.fill();
    }
    context.filter = "none";
  };

  const drawBirds = (time: number) => {
    if (sky.day < 0.5) return;
    if (birds.length === 0 && Math.random() < 0.002) {
      const y = 140 + Math.random() * 160;
      for (let index = 0; index < 4; index += 1) {
        birds.push({
          x: -60 - index * 38,
          y: y + (index % 2) * 18 + index * 6,
          speed: 0.9,
          phase: index,
        });
      }
    }
    context.strokeStyle = "rgba(40,40,40,0.55)";
    context.lineWidth = 1.6;
    for (const bird of birds) {
      bird.x += bird.speed;
      const flap = Math.sin(time * 0.012 + bird.phase) * 5;
      context.beginPath();
      context.moveTo(bird.x - 9, bird.y - flap);
      context.quadraticCurveTo(bird.x - 4, bird.y - 3, bird.x, bird.y);
      context.quadraticCurveTo(bird.x + 4, bird.y - 3, bird.x + 9, bird.y - flap);
      context.stroke();
    }
    if (birds.length && birds.every((bird) => bird.x > SCENE_WIDTH + 40)) birds.length = 0;
  };

  const drawShootingStar = () => {
    if (sky.stars < 0.6) return;
    if (!shootingStar && Math.random() < 0.003) {
      shootingStar = { x: 200 + Math.random() * 1000, y: 40 + Math.random() * 160, life: 1 };
    }
    if (!shootingStar) return;
    const { x, y, life } = shootingStar;
    const tail = context.createLinearGradient(x, y, x - 120, y - 40);
    tail.addColorStop(0, `rgba(255,255,255,${life})`);
    tail.addColorStop(1, "rgba(255,255,255,0)");
    context.strokeStyle = tail;
    context.lineWidth = 2;
    context.beginPath();
    context.moveTo(x, y);
    context.lineTo(x - 120, y - 40);
    context.stroke();
    shootingStar.x += 9;
    shootingStar.y += 3;
    shootingStar.life -= 0.02;
    if (shootingStar.life <= 0) shootingStar = null;
  };

  const drawHills = () => {
    hillLayers.forEach((layer, index) => {
      const depth = hills[index].depth;
      const dx = pointer.parallaxX * depth;
      const dy = pointer.parallaxY * depth * 0.4;
      context.drawImage(layer, -80 + dx, dy, SCENE_WIDTH + 160, SCENE_HEIGHT);
    });
    context.fillStyle = "rgba(244,230,166,0.9)";
    context.save();
    context.translate(pointer.parallaxX * 24, pointer.parallaxY * 24 * 0.4);
    context.fill(road);
    context.restore();
  };

  const drawGrass = (time: number) => {
    const seconds = time / 1000;
    const shiftX = pointer.parallaxX * 24;
    const shiftY = pointer.parallaxY * 24 * 0.4;
    for (const blade of blades) {
      const x = blade.x + shiftX;
      const y = blade.y + shiftY;
      // Travelling wind waves: broad gusts plus a quicker flutter per blade.
      const gust = noise(x * 0.004 - seconds * 0.55) * 2 - 1;
      const flutter = Math.sin(seconds * 2.2 + blade.phase) * 0.12;
      let lean = (gust * 0.55 + flutter + 0.15) * blade.height * 0.5;
      // Part around the pointer, easing in and out.
      const dx = x - pointer.x;
      const dy = y - blade.height * 0.5 - pointer.y;
      const distance = Math.hypot(dx, dy);
      const reach = 110;
      const target =
        distance < reach ? (Math.sign(dx) || 1) * (1 - distance / reach) * blade.height * 0.9 : 0;
      blade.bend += (target - blade.bend) * 0.12;
      lean += blade.bend;
      const tipX = x + lean;
      const tipY =
        y -
        Math.sqrt(
          Math.max(blade.height ** 2 - lean ** 2 * 0.5, blade.height * blade.height * 0.25),
        );
      context.fillStyle = blade.color;
      context.beginPath();
      context.moveTo(x - blade.width / 2, y);
      context.quadraticCurveTo(
        x + lean * 0.35 - blade.width * 0.2,
        y - blade.height * 0.55,
        tipX,
        tipY,
      );
      context.quadraticCurveTo(
        x + lean * 0.35 + blade.width * 0.3,
        y - blade.height * 0.5,
        x + blade.width / 2,
        y,
      );
      context.fill();
      if (blade.flower) {
        context.fillStyle = blade.flower;
        context.beginPath();
        context.arc(tipX, tipY, 2 + blade.width * 0.6, 0, Math.PI * 2);
        context.fill();
      }
    }
  };

  const paintTint = (value: number) => {
    const layer = document.createElement("canvas");
    const ratio = scale * pixelRatio;
    layer.width = Math.ceil((SCENE_WIDTH + 160) * ratio);
    layer.height = Math.ceil(SCENE_HEIGHT * ratio);
    const layerContext = layer.getContext("2d");
    if (layerContext) {
      layerContext.scale(ratio, ratio);
      layerContext.translate(80, 0);
      layerContext.fillStyle = `rgb(${value},${value},${Math.min(255, value + 30)})`;
      for (const hill of hills) layerContext.fill(new Path2D(hill.path));
    }
    tintLayer = layer;
    tintValue = value;
  };

  const drawNightTint = () => {
    if (sky.land >= 0.995) return;
    const value = Math.round(255 * sky.land);
    if (!tintLayer || value !== tintValue) paintTint(value);
    if (!tintLayer) return;
    context.globalCompositeOperation = "multiply";
    context.drawImage(
      tintLayer,
      -80 + pointer.parallaxX * 6,
      pointer.parallaxY * 2.4,
      SCENE_WIDTH + 160,
      SCENE_HEIGHT,
    );
    context.globalCompositeOperation = "source-over";
  };

  const drawFireflies = (time: number) => {
    if (sky.stars < 0.3) return;
    for (const fly of fireflies) {
      fly.x += Math.sin(time * 0.0007 + fly.phase) * fly.speed;
      fly.y += Math.cos(time * 0.0009 + fly.phase) * fly.speed * 0.5;
      const pulse = 0.5 + 0.5 * Math.sin(time * 0.003 + fly.phase * 3);
      context.globalAlpha = sky.stars * pulse;
      const glow = context.createRadialGradient(fly.x, fly.y, 0, fly.x, fly.y, 10);
      glow.addColorStop(0, "rgba(230,255,140,0.95)");
      glow.addColorStop(1, "rgba(230,255,140,0)");
      context.fillStyle = glow;
      context.fillRect(fly.x - 10, fly.y - 10, 20, 20);
    }
    context.globalAlpha = 1;
  };

  const draw = (time: number) => {
    pointer.parallaxX += (pointer.targetX - pointer.parallaxX) * 0.05;
    pointer.parallaxY += (pointer.targetY - pointer.parallaxY) * 0.05;
    context.setTransform(
      pixelRatio * scale,
      0,
      0,
      pixelRatio * scale,
      pixelRatio * offsetX,
      pixelRatio * offsetY,
    );
    drawSky(time);
    drawCelestial();
    drawClouds(time);
    drawBirds(time);
    drawShootingStar();
    drawHills();
    drawGrass(time);
    drawNightTint();
    drawFireflies(time);
  };

  const loop = (time: number) => {
    frame = 0;
    if (!visible) return;
    draw(time);
    if (!reducedMotion) frame = requestAnimationFrame(loop);
  };

  const wake = () => {
    if (!frame && visible) frame = requestAnimationFrame(loop);
  };

  const frameElement = canvas.closest<HTMLElement>(".hero-frame") ?? canvas;
  frameElement.addEventListener("pointermove", (event) => {
    const point = toScene(event.clientX, event.clientY);
    pointer.x = point.x;
    pointer.y = point.y;
    pointer.targetX = (event.clientX / window.innerWidth - 0.5) * -1;
    pointer.targetY = (event.clientY / window.innerHeight - 0.5) * -1;
    if (reducedMotion) wake();
  });
  frameElement.addEventListener("pointerleave", () => {
    pointer.x = -9999;
    pointer.y = -9999;
    pointer.targetX = 0;
    pointer.targetY = 0;
  });
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting && document.visibilityState === "visible";
    wake();
  }).observe(canvas);
  document.addEventListener("visibilitychange", () => {
    visible = document.visibilityState === "visible";
    wake();
  });
  new ResizeObserver(() => {
    resize();
    wake();
    if (reducedMotion) draw(performance.now());
  }).observe(canvas);

  resize();
  draw(performance.now());
  canvas.dataset.ready = "true";
  wake();
  return (state: SkyState) => {
    sky = state;
    if (reducedMotion) draw(performance.now());
  };
}
