import { timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { canonical, digest, Invalid, registry, Store, validate } from "./core.ts";
import type { Registry } from "./core.ts";

export function server(r: Registry, hashes: Record<string, Buffer>, store: Store) {
	store.restore(r);
	return createServer(
		{ requestTimeout: 15000, headersTimeout: 10000, maxHeaderSize: 16384 },
		async (req, res) => {
			const send = (status: number, data?: unknown) => {
				res.writeHead(status, { "Content-Type": "application/json" });
				res.end(data === undefined ? undefined : JSON.stringify(data));
			};
			try {
				if (req.method === "GET" && req.url === "/healthz") return send(204);
				const match = /^\/v1\/projects\/([a-z0-9-]+)\/routes$/.exec(req.url ?? "");
				if (!match || !Object.hasOwn(r.projects, match[1]))
					return send(404, { error: "Unknown project or path" });
				const id = match[1],
					token = req.headers.authorization?.startsWith("Bearer ")
						? req.headers.authorization.slice(7)
						: "";
				if (!token || !timingSafeEqual(digest(token), hashes[id])) {
					res.setHeader("WWW-Authenticate", 'Bearer realm="routes"');
					return send(401, { error: "Missing or wrong project key" });
				}
				if (req.method === "GET") return send(200, store.load(id));
				if (req.method !== "PUT") {
					res.setHeader("Allow", "GET, PUT");
					return send(405);
				}
				let size = 0;
				const chunks: Buffer[] = [];
				for await (const chunk of req) {
					size += chunk.length;
					if (size > 65536) {
						send(413, { error: "Body larger than 64 KiB" });
						return;
					}
					chunks.push(chunk);
				}
				let input: unknown;
				try {
					input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
				} catch {
					throw new Invalid("Invalid JSON");
				}
				const table = validate(r.projects[id], input),
					hash = digest(canonical(table)).toString("hex").slice(0, 16);
				// Synchronous filesystem operations serialize commits, including concurrent PUTs.
				store.save(id, table);
				console.info(JSON.stringify({ project: id, routes: table.routes.length, hash }));
				send(200, { project: id, routes: table.routes.length, hash });
			} catch (e) {
				if (res.headersSent) return res.destroy();
				if (e instanceof Invalid) send(e.status, { error: e.message });
				else {
					console.error("Routes operation failed", e);
					send(500, { error: "Could not read or store table" });
				}
			}
		},
	);
}
if (import.meta.main) {
	if (process.argv[2] === "-healthcheck") {
		try {
			const response = await fetch(process.argv[3], { signal: AbortSignal.timeout(2000) });
			process.exit(response.ok ? 0 : 1);
		} catch {
			process.exit(1);
		}
	}
	const args = new Map<string, string>();
	for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
	const r = registry(
		JSON.parse(readFileSync(args.get("-config") ?? "/config/registry.json", "utf8")),
	);
	const hashes: Record<string, Buffer> = {};
	for (const id of Object.keys(r.projects)) {
		const hex = readFileSync(join(args.get("-keys") ?? "/keys", `${id}.sha256`), "utf8").trim();
		if (!/^[a-f0-9]{64}$/.test(hex)) throw new Error(`Invalid key hash: ${id}`);
		hashes[id] = Buffer.from(hex, "hex");
	}
	server(
		r,
		hashes,
		new Store(args.get("-state") ?? "/state", args.get("-dynamic") ?? "/dynamic"),
	).listen(8080, "0.0.0.0");
}
