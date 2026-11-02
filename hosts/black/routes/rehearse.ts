// Offline: validates the evaluated Nix registry and candidate map, then emits
// the exact Traefik input. It never contacts DNS, ACME or the live route API.
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { registry, render, validate } from "./core.ts";

const { values } = parseArgs({
	options: {
		registry: { type: "string" },
		table: { type: "string" },
		project: { type: "string" },
	},
});
if (!values.registry || !values.table || !values.project)
	throw new Error(
		"Usage: rehearse.ts --registry <evaluated-json> --table <candidate-json> --project <id>",
	);
const r = registry(JSON.parse(readFileSync(values.registry, "utf8")));
const p = r.projects[values.project];
if (!p) throw new Error("Unknown project");
const table = validate(p, JSON.parse(readFileSync(values.table, "utf8")));
console.log(render(values.project, table) ?? "{}");
