import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  decodeClientFrameSync,
  decodeServerJsonSync,
  type ServerFrame,
} from "../src/data/protocol.ts";

export function fixture(name: string): unknown {
  return JSON.parse(
    readFileSync(resolve("../web-fixtures", name), "utf8"),
  ) as unknown;
}

export const clientTranscript = (
  fixture("protocol-v1-client-transcript.json") as unknown[]
).map(decodeClientFrameSync);
export const serverTranscript = (
  fixture("protocol-v1-server-transcript.json") as unknown[]
).map((frame) => decodeServerJsonSync(JSON.stringify(frame)));

export function serverFrame<Type extends ServerFrame["type"]>(
  type: Type,
): Extract<ServerFrame, { readonly type: Type }> {
  const frame = serverTranscript.find((frame) => frame.type === type);
  if (frame === undefined) throw new Error(`missing ${type} fixture`);
  return frame as Extract<ServerFrame, { readonly type: Type }>;
}
