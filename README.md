# gqmd

`update`, `collection list` and plain `search` from [qmd](https://github.com/tobi/qmd), written in [Goose](https://github.com/aardappel/goose), on the same SQLite index file that TypeScript qmd 2.8.3 writes. For the commands qmd runs most, it uses far less memory.

This is a port of the logic of qmd's `store.ts` (and the printing in `qmd.ts`), not a fork. It is pinned to qmd **2.8.3** and Goose commit **e0b1225** (Goose is pre-1.0 and its language may change). MIT licence; the LICENSE file holds ours and qmd's notice.

There is no test suite: this is a hand demonstration, and section 4 says what was shown.

## 1. Build and use

Linux x86_64, with libsqlite3, libcrypto and libc installed (the build file maps them). With a Goose build on your PATH:

```
goose build gqmd.goose
./gqmd update
./gqmd collection list
./gqmd search [-n N] [-c NAME] "words"
```

`--index NAME` picks a different index, as in qmd. The index is `$XDG_CACHE_HOME/qmd/<name>.sqlite`, or `~/.cache/qmd/<name>.sqlite`. Collections come from qmd's own configuration, so add them with qmd first. Exit codes: 2 for a command or flag gqmd does not read, 3 for an error (for example the index or a file could not be opened), 4 when `update` meets a collection it will not reproduce (an update command, or a glob pattern it does not read), before it writes anything. So a script can fall back to qmd: `gqmd update || qmd update`.

## 2. What it does not do

1. `embed`, `vsearch`, `query`, `get`, `status`, and the json/csv/md/xml/files formats and `--full-path`.
2. `update` leaves out qmd's closing "Run 'qmd embed'" line, because its count needs the embedding model and fingerprint.
3. `update` takes no lock of its own; it waits up to 30 s for SQLite's write lock. Run one at a time per index.

## 2a. What `update` writes to your index

`gqmd update` writes into the same index file qmd uses, so do not point it at an index you cannot rebuild without reading this first.

1. It adds a table `gqmd_seen (collection, path, size, mtime_ms)` and leaves it there. It holds the size and modification time each file had when gqmd last read it, so an `update` with nothing changed skips reading the file. qmd 2.8.3 ignores the table. To remove it: `DROP TABLE gqmd_seen;` (the next `gqmd update` then reads every file once and rebuilds it).
2. It makes two temporary tables, `gqmd_live` (update) and `gqmd_res` (search), which SQLite drops when the program ends; neither is stored in your index file.
3. Like qmd's own `update`, it clears the `llm_cache` table (qmd 2.8.3 does so on every update).
4. The rows it writes in `documents`, `content` and the full-text table are meant to equal what qmd writes (section 4, item 1). `search` and `collection list` only read.

## 3. The files

1. `gqmd.goose` the command line; `update.goose`, `search.goose` the two commands.
2. `sql.goose` the few libsqlite3 calls, `hash.goose` SHA-256 through libcrypto, `text.goose` qmd's whitespace, title and CJK rules, `cjk.goose` the code point ranges of qmd's CJK pattern (made by `gen/cjk-ranges.mjs` with Node), `json.goose` the small JSON reader, `fs.goose` the folder walk and glob. They are vendored here so the repo builds on its own. If you want packages instead, others have published Goose SQLite bindings (kaitk/goose-sqlite, carabistouflette/goose-sqlite) and SHA-256 (clintecker/goose-sha256); I have not tried gqmd against them.

## 4. What was shown, and on what

1. `update`, measured by hand on a scratch copy of a 2.8.3-shaped index of 103,785 documents, **once** (n=1): first run read all 103,813 files, peak memory 24.7 MB, about 18 s; a run with nothing changed took 3.8 s. TypeScript qmd 2.8.3 on an index of the same size, with nothing changed: 222-252 MB and a mean of 41.9 s, range 29-60 s (n=5, under bun, on a busy machine, in a different session from the gqmd runs). An earlier version of this README gave 808-886 MB and about 122 s; those were measured on a 471,000-document index, so they were not comparable. The rows `update` wrote equalled qmd's, except for 9 files edited between the two runs.
2. `collection list`: byte-identical to qmd's output on the scratch index.
3. `search`: byte-identical stdout to qmd 2.8.3 on 160 queries on a scratch index. Those are the queries the port was checked against while it was written, not a held-out set.
4. A fresh check from this repo: a two-document collection, one file added, `gqmd update` indexed the 1 new file and kept 2, and `gqmd search "socket"` was byte-identical to `qmd search "socket"` (294 bytes). That is n=1 and tiny.

Not shown: a second machine, a non-Linux system, concurrent writers, and any index that a newer qmd than 2.8.3 wrote.
