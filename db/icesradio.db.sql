CREATE TABLE replies (
    id               INTEGER PRIMARY KEY,
    status_id        INTEGER NOT NULL,
    text             TEXT NOT NULL,
    user_id          INTEGER NOT NULL,
    user_name        TEXT NOT NULL,
    user_screen_name TEXT NOT NULL,
    created_at       TEXT NOT NULL,
    state            INTEGER NOT NULL DEFAULT 0,
    UNIQUE(status_id)
);

CREATE TABLE files (
    id       INTEGER PRIMARY KEY,
    url      TEXT NOT NULL,
    title    TEXT,
    filename TEXT,
    username TEXT,
    try      INTEGER NOT NULL DEFAULT 0,
    state    INTEGER NOT NULL DEFAULT 0,
    UNIQUE(url)
);

CREATE TABLE programs (
    id         INTEGER PRIMARY KEY,
    file_id    INTEGER REFERENCES files(id),
    type       INTEGER NOT NULL DEFAULT 0,
    request_id INTEGER,
    added      INTEGER NOT NULL DEFAULT 0
);

