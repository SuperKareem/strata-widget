// strata control server on :8090 — start/stop endpoints are generated from list-models.sh.
//
// Every model id list-models.sh reports gets a "/<model-id>" endpoint whose script is
// "<model-id>.sh" next to this file; an id without that script is reported by /models as
// not startable. So adding a download plus its start script needs no change here.
// Reserved paths: /start (legacy alias for /coder-IQ1_M), /stop, /status, /models.
// /coder-IQ1_M-prebuilt stays manual: it serves Coder through the old prebuilt engine.
// A start refuses to restart when this folder already started that same id and something
// is still running (see last-started.txt); switching models still stops the previous one.
// install.sh owns the two config files read here: "server.port" (the port) and
// "model-scripts.txt" (id<TAB>script lines that point an endpoint at another script).
const { createServer } = require("node:http");
const { spawn } = require("node:child_process");
const { dirname, join } = require("node:path");
const { existsSync, readFileSync, writeFileSync } = require("node:fs");

const HERE = dirname(process.argv[1]);
const readOr = (file, fallback) => {
  try {
    return readFileSync(join(HERE, file), "utf8");
  } catch {
    return fallback;
  }
};
const configuredPort = Number(readOr("server.port", ""));
const PORT = configuredPort >= 1024 && configuredPort <= 65535 ? configuredPort : 8090;
const STOP = join(HERE, "stop-strata.sh");
const LIST_MODELS = join(HERE, "list-models.sh");
const LAST = join(HERE, "last-started.txt");
const CODER = "coder-IQ1_M";
const PREBUILT = { id: "coder-IQ1_M-prebuilt", script: join(HERE, "start-prebuilt.sh") };
const RESERVED = new Set(["start", "stop", "status", "models"]);
// Bracket on the first letter of each alternative: this command's own argv would
// otherwise contain the pattern text and pgrep -f would report "running" forever.
const RUNNING = 'pgrep -f "[s]erve/server[.]py|[s]trata --serve|[s]trata[.]py"';
const busy = new Set();

// install.sh appends "id<TAB>script" lines here to point one endpoint at another script.
const SCRIPTS = (() => {
  const map = {};
  readOr("model-scripts.txt", "").split("\n").forEach((line) => {
    const tab = line.indexOf("\t");
    if (tab > 0) map[line.slice(0, tab)] = line.slice(tab + 1);
  });
  return map;
})();

const scriptFor = (id) => {
  const path = SCRIPTS[id] || join(HERE, `${id}.sh`);
  return existsSync(path) ? path : null;
};

const sh = (cmd) =>
  new Promise((resolve) => {
    const child = spawn("sh", ["-c", cmd]);
    let out = "";
    child.stdout.on("data", (c) => { out += c; });
    child.stderr.on("data", (c) => { out += c; });
    child.on("close", (code) => resolve({ code, out: out.trim() }));
  });

const isRunning = () => sh(RUNNING).then(({ code }) => code === 0);

const modelIds = () =>
  sh(`"${LIST_MODELS}" --ids`).then(({ code, out }) => ({
    ok: code === 0,
    models: out
      .split("\n")
      .filter((line) => line.includes("\t"))
      .map((line) => {
        const [id, state] = line.split("\t");
        return { id, state, script: scriptFor(id) };
      }),
    ...(code === 0 ? {} : { out }),
  }));

const run = (script) => sh(`"${script}"`).then((r) => ({ ok: r.code === 0, out: r.out }));

const serve = (key, script) => {
  if (busy.has(key)) return Promise.resolve({ ok: false, out: `${key} already in progress` });
  busy.add(key);
  const done = (r) => {
    busy.delete(key);
    if (key !== "stop" && r.ok) writeFileSync(LAST, `${key}\n`);
    return r;
  };
  const work = async () => {
    const running = await isRunning();
    if (key === "stop") return running ? run(script) : { ok: true, out: "nothing running" };
    if (!script) return { ok: false, out: `no start script for ${key}` };
    const previous = (await sh(`cat "${LAST}" 2>/dev/null`)).out.trim();
    if (running && previous === key) {
      return { ok: false, out: `already serving ${key} - left running, nothing to do` };
    }
    return run(script);
  };
  return work().catch((e) => ({ ok: false, out: String(e) })).then(done);
};

const server = createServer((req, res) => {
  const path = (req.url || "/").split("?")[0];
  console.log(`${new Date().toISOString()} ${req.method} ${path}`);
  const reply = (obj) => {
    console.log(`${req.method} ${path} -> ${JSON.stringify(obj)}`);
    res.writeHead(200, { "content-type": "application/json", "access-control-allow-origin": "*" });
    res.end(JSON.stringify(obj));
  };
  const notFound = () =>
    modelIds().then((m) => {
      const routes = ["/start", "/stop", "/status", "/models", `/${PREBUILT.id}`]
        .concat(m.models.filter((x) => x.script).map((x) => `/${x.id}`));
      res.writeHead(404, { "content-type": "text/plain" });
      res.end(`use ${routes.join(", ")}`);
    });

  if (path === "/status") return isRunning().then((running) => reply({ running }));
  if (path === "/stop") return serve("stop", STOP).then(reply);
  if (path === "/models") {
    return modelIds().then((m) =>
      reply({
        ok: m.ok,
        models: m.models.map((x) => ({ id: x.id, state: x.state, endpoint: x.script ? `/${x.id}` : null })),
        ...(m.out ? { out: m.out } : {}),
      }),
    );
  }
  if (path === `/${PREBUILT.id}`) return serve(PREBUILT.id, PREBUILT.script).then(reply);
  const wanted = path === "/start" ? CODER : path.slice(1);
  if (RESERVED.has(wanted)) return notFound();
  return modelIds().then((m) => {
    const hit = m.models.find((x) => x.id === wanted);
    if (!hit) return notFound();
    return serve(hit.id, hit.script).then(reply);
  });
});

server.listen(PORT, "0.0.0.0");
console.log(`strata control server listening on :${PORT}`);
