// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

interface PositionedStep {
  getBoundingClientRect(): { top: number; height: number };
}

export function nearestStep<T extends PositionedStep>(
  steps: Iterable<T>,
  viewportCenter: number,
): T | undefined {
  let nearest: T | undefined;
  let nearestDistance = Number.POSITIVE_INFINITY;
  for (const step of steps) {
    const bounds = step.getBoundingClientRect();
    const distance = Math.abs(bounds.top + bounds.height / 2 - viewportCenter);
    if (distance < nearestDistance) {
      nearest = step;
      nearestDistance = distance;
    }
  }
  return nearest;
}
