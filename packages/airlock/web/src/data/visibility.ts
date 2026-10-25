import { useAtomValue } from "@effect/atom-react";
import type * as AsyncResult from "effect/reactivity/AsyncResult";
import * as AsyncResultModule from "effect/reactivity/AsyncResult";
import type * as Atom from "effect/reactivity/Atom";
import * as AtomRuntime from "effect/reactivity/Atom";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { AppRuntime } from "./app.ts";
import type { ControlError, SubscriptionQuery } from "./protocol.ts";
import { initialViewState, type ViewState } from "./reducer.ts";

export type SubscriptionResult = AsyncResult.AsyncResult<
  ViewState,
  ControlError | import("effect").Cause.NoSuchElementError
>;

export type PausedAtom = Atom.Atom<AsyncResult.AsyncResult<ViewState, never>>;

function makePausedAtom(state: ViewState): PausedAtom {
  const paused: ViewState = { ...state, phase: "paused" };
  return AtomRuntime.make(AsyncResultModule.success(paused));
}

interface VisibilitySignals {
  readonly tabVisible: boolean;
  readonly intersectionVisible: boolean | null;
}

export interface VisibleSubscription {
  readonly liveAtom: ReturnType<AppRuntime["subscriptionAtom"]>;
  readonly pausedAtom: PausedAtom;
  readonly targetRef: (element: Element | null) => void;
  readonly visible: boolean;
  readonly result: SubscriptionResult;
}

export function useVisibleSubscription(
  runtime: AppRuntime,
  query: SubscriptionQuery,
  options: { readonly debounceMs?: number } = {},
): VisibleSubscription {
  const debounceMs = options.debounceMs ?? 250;
  const liveAtom = useMemo(
    () => runtime.subscriptionAtom(query),
    [runtime, query],
  );
  const [signals, setSignals] = useState<VisibilitySignals>(() => ({
    tabVisible: document.visibilityState === "visible",
    intersectionVisible: null,
  }));
  const [pausedGeneration, setPausedGeneration] = useState(0);
  const [target, setTarget] = useState<Element | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const rawIntersectionRef = useRef<boolean | null>(null);
  const lastGoodRef = useRef<ViewState>(initialViewState());
  const visible = signals.tabVisible && signals.intersectionVisible === true;
  // biome-ignore lint/correctness/useExhaustiveDependencies: A fresh paused atom is intentionally created only when this widget enters pause.
  const pausedAtom = useMemo(
    () => makePausedAtom(lastGoodRef.current),
    [pausedGeneration],
  );

  const clearTimer = useCallback(() => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const pauseNow = useCallback(() => {
    clearTimer();
    setSignals((previous) => ({
      ...previous,
      intersectionVisible: false,
    }));
    setPausedGeneration((generation) => generation + 1);
  }, [clearTimer]);

  useEffect(() => {
    const visibilityChanged = () => {
      if (document.visibilityState === "visible") {
        setSignals((previous) => ({
          ...previous,
          tabVisible: true,
          intersectionVisible:
            rawIntersectionRef.current === false
              ? false
              : previous.intersectionVisible,
        }));
      } else {
        clearTimer();
        setSignals((previous) => ({ ...previous, tabVisible: false }));
        setPausedGeneration((generation) => generation + 1);
      }
    };
    document.addEventListener("visibilitychange", visibilityChanged);
    return () =>
      document.removeEventListener("visibilitychange", visibilityChanged);
  }, [clearTimer]);

  useEffect(() => {
    if (target === null) return;
    const observer = new IntersectionObserver((entries) => {
      const intersecting = entries.some((entry) => entry.isIntersecting);
      rawIntersectionRef.current = intersecting;
      if (intersecting) {
        clearTimer();
        setSignals((previous) => ({
          ...previous,
          intersectionVisible: true,
        }));
      } else {
        setSignals((previous) => {
          if (previous.tabVisible && previous.intersectionVisible !== false) {
            if (timerRef.current === null) {
              timerRef.current = setTimeout(() => {
                timerRef.current = null;
                pauseNow();
              }, debounceMs);
            }
            return previous;
          }
          return {
            ...previous,
            intersectionVisible: false,
          };
        });
      }
    });
    observer.observe(target);
    return () => {
      clearTimer();
      observer.disconnect();
    };
  }, [clearTimer, debounceMs, pauseNow, target]);

  const targetRef = useCallback((element: Element | null) => {
    rawIntersectionRef.current = null;
    setSignals((previous) => ({
      ...previous,
      intersectionVisible: null,
    }));
    setTarget(element);
  }, []);

  const result = useAtomValue(visible ? liveAtom : pausedAtom);
  useEffect(() => {
    if (visible && result._tag === "Success")
      lastGoodRef.current = result.value;
  }, [result, visible]);

  return { liveAtom, pausedAtom, targetRef, visible, result };
}
