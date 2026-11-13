// A model server for the end-to-end suite: OpenAI's chat completions, from a script.
//
//   node test/e2e/model.mjs CTRL      listens on 127.0.0.1, an ephemeral port, written to CTRL/port
//
// Each request's body is kept as CTRL/requests/NNN.json. The reply is the next file of
// CTRL/replies/MODEL/ in name order (MODEL is the request's `model`), moved to
// CTRL/replies/MODEL/used/ once sent. A reply file is JSON, one of:
//   {"tool": "NAME", "args": {...}}       one tool call
//   {"content": "TEXT"}                   a plain answer
//   {"status": 500, "error": "TEXT"}      the server failing
// With the queue empty, the reply is CTRL/replies/MODEL.last if there is one, else a 500
// that says the script ran out, so a case that asks more than it scripted fails loudly.
// A request with max_tokens === 1 is the one-token probe, answered immediately without
// using a scripted reply.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const ctrl = process.argv[2];
if (!ctrl) {
  console.error("usage: model.mjs CTRL");
  process.exit(2);
}
fs.mkdirSync(path.join(ctrl, "requests"), { recursive: true });
let n = 0;

function next(model) {
  const dir = path.join(ctrl, "replies", model);
  let files = [];
  try {
    files = fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  } catch {}
  if (files.length > 0) {
    const f = files[0];
    const text = fs.readFileSync(path.join(dir, f), "utf8");
    fs.mkdirSync(path.join(dir, "used"), { recursive: true });
    fs.renameSync(path.join(dir, f), path.join(dir, "used", f));
    return JSON.parse(text);
  }
  try {
    return JSON.parse(fs.readFileSync(path.join(ctrl, "replies", `${model}.last`), "utf8"));
  } catch {}
  return { status: 500, error: `the script for ${model} ran out` };
}

function completion(model, r) {
  const message = r.tool
    ? {
        role: "assistant",
        content: null,
        tool_calls: [
          {
            id: `call_${n}`,
            type: "function",
            function: { name: r.tool, arguments: JSON.stringify(r.args ?? {}) },
          },
        ],
      }
    : { role: "assistant", content: r.content ?? "" };
  return {
    id: `chatcmpl-${n}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message, finish_reason: r.tool ? "tool_calls" : "stop" }],
    usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 },
  };
}

const server = http.createServer((req, res) => {
  if (req.method === "GET") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    // A round's one-token probe: answered at once, kept nowhere, no scripted reply used.
    let probe = false;
    try {
      probe = JSON.parse(body).max_tokens === 1;
    } catch {}
    if (probe) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(completion("probe", { content: "" })));
      return;
    }
    n += 1;
    fs.writeFileSync(path.join(ctrl, "requests", `${String(n).padStart(3, "0")}.json`), body);
    let model = "unknown";
    let history = [];
    try {
      const parsed = JSON.parse(body);
      model = parsed.model ?? "unknown";
      history = parsed.messages ?? [];
    } catch {}
    // llama-server's gpt-oss chat template refuses a history whose assistant turns carry
    // Harmony's tags (web-2ad.4's reviewer, 8 Nov): a 500, before any reply is taken.
    const tagged = history.some(
      (m) => m.role === "assistant" && typeof m.content === "string" && m.content.includes("<|channel|>"),
    );
    if (tagged) {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: "the chat template refused a Harmony-tagged history" } }));
      return;
    }
    const r = next(model);
    if (r.status) {
      res.writeHead(r.status, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: r.error ?? "error" } }));
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(completion(model, r)));
  });
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(path.join(ctrl, "port"), String(server.address().port));
});
