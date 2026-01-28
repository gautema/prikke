export interface Env {
  DB: D1Database;
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS });
    }

    // Only accept POST
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
    }

    try {
      const body = await request.json() as { email?: string };
      const email = body.email?.trim().toLowerCase();

      // Validate email
      if (!email || !email.includes("@")) {
        return Response.json(
          { success: false, error: "Invalid email" },
          { status: 400, headers: CORS_HEADERS }
        );
      }

      // Insert into D1 (ignore duplicates)
      await env.DB.prepare(
        "INSERT OR IGNORE INTO waitlist (email, created_at) VALUES (?, ?)"
      )
        .bind(email, new Date().toISOString())
        .run();

      return Response.json(
        { success: true, message: "You're on the list!" },
        { headers: CORS_HEADERS }
      );
    } catch (err) {
      console.error(err);
      return Response.json(
        { success: false, error: "Something went wrong" },
        { status: 500, headers: CORS_HEADERS }
      );
    }
  },
};
