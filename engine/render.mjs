// ResumeGrabber rendering engine.
//
// Runs resume.io's own rendering web worker inside a Node.js vm sandbox and writes the
// multi-page vector PDF it produces straight to disk.
//
// Adapted from felipeall/resumeio-to-pdf (MIT License, Copyright (c) 2022 Felipe Allegretti).
//
// Usage: node render.mjs <payload.json> <output.pdf>
//   payload.json = { document, config, assetsDir, entry, host }

import { webcrypto } from "node:crypto";
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { join, basename } from "node:path";
import vm from "node:vm";

const STARTUP_TIMEOUT_MS = 15_000;
const RENDER_TIMEOUT_MS = 90_000;
const ALLOWED_HOST = /(^|\.)resume\.io$/;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
const MAX_REDIRECTS = 5;

const [payloadPath, outputPath] = process.argv.slice(2);
if (!payloadPath || !outputPath) {
  console.error("Error: usage: node render.mjs <payload.json> <output.pdf>");
  process.exit(2);
}

const log = (msg) => process.stderr.write(`[engine] ${msg}\n`);

function assertAllowed(target) {
  if (target.protocol !== "data:" && !ALLOWED_HOST.test(target.hostname)) {
    throw new Error(`blocked request to ${target.hostname || target.protocol}`);
  }
}

const raw = readFileSync(payloadPath, "utf8").replace(/^﻿/, "");
const { document, config, assetsDir, entry, host } = JSON.parse(raw);

let settle;
const rendered = new Promise((resolve, reject) => {
  settle = { resolve, reject };
});

// A fresh context brings its own ECMAScript globals; everything else the worker expects
// from a browser WorkerGlobalScope is handed over explicitly. Host functions must keep
// globalThis as their receiver or Node throws ERR_INVALID_THIS.
const context = vm.createContext();
Object.assign(context, {
  importScripts(...urls) {
    for (const url of urls) {
      const name = basename(String(url).split("?")[0]);
      const file = join(assetsDir, name);
      vm.runInContext(readFileSync(file, "utf8"), context, { filename: file });
    }
  },
  postMessage(message) {
    if (message && message.success) settle.resolve(message.result);
    else settle.reject(new Error(message?.error?.message || "worker reported failure"));
  },
  location: new URL(host),
  navigator: { userAgent: "Mozilla/5.0 ResumeGrabber", language: "en-US", hardwareConcurrency: 4 },
  console: { log() {}, info() {}, debug() {}, warn: console.warn, error: console.error },
  setTimeout: setTimeout.bind(globalThis),
  clearTimeout: clearTimeout.bind(globalThis),
  setInterval: setInterval.bind(globalThis),
  clearInterval: clearInterval.bind(globalThis),
  queueMicrotask: queueMicrotask.bind(globalThis),
  structuredClone: structuredClone.bind(globalThis),
  async fetch(input, init) {
    let target = new URL(input?.url ?? input, host);
    assertAllowed(target);
    let response = await fetch(input instanceof Request ? input : target, { ...init, redirect: "manual" });

    // Follow redirects by hand so every hop goes through the allowlist.
    for (let hop = 0; REDIRECT_STATUSES.has(response.status); hop++) {
      const location = response.headers.get("location");
      if (!location) return toContextRealm(response);
      if (hop === MAX_REDIRECTS) throw new Error(`too many redirects for ${target}`);
      target = new URL(location, target);
      assertAllowed(target);
      response = await fetch(target, { redirect: "manual" });
    }
    return toContextRealm(response);
  },
  btoa: btoa.bind(globalThis),
  atob: atob.bind(globalThis),
  TextEncoder,
  TextDecoder,
  URL,
  URLSearchParams,
  Blob,
  Response,
  Request,
  Headers,
  AbortController,
  AbortSignal,
  ReadableStream,
  performance,
  crypto: globalThis.crypto ?? webcrypto,
  webpackChunk_rio_web_worker: [],
});
context.self = context;

// Bytes from Node's fetch belong to the host realm; the worker's Buffer polyfill checks
// `instanceof ArrayBuffer` against its own realm and would silently drop images such as
// the profile photo. Copy them into an ArrayBuffer of the worker's realm.
const ContextUint8Array = vm.runInContext("Uint8Array", context);
function toContextRealm(response) {
  const arrayBuffer = response.arrayBuffer.bind(response);
  response.arrayBuffer = async () => ContextUint8Array.from(new Uint8Array(await arrayBuffer())).buffer;
  return response;
}

log("booting resume.io rendering worker");
vm.runInContext(readFileSync(join(assetsDir, entry), "utf8"), context, { filename: entry });

for (let waited = 0; typeof context.onmessage !== "function"; waited += 10) {
  if (waited > STARTUP_TIMEOUT_MS) throw new Error("worker did not register an onmessage handler");
  await new Promise((resolve) => setTimeout(resolve, 10));
}

log("rendering pages");
context.onmessage({ data: { taskId: "render", document, config, host } });

const timeout = new Promise((_, reject) =>
  setTimeout(() => reject(new Error("rendering timed out")), RENDER_TIMEOUT_MS).unref(),
);

const result = await Promise.race([rendered, timeout]);
const bytes = Buffer.from(result);
if (bytes.subarray(0, 4).toString("latin1") !== "%PDF") {
  throw new Error("worker returned something that is not a PDF");
}

const partial = `${outputPath}.part`;
writeFileSync(partial, bytes);
renameSync(partial, outputPath);
log(`wrote ${bytes.length} bytes`);
process.exit(0);
