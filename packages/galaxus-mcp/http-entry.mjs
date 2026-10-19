#!/usr/bin/env node
// Upstream ships a stdio server only (src/index.ts). This serves the same seven
// tools over streamable HTTP behind a static bearer token, which is what vps
// runs; `GALAXUS_MCP_TRANSPORT=stdio` (the default) still gives the plain stdio
// server, so this one file covers both and framework can use the same package.
//
// Deliberately node:http rather than express. The SDK's streamableHttp module
// imports only @hono/node-server, so going through node:http leaves express,
// qs, proxy-addr and express-rate-limit - four of the seven advisories `npm
// audit` reports against this dependency tree, including the only critical one
// (proxy-addr IP spoofing) - never loaded at all.
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { GalaxusClient, GalaxusError } from "./dist/client.js";
import { buildTools } from "./dist/tools.js";

const portal = process.env.GALAXUS_PORTAL ?? "galaxus";
const language = process.env.GALAXUS_LANGUAGE ?? "en";
const listenHost = process.env.GALAXUS_MCP_HOST ?? "127.0.0.1";
const listenPort = Number(process.env.GALAXUS_MCP_PORT ?? "3002");

// Requests are JSON-RPC calls with a handful of short string arguments; a body
// anywhere near this is not one.
const MAX_BODY_BYTES = 1024 * 1024;

/** The shared secret, from a file where systemd put one, else the environment. */
function readToken() {
  const path = process.env.GALAXUS_MCP_TOKEN_FILE;
  if (!path) return process.env.GALAXUS_MCP_TOKEN || null;
  const token = readFileSync(path, "utf8").trim();
  if (!token) throw new Error(`${path} is empty`);
  return token;
}

/**
 * Upstream's registration loop, kept identical to src/index.ts: same tools, same
 * read-only annotations, same mapping of GalaxusError to a readable message. The
 * hint matters - it is what names `refresh-hashes` when the shop rotates its
 * persisted query hashes and every tool starts failing at once.
 */
function buildServer() {
  const client = new GalaxusClient({ portal, language });
  const server = new McpServer({ name: "galaxus-mcp", version: "0.1.0" });

  for (const tool of buildTools(client)) {
    server.registerTool(
      tool.name,
      {
        title: tool.title,
        description: tool.description,
        inputSchema: tool.schema,
        annotations: { readOnlyHint: true, openWorldHint: true },
      },
      async (args) => {
        try {
          const result = await tool.handler(args);
          return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
        } catch (error) {
          const message =
            error instanceof GalaxusError
              ? [error.message, error.hint].filter(Boolean).join(" ")
              : error instanceof Error
                ? error.message
                : String(error);
          return { content: [{ type: "text", text: message }], isError: true };
        }
      },
    );
  }
  return server;
}

function authorized(req, secret) {
  const match = /^Bearer (.+)$/.exec(req.headers.authorization ?? "");
  if (!match) return false;
  const given = Buffer.from(match[1]);
  const expected = Buffer.from(secret);
  // timingSafeEqual throws on a length mismatch, so the lengths have to be
  // compared first - which leaks only the length of the token.
  return given.length === expected.length && timingSafeEqual(given, expected);
}

/** Collect and parse a JSON body, or answer the request and return undefined. */
async function readJsonBody(req, res) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      res.writeHead(413).end();
      req.destroy();
      return undefined;
    }
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) return undefined;
  try {
    return JSON.parse(raw);
  } catch {
    res.writeHead(400, { "content-type": "application/json" }).end(
      JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }),
    );
    return null;
  }
}

async function serveHttp(secret) {
  if (!secret) console.warn("galaxus-mcp: no token configured - serving HTTP without auth");

  const httpServer = createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
      if (url.pathname !== "/mcp") {
        res.writeHead(404).end();
        return;
      }
      if (secret && !authorized(req, secret)) {
        res.writeHead(401, { "www-authenticate": 'Bearer realm="galaxus-mcp"' }).end();
        return;
      }

      let body;
      if (req.method === "POST") {
        body = await readJsonBody(req, res);
        // null means readJsonBody has already answered; undefined means no body.
        if (body === null || res.writableEnded) return;
      }

      // Stateless: a transport and server per request, so there is no session
      // table to keep, expire or leak. Every tool here is a read-only lookup
      // with no state to carry between calls, so nothing is lost by it.
      const server = buildServer();
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      res.on("close", () => {
        transport.close();
        server.close();
      });
      await server.connect(transport);
      await transport.handleRequest(req, res, body);
    } catch (error) {
      console.error("galaxus-mcp: request failed", error);
      if (!res.headersSent) res.writeHead(500).end();
    }
  });

  httpServer.listen(listenPort, listenHost, () => {
    console.error(`galaxus-mcp: listening on http://${listenHost}:${listenPort}/mcp`);
  });
}

if ((process.env.GALAXUS_MCP_TRANSPORT ?? "stdio") === "stdio") {
  await buildServer().connect(new StdioServerTransport());
} else {
  await serveHttp(readToken());
}
