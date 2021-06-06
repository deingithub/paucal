CREATE TABLE applied_migrations (
    number INTEGER PRIMARY KEY
);

CREATE TABLE systems (
    discord_id INTEGER PRIMARY KEY,
    pk_system_id TEXT NOT NULL,
    pk_token TEXT NOT NULL
);

CREATE TABLE bots (
    token TEXT PRIMARY KEY
);

CREATE TABLE members (
    pk_member_id TEXT PRIMARY KEY,
    deleted BOOLEAN NOT NULL DEFAULT false,
    system_discord_id INTEGER NOT NULL,
    token TEXT NOT NULL,
    pk_data TEXT NOT NULL,
    FOREIGN KEY (system_discord_id) REFERENCES systems(discord_id),
    FOREIGN KEY (token) REFERENCES bots(token)
);
