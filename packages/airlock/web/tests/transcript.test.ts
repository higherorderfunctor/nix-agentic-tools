import { Effect, Schema } from "effect";
import { describe, expect, it } from "vitest";
import {
  Credential,
  decodeServerFrame,
  encodeClientFrameSync,
  ReportAggregate,
  ResetEvent,
  Snapshot,
} from "../src/data/protocol.ts";

import {
  clientTranscript,
  fixture,
  serverTranscript,
} from "./protocol-fixtures.ts";

describe("Rust protocol fixtures", () => {
  it("decodes every frozen server frame and encodes every frozen client frame", async () => {
    expect(serverTranscript).toHaveLength(10);
    expect(clientTranscript).toHaveLength(8);
    for (const frame of fixture(
      "protocol-v1-server-transcript.json",
    ) as unknown[]) {
      await expect(
        Effect.runPromise(decodeServerFrame(frame)),
      ).resolves.toMatchObject({ v: 1 });
    }
    for (const frame of clientTranscript) {
      expect(JSON.parse(encodeClientFrameSync(frame))).toEqual(frame);
    }
  });

  it("decodes the frozen report values with closed schemas", () => {
    const report = fixture("usage-report-v1.json") as Record<string, unknown>;
    const collections = [
      ["credentials", Credential, 2],
      ["snapshots", Snapshot, 5],
      ["request_usage", ReportAggregate, 1],
      ["reset_events", ResetEvent, 2],
    ] as const;
    for (const [name, schema, count] of collections) {
      const values = report[name] as unknown[];
      expect(values).toHaveLength(count);
      for (const value of values) {
        expect(
          Schema.decodeUnknownSync(schema, { onExcessProperty: "error" })(
            value,
          ),
        ).toBeDefined();
      }
    }
  });
});
