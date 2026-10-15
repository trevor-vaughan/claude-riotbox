// Build-time smoke test for the Pi layer in the Containerfile.
//
// Usage: node smoke.mjs <pi-core-package-dir> <extensions-root>
//
// Loads every extension declared in <extensions-root>/package.json into a real
// Pi session, the same way a RiotBox session does (a `packages` list of
// absolute paths in settings.json), and fails when any of them does not load
// cleanly. This is the compatibility gate for the floating Pi core: a release
// that breaks a pinned extension fails the image build here instead of
// shipping a session where the extension silently does nothing. Pi itself
// skips a `packages` path that does not resolve without any diagnostic, which
// is why every package is checked individually.
//
// Runs offline in a throwaway HOME so nothing the build user owns is read or
// written, and so the result does not depend on any host Pi configuration.
// TMPDIR points into the same directory so the temp files Pi's extension
// loader (jiti) and pi-subagents write are removed with it instead of being
// left in the image layer. It is a subdirectory, not HOME itself: jiti
// ignores a TMPDIR equal to the working directory and falls back to /tmp.
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// The tools that give Pi parity with Claude Code's Task, AskUserQuestion and
// TodoWrite. A package that loads but stops registering its tool is exactly
// the silent failure this script exists to catch.
const PARITY_TOOLS = ["subagent", "ask_user_question", "todo"];

const [corePkg, extRoot] = process.argv.slice(2);
if (!corePkg || !extRoot) {
	console.error("usage: node smoke.mjs <pi-core-package-dir> <extensions-root>");
	process.exit(2);
}

const manifest = JSON.parse(readFileSync(join(extRoot, "package.json"), "utf8"));
const packages = Object.keys(manifest.dependencies ?? {}).map((name) => join(extRoot, "node_modules", name));
if (packages.length === 0) {
	console.error(`${extRoot}/package.json declares no dependencies — nothing to smoke-test`);
	process.exit(1);
}

const home = mkdtempSync(join(tmpdir(), "pi-smoke-"));
const failures = [];
try {
	mkdirSync(join(home, ".pi", "agent"), { recursive: true });
	mkdirSync(join(home, "tmp"));
	writeFileSync(join(home, ".pi", "agent", "settings.json"), JSON.stringify({ packages }));
	process.env.HOME = home;
	process.env.TMPDIR = join(home, "tmp");
	process.env.PI_OFFLINE = "1";
	process.env.PI_TELEMETRY = "0";
	process.chdir(home);

	const pi = await import(pathToFileURL(join(corePkg, "dist", "index.js")).href);
	const { session } = await pi.createAgentSession({ sessionManager: pi.SessionManager.inMemory() });
	const loaded = session.resourceLoader.getExtensions();

	for (const error of loaded.errors) failures.push(`load error in ${error.path}: ${error.error}`);
	for (const warning of loaded.warnings ?? []) failures.push(`load warning in ${warning.path}: ${warning.warning}`);
	for (const pkg of packages) {
		const own = loaded.extensions.filter((ext) => ext.path.startsWith(`${pkg}/`));
		if (own.length === 0) failures.push(`${pkg} contributed no extension`);
		else if (own.every((ext) => ext.tools.size === 0)) failures.push(`${pkg} loaded but registered no tools`);
	}
	const tools = new Set(session.getAllTools().map((tool) => tool.name));
	for (const tool of PARITY_TOOLS) if (!tools.has(tool)) failures.push(`tool ${tool} is not registered`);

	console.log(`pi smoke: ${loaded.extensions.length} extensions, tools: ${[...tools].sort().join(" ")}`);
} finally {
	rmSync(home, { recursive: true, force: true });
}

if (failures.length > 0) {
	for (const failure of failures) console.error(`pi smoke: FAIL ${failure}`);
	process.exit(1);
}
