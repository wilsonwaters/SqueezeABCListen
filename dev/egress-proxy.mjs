#!/usr/bin/env node
// egress-proxy.mjs - local CONNECT proxy that lets LMS (and squeezelite) reach the
// internet from this sandbox. Dev tooling only; not part of the plugin.
//
// Why it exists (see ai-state/RUNBOOK.md for the full story):
//   * The sandbox's only sanctioned egress is an HTTPS CONNECT proxy ($HTTPS_PROXY).
//   * LMS has no CONNECT/HTTPS proxy support, so LMS is wrapped in proxychains4
//     (LD_PRELOAD), which turns every outbound TCP connect() into
//     "CONNECT <ip>:<port>" sent to THIS helper.
//   * Egress for plain HTTP is inspected upstream and HTTP/1.0 requests are
//     rejected with "426 Upgrade Required" -- and LMS speaks HTTP/1.0 everywhere.
//     The upstream proxy also insists that the CONNECT target matches the Host
//     header, while proxychains only knows the IP.
//
// What it does for each CONNECT from proxychains:
//   1. Replies "200 Connection Established" immediately (keeps LMS's event loop snappy).
//   2. Sniffs the first bytes the client sends:
//      - TLS ClientHello (0x16): extracts SNI and opens an upstream tunnel to
//        <sni>:<port> via $HTTPS_PROXY, then pipes bytes both ways untouched.
//      - HTTP request: parses it, re-issues it upstream as HTTP/1.1 (Connection: close)
//        through a tunnel to <Host header>:<port>, de-chunks the response and
//        returns it close-delimited (no Transfer-Encoding) so HTTP/1.0 clients cope.
//      - anything else: raw tunnel to the original <ip>:<port>.
//   If $HTTPS_PROXY is unset, upstream connections are made directly.
//   There is deliberately no host allowlist here: every host is forwarded and the upstream
//   policy proxy decides (it answers 502 to CONNECT for hosts it does not allow).
//
// Env: EGRESS_PORT (default 3129), EGRESS_HOST (default 127.0.0.1), EGRESS_DEBUG=1.

import http from 'node:http';
import net from 'node:net';

const LISTEN_HOST = process.env.EGRESS_HOST || '127.0.0.1';
const LISTEN_PORT = Number(process.env.EGRESS_PORT || 3129);
const UPSTREAM_RAW = process.env.HTTPS_PROXY || process.env.https_proxy || '';
const UPSTREAM = UPSTREAM_RAW ? new URL(UPSTREAM_RAW) : null;
const DEBUG = process.env.EGRESS_DEBUG === '1';
const TUNNEL_TIMEOUT_MS = 15000;
const SNIFF_TIMEOUT_MS = 5000;
const MAX_HEAD = 64 * 1024;
const HOP_BY_HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'te', 'trailer', 'upgrade']);

let connSeq = 0;
const log = (...a) => console.log(new Date().toISOString(), ...a);
const dbg = (...a) => { if (DEBUG) log(...a); };

function splitHostPort(s, defPort) {
  const m = /^\[([^\]]+)\](?::(\d+))?$/.exec(s) || /^([^:]+)(?::(\d+))?$/.exec(s);
  if (!m) return { host: s, port: defPort };
  return { host: m[1], port: m[2] ? Number(m[2]) : defPort };
}
const fmtHostPort = (h, p) => (h.includes(':') ? `[${h}]:${p}` : `${h}:${p}`);

