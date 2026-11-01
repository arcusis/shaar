// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Living hero landscape: painted hills, swaying grass and wildflowers, drifting clouds,
// and a sun or moon placed by the current time in Jerusalem (see client.ts).
// Everything is SVG plus CSS, so the scene needs no image files.

const WIDTH = 1600;
const HEIGHT = 900;

// Small deterministic generator so the build output is stable between runs.
function random(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state * 1664525 + 1013904223) % 4294967296;
    return state / 4294967296;
  };
}

const bladeColors = ["#4f8a2c", "#5f9a34", "#6fa83c", "#3f7726", "#80b44a"];
const flowerColors = ["#f7d54a", "#f4f1e6", "#e98fb3", "#b59be0", "#f2a65a"];

function grassBlades(
  count: number,
  top: number,
  minHeight: number,
  maxHeight: number,
  seed: number,
): string {
  const next = random(seed);
  const blades: string[] = [];
  for (let index = 0; index < count; index += 1) {
    const x = Math.round(next() * WIDTH);
    const y = Math.round(top + next() * (HEIGHT - top));
    const height =
      minHeight + next() * (maxHeight - minHeight) * (0.5 + (y - top) / (HEIGHT - top));
    const bend = (next() - 0.5) * height * 0.5;
    const width = 3 + next() * 4;
    const color = bladeColors[Math.floor(next() * bladeColors.length)];
    const tipX = x + bend;
    const tipY = y - height;
    const path = `M${x} ${y}Q${(x + bend * 0.35).toFixed(1)} ${(y - height * 0.6).toFixed(1)} ${tipX.toFixed(1)} ${tipY.toFixed(1)}Q${(x + bend * 0.3 + width * 0.6).toFixed(1)} ${(y - height * 0.55).toFixed(1)} ${(x + width).toFixed(1)} ${y}Z`;
    const flower =
      next() < 0.12
        ? `<circle cx="${tipX.toFixed(1)}" cy="${tipY.toFixed(1)}" r="${(3 + next() * 3).toFixed(1)}" fill="${flowerColors[Math.floor(next() * flowerColors.length)]}"/>`
        : "";
    blades.push(`<g class="blade"><path d="${path}" fill="${color}"/>${flower}</g>`);
  }
  return blades.join("");
}

function stars(count: number): string {
  const next = random(42);
  return Array.from({ length: count }, () => {
    const radius = (0.6 + next() * 1.4).toFixed(1);
    return `<circle class="star" cx="${Math.round(next() * WIDTH)}" cy="${Math.round(next() * 460)}" r="${radius}"/>`;
  }).join("");
}

function clouds(): string {
  const shapes = [
    [180, 150, 1.0],
    [760, 90, 0.8],
    [1250, 190, 1.15],
  ] as const;
  return shapes
    .map(
      ([x, y, scale]) =>
        `<g class="cloud"><g transform="translate(${x} ${y}) scale(${scale})"><ellipse cx="0" cy="0" rx="120" ry="26"/><ellipse cx="-48" cy="-14" rx="60" ry="30"/><ellipse cx="38" cy="-20" rx="70" ry="36"/></g></g>`,
    )
    .join("");
}

