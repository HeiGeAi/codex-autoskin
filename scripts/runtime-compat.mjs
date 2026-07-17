import path from "node:path";
import { fileURLToPath } from "node:url";

export const MIN_NODE_MAJOR = 22;

export function assertSupportedRuntime(options = {}) {
  const nodeVersion = options.nodeVersion ?? process.versions.node;
  const WebSocketClass = Object.hasOwn(options, "WebSocketClass")
    ? options.WebSocketClass
    : globalThis.WebSocket;
  const major = Number.parseInt(String(nodeVersion).split(".", 1)[0], 10);
  if (!Number.isInteger(major) || major < MIN_NODE_MAJOR) {
    throw new Error(`Codex AutoSkin requires Node.js ${MIN_NODE_MAJOR} or newer; found ${nodeVersion}.`);
  }
  if (typeof WebSocketClass !== "function") {
    throw new Error(`Codex AutoSkin requires the global WebSocket available in Node.js ${MIN_NODE_MAJOR} or newer.`);
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    assertSupportedRuntime();
    if (!process.argv.includes("--quiet")) {
      console.log(`Codex AutoSkin runtime OK: Node.js ${process.versions.node}`);
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
