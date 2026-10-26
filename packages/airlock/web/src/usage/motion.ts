import { useEffect, useRef, useState } from "react";
import type { UsageLayout } from "./geometry.ts";

export const usageMotionStageMs = 240;
type Frame = { stacking: number; maximum: number; phase: string };

export function useUsageMotion(
  identity: unknown,
  layout: UsageLayout,
  maximum: number,
  animate: boolean,
) {
  const target = { stacking: layout === "stack" ? 1 : 0, maximum, phase: "" };
  const [frame, setFrame] = useState<Frame>(target);
  const current = useRef(frame);
  const previous = useRef(identity);
  useEffect(() => {
    const publish = (next: Frame) => {
      current.current = next;
      setFrame(next);
    };
    const end = { stacking: layout === "stack" ? 1 : 0, maximum, phase: "" };
    if (!animate || previous.current !== identity) {
      previous.current = identity;
      publish(end);
      return;
    }
    const start = current.current;
    // Reverse safely from the current interpolated frame on rapid toggles.
    const middle =
      layout === "overlay"
        ? {
            ...end,
            maximum: Math.max(start.maximum, maximum),
            phase: "Separating series",
          }
        : {
            ...start,
            maximum: Math.max(start.maximum, maximum),
            phase: "Expanding scale",
          };
    const began = performance.now();
    let request = 0;
    const tick = (now: number) => {
      const elapsed = now - began;
      const second = elapsed >= usageMotionStageMs;
      const from = second ? middle : start;
      const to = second ? end : middle;
      const progress = Math.min(
        1,
        (elapsed % usageMotionStageMs) / usageMotionStageMs,
      );
      const eased = progress * progress * (3 - 2 * progress);
      if (elapsed >= usageMotionStageMs * 2) {
        publish(end);
        return;
      }
      publish({
        stacking: from.stacking + (to.stacking - from.stacking) * eased,
        maximum: from.maximum + (to.maximum - from.maximum) * eased,
        phase: second
          ? layout === "stack"
            ? "Stacking series"
            : "Tightening scale"
          : middle.phase,
      });
      request = requestAnimationFrame(tick);
    };
    if (start.stacking === end.stacking && start.maximum === end.maximum)
      return;
    request = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(request);
  }, [animate, identity, layout, maximum]);
  return frame;
}