export function Landscape(): string {
  return `<div class="landscape" data-landscape aria-hidden="true">
    <svg class="landscape-art" viewBox="0 0 ${WIDTH} ${HEIGHT}" preserveAspectRatio="xMidYMax slice" focusable="false">
      <defs>
        <linearGradient id="sky" x2="0" y2="1"><stop class="sky-top"/><stop offset=".6" class="sky-middle"/><stop offset="1" class="sky-bottom"/></linearGradient>
        <radialGradient id="sun-glow"><stop stop-color="#fffbe0" stop-opacity=".95"/><stop offset=".45" stop-color="#fff3b8" stop-opacity=".5"/><stop offset="1" stop-color="#fff3b8" stop-opacity="0"/></radialGradient>
        <radialGradient id="sun-disc" cx=".42" cy=".38"><stop stop-color="#ffe46b"/><stop offset=".7" stop-color="#f7c531"/><stop offset="1" stop-color="#eeb21c"/></radialGradient>
        <radialGradient id="moon-glow"><stop stop-color="#e8eeff" stop-opacity=".5"/><stop offset="1" stop-color="#e8eeff" stop-opacity="0"/></radialGradient>
        <mask id="moon-phase"><rect x="-80" y="-80" width="160" height="160" fill="#fff"/><circle cx="20" cy="-12" r="40" fill="#000"/></mask>
        <linearGradient id="hill-far" x2="0" y2="1"><stop stop-color="#a9cf8c"/><stop offset="1" stop-color="#7fb26d"/></linearGradient>
        <linearGradient id="hill-ridge" x2="0" y2="1"><stop stop-color="#3f8a5a"/><stop offset="1" stop-color="#1f5f43"/></linearGradient>
        <linearGradient id="hill-mid" x2="0" y2="1"><stop stop-color="#cfe08a"/><stop offset="1" stop-color="#93bf5a"/></linearGradient>
        <linearGradient id="meadow" x2="0" y2="1"><stop stop-color="#86b04a"/><stop offset=".5" stop-color="#5f9636"/><stop offset="1" stop-color="#3f7429"/></linearGradient>
        <filter id="brush" x="-5%" y="-5%" width="110%" height="110%">
          <feTurbulence type="fractalNoise" baseFrequency=".008 .045" numOctaves="3" seed="7" result="noise"/>
          <feDisplacementMap in="SourceGraphic" in2="noise" scale="9" xChannelSelector="R" yChannelSelector="G"/>
        </filter>
        <filter id="strokes" x="0" y="0" width="100%" height="100%">
          <feTurbulence type="fractalNoise" baseFrequency=".006 .12" numOctaves="3" seed="3"/>
          <feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 -2.2 1.25"/>
          <feComposite in2="SourceGraphic" operator="in"/>
        </filter>
        <filter id="grain" x="0" y="0" width="100%" height="100%">
          <feTurbulence type="fractalNoise" baseFrequency=".06 .9" numOctaves="2" seed="11"/>
          <feColorMatrix values="0 0 0 0 .1  0 0 0 0 .2  0 0 0 0 .05  0 0 0 -2 1.15"/>
          <feComposite in2="SourceGraphic" operator="in"/>
        </filter>
      </defs>
      <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#sky)"/>
      <rect class="sky-strokes" width="${WIDTH}" height="560" fill="#ffffff" filter="url(#strokes)"/>
      <g class="stars">${stars(90)}</g>
      <g class="celestial sun-body" data-sun transform="translate(1200 210)"><circle r="130" fill="url(#sun-glow)"/><circle r="58" fill="url(#sun-disc)" filter="url(#brush)"/></g>
      <g class="celestial moon-body" data-moon transform="translate(1200 200)"><circle r="110" fill="url(#moon-glow)"/><circle r="44" fill="#f3f1e4" mask="url(#moon-phase)"/></g>
      <g class="clouds">${clouds()}</g>
      <g class="land">
        <g filter="url(#brush)">
          <path fill="url(#hill-far)" d="M-40 520C120 430 260 380 420 420S640 520 760 500s180-70 300-60 220 90 360 70 180-40 220-30V900H-40Z"/>
          <path fill="url(#hill-ridge)" d="M700 610c120-10 220-60 330-130s220-120 340-120 190 30 270 60V900H700Z"/>
          <path fill="url(#hill-mid)" d="M-40 610c180-40 360-90 560-60s360 110 560 100 330-60 560-40V900H-40Z"/>
          <path fill="url(#meadow)" d="M-40 690c220-30 480-40 760-20s560 50 920 10V900H-40Z"/>
        </g>
        <path d="M-40 690c220-30 480-40 760-20s560 50 920 10V900H-40Z" fill="#2c5a1f" filter="url(#grain)" opacity=".5"/>
        <path class="road" filter="url(#brush)" d="M1010 900c-70-60-170-90-150-130s150-50 160-80-60-40-40-62c40 20 82 42 70 74s-150 50-130 88 140 60 210 110Z"/>
        <g class="grass grass-back">${grassBlades(420, 688, 16, 38, 5)}</g>
        <g class="grass grass-front">${grassBlades(290, 770, 40, 95, 9)}</g>
      </g>
    </svg>
  </div>`;
}

export function SkyControl(): string {
  return `<div class="sky-control" role="group" aria-label="Sky" hidden>
    <button type="button" data-sky="auto" aria-pressed="true">Jerusalem time</button>
    <button type="button" data-sky="sun" aria-pressed="false">Sun</button>
    <button type="button" data-sky="moon" aria-pressed="false">Moon</button>
  </div>`;
}
