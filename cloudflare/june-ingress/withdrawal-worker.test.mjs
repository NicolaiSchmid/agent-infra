import assert from "node:assert/strict";
import test from "node:test";
import worker, { handleRequest, isWithdrawnPath, normalizedPath } from "./withdrawal-worker.mjs";

const blocked = [
	"/june/a%23/%252e%252e/git/receive-pack", "/june/a%3f/%252e%252e/git/receive-pack", "/june/git", "/june/git/info/refs?service=git-receive-pack",
	"/june/git/upload-pack", "/june/git/receive-pack",
	"/june/agent/eve/v1", "/june/agent/eve/v1/sessions/session/stream",
	"/api/internal/customer-agent-builds/run", "/api/internal/customer-agent-builds/run/descendant",
	"/june%5cgit/receive-pack", "/june/a/%252e%252e/git/receive-pack", "/june/%255cgit/receive-pack", "/june/%67it/receive-pack", "/june%2fgit/upload-pack",
	"/june/%2567it/receive-pack", "/june/other/../git/receive-pack",
	"/june/agent/eve/%76%31/sessions", "/june/a%2fb/%65ve/v1/sessions", "/api/internal/customer-agent-builds/%72un/child",
];
for (const pathname of blocked) {
	for (const method of ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "PROPFIND"]) {
		test(`${method} ${pathname} never consumes or forwards a body`, async () => {
			const request = new Request(`https://www.dearjune.ai${pathname}`, {
				method, ...(["GET", "HEAD"].includes(method) ? {} : { body: "synthetic-withdrawal-probe" }),
			});
			let forwards = 0;
			const response = await handleRequest(request, {}, async () => { forwards++; return new Response(); });
			assert.equal(response.status, 503);
			assert.equal(response.headers.get("X-June-Ingress-Withdrawal"), "edge");
			assert.equal(forwards, 0);
			assert.equal(request.bodyUsed, false);
		});
	}
}
for (const pathname of ["/", "/callback", "/remote.php/dav/files/example", "/owncloud", "/june/git-other", "/june/agent/eve/v10", "/api/internal/customer-agent-builds/runner", "/api/other"]) {
	test(`preserves unrelated ${pathname}`, async () => {
		assert.equal(isWithdrawnPath(normalizedPath(`https://www.dearjune.ai${pathname}`)), false);
		let forwarded;
		const request = new Request(`https://www.dearjune.ai${pathname}`, { method: "PROPFIND", body: "synthetic-dav-probe", headers: { "x-vercel-protection-bypass": "untrusted-client-value" } });
		const response = await handleRequest(request, { VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-test-only" }, async r => { forwarded = r; return new Response("upstream", { status: 207 }); });
		assert.equal(response.status, 207);
		assert.equal(forwarded.url, request.url);
		assert.equal(forwarded.method, request.method);
		assert.equal(forwarded.headers.get("x-vercel-protection-bypass"), "synthetic-test-only");
		assert.equal(await forwarded.text(), "synthetic-dav-probe");
	});
}
test("missing origin binding fails closed before forwarding", async () => {
	const response = await handleRequest(new Request("https://www.dearjune.ai/"), {}, () => { throw new Error("must not forward"); });
	assert.equal(response.status, 503);
});

test("client cannot request an origin bypass cookie", async () => {
	const request = new Request("https://www.dearjune.ai/callback?code=synthetic&x-vercel-set-bypass-cookie=true&x-vercel-protection-bypass=untrusted", { headers: { "x-vercel-set-bypass-cookie": "true" } });
	await handleRequest(request, { VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-test-only" }, async forwarded => {
		assert.equal(forwarded.headers.has("x-vercel-set-bypass-cookie"), false);
		assert.equal(forwarded.url, "https://www.dearjune.ai/callback?code=synthetic");
		return new Response();
	});
});
test("Cloudflare execution context is not treated as upstream fetch", async () => {
	const response = await worker.fetch(new Request("https://www.dearjune.ai/june/git"), {}, { waitUntil() {} });
	assert.equal(response.status, 503);
});

test("unexpected host never receives origin capability", async () => {
 const response = await handleRequest(new Request("https://unexpected.workers.dev/"), { VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-test-only" }, () => { throw new Error("must not forward"); });
 assert.equal(response.status, 421);
});

test('unaffected redirect stays manual and disables Cloudflare cache', async () => {
 const request = new Request('https://dearjune.ai/callback?code=synthetic%2Fvalue&state=a+b');
 const response = await handleRequest(request, { VERCEL_AUTOMATION_BYPASS_SECRET: 'synthetic-test-only' }, async (forwarded, options) => {
  assert.equal(forwarded.redirect, 'manual');
  assert.equal(forwarded.url, request.url);
  assert.deepEqual(options, { cf: { cacheEverything: false, cacheTtl: -1 } });
  return new Response(null, { status: 302, headers: { location: 'https://external.invalid/' } });
 });
 assert.equal(response.status, 302);
});
for (const path of ['/%zz', '/june/%E0%A4', '/june/' + '%25'.repeat(9)]) test(`invalid path fails closed ${path}`, async () => {
 const r = await handleRequest(new Request('https://dearjune.ai' + path), {}, () => { throw new Error('must not fetch'); });
 assert.equal(r.status, 400);
});
