# Airlock dashboard

> **Last verified:** 2026-10-26 — Usage controls, explicit synthetic Demo, and
> live chart/table lifecycle are checked against the loopback fixture.

## Local preview

With the existing web dependencies available, start Vite:

```console
npm run dev -- --host 127.0.0.1
```

Open `http://127.0.0.1:5173/#demo` for the explicit **Synthetic demo**. It is
available before connecting, creates no live runtime or authenticated socket,
and has a fixed clock with 72 days of generated activity. Its costs are
independently assigned illustrative fixtures, not provider prices or live spend.
Live errors never select the demo automatically.

For a fully local live-protocol preview, run this in another terminal:

```console
npm run fixture
```

Open `http://127.0.0.1:5173/#usage` and connect with the synthetic read token
`fixture-read-token`. The loopback fixture contains no provider credentials and
never contacts a provider. Its small chart fixtures are protocol examples; the
explicit Demo has the richer synthetic presentation. To exercise a fixture
failure, restart it with a scenario such as
`npm run fixture -- --scenario reconnect`.

## Screens and controls

**Usage** is the single request/token chart. Range, selected dimensions and
exact Client/Model/Provider filters form its server query. Requests/Tokens,
token part, style, layout and error visibility reuse matching rows when query
dimensions stay unchanged. Live Cost is explicitly unavailable and leaves the
chart subscription while selected. Its query resumes when returning to Requests
or Tokens.

Stack by Provider plus Split by Model means provider segments within each
model’s independent stack. Metadata supplies the resolved range and bucket size;
All is never inferred from returned chart rows. Yesterday uses the browser’s
local calendar and refreshes at local midnight. Errors are counts within
buckets, not inferred incident spans.

Raw request details start collapsed below the Explorer. Expanding them activates
their independent last-hour table, filters, paging and pause/resume controls.
Collapse or offscreen visibility releases the table subscription; its filters do
not change the Explorer. Overview and Provider history retain provider
observations, quotas and credit gaps.

The read token stays in page memory and is cleared on Disconnect. Navigating to
Demo releases live widgets; entering Demo without a token does not create the
live runtime. Tests and production compilation:

```console
npm test
npm run typecheck
npm run build
```

## Data lifecycle

The browser data layer uses one scoped Effect transport for all visible widget
subscriptions. `ControlTransport` owns the authenticated WebSocket, its single
message listener, bounded per-widget ingress queues, heartbeat timeout, and
connection generation. `Subscriptions` owns widget IDs, applied sequence state,
fresh reconnection, and retry. The root Atom runtime shares these layers; a
widget's scope sends `unsubscribe` and releases its reference when hidden or
unmounted. The socket closes after a 250 ms idle grace following the final
reference, or when the app runtime shuts down.

The local query includes `kind` for discriminated typing, while the subscribe
frame sends that field beside a query object containing only the kind's filter
fields. Collection entries use the persisted identities: provider and credential
tuple, opaque snapshot ID, decimal request ID, aggregate tuple, or reset
provenance tuple. The reducer rejects mismatched keys, unknown fields, unsafe
integers, sequence gaps, and a fresh snapshot that reuses the current epoch.
Server contact uses receipt time in Unix seconds; `meta.as_of_unix` describes
the server view, and provider observations retain their own row timestamps.

An ingress overflow closes its socket generation before buffered data can be
applied or acknowledged, publishes `client_overflow`, and requests a fresh
snapshot. Schema failures and nonretryable server errors end in a typed failed
state. Transport loss and retryable gaps use jittered exponential retry from
about one second, capped at 30 seconds. Last-good entries remain visible while
reconnecting or paused. The visibility hook combines tab and intersection
signals and remembers the raw intersection result through its 250 ms leave
debounce.

`fixtures/server.mjs` is a loopback-only fake with a separate fake read token.
It independently emits the four supported kinds, filters and windows, fresh
subscriptions, and explicit normal, stale, partial, failed, Console gap,
reconnect, slow consumer, client overflow, malformed, unknown-field, and
unsafe-number cases. `logs.tail` returns `unsupported_subscription`. Run
`npm run fixture` for Vite development and `npm test` for offline data-layer and
loopback tests. The fixture is never selected by a production build. Do not put
real provider credentials or request/response bodies in fixture data.
