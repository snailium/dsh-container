// dsh-tls-relay.js — TLS termination + per-request HTTP/1.1 relay → DSH web
//
// WHAT: https://<lan-ip>:8443 (TLS) -> http://127.0.0.1:3080 (DSH GUI).
// Works for plain HTTP RPC and WebSocket upgrades alike.
//
// WHY PER-REQUEST REWRITE (the old relay only rewrote the FIRST request of a
// connection, then piped everything — browsers reuse one TLS socket for many
// keep-alive requests, so every request after the first flew with the
// untrusted LAN authority (Host: 192.168.1.1:8443) and was 403'd by dsh's
// fence. Symptom: sporadic "transport failure for /api/<method>: HTTP 403").
//
// FENCE INVARIANT (keep it!): the relay rewrites `Host:` and `Origin:` of
// EVERY request head to TRUSTED_AUTHORITY — a declared NON-LOOPBACK trusted
// entry (192.168.1.1:3080). dsh's loopback-only privileged methods
// (settings.*, credentials.*, host.pickDirectory/openPath, agentPreset.*,
// llm.discoverModels) therefore stay 403 for the LAN browser, exactly as
// designed. Never point this at a loopback authority.
//
// The relay tracks request framing only to know where a body ends (so the
// next head can be found); every byte — request or response — passes through
// unmodified: chunked bodies, 100-continue, response encodings, and the
// post-upgrade WebSocket byte stream all survive intact.
//
// Usage: node dsh-tls-relay.js [bind] [port] [certFile] [targetHost] [targetPort] [trustedAuthority]
"use strict";
const tls = require("node:tls");
const net = require("node:net");
const fs = require("node:fs");

const [
  bindAddr = "0.0.0.0",
  port = 8443,
  certFile = "/home/user/deepseek-harness/tls/server.pem",
  targetHost = "127.0.0.1",
  targetPort = 3080,
  trustedAuthority = "192.168.1.1:3080",
] = process.argv.slice(2);

const MAX_HEAD_BYTES = 64 * 1024;
const keyCert = fs.readFileSync(certFile); // combined cert + private key

