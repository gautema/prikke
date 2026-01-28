import { readFileSync, existsSync } from "fs";
import { join } from "path";

const PORT = process.env.PORT || 3000;
const DATABASE_URL = process.env.DATABASE_URL;

// Use Postgres if DATABASE_URL is set, otherwise SQLite for local dev
let db: any = null;
let pgPool: any = null;

if (DATABASE_URL) {
  // Postgres for production (Koyeb)
  const { Pool } = await import("pg");
  pgPool = new Pool({
    connectionString: DATABASE_URL,
    ssl: { rejectUnauthorized: false }
  });
  await pgPool.query(`
    CREATE TABLE IF NOT EXISTS waitlist (
      id SERIAL PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  console.log("Connected to Postgres");
} else {
  // SQLite for local development
  const { Database } = await import("bun:sqlite");
  db = new Database("waitlist.sqlite");
  db.run(`
    CREATE TABLE IF NOT EXISTS waitlist (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT UNIQUE NOT NULL,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  `);
  console.log("Using local SQLite");
}

async function addToWaitlist(email: string): Promise<boolean> {
  try {
    if (pgPool) {
      await pgPool.query(
        "INSERT INTO waitlist (email) VALUES ($1) ON CONFLICT (email) DO NOTHING",
        [email]
      );
    } else if (db) {
      db.run("INSERT OR IGNORE INTO waitlist (email) VALUES (?)", [email]);
    }
    return true;
  } catch (err) {
    console.error("DB error:", err);
    return false;
  }
}

const staticDir = join(import.meta.dir, "static");
const pagesDir = join(import.meta.dir, "pages");
const templatesDir = join(import.meta.dir, "templates");

// Load layout template
const layoutTemplate = readFileSync(join(templatesDir, "layout.html"), "utf-8");

function renderPage(pagePath: string): string | null {
  if (!existsSync(pagePath)) return null;

  const content = readFileSync(pagePath, "utf-8");

  // Extract title from HTML comment at top: <!-- title: Page Title -->
  const titleMatch = content.match(/<!--\s*title:\s*(.+?)\s*-->/);
  const title = titleMatch ? titleMatch[1] : "Prikke";

  // Remove the title comment from content
  const cleanContent = content.replace(/<!--\s*title:\s*.+?\s*-->\s*/, "");

  // Render with layout
  return layoutTemplate
    .replace("{{title}}", title)
    .replace("{{content}}", cleanContent);
}

const server = Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);

    // Waitlist API
    if (url.pathname === "/waitlist" && req.method === "POST") {
      try {
        const body = await req.json();
        const email = body.email?.trim().toLowerCase();

        if (!email || !email.includes("@")) {
          return Response.json(
            { success: false, error: "Invalid email" },
            { status: 400 }
          );
        }

        const success = await addToWaitlist(email);
        if (success) {
          return Response.json({ success: true, message: "You're on the list!" });
        } else {
          return Response.json(
            { success: false, error: "Could not save email" },
            { status: 500 }
          );
        }
      } catch (err) {
        return Response.json(
          { success: false, error: "Invalid request" },
          { status: 400 }
        );
      }
    }

    // Landing page - serve directly from static (has its own design)
    if (url.pathname === "/") {
      const file = Bun.file(join(staticDir, "index.html"));
      return new Response(file);
    }

    // Try to serve from pages directory (templated)
    let pagePath = join(pagesDir, url.pathname);

    // Try adding .html extension
    if (!url.pathname.includes(".") && existsSync(pagePath + ".html")) {
      pagePath = pagePath + ".html";
    }
    // Try index.html for directories
    else if (!url.pathname.includes(".") && existsSync(join(pagePath, "index.html"))) {
      pagePath = join(pagePath, "index.html");
    }

    if (existsSync(pagePath) && pagePath.endsWith(".html")) {
      const html = renderPage(pagePath);
      if (html) {
        return new Response(html, {
          headers: { "Content-Type": "text/html" }
        });
      }
    }

    // Static files (favicon, etc.)
    let staticPath = join(staticDir, url.pathname);
    if (existsSync(staticPath)) {
      const file = Bun.file(staticPath);
      return new Response(file);
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log(`Server running at http://localhost:${PORT}`);
