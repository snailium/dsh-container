#!/usr/bin/env node
// dsh-tls-relay 纯函数单元测试 (review M2)
// 运行: node docker/test/dsh-tls-relay.test.js
//       或容器构建时 npm run test (见 Dockerfile/CI)
const assert = require("node:assert");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");
const { execFileSync } = require("node:child_process");

// 测试自举: relay 模块加载需一个合法证书(惰性 loadKeyCert)。无则生成临时自签。
if (!process.env.DSH_TLS_CERT) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "relaytest-"));
  const serverPem = path.join(dir, "server.pem");
  try {
    execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", path.join(dir, "key.pem"), "-out", path.join(dir, "cert.pem"),
      "-days", "1", "-subj", "/CN=test"], { stdio: "ignore" });
    fs.writeFileSync(serverPem, fs.readFileSync(path.join(dir, "cert.pem")) + fs.readFileSync(path.join(dir, "key.pem")));
  } catch {
    // openssl 不可用: 用最小自签(测试只需 keyCert 可读, 不真正握手)
    fs.writeFileSync(serverPem, "-----BEGIN PRIVATE KEY-----\nMIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEAj\n-----END PRIVATE KEY-----\n");
  }
  process.env.DSH_TLS_CERT = serverPem;
}

const { rewriteHead, headBodyState, headIsUpgrade } = require(
  path.join(__dirname, "..", "dsh-tls-relay.js")
);

const AUTH = "192.168.1.1:3080";
let failed = 0;
function ok(name, fn) {
  try { fn(); console.log(`  ✓ ${name}`); }
  catch (e) { failed++; console.log(`  ✗ ${name}: ${e.message}`); }
}

// helpers
function req(method, path_, headers = {}) {
  const h = [`${method} ${path_} HTTP/1.1`];
  for (const [k, v] of Object.entries(headers)) h.push(`${k}: ${v}`);
  return Buffer.from(h.join("\r\n") + "\r\n", "latin1");
}

console.log("## rewriteHead");
ok("Host 被重写为 authority", () => {
  const out = rewriteHead(req("GET", "/", { Host: "evil:8443" }), AUTH).toString("latin1");
  assert.ok(out.includes(`Host: ${AUTH}`));
  assert.ok(!out.includes("evil:8443"));
});
ok("缺 Host 时补全", () => {
  const out = rewriteHead(req("GET", "/api/x", {}), AUTH).toString("latin1");
  assert.ok(out.includes(`Host: ${AUTH}`));
});
ok("Origin 重写且保留原 scheme", () => {
  const out = rewriteHead(
    req("POST", "/api/y", { Host: "a:8443", Origin: "https://a:8443" }), AUTH
  ).toString("latin1");
  assert.ok(out.includes(`Origin: https://${AUTH}`), out);
});
ok("keep-alive 多请求逐条重写(FENCE INVARIANT)", () => {
  // 模拟同一 TLS 连接复用 socket 的两个请求
  const headA = rewriteHead(req("GET", "/one", { Host: "a:8443" }), AUTH).toString("latin1");
  const headB = rewriteHead(req("GET", "/two", { Host: "a:8443" }), AUTH).toString("latin1");
  assert.ok(headA.includes(`Host: ${AUTH}`) && headB.includes(`Host: ${AUTH}`));
});

console.log("## headBodyState");
ok("Content-Length 判定 CL", () => {
  const s = headBodyState(req("POST", "/x", { "Content-Length": "42" }));
  assert.deepStrictEqual(s, { state: "CL", rem: 42 });
});
ok("Content-Length: 0 判定 HEAD", () => {
  const s = headBodyState(req("GET", "/x", { "Content-Length": "0" }));
  assert.deepStrictEqual(s, { state: "HEAD", rem: 0 });
});
ok("Transfer-Encoding: chunked 判定 SIZE", () => {
  const s = headBodyState(req("POST", "/x", { "Transfer-Encoding": "chunked" }));
  assert.deepStrictEqual(s, { state: "SIZE", rem: 0 });
});

console.log("## headIsUpgrade");
ok("Upgrade: websocket 判定 upgrade", () => {
  assert.ok(headIsUpgrade(req("GET", "/ws", { Upgrade: "websocket", Connection: "Upgrade" })));
});
ok("非 upgrade 判定 false", () => {
  assert.ok(!headIsUpgrade(req("GET", "/x", { Host: "a" })));
});

console.log(`\n${failed === 0 ? "ALL PASS" : `${failed} FAILED`}`);
process.exit(failed === 0 ? 0 : 1);