import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { registry, validate, render, Store, digest, Invalid } from "./core.ts";
import { server } from "./server.ts";
const p = {
	hosts: ["inference.modusservice.com", "*.preview.modusservice.com"],
	convex: ["modus-gateway-prod"],
};
const table = {
	routes: [
		{
			host: "inference.modusservice.com",
			target: { convex: "modus-gateway-prod", origin: "site" },
		},
	],
};
test("rejects external targets, foreign hosts/deployments, injection, malformed tables and normalized duplicates", () => {
	for (const input of [
		null,
		{},
		{ routes: null },
		{ routes: Array(65).fill(table.routes[0]) },
		{ routes: [{ ...table.routes[0], target: { url: "https://example.com" } }] },
		{ routes: [{ ...table.routes[0], host: "x`) || Host(`evil.com" }] },
		{ routes: [{ ...table.routes[0], pathPrefix: "/x`" }] },
		{ routes: [{ ...table.routes[0], extra: 1 }] },
		{ routes: [table.routes[0], { ...table.routes[0], pathPrefix: "/" }] },
	])
		assert.throws(() => validate(p, input));
	for (const routes of [
		[{ ...table.routes[0], host: "foreign.com" }],
		[{ ...table.routes[0], target: { convex: "other", origin: "site" } }],
	])
		assert.throws(
			() => validate(p, { routes }),
			(e: unknown) => e instanceof Invalid && e.status === 403,
		);
	assert.doesNotThrow(() =>
		validate(p, { routes: [{ ...table.routes[0], host: "pr-1.preview.modusservice.com" }] }),
	);
	assert.throws(() =>
		validate(p, { routes: [{ ...table.routes[0], host: "nested.pr-1.preview.modusservice.com" }] }),
	);
});
test("registry rejects overlapping wildcard owners and reserved hosts", () => {
	assert.throws(() =>
		registry({ projects: { a: p, b: { ...p, hosts: ["x.preview.modusservice.com"] } } }),
	);
	assert.throws(() => registry({ projects: { a: { ...p, hosts: ["*.modusservice.com"] } } }));
});
test("renders only Docker Convex services, with specific prefixes taking priority", () => {
	const t = validate(p, {
		routes: [
			table.routes[0],
			{
				...table.routes[0],
				pathPrefix: "/api",
				target: { convex: "modus-gateway-prod", origin: "cloud" },
			},
		],
	});
	const cfg = JSON.parse(render("gateway", t)!);
	assert.equal(cfg.http.routers["routes-gateway-r0"].service, "modus-gateway-prod-site@docker");
	assert.equal(cfg.http.routers["routes-gateway-r1"].service, "modus-gateway-prod-cloud@docker");
	assert.equal(cfg.http.routers["routes-gateway-r1"].priority, 1004);
	assert.equal(cfg.http.services, undefined);
});
test("HTTP authentication, replacement, limits, restart and registry revocation", async () => {
	const dir = mkdtempSync(join(tmpdir(), "routes-test-"));
	mkdirSync(join(dir, "state"));
	mkdirSync(join(dir, "dynamic"));
	const store = new Store(join(dir, "state"), join(dir, "dynamic"));
	const r = registry({ projects: { gateway: p } });
	const s = server(r, { gateway: digest("secret") }, store);
	await new Promise<void>((resolve) => s.listen(0, "127.0.0.1", resolve));
	const address = s.address();
	assert(address && typeof address !== "string");
	const url = `http://127.0.0.1:${address.port}/v1/projects/gateway/routes`;
	const put = (body: unknown, key = "secret") =>
		fetch(url, {
			method: "PUT",
			headers: { Authorization: `Bearer ${key}` },
			body: JSON.stringify(body),
		});
	try {
		assert.equal((await put(table, "wrong")).status, 401);
		assert.equal(
			(await put({ routes: [{ ...table.routes[0], host: "foreign.com" }] })).status,
			403,
		);
		assert.equal((await put(table)).status, 200);
		assert.deepEqual(
			await (await fetch(url, { headers: { Authorization: "Bearer secret" } })).json(),
			table,
		);
		const file = join(dir, "dynamic", "routes-gateway.yml"),
			rendered = readFileSync(file, "utf8");
		assert.equal((await put(table)).status, 200);
		assert.equal(readFileSync(file, "utf8"), rendered);
		assert.equal((await put({ routes: [], padding: "x".repeat(65536) })).status, 413);
		assert.equal(readFileSync(file, "utf8"), rendered);
		writeFileSync(join(dir, "dynamic", "routes-removed.yml"), "stale");
		store.restore(r);
		assert.equal(existsSync(join(dir, "dynamic", "routes-removed.yml")), false);
		assert.equal(readFileSync(file, "utf8"), rendered);
		store.restore({ projects: { gateway: { ...p, hosts: [] } } });
		assert.equal(existsSync(file), false);
		assert.equal((await put({ routes: [] })).status, 200);
		assert.equal(existsSync(file), false);
	} finally {
		await new Promise<void>((resolve, reject) => s.close((e) => (e ? reject(e) : resolve())));
		rmSync(dir, { recursive: true, force: true });
	}
});
