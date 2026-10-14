-- tor: 1 connects through Tor, at proxy or, when that's "", 127.0.0.1:9050.
ALTER TABLE account ADD COLUMN tor INTEGER NOT NULL DEFAULT 0;
