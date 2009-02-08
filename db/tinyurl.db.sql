CREATE TABLE tinyurl (
    id   INTEGER PRIMARY KEY,
    tiny TEXT,
    url  TEXT,
    UNIQUE(tiny) ON CONFLICT IGNORE
);

