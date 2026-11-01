// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

export function Landscape(): string {
  return `<div class="landscape" aria-hidden="true">
    <svg viewBox="0 0 1440 820" preserveAspectRatio="xMidYMax slice" focusable="false">
      <defs>
        <linearGradient id="far-hill" x2="0" y2="1"><stop stop-color="#a4cf91"/><stop offset="1" stop-color="#72ad76"/></linearGradient>
        <linearGradient id="middle-hill" x2="0" y2="1"><stop stop-color="#459e69"/><stop offset="1" stop-color="#026748"/></linearGradient>
        <linearGradient id="near-hill" x2="0.5" y2="1"><stop stop-color="#026748"/><stop offset="1" stop-color="#013C3C"/></linearGradient>
        <pattern id="field-lines" width="32" height="32" patternUnits="userSpaceOnUse" patternTransform="rotate(-24)"><path d="M0 0V32" stroke="#83F0B4" stroke-opacity=".13" stroke-width="1"/></pattern>
      </defs>
      <g class="sun-orbit"><circle class="sun-halo" cx="1100" cy="270" r="108"/><circle class="sun" cx="1100" cy="270" r="75"/></g>
      <g class="hill hill-far"><path fill="url(#far-hill)" d="M0 735C180 715 267 790 493 712S827 423 1050 456s253 96 390 34V820H0Z"/>
        <path class="contour" d="M626 710c222-136 321-163 529-84s222 25 285 1"/>
        <path class="contour" d="M662 737c223-124 338-146 522-69s206 20 256-1"/></g>
      <g class="hill hill-middle"><path fill="url(#middle-hill)" d="M0 778C139 718 313 680 498 725S793 800 989 697s288-169 451-115v238H0Z"/>
        <path class="contour" d="M0 801C139 741 313 703 498 748S793 823 989 720s288-169 451-115"/></g>
      <g class="hill hill-near"><path fill="url(#near-hill)" d="M0 752c219-70 342-54 554 9s354 11 504-56 277-65 382-21v136H0Z"/>
        <path fill="url(#field-lines)" d="M0 752c219-70 342-54 554 9s354 11 504-56 277-65 382-21v136H0Z"/>
        <path class="landscape-path" d="M1060 820c-84-57-148-78-164-104-12-20 46-36 107-57 59-21 71-43 31-60 59 11 67 35 24 59-49 28-89 42-69 60 31 27 133 53 203 102Z"/>
      </g>
    </svg>
  </div>`;
}
