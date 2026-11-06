/**
 * Candidate NEW Cloudflare edge; not installed. Route only the hostnames in
 * withdrawal-operations.json. Reject locally before body consumption/fetch.
 * Origin protection and a scoped bypass secret are required before activation.
 */
function canonicalPath(pathname) {
	const segments = [];
	for (const segment of pathname.replaceAll("\\", "/").split("/")) {
		if (segment === "..") segments.pop();
		else if (segment && segment !== ".") segments.push(segment);
	}
	return `/${segments.join("/")}`;
}

function inspectPath(rawUrl) {
	let pathname = new URL(rawUrl).pathname;
	let withdrawn = false;
	for (let attempt = 0; attempt < 8; attempt++) {
		withdrawn ||= isWithdrawnPath(pathname) || isWithdrawnPath(canonicalPath(pathname));
		// A router may decode a slug after matching segments. Check that view too:
		// encoded separators inside the slug must not hide a withdrawn endpoint.
		try {
			withdrawn ||= isWithdrawnPath(pathname.split("/").map(segment =>
				decodeURIComponent(segment).replaceAll("/", "_").replaceAll("\\", "_")
			).join("/"));
		} catch { return null; }
		let decoded;
		try {
			decoded = decodeURIComponent(pathname);
		} catch {
			return null;
		}
		if (decoded === pathname) {
			// Normalize decoded slash/dot segments as the downstream URL parser does.
			const path = canonicalPath(pathname);
			return { path, withdrawn: withdrawn || isWithdrawnPath(path) };
		}
		pathname = decoded;
	}
	return null;
}

export function normalizedPath(rawUrl) {
	return inspectPath(rawUrl)?.path ?? null;
}

export function isWithdrawnPath(pathname) {
	return (
		/^\/june\/git(?:\/|$)/.test(pathname) ||
		/^\/june\/[^/]+\/eve\/v1(?:\/|$)/.test(pathname) ||
		/^\/api\/internal\/customer-agent-builds\/run(?:\/|$)/.test(pathname)
	);
}

/** @param {{ VERCEL_AUTOMATION_BYPASS_SECRET: string }} env */
export async function handleRequest(request, env, upstream = fetch) {
	// Never attach the project capability to an unexpected host or workers.dev.
	const host = new URL(request.url).hostname;
	if (!["dearjune.ai", "www.dearjune.ai"].includes(host)) {
		return new Response("Unknown ingress", { status: 421 });
	}
	const inspection = inspectPath(request.url);
	if (inspection === null) {
		return new Response("Invalid path", { status: 400 });
	}
	if (inspection.withdrawn) {
		return new Response("Temporarily unavailable", {
			status: 503,
			headers: { "Cache-Control": "no-store", "X-June-Ingress-Withdrawal": "edge" },
		});
	}
	// Never operate a public proxy with the origin-access prerequisite missing.
	if (!env.VERCEL_AUTOMATION_BYPASS_SECRET?.trim()) {
		return new Response("Ingress not configured", { status: 503 });
	}
	const headers = new Headers(request.headers);
	// Ignore a client-supplied bypass header; the origin trusts only this binding.
	headers.set("x-vercel-protection-bypass", env.VERCEL_AUTOMATION_BYPASS_SECRET);
	// Never turn the private origin capability into a browser bypass cookie.
	headers.delete("x-vercel-set-bypass-cookie");
	const url = new URL(request.url);
	const hasBypassQuery = url.searchParams.has("x-vercel-protection-bypass") || url.searchParams.has("x-vercel-set-bypass-cookie");
	if (!hasBypassQuery) return upstream(new Request(request, { headers, redirect: "manual" }), { cf: { cacheEverything: false, cacheTtl: -1 } });
	url.searchParams.delete("x-vercel-protection-bypass");
	url.searchParams.delete("x-vercel-set-bypass-cookie");
	return upstream(new Request(url, new Request(request, { headers, redirect: "manual" })), { cf: { cacheEverything: false, cacheTtl: -1 } });
}

export default { fetch: (request, env) => handleRequest(request, env) };
