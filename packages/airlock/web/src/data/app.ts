import { type Cause, type Layer, Stream } from "effect";
import type * as AsyncResult from "effect/reactivity/AsyncResult";
import type * as Atom from "effect/reactivity/Atom";
import * as AtomRuntime from "effect/reactivity/Atom";
import type { ControlError, SubscriptionQuery } from "./protocol.ts";
import { initialViewState, type ViewState } from "./reducer.ts";
import {
  type ControlEndpoint,
  makeDataLayer,
  Subscriptions,
} from "./services.ts";

export interface AppRuntime {
  readonly subscriptionAtom: (
    query: SubscriptionQuery,
  ) => Atom.Atom<
    AsyncResult.AsyncResult<ViewState, ControlError | Cause.NoSuchElementError>
  >;
}

function stableKey(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(stableKey).join(",")}]`;
  }
  if (value instanceof Object) {
    const entries = Object.entries(value as Record<string, unknown>).sort(
      ([left], [right]) => left.localeCompare(right),
    );
    return `{${entries.map(([key, item]) => `${JSON.stringify(key)}:${stableKey(item)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

export function makeAppRuntime(
  layer: Layer.Layer<Subscriptions, ControlError>,
): AppRuntime {
  const runtime = AtomRuntime.runtime(layer);
  const atoms = new Map<
    string,
    Atom.Atom<
      AsyncResult.AsyncResult<
        ViewState,
        ControlError | Cause.NoSuchElementError
      >
    >
  >();
  return {
    subscriptionAtom: (query) => {
      const key = stableKey(query);
      let atom = atoms.get(key);
      if (atom !== undefined) {
        atoms.delete(key);
        atoms.set(key, atom);
        return atom;
      }
      if (atoms.size >= 8) {
        const oldest = atoms.keys().next();
        if (!oldest.done) atoms.delete(oldest.value);
      }
      atom = runtime.atom(
        Stream.scoped(
          Stream.unwrap(
            // biome-ignore lint/correctness/useHookAtTopLevel: this is Effect's service API, not a React hook.
            Subscriptions.useSync((subscriptions) =>
              subscriptions.stream(query),
            ),
          ),
        ),
        { initialValue: initialViewState() },
      );
      atoms.set(key, atom);
      return atom;
    },
  };
}

export function fixtureAppRuntime(endpoint: ControlEndpoint): AppRuntime {
  return makeAppRuntime(makeDataLayer(endpoint));
}
