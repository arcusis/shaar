// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Places the hero sun or moon from the sun's real position over Jerusalem and tints
// the sky to match. Visitors can pin the scene to Sun or Moon with the sky control.

const JERUSALEM = { latitude: 31.778, longitude: 35.235 };
const RADIANS = Math.PI / 180;

export interface SunPosition {
  elevation: number; // degrees above the horizon
  hourAngle: number; // degrees, negative in the morning, positive in the afternoon
}

// Low-precision solar position (accurate to well under a degree), from UTC time.
export function sunPosition(date: Date, place = JERUSALEM): SunPosition {
  const days = date.getTime() / 86_400_000 - 10_957.5;
  const anomaly = (357.529 + 0.98560028 * days) * RADIANS;
  const meanLongitude = 280.459 + 0.98564736 * days;
  const longitude =
    (meanLongitude + 1.915 * Math.sin(anomaly) + 0.02 * Math.sin(2 * anomaly)) * RADIANS;
  const obliquity = (23.439 - 0.00000036 * days) * RADIANS;
  const rightAscension = Math.atan2(Math.cos(obliquity) * Math.sin(longitude), Math.cos(longitude));
  const declination = Math.asin(Math.sin(obliquity) * Math.sin(longitude));
  const siderealHours = 18.697374558 + 24.06570982441908 * days + place.longitude / 15;
  let hourAngle = (siderealHours * 15 - rightAscension / RADIANS) % 360;
  if (hourAngle > 180) hourAngle -= 360;
  if (hourAngle < -180) hourAngle += 360;
  const latitude = place.latitude * RADIANS;
  const elevation = Math.asin(
    Math.sin(latitude) * Math.sin(declination) +
      Math.cos(latitude) * Math.cos(declination) * Math.cos(hourAngle * RADIANS),
  );
  return { elevation: elevation / RADIANS, hourAngle };
}

type Palette = [top: string, middle: string, bottom: string, land: number, stars: number];

// Sky colors keyed by sun elevation, from deep night to full day.
const palettes: [number, Palette][] = [
  [-14, ["#0b1330", "#1a2650", "#2e3a66", 0.36, 1]],
  [-7, ["#25335f", "#6b5488", "#d9836f", 0.55, 0.45]],
  [0, ["#93acd2", "#f3c298", "#f6a779", 0.82, 0]],
  [12, ["#cfe1ec", "#f2efdc", "#f6efd0", 1, 0]],
];

function mix(from: string, to: string, amount: number): string {
  const channel = (hex: string, index: number) =>
    Number.parseInt(hex.slice(1 + index * 2, 3 + index * 2), 16);
  const value = [0, 1, 2]
    .map((index) =>
      Math.round(channel(from, index) + (channel(to, index) - channel(from, index)) * amount),
    )
    .map((part) => part.toString(16).padStart(2, "0"))
    .join("");
  return `#${value}`;
}

function palette(elevation: number): Palette {
  if (elevation <= palettes[0][0]) return palettes[0][1];
  for (let index = 1; index < palettes.length; index += 1) {
    const [limit, upper] = palettes[index];
    const [start, lower] = palettes[index - 1];
    if (elevation <= limit) {
      const amount = (elevation - start) / (limit - start);
      return [
        mix(lower[0], upper[0], amount),
        mix(lower[1], upper[1], amount),
        mix(lower[2], upper[2], amount),
        lower[3] + (upper[3] - lower[3]) * amount,
        lower[4] + (upper[4] - lower[4]) * amount,
      ];
    }
  }
  return palettes[palettes.length - 1][1];
}

// Maps a body's hour angle and elevation onto the 1600 x 900 scene.
function placement(hourAngle: number, elevation: number): string {
  const x = 800 + Math.max(-1, Math.min(1, hourAngle / 110)) * 620;
  const y = 600 - Math.max(-20, elevation) * 7.5;
  return `translate(${x.toFixed(1)} ${y.toFixed(1)})`;
}

type SkyMode = "auto" | "sun" | "moon";

function render(landscape: HTMLElement, mode: SkyMode, now: Date): void {
  const real = sunPosition(now);
  const sun =
    mode === "sun"
      ? { elevation: 48, hourAngle: 18 }
      : mode === "moon"
        ? { elevation: -30, hourAngle: 160 }
        : real;
  const [top, middle, bottom, land, stars] = palette(sun.elevation);
  landscape.style.setProperty("--sky-top", top);
  landscape.style.setProperty("--sky-middle", middle);
  landscape.style.setProperty("--sky-bottom", bottom);
  landscape.style.setProperty("--land", land.toFixed(3));
  landscape.style.setProperty("--stars", stars.toFixed(3));
  landscape.style.setProperty(
    "--day",
    Math.max(0, Math.min(1, (sun.elevation + 4) / 16)).toFixed(3),
  );

  // The moon is drawn roughly opposite the sun; this scene does not model lunar orbits.
  const moonAngle = sun.hourAngle > 0 ? sun.hourAngle - 180 : sun.hourAngle + 180;
  landscape
    .querySelector("[data-sun]")
    ?.setAttribute("transform", placement(sun.hourAngle, sun.elevation));
  landscape
    .querySelector("[data-moon]")
    ?.setAttribute("transform", placement(moonAngle, Math.max(-20, -sun.elevation)));

  const frame = landscape.closest<HTMLElement>(".hero-frame");
  if (frame) {
    if (sun.elevation < -3) frame.dataset.night = "true";
    else delete frame.dataset.night;
  }
}

function jerusalemTime(now: Date): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Jerusalem",
    hour: "2-digit",
    minute: "2-digit",
  }).format(now);
}

export function initializeSky(): void {
  const landscape = document.querySelector<HTMLElement>("[data-landscape]");
  const control = document.querySelector<HTMLElement>(".sky-control");
  if (!landscape || !control) return;
  const buttons = [...control.querySelectorAll<HTMLButtonElement>("[data-sky]")];
  const autoButton = buttons.find((button) => button.dataset.sky === "auto");
  let mode: SkyMode = "auto";
  const update = () => {
    const now = new Date();
    render(landscape, mode, now);
    if (autoButton) autoButton.textContent = `Jerusalem ${jerusalemTime(now)}`;
    for (const button of buttons)
      button.setAttribute("aria-pressed", String(button.dataset.sky === mode));
  };
  for (const button of buttons) {
    button.addEventListener("click", () => {
      mode = (button.dataset.sky as SkyMode | undefined) ?? "auto";
      update();
    });
  }
  control.hidden = false;
  update();
  window.setInterval(update, 60_000);
}
