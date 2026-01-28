import { Database } from "bun:sqlite";
import { readFileSync, existsSync } from "fs";
import { join } from "path";

const PORT = process.env.PORT || 3000;
const DATABASE_URL = process.env.DATABASE_URL;

// Use Postgres if DATABASE_URL is set, otherwise SQLite for local dev
let db: Database | null = null;
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

    // Static files
    let filepath = join(staticDir, url.pathname);
    if (url.pathname === "/") {
      filepath = join(staticDir, "index.html");
    }

    if (existsSync(filepath)) {
      const file = Bun.file(filepath);
      return new Response(file);
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log(`Server running at http://localhost:${PORT}`);