// Open a TCP stream to host:port, through the upstream CONNECT proxy when configured.
function openTunnel(host, port) {
  return new Promise((resolve, reject) => {
    const target = fmtHostPort(host, port);
    const sock = UPSTREAM
      ? net.connect(Number(UPSTREAM.port || 80), UPSTREAM.hostname)
      : net.connect(port, host);
    let done = false;
    const fail = (err) => { if (done) return; done = true; sock.destroy(); reject(err); };
    sock.setTimeout(TUNNEL_TIMEOUT_MS, () => fail(new Error(`timeout opening ${target}`)));
    sock.once('error', fail);
    sock.once('connect', () => {
      if (!UPSTREAM) { done = true; sock.setTimeout(0); sock.removeListener('error', fail); return resolve(sock); }
      let auth = '';
      if (UPSTREAM.username) {
        auth = `Proxy-Authorization: Basic ${Buffer.from(`${decodeURIComponent(UPSTREAM.username)}:${decodeURIComponent(UPSTREAM.password)}`).toString('base64')}\r\n`;
      }
      sock.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n${auth}\r\n`);
      let buf = Buffer.alloc(0);
      const onData = (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        const end = buf.indexOf('\r\n\r\n');
        if (end < 0) { if (buf.length > MAX_HEAD) fail(new Error('oversized CONNECT reply')); return; }
        sock.removeListener('data', onData);
        const statusLine = buf.subarray(0, buf.indexOf('\r\n')).toString('latin1');
        const code = Number((/^HTTP\/1\.\d (\d{3})/.exec(statusLine) || [])[1]);
        if (code !== 200) return fail(new Error(`upstream CONNECT ${target} -> ${statusLine}`));
        const rest = buf.subarray(end + 4);
        if (rest.length) sock.unshift(rest);
        done = true;
        sock.setTimeout(0);
        sock.removeListener('error', fail);
        resolve(sock);
      };
      sock.on('data', onData);
    });
  });
}

// Parse SNI from a TLS ClientHello. Returns: hostname string, null (no SNI), or undefined (need more data).
function parseSni(buf) {
  if (buf.length < 5) return undefined;
  const recLen = buf.readUInt16BE(3);
  if (buf.length < 5 + recLen) return recLen > 16384 ? null : undefined;
  try {
    let p = 5;
    if (buf[p] !== 0x01) return null; // not ClientHello
    p += 4; // type + 3-byte length
    p += 2 + 32; // client_version + random
    p += 1 + buf[p]; // session id
    p += 2 + buf.readUInt16BE(p); // cipher suites
    p += 1 + buf[p]; // compression methods
    if (p + 2 > 5 + recLen) return null;
    const extEnd = p + 2 + buf.readUInt16BE(p);
    p += 2;
    while (p + 4 <= extEnd) {
      const type = buf.readUInt16BE(p);
      const len = buf.readUInt16BE(p + 2);
      p += 4;
      if (type === 0x0000) {
        let q = p + 2; // server_name_list length
        while (q + 3 <= p + len) {
          const nameType = buf[q];
          const nameLen = buf.readUInt16BE(q + 1);
          if (nameType === 0) return buf.subarray(q + 3, q + 3 + nameLen).toString('ascii');
          q += 3 + nameLen;
        }
        return null;
      }
      p += len;
    }
  } catch { /* malformed */ }
  return null;
}

function pipeBoth(a, b, id, label) {
  a.pipe(b); b.pipe(a);
  const close = () => { a.destroy(); b.destroy(); };
  a.on('error', (e) => { dbg(`#${id} ${label} client error: ${e.message}`); close(); });
  b.on('error', (e) => { dbg(`#${id} ${label} upstream error: ${e.message}`); close(); });
  a.on('close', close); b.on('close', close);
}

async function handleTls(client, first, target, id) {
  let buf = first;
  let sni = parseSni(buf);
  const deadline = Date.now() + SNIFF_TIMEOUT_MS;
  while (sni === undefined && Date.now() < deadline && buf.length < 20000) {
    const more = await readChunk(client, deadline - Date.now());
    if (!more) break;
    buf = Buffer.concat([buf, more]);
    sni = parseSni(buf);
  }
  const upHost = sni || target.host;
  log(`#${id} TLS ${fmtHostPort(target.host, target.port)} sni=${sni || '-'} -> tunnel ${fmtHostPort(upHost, target.port)}`);
  let up;
  try { up = await openTunnel(upHost, target.port); } catch (e) {
    log(`#${id} TLS tunnel failed: ${e.message}`); client.destroy(); return;
  }
  up.write(buf);
  pipeBoth(client, up, id, 'tls');
}

function readChunk(sock, timeoutMs) {
  return new Promise((resolve) => {
    const t = setTimeout(() => { cleanup(); resolve(null); }, Math.max(1, timeoutMs));
    const onData = (d) => { cleanup(); sock.pause(); resolve(d); };
    const onEnd = () => { cleanup(); resolve(null); };
    const cleanup = () => { clearTimeout(t); sock.removeListener('data', onData); sock.removeListener('end', onEnd); sock.removeListener('close', onEnd); };
    sock.on('data', onData); sock.once('end', onEnd); sock.once('close', onEnd);
    sock.resume();
  });
}

async function handleHttp(client, first, target, id) {
  let buf = first;
  const deadline = Date.now() + SNIFF_TIMEOUT_MS * 2;
  while (buf.indexOf('\r\n\r\n') < 0) {
    if (buf.length > MAX_HEAD || Date.now() > deadline) { client.destroy(); return; }
    const more = await readChunk(client, deadline - Date.now());
    if (!more) { client.destroy(); return; }
    buf = Buffer.concat([buf, more]);
  }
  const headEnd = buf.indexOf('\r\n\r\n');
  const lines = buf.subarray(0, headEnd).toString('latin1').split('\r\n');
  const body = buf.subarray(headEnd + 4);
  const m = /^([A-Z]+) (\S+) HTTP\/(1\.[01])$/.exec(lines[0]);
  if (!m) { log(`#${id} bad request line: ${lines[0]}`); client.destroy(); return; }
  const [, method, rawPath, clientVer] = m;
  const rawHeaders = [];
  let hostHeader = null;
  let contentLength = 0;
  for (const line of lines.slice(1)) {
    const i = line.indexOf(':');
    if (i <= 0) continue;
    const k = line.slice(0, i).trim();
    const v = line.slice(i + 1).trim();
    const lk = k.toLowerCase();
    if (lk === 'host') hostHeader = v;
    if (lk === 'content-length') contentLength = Number(v) || 0;
    if (HOP_BY_HOP.has(lk)) continue;
    rawHeaders.push(k, v);
  }
  let path = rawPath;
  let upHost = hostHeader ? splitHostPort(hostHeader, target.port).host : target.host;
  if (/^https?:\/\//i.test(rawPath)) { // absolute-form, just in case
    const u = new URL(rawPath);
    upHost = u.hostname; path = u.pathname + u.search;
  }
  if (!hostHeader) rawHeaders.unshift('Host', upHost);
  rawHeaders.push('Connection', 'close');
  log(`#${id} HTTP/${clientVer} ${method} http://${fmtHostPort(upHost, target.port)}${path} (connected to ${target.host})`);

  let up;
  try { up = await openTunnel(upHost, target.port); } catch (e) {
    log(`#${id} HTTP tunnel failed: ${e.message}`);
    client.end(`HTTP/${clientVer} 502 Bad Gateway\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\negress-proxy: ${e.message}\n`);
    return;
  }
  const upReq = http.request({
    method, path, headers: rawHeaders, setHost: false, // no agent: createConnection is only honoured without one
    createConnection: () => up,
  });
  let responded = false;
  upReq.on('response', (upRes) => {
    responded = true;
    const out = [];
    for (let i = 0; i < upRes.rawHeaders.length; i += 2) {
      if (HOP_BY_HOP.has(upRes.rawHeaders[i].toLowerCase())) continue;
      out.push(`${upRes.rawHeaders[i]}: ${upRes.rawHeaders[i + 1]}`);
    }
    out.push('Connection: close');
    log(`#${id} <- ${upRes.statusCode} ${upRes.headers['content-type'] || ''}${upRes.headers['transfer-encoding'] ? ' (de-chunked)' : ''}`);
    client.write(`HTTP/${clientVer} ${upRes.statusCode} ${upRes.statusMessage || ''}\r\n${out.join('\r\n')}\r\n\r\n`);
    upRes.pipe(client);
    upRes.on('error', () => client.destroy());
  });
  upReq.on('error', (e) => {
    log(`#${id} upstream request error: ${e.message}`);
    if (!responded) client.end(`HTTP/${clientVer} 502 Bad Gateway\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\negress-proxy: ${e.message}\n`);
    else client.destroy();
  });
  client.on('error', () => upReq.destroy());
  client.on('close', () => { upReq.destroy(); up.destroy(); });

  // request body (e.g. POST): forward whatever the client sends after the head
  if (body.length) upReq.write(body);
  if (contentLength > body.length) {
    let remaining = contentLength - body.length;
    client.on('data', (d) => {
      if (remaining <= 0) return;
      upReq.write(d.subarray(0, remaining));
      remaining -= d.length;
      if (remaining <= 0) upReq.end();
    });
    client.resume();
  } else {
    upReq.end();
  }
}

const server = http.createServer((req, res) => {
  res.writeHead(405, { 'Content-Type': 'text/plain', Connection: 'close' });
  res.end('egress-proxy only supports CONNECT (use it via proxychains4 or curl -p -x)\n');
});
server.requestTimeout = 0;
server.timeout = 0;

server.on('connect', (req, client, head) => {
  const id = ++connSeq;
  const target = splitHostPort(req.url, 443);
  client.on('error', (e) => dbg(`#${id} client socket error: ${e.message}`));
  client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
  const start = async () => {
    const first = head && head.length ? head : await readChunk(client, SNIFF_TIMEOUT_MS);
    if (!first) { // client silent (server-speaks-first protocol?) -> raw tunnel
      dbg(`#${id} no client bytes; raw tunnel to ${req.url}`);
      try { const up = await openTunnel(target.host, target.port); pipeBoth(client, up, id, 'raw'); } catch (e) { log(`#${id} raw tunnel failed: ${e.message}`); client.destroy(); }
      return;
    }
    if (first[0] === 0x16) return handleTls(client, first, target, id);
    if (/^[A-Z]{3,10} /.test(first.subarray(0, 12).toString('latin1'))) return handleHttp(client, first, target, id);
    log(`#${id} RAW ${req.url}`);
    try { const up = await openTunnel(target.host, target.port); up.write(first); pipeBoth(client, up, id, 'raw'); } catch (e) { log(`#${id} raw tunnel failed: ${e.message}`); client.destroy(); }
  };
  start().catch((e) => { log(`#${id} error: ${e.stack || e}`); client.destroy(); });
});

server.on('clientError', (err, sock) => { dbg(`clientError: ${err.message}`); sock.destroy(); });
process.on('uncaughtException', (e) => log(`uncaughtException: ${e.stack || e}`));
process.on('SIGTERM', () => { log('SIGTERM, exiting'); process.exit(0); });

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log(`egress-proxy listening on ${LISTEN_HOST}:${LISTEN_PORT}; upstream=${UPSTREAM ? UPSTREAM.host : 'DIRECT'}`);
});
