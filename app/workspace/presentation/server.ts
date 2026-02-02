const server = Bun.serve({
  port: 3001,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/" || url.pathname === "/index.html") {
      const file = Bun.file("./index.html");
      return new Response(file, {
        headers: { "Content-Type": "text/html" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log(`\x1b[32m$ presentation --serve\x1b[0m`);
console.log(`\x1b[90m> Server running at \x1b[32mhttp://localhost:${server.port}\x1b[0m`);
console.log(`\x1b[90m> Press Ctrl+C to stop\x1b[0m`);
