// Convex portal on black: a passkey login in front of the shared Convex
// dashboard, the list of deployments, and each deployment's dashboard with its
// admin key applied, so nobody copies keys around (hosts/black/convex.nix).
//
// It lives under /_portal on the dashboard's own origin because the dashboard
// only allows same-origin framing. The deployment page frames the dashboard and
// answers its "dashboard-credentials-request" postMessage (the hook the
// dashboard has for embedding) with the deployment URL and admin key.
// Traefik asks /_portal/auth before every dashboard request (forwardAuth):
// without a session the dashboard answers nothing, and opened directly it
// sends you to the list.
//
// Passkeys are enrolled with a one-time link from `convex-portal-enroll` on
// black. Node built-ins only: the browser hands over the public key as SPKI at
// enrollment, so verifying a login is one signature check.
import { createPublicKey, createHash, createHmac, randomBytes, timingSafeEqual, verify } from "node:crypto";
import { readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const { origin, rpId, deployments } = JSON.parse(readFileSync(process.env.PORTAL_CONFIG, "utf8"));
const stateFile = (name) => `${process.env.PORTAL_STATE_DIR}/${name}`;
const COOKIE = "__Host-convex-portal";
const SESSION_SECONDS = 12 * 60 * 60;
const CHALLENGE_MS = 2 * 60 * 1000;
// ES256 and RS256, what platform authenticators and security keys use.
const ALGORITHMS = [-7, -257];
// One admin user; every passkey belongs to it.
const USER_ID = createHash("sha256").update("convex-portal-admin").digest().subarray(0, 16);

const sha256 = (data) => createHash("sha256").update(data).digest();
const b64 = (buf) => Buffer.from(buf).toString("base64url");
const unb64 = (str) => Buffer.from(String(str ?? ""), "base64url");
const now = () => Math.floor(Date.now() / 1000);

function readJson(name, fallback) {
  try {
    return JSON.parse(readFileSync(stateFile(name), "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
}

function writeJson(name, value) {
  writeFileSync(stateFile(`${name}.tmp`), JSON.stringify(value, null, 2), { mode: 0o600 });
  renameSync(stateFile(`${name}.tmp`), stateFile(name));
}

const sessionKey = (() => {
  const stored = readJson("session-key.json", null);
  if (stored) return unb64(stored.key);
  const key = randomBytes(32);
  writeJson("session-key.json", { key: b64(key) });
  return key;
})();

// Sessions: "<expiry>.<hmac>" in an HttpOnly cookie, nothing stored server-side.
function newSession() {
  const expiry = String(now() + SESSION_SECONDS);
  return `${expiry}.${b64(createHmac("sha256", sessionKey).update(expiry).digest())}`;
}

function hasSession(req) {
  const cookie = (req.headers.cookie ?? "").split(/;\s*/).find((c) => c.startsWith(`${COOKIE}=`));
  if (!cookie) return false;
  const [expiry, mac] = cookie.slice(COOKIE.length + 1).split(".");
  const expected = createHmac("sha256", sessionKey).update(expiry ?? "").digest();
  const given = unb64(mac);
  return given.length === expected.length && timingSafeEqual(given, expected) && Number(expiry) > now();
}

const sessionCookie = (value, maxAge) =>
  `${COOKIE}=${value}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Strict`;

// WebAuthn: single-use challenges, then the checks of the spec's verification
// steps that matter without attestation.
const challenges = new Map();

function issueChallenge(type) {
  for (const [key, c] of challenges) if (c.expires < Date.now()) challenges.delete(key);
  const challenge = b64(randomBytes(32));
  challenges.set(challenge, { type, expires: Date.now() + CHALLENGE_MS });
  return challenge;
}

function checkClientData(clientDataJSON, type) {
  const data = JSON.parse(clientDataJSON.toString("utf8"));
  const challenge = challenges.get(data.challenge);
  challenges.delete(data.challenge);
  if (data.type !== type || data.origin !== origin || data.crossOrigin) throw new Error("client data mismatch");
  if (!challenge || challenge.type !== type || challenge.expires < Date.now()) throw new Error("unknown or expired challenge");
}

function checkAuthenticatorData(authData) {
  if (authData.length < 37 || !authData.subarray(0, 32).equals(sha256(rpId))) throw new Error("wrong relying party");
  // User present and user verified (biometric or PIN), not just a tap.
  if ((authData[32] & 0x05) !== 0x05) throw new Error("user not verified");
  return authData.readUInt32BE(33);
}

function enrollmentToken(token) {
  const pending = readJson("enroll.json", null);
  const given = sha256(String(token ?? ""));
  if (!pending || pending.expires < now() || !given.equals(unb64(pending.hash))) {
    throw new Error("enrollment link invalid or expired, run convex-portal-enroll again");
  }
}

const api = {
  "login/options": () => ({ challenge: issueChallenge("webauthn.get"), rpId }),

  login: (body, res) => {
    const passkeys = readJson("passkeys.json", []);
    const passkey = passkeys.find((p) => p.id === body.id);
    if (!passkey) throw new Error("unknown passkey");
    const clientDataJSON = unb64(body.clientDataJSON);
    const authData = unb64(body.authenticatorData);
    checkClientData(clientDataJSON, "webauthn.get");
    const signCount = checkAuthenticatorData(authData);
    const key = createPublicKey({ key: unb64(passkey.publicKey), format: "der", type: "spki" });
    if (!verify("sha256", Buffer.concat([authData, sha256(clientDataJSON)]), key, unb64(body.signature))) {
      throw new Error("bad signature");
    }
    // Synced passkeys always report 0; a counter that goes backwards means a clone.
    if (signCount !== 0 || passkey.signCount !== 0) {
      if (signCount <= passkey.signCount) throw new Error("signature counter went backwards");
      passkey.signCount = signCount;
    }
    passkey.lastUsed = new Date().toISOString();
    writeJson("passkeys.json", passkeys);
    res.setHeader("set-cookie", sessionCookie(newSession(), SESSION_SECONDS));
    return { ok: true };
  },

  logout: (_body, res) => {
    res.setHeader("set-cookie", sessionCookie("", 0));
    return { ok: true };
  },

  "enroll/options": (body) => {
    enrollmentToken(body.token);
    return {
      challenge: issueChallenge("webauthn.create"),
      rpId,
      userId: b64(USER_ID),
      algorithms: ALGORITHMS,
      exclude: readJson("passkeys.json", []).map((p) => p.id),
    };
  },

  enroll: (body, res) => {
    enrollmentToken(body.token);
    const clientDataJSON = unb64(body.clientDataJSON);
    checkClientData(clientDataJSON, "webauthn.create");
    const signCount = checkAuthenticatorData(unb64(body.authenticatorData));
    if (!ALGORITHMS.includes(body.alg)) throw new Error("unsupported key algorithm");
    const publicKey = unb64(body.publicKey);
    createPublicKey({ key: publicKey, format: "der", type: "spki" });
    const passkeys = readJson("passkeys.json", []);
    passkeys.push({
      id: String(body.id),
      publicKey: b64(publicKey),
      alg: body.alg,
      signCount,
      created: new Date().toISOString(),
    });
    writeJson("passkeys.json", passkeys);
    rmSync(stateFile("enroll.json"), { force: true });
    res.setHeader("set-cookie", sessionCookie(newSession(), SESSION_SECONDS));
    return { ok: true };
  },
};

function credentials(name) {
  const deployment = deployments.find((d) => d.name === name);
  if (!deployment) return null;
  return {
    deploymentName: name,
    deploymentUrl: deployment.url,
    // Read per request: the key file appears on the deployment's first start.
    adminKey: readFileSync(`/keys/${name}`, "utf8").trim(),
  };
}

// Pages.
const escape = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const CLIENT = `
const enc = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
const dec = (str) => Uint8Array.from(atob(str.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
async function post(path, body) {
  const res = await fetch("/_portal/api/" + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body ?? {}) });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error ?? res.statusText);
  return data;
}
const status = (text) => { document.getElementById("status").textContent = text; };
`;

const STYLE = `
:root { color-scheme: light dark; font: 14px/1.5 system-ui, sans-serif; }
body { margin: 0; }
main { max-width: 40rem; margin: 4rem auto; padding: 0 1.5rem; }
h1 { font-size: 1.25rem; margin: 0 0 1.5rem; }
button, .button { font: inherit; padding: .5rem 1rem; border: 1px solid; border-radius: .375rem; background: none; color: inherit; cursor: pointer; text-decoration: none; }
table { width: 100%; border-collapse: collapse; }
td { padding: .75rem .5rem; border-top: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
td:last-child { text-align: right; }
.muted { opacity: .6; }
#status { min-height: 1.5em; }
`;

function page(res, title, body, script = "") {
  const nonce = b64(randomBytes(16));
  const connect = ["'self'", ...deployments.map((d) => new URL(d.url).origin)].join(" ");
  res.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-security-policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; connect-src ${connect}; frame-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`,
  });
  res.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escape(title)}</title><style>${STYLE}</style></head><body>${body}
<script nonce="${nonce}">${CLIENT}${script}</script></body></html>`);
}

const pages = {
  login: (res, url) =>
    page(
      res,
      "Convex on black",
      `<main><h1>Convex on black</h1><p><button id="login">Sign in with passkey</button></p><p id="status" class="muted"></p></main>`,
      `const next = ${JSON.stringify(safeNext(url.searchParams.get("next")))};
document.getElementById("login").onclick = async () => {
  try {
    const { challenge, rpId } = await post("login/options");
    const cred = await navigator.credentials.get({ publicKey: { challenge: dec(challenge), rpId, userVerification: "required", timeout: 60000 } });
    const r = cred.response;
    await post("login", { id: cred.id, clientDataJSON: enc(r.clientDataJSON), authenticatorData: enc(r.authenticatorData), signature: enc(r.signature) });
    location.href = next;
  } catch (e) { status(e.message); }
};`,
    ),

  enroll: (res) =>
    page(
      res,
      "Add a passkey",
      `<main><h1>Add a passkey</h1><p><button id="enroll">Create passkey</button></p><p id="status" class="muted"></p></main>`,
      `const token = location.hash.slice(1);
history.replaceState(null, "", location.pathname);
document.getElementById("enroll").onclick = async () => {
  try {
    const o = await post("enroll/options", { token });
    const cred = await navigator.credentials.create({ publicKey: {
      rp: { id: o.rpId, name: "Convex on black" },
      user: { id: dec(o.userId), name: "admin", displayName: "Convex admin" },
      challenge: dec(o.challenge),
      pubKeyCredParams: o.algorithms.map((alg) => ({ type: "public-key", alg })),
      authenticatorSelection: { residentKey: "required", userVerification: "required" },
      excludeCredentials: o.exclude.map((id) => ({ type: "public-key", id: dec(id) })),
      attestation: "none",
      timeout: 60000,
    } });
    const r = cred.response;
    await post("enroll", { token, id: cred.id, clientDataJSON: enc(r.clientDataJSON), authenticatorData: enc(r.getAuthenticatorData()), publicKey: enc(r.getPublicKey()), alg: r.getPublicKeyAlgorithm() });
    location.href = "/_portal/";
  } catch (e) { status(e.message); }
};`,
    ),

  list: (res) =>
    page(
      res,
      "Convex deployments",
      `<main><h1>Convex deployments</h1><table>${deployments
        .map(
          (d) => `<tr><td><strong>${escape(d.name)}</strong><br><span class="muted">${escape(d.url)}</span></td>
<td class="muted" data-version="${escape(d.url)}">…</td>
<td><a class="button" href="/_portal/d/${escape(d.name)}/">Open dashboard</a></td></tr>`,
        )
        .join("")}</table><p><button id="logout">Sign out</button></p><p id="status" class="muted"></p></main>`,
      `for (const cell of document.querySelectorAll("[data-version]")) {
  fetch(cell.dataset.version + "/version").then((r) => r.ok ? r.text() : Promise.reject())
    .then((v) => { cell.textContent = "up, " + v; }, () => { cell.textContent = "unreachable"; });
}
document.getElementById("logout").onclick = () => post("logout").then(() => { location.href = "/_portal/login"; });`,
    ),

  deployment: (res, name, rest) =>
    page(
      res,
      `${name}: Convex`,
      `<div style="display:flex;flex-direction:column;height:100vh">
<nav style="display:flex;gap:1rem;align-items:center;padding:.375rem 1rem;border-bottom:1px solid color-mix(in srgb,currentColor 15%,transparent)">
<a href="/_portal/" style="color:inherit">Deployments</a><strong>${escape(name)}</strong><span id="status" class="muted"></span></nav>
<div style="position:relative;flex:1">
<div id="cover" style="position:absolute;inset:0;display:grid;place-items:center;background:Canvas" class="muted">Signing in to ${escape(name)}…</div>
<iframe id="frame" src="${escape(rest)}" style="border:0;width:100%;height:100%"></iframe></div></div>`,
      `const name = ${JSON.stringify(name)};
const frame = document.getElementById("frame");
const cover = document.getElementById("cover");
const creds = fetch("/_portal/api/credentials/" + encodeURIComponent(name)).then((r) => r.ok ? r.json() : Promise.reject(new Error("no credentials (" + r.status + ")")));
addEventListener("message", (e) => {
  if (e.origin !== location.origin || e.source !== frame.contentWindow || e.data?.type !== "dashboard-credentials-request") return;
  creds.then((c) => frame.contentWindow.postMessage({ type: "dashboard-credentials", ...c }, location.origin), (err) => status(err.message));
});
// Keep the address bar on the dashboard page shown, so a reload or a copied
// link returns to it; uncover the dashboard once it is signed in (its header
// only renders then), so its login form never flashes.
const started = Date.now();
setInterval(() => {
  const doc = frame.contentDocument;
  if (!doc) return;
  const target = "/_portal/d/" + name + doc.location.pathname + doc.location.search;
  if (target !== location.pathname + location.search && doc.location.pathname !== "blank") history.replaceState(null, "", target);
  if (cover.isConnected && (doc.querySelector("header") || Date.now() - started > 15000)) cover.remove();
  if (cover.isConnected && doc.body?.textContent.includes("admin key is invalid")) { cover.remove(); status("the dashboard rejected the admin key"); }
}, 300);`,
    ),
};

// Only same-origin paths, never "//host".
function safeNext(next) {
  return next && next.startsWith("/") && !next.startsWith("//") ? next : "/_portal/";
}

function send(res, status, data, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store", ...headers });
  res.end(JSON.stringify(data));
}

async function readBody(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 64 * 1024) throw new Error("body too large");
    chunks.push(chunk);
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
}

const client = (req) => req.headers["x-forwarded-for"]?.split(",")[0].trim() ?? req.socket.remoteAddress;

async function handle(req, res) {
  const url = new URL(req.url, origin);
  const path = url.pathname;
  const session = hasSession(req);

  // forwardAuth for every dashboard request.
  if (path === "/_portal/auth") {
    const forwarded = req.headers["x-forwarded-uri"] ?? "/";
    const topLevel = req.headers["sec-fetch-dest"] === "document";
    if (!session) {
      return topLevel
        ? send(res, 302, {}, { location: `/_portal/login?next=${encodeURIComponent("/_portal/")}` })
        : send(res, 401, { error: "sign in at /_portal/login" });
    }
    // Opened directly, the dashboard would ask for a key: show the list instead.
    return topLevel ? send(res, 302, {}, { location: "/_portal/" }) : send(res, 200, { ok: true, uri: forwarded });
  }

  if (path.startsWith("/_portal/api/")) {
    const action = path.slice("/_portal/api/".length);
    if (req.method === "GET" && action.startsWith("credentials/")) {
      if (!session) return send(res, 401, { error: "not signed in" });
      if (req.headers["sec-fetch-site"] && req.headers["sec-fetch-site"] !== "same-origin") {
        return send(res, 403, { error: "same-origin only" });
      }
      const result = credentials(decodeURIComponent(action.slice("credentials/".length)));
      return result ? send(res, 200, result) : send(res, 404, { error: "unknown deployment" });
    }
    const handler = Object.hasOwn(api, action) ? api[action] : null;
    if (req.method !== "POST" || !handler) return send(res, 404, { error: "not found" });
    // CSRF: browsers send Origin on every POST; the cookie is SameSite=Strict too.
    if (req.headers.origin !== origin || !req.headers["content-type"]?.startsWith("application/json")) {
      return send(res, 403, { error: "same-origin JSON only" });
    }
    try {
      const result = handler(await readBody(req), res);
      if (action === "login" || action === "enroll") console.log(`${action} ok from ${client(req)}`);
      return send(res, 200, result);
    } catch (error) {
      console.log(`${action} failed from ${client(req)}: ${error.message}`);
      return send(res, 400, { error: error.message });
    }
  }

  if (req.method !== "GET") return send(res, 405, { error: "method not allowed" });
  if (path === "/_portal/login") return session ? send(res, 302, {}, { location: "/_portal/" }) : pages.login(res, url);
  if (path === "/_portal/enroll") return pages.enroll(res);
  if (!session) return send(res, 302, {}, { location: `/_portal/login?next=${encodeURIComponent(path + url.search)}` });
  if (path === "/_portal" || path === "/_portal/") return pages.list(res);

  const match = path.match(/^\/_portal\/d\/([^/]+)(\/.*)?$/);
  if (match && deployments.some((d) => d.name === match[1])) {
    // The dashboard page to frame; never the portal inside itself.
    const rest = match[2]?.startsWith("/_portal") ? "/" : (match[2] ?? "/");
    return pages.deployment(res, match[1], `${rest}${url.search}`);
  }
  return send(res, 404, { error: "not found" });
}

createServer((req, res) =>
  handle(req, res).catch((error) => {
    console.error(error);
    if (!res.headersSent) send(res, 500, { error: "internal error" });
  }),
).listen(8080, () => console.log(`convex portal for ${deployments.map((d) => d.name).join(", ")} on :8080`));
