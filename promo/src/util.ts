import { Easing, interpolate } from "remotion";

type Bez = [number, number, number, number];

export const ENTER: Bez = [0.16, 1, 0.3, 1]; // crisp deceleration
export const POP: Bez = [0.34, 1.56, 0.64, 1]; // playful overshoot
export const GLIDE: Bez = [0.22, 1, 0.36, 1];

/** Clamped, eased interpolate over an explicit frame window. */
export const ramp = (
  frame: number,
  window: [number, number],
  out: [number, number],
  bez: Bez = ENTER,
): number =>
  interpolate(frame, window, out, {
    easing: Easing.bezier(...bez),
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

export const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));
