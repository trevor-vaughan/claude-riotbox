// Test-only Pi extension: registers a scripted provider so a real `pi -p` run
// executes a tool call and persists a session with zero network inference.
// Used by tests/pi-integration.venom.yml through a synthetic host agent dir;
// it is never installed into an image. `.js`, not `.mjs`: Pi's extensions/
// directory discovery does not pick up .mjs files.
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai";

export default function (pi) {
	const faux = fauxProvider({ provider: "riotbox-faux", models: [{ id: "faux-1" }] });
	faux.setResponses([
		fauxAssistantMessage(fauxToolCall("todo", { action: "create", subject: "riotbox faux todo" }), { stopReason: "toolUse" }),
		fauxAssistantMessage(fauxText("RIOTBOX_FAUX_DONE")),
	]);
	pi.registerProvider(faux.provider);
}