/** Rewrite the Host/Origin authority lines of one completed head (latin1-safe). */
function rewriteHead(head, authority) {
  const lines = head.toString("latin1").split("\r\n");
  let scheme = "http";
  for (let i = 1; i < lines.length; i++) {
    const m = lines[i].match(/^origin:[ \t]*(\w+):\/\//i);
    if (m) { scheme = m[1].toLowerCase(); break; }
  }
  const hasHost = lines.slice(1).some((l) => l.toLowerCase().startsWith("host:"));
  if (!hasHost) lines.splice(1, 0, `Host: ${authority}`);
  let hostSeen = false;
  for (let i = 1; i < lines.length; i++) {
    const lower = lines[i].toLowerCase();
    if (!hostSeen && lower.startsWith("host:")) { lines[i] = `Host: ${authority}`; hostSeen = true; }
    else if (lower.startsWith("origin:")) { lines[i] = `Origin: ${scheme}://${authority}`; }
  }
  return Buffer.from(lines.join("\r\n"), "latin1");
}

function headBodyState(head) {
  let state = null, rem = 0;
  for (const line of head.toString("latin1").split("\r\n").slice(1)) {
    const lower = line.toLowerCase();
    if (lower.startsWith("transfer-encoding:") && /\bchunked\b/.test(lower)) { state = "SIZE"; }
    else if (lower.startsWith("content-length:")) { rem = Number.parseInt(line.slice(16).split(";")[0].trim(), 10) || 0; }
  }
  if (state === "SIZE") return { state, rem };
  return { state: rem === 0 ? "HEAD" : "CL", rem };
}

function headIsUpgrade(head) {
  for (const line of head.toString("latin1").split("\r\n").slice(1)) {
    const lower = line.toLowerCase().trim();
    if (lower.startsWith("upgrade:")) return true;
    if (lower.startsWith("connection:") && /\bupgrade\b/.test(lower.replace("connection:", ""))) return true;
  }
  return false;
}

const server = tls.createServer({ cert: keyCert, key: keyCert, ciphers: "DEFAULT" }, (client) => {
  client.setNoDelay(true);
  const upstream = new net.Socket();
  upstream.setNoDelay(true);

  let closed = false;
  const closeBoth = () => {
    if (closed) return;
    closed = true;
    try { client.destroy(); } catch { /* already gone */ }
    try { upstream.destroy(); } catch { /* already gone */ }
  };
  upstream.on("error", closeBoth);
  client.on("error", closeBoth);
  client.on("close", closeBoth);
  upstream.on("close", closeBoth);
  upstream.on("drain", () => { if (!closed) client.resume(); });

  // Response direction: pure byte pipe (node handles backpressure to the client).
  upstream.pipe(client);

  const r = { state: "HEAD", head: null, buf: null, rem: 0, raw: false };
  const write = (b) => {
    if (closed || b.length === 0) return;
    if (!upstream.write(b)) client.pause();
  };

  const afterHead = (head) => {
    write(rewriteHead(head, trustedAuthority));
    if (headIsUpgrade(head)) {
      r.raw = true; // upgrade handshake owns the socket from here on
      return;
    }
    const bs = headBodyState(head);
    r.state = bs.state;
    r.rem = bs.rem;
  };

  const feed = (chunk) => {
    if (closed) return;
    if (r.raw) { write(chunk); return; }
    if (r.state === "HEAD") {
      r.buf = null;
      r.head = r.head ? Buffer.concat([r.head, chunk]) : Buffer.from(chunk);
    } else {
      r.buf = r.buf ? Buffer.concat([r.buf, chunk]) : Buffer.from(chunk);
    }
    while (!closed) {
      if (r.state === "HEAD") {
        if (r.head === null) { r.head = r.buf ? r.buf : Buffer.alloc(0); r.buf = null; }
        const end = r.head.indexOf("\r\n\r\n");
        if (end === -1) {
          if (r.head.length > MAX_HEAD_BYTES) { console.error("relay: head exceeds limit; closing"); closeBoth(); }
          return; // wait for the rest of this head
        }
        const head = r.head.subarray(0, end + 4);
        r.buf = r.head.subarray(end + 4);
        r.head = null;
        afterHead(head);
        if (closed) return;
        if (r.raw) { if (r.buf.length) write(r.buf); r.buf = null; return; }
        if (r.buf.length === 0) return; // no body bytes from this event
        continue;
      }
      if (r.buf === null || r.buf.length === 0) return; // wait for body bytes
      if (r.state === "CL" || r.state === "DATA") {
        const take = Math.min(r.rem, r.buf.length);
        write(r.buf.subarray(0, take));
        r.buf = r.buf.subarray(take);
        r.rem -= take;
        if (r.rem === 0) r.state = r.state === "CL" ? "HEAD" : "CRLF2";
        continue;
      }
      if (r.state === "CRLF2") {
        if (r.buf.length >= 2 && r.buf[0] === 0x0d && r.buf[1] === 0x0a) {
          write(r.buf.subarray(0, 2));
          r.buf = r.buf.subarray(2);
          r.state = "SIZE";
          continue;
        }
        if (r.buf.length > 2) { console.error("relay: bad chunk terminator; closing"); closeBoth(); return; }
        return; // wait for the rest of the CRLF
      }
      if (r.state === "SIZE") {
        const idx = r.buf.indexOf("\r\n");
        if (idx === -1) {
          if (r.buf.length > 1024) { console.error("relay: bad chunk size line; closing"); closeBoth(); }
          return;
        }
        const hex = r.buf.subarray(0, idx).toString("latin1").split(";", 1)[0].trim();
        if (!/^[0-9a-f]+$/i.test(hex)) { console.error("relay: bad chunk size; closing"); closeBoth(); return; }
        const n = Number.parseInt(hex, 16);
        write(r.buf.subarray(0, idx + 2));
        r.buf = r.buf.subarray(idx + 2);
        if (n === 0) r.state = "TRAIL";
        else { r.rem = n; r.state = "DATA"; }
        continue;
      }
      // TRAIL: pass trailer lines; the terminating empty line ends the message.
      const idx = r.buf.indexOf("\r\n");
      if (idx === -1) {
        if (r.buf.length > MAX_HEAD_BYTES) { console.error("relay: trailer run too long; closing"); closeBoth(); }
        return;
      }
      write(r.buf.subarray(0, idx + 2));
      r.buf = r.buf.subarray(idx + 2);
      if (idx === 0) r.state = "HEAD";
      continue;
    }
  };

  // Read the client only once upstream is connected, so no bytes can be
  // consumed but unforwarded.
  upstream.connect(Number(targetPort), targetHost, () => {
    client.on("data", feed);
    client.resume();
  });
});

server.on("tls_client_error", (err, socket) => {
  try { socket.destroy(); } catch { /* already gone */ }
});

server.listen(Number(port), bindAddr, () => {
  console.log(`DSH TLS relay: https://${bindAddr}:${port} -> http://${targetHost}:${targetPort} (trusted-as ${trustedAuthority}, per-request rewrite)`);
});
