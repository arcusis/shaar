// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Painted hills and a draggable sun. Brush texture comes from SVG turbulence
// filters, so the scene needs no image files and stays sharp at any size.

export function Landscape(): string {
  return `<div class="landscape" aria-hidden="true">
    <svg class="landscape-art" viewBox="0 0 1600 900" preserveAspectRatio="xMidYMax slice" focusable="false">
      <defs>
        <linearGradient id="sky" x2="0" y2="1"><stop stop-color="#dfe9ec"/><stop offset=".55" stop-color="#f3f1df"/><stop offset="1" stop-color="#f6f0d2"/></linearGradient>
        <radialGradient id="sun-glow"><stop stop-color="#fffbe0" stop-opacity=".95"/><stop offset=".45" stop-color="#fff6c4" stop-opacity=".55"/><stop offset="1" stop-color="#fff6c4" stop-opacity="0"/></radialGradient>
        <radialGradient id="sun-disc" cx=".42" cy=".38"><stop stop-color="#ffe46b"/><stop offset=".7" stop-color="#f7c531"/><stop offset="1" stop-color="#eeb21c"/></radialGradient>
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
        <filter id="grass" x="0" y="0" width="100%" height="100%">
          <feTurbulence type="fractalNoise" baseFrequency=".06 .9" numOctaves="2" seed="11"/>
          <feColorMatrix values="0 0 0 0 .1  0 0 0 0 .2  0 0 0 0 .05  0 0 0 -2 1.15"/>
          <feComposite in2="SourceGraphic" operator="in"/>
        </filter>
      </defs>
      <rect width="1600" height="900" fill="url(#sky)"/>
      <rect class="sky-strokes" width="1600" height="560" fill="#ffffff" filter="url(#strokes)" opacity=".5"/>
      <g filter="url(#brush)">
        <path fill="url(#hill-far)" d="M-40 520C120 430 260 380 420 420S640 520 760 500s180-70 300-60 220 90 360 70 180-40 220-30V900H-40Z"/>
        <path fill="url(#hill-ridge)" d="M700 610c120-10 220-60 330-130s220-120 340-120 190 30 270 60V900H700Z"/>
        <path fill="url(#hill-mid)" d="M-40 610c180-40 360-90 560-60s360 110 560 100 330-60 560-40V900H-40Z"/>
        <path fill="url(#meadow)" d="M-40 690c220-30 480-40 760-20s560 50 920 10V900H-40Z"/>
      </g>
      <path d="M-40 690c220-30 480-40 760-20s560 50 920 10V900H-40Z" fill="#2c5a1f" filter="url(#grass)" opacity=".55"/>
      <path class="road" filter="url(#brush)" d="M1010 900c-70-60-170-90-150-130s150-50 160-80-60-40-40-62c40 20 82 42 70 74s-150 50-130 88 140 60 210 110Z"/>
    </svg>
    <div class="sun" data-sun>
      <svg viewBox="0 0 240 240" focusable="false"><circle cx="120" cy="120" r="120" fill="url(#sun-glow)"/><circle cx="120" cy="120" r="54" fill="url(#sun-disc)" filter="url(#brush)"/></svg>
      <span class="sun-hint">← drag the sun</span>
    </div>
  </div>`;
}
