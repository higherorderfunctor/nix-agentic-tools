import Anthropic from "@anthropic-ai/sdk";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import axios from "axios";
import OpenAI from "openai";
// S01 OpenAI SDK baseURL
export const s01 = () =>
  new OpenAI({ baseURL: "https://s01-openai-sdk.test/v1", apiKey: "x" });
// S02 Anthropic SDK baseURL
export const s02 = () =>
  new Anthropic({ baseURL: "https://s02-anthropic-sdk.test", apiKey: "x" });
// S03 MCP streamable HTTP transport
export const s03 = () =>
  new StreamableHTTPClientTransport(new URL("https://s03-mcp-http.test/mcp"));
// S04 MCP SSE transport
export const s04 = () =>
  new SSEClientTransport(new URL("https://s04-mcp-sse.test/sse"));
// S05 axios control (modeled upstream)
export const s05 = () => axios.get("https://s05-axios.test/v1");
