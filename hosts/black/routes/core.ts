import { createHash } from "node:crypto";
import {
	readFileSync,
	writeFileSync,
	renameSync,
	unlinkSync,
	readdirSync,
	openSync,
	fsyncSync,
	closeSync,
} from "node:fs";
import { join } from "node:path";

export type Project = { hosts: string[]; convex: string[] };
export type Registry = { projects: Record<string, Project> };
export type Table = {
	routes: {
		host: string;
		pathPrefix?: string;
		target: { convex: string; origin: "cloud" | "site" };
	}[];
};
const name = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const hostname = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
export class Invalid extends Error {
	status: number;
	constructor(message: string, status = 400) {
		super(message);
		this.status = status;
	}
}
function object(value: unknown, keys: string[]): asserts value is Record<string, unknown> {
	if (
		!value ||
		typeof value !== "object" ||
		Array.isArray(value) ||
		Object.keys(value).some((k) => !keys.includes(k))
	)
		throw new Invalid(`Expected object with fields: ${keys.join(", ")}`);
}
export function allows(pattern: string, host: string): boolean {
	if (pattern === host) return true;
	if (!pattern.startsWith("*.")) return false;
	const suffix = pattern.slice(1),
		label = host.endsWith(suffix) ? host.slice(0, -suffix.length) : "";
	return label.length > 0 && !label.includes(".");
}
export function registry(value: unknown): Registry {
	object(value, ["projects"]);
	object(value.projects, Object.keys(value.projects ?? {}));
	const claims: [string, string][] = [];
	if (!Object.keys(value.projects).length) throw new Invalid("No projects");
	for (const [id, p] of Object.entries(value.projects)) {
		if (!name.test(id)) throw new Invalid("Invalid project name");
		object(p, ["hosts", "convex"]);
		if (
			!Array.isArray(p.hosts) ||
			!Array.isArray(p.convex) ||
			!p.convex.every((d) => typeof d === "string" && name.test(d))
		)
			throw new Invalid("Invalid deployments");
		for (const h of p.hosts) {
			if (typeof h !== "string" || h.length > 253 || !hostname.test(h.replace(/^\*\./, "")))
				throw new Invalid("Invalid hostname");
			if (claims.some(([other, host]) => other !== id && (allows(host, h) || allows(h, host))))
				throw new Invalid("Overlapping hostname claims");
			if (
				allows(h, "routes.modusservice.com") ||
				h === "convex.modusservice.com" ||
				h.endsWith(".convex.modusservice.com")
			)
				throw new Invalid("Reserved hostname");
			claims.push([id, h]);
		}
	}
	return value as Registry;
}
export function validate(p: Project, value: unknown): Table {
	object(value, ["routes"]);
	if (!Array.isArray(value.routes) || value.routes.length > 64)
		throw new Invalid("routes must be an array of at most 64 entries");
	const seen = new Set<string>();
	const routes = value.routes.map((r) => {
		object(r, ["host", "pathPrefix", "target"]);
		object(r.target, ["convex", "origin"]);
		if (typeof r.host !== "string" || r.host.length > 253 || !hostname.test(r.host))
			throw new Invalid("Invalid host");
		if (!p.hosts.some((h) => allows(h, r.host as string)))
			throw new Invalid("Host outside project registry", 403);
		if (
			r.pathPrefix !== undefined &&
			(typeof r.pathPrefix !== "string" || !/^\/[A-Za-z0-9._~/-]{0,127}$/.test(r.pathPrefix))
		)
			throw new Invalid("Invalid pathPrefix");
		if (
			typeof r.target.convex !== "string" ||
			!name.test(r.target.convex) ||
			!["cloud", "site"].includes(r.target.origin as string)
		)
			throw new Invalid("Expected convex deployment and cloud/site origin");
		if (!p.convex.includes(r.target.convex))
			throw new Invalid("Deployment outside project registry", 403);
		const prefix = r.pathPrefix === "/" ? undefined : (r.pathPrefix as string | undefined);
		const key = `${r.host}:${prefix ?? ""}`;
		if (seen.has(key)) throw new Invalid("Duplicate host and prefix");
		seen.add(key);
		return {
			host: r.host,
			...(prefix ? { pathPrefix: prefix } : {}),
			target: { convex: r.target.convex, origin: r.target.origin as "cloud" | "site" },
		};
	});
	return { routes };
}
export const canonical = (t: Table) => JSON.stringify(t, null, 2) + "\n";
export const digest = (s: string) => createHash("sha256").update(s).digest();
export function render(project: string, t: Table): string | undefined {
	if (!t.routes.length) return;
	return (
		JSON.stringify(
			{
				http: {
					routers: Object.fromEntries(
						t.routes.map((r, i) => [
							`routes-${project}-r${i}`,
							{
								rule: `Host(\`${r.host}\`)${r.pathPrefix ? ` && PathPrefix(\`${r.pathPrefix}\`)` : ""}`,
								entryPoints: ["websecure"],
								service: `${r.target.convex}-${r.target.origin}@docker`,
								priority: 1000 + (r.pathPrefix?.length ?? 0),
								tls: { certResolver: "letsencrypt" },
							},
						]),
					),
				},
			},
			null,
			2,
		) + "\n"
	);
}
function atomic(file: string, body: string) {
	const temp = `${file}.${process.pid}.tmp`;
	try {
		writeFileSync(temp, body, { mode: 0o644 });
		const fd = openSync(temp, "r");
		try {
			fsyncSync(fd);
		} finally {
			closeSync(fd);
		}
		renameSync(temp, file);
	} finally {
		try {
			unlinkSync(temp);
		} catch (e) {
			if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
		}
	}
}
export class Store {
	state: string;
	dynamic: string;
	constructor(state: string, dynamic: string) {
		this.state = state;
		this.dynamic = dynamic;
	}
	load(id: string): unknown {
		try {
			return JSON.parse(readFileSync(join(this.state, `${id}.json`), "utf8"));
		} catch (e) {
			if ((e as NodeJS.ErrnoException).code === "ENOENT") return { routes: [] };
			throw e;
		}
	}
	apply(id: string, table: Table) {
		const file = join(this.dynamic, `routes-${id}.yml`),
			body = render(id, table);
		if (body) atomic(file, body);
		else {
			try {
				unlinkSync(file);
			} catch (e) {
				if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
			}
		}
	}
	save(id: string, table: Table) {
		atomic(join(this.state, `${id}.json`), canonical(table));
		this.apply(id, table);
	}
	restore(r: Registry) {
		for (const file of readdirSync(this.dynamic))
			if (
				file.startsWith("routes-") &&
				file.endsWith(".yml") &&
				!Object.hasOwn(r.projects, file.slice(7, -4))
			)
				unlinkSync(join(this.dynamic, file));
		for (const [id, p] of Object.entries(r.projects)) {
			const saved = this.load(id);
			let table: Table;
			try {
				table = validate(p, saved);
			} catch {
				console.error("Stored table outside registry; disabling", id);
				table = { routes: [] };
			}
			this.apply(id, table);
		}
	}
}
