// Mini servidor estático para el banco de pruebas de shaders.
// Sirve la raíz del repo (para llegar a /shaders y /test.png) sin caché,
// así el tester puede re-leer los .glsl del disco en cada poll.
//
//   node test/server.js        → http://localhost:8123/test/
//
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 8123;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".glsl": "text/plain; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".json": "application/json",
  ".css": "text/css; charset=utf-8",
};

const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent(new URL(req.url, "http://x").pathname);
  let filePath = path.normalize(path.join(ROOT, urlPath));
  if (!filePath.startsWith(ROOT)) {
    res.writeHead(403).end("forbidden");
    return;
  }
  if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
    filePath = path.join(filePath, "index.html");
  }
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404).end("not found: " + urlPath);
      return;
    }
    res.writeHead(200, {
      "Content-Type": MIME[path.extname(filePath).toLowerCase()] || "application/octet-stream",
      "Cache-Control": "no-store", // clave: los .glsl siempre frescos
    });
    res.end(data);
  });
});

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(
      `El puerto ${PORT} ya está en uso (¿otro server.js corriendo?).\n` +
        `Cerrá el otro o usá otro puerto: PORT=8124 node test/server.js`
    );
    process.exit(1);
  }
  throw err;
});

server.listen(PORT, () => {
  console.log(`Shader tester: http://localhost:${PORT}/test/`);
});
