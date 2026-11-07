// Stand-in for `next dev` started with Node's inspector.
// Next's overlay POSTs /__nextjs_attach-nodejs-inspector, reads this
// process's /json/list, and returns the first target's devtoolsFrontendUrl.
// The process stays up the way that dev server does.

const http = require("node:http");
const inspector = require("node:inspector");

function inspectorFrontendURL() {
  const raw = inspector.url();
  if (!raw) return Promise.reject(new Error("inspector is not open"));
  const host = new URL(raw).host;
  return fetch(`http://${host}/json/list`).then(async (response) => {
    const targets = await response.json();
    const target = Array.isArray(targets) ? targets[0] : null;
    if (!target || !target.devtoolsFrontendUrl) {
      throw new Error("No debug targets found");
    }
    return target.devtoolsFrontendUrl;
  });
}

const server = http.createServer((request, response) => {
  if (request.method !== "POST" || request.url !== "/__nextjs_attach-nodejs-inspector") {
    response.writeHead(404);
    response.end();
    return;
  }
  inspectorFrontendURL().then((frontendURL) => {
    const body = JSON.stringify(frontendURL);
    response.writeHead(200, {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
    });
    response.end(body);
  }).catch(() => {
    response.writeHead(500);
    response.end();
  });
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  process.stdout.write(`ready - started server on 127.0.0.1:${address.port}\n`);
});
