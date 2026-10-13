-- proxy: "socks5://[user:pass@]host:port", or "" to connect directly.
ALTER TABLE account ADD COLUMN proxy TEXT NOT NULL DEFAULT '';
