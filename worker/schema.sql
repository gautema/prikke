-- Waitlist table
CREATE TABLE IF NOT EXISTS waitlist (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT UNIQUE NOT NULL,
    created_at TEXT NOT NULL
);

-- Index for quick lookups
CREATE INDEX IF NOT EXISTS idx_waitlist_email ON waitlist(email);
