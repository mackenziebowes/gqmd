// update: gqmd's `update`, a port of reindexCollection in qmd 2.8.3 (src/store.ts) onto the same SQLite file.
//
// One module, one machine. A file the walk lists is in one of these states, and an event moves it:
//
//   Fresh    no active document row for (collection, path)
//   Known    an active row exists; gqmd_seen may hold the stat that the file had when it was last read
//
//   event StatSame      Known + stat equal to gqmd_seen              -> Skip           (the new skip-unchanged step)
//   event Read(...)     the file was read, decoded, hashed and titled -> one of the Effects below
//
//   Fresh                       -> Insert
//   Known, same hash, same title -> Touch        (only the stat is recorded)
//   Known, same hash, new title  -> Retitle
//   Known, new hash              -> Replace
//
// `decide` is the transition function; `apply` carries out an Effect against SQLite. Nothing else decides.
import std;
import os;
import sql;
import text;
import hash;
import fs;
namespace update;

enum Effect { Skip, Insert, Touch, Retitle, Replace }

// What the database knows about a path before the file is read.
struct Known {
    present: bool,       // an active documents row exists
    id: i64,
    seen: bool,          // gqmd_seen holds a stat that can be trusted
    seen_size: i64,
    seen_mtime_ms: i64,
}

struct Counts {
    indexed: i64,
    updated: i64,
    unchanged: i64,
    removed: i64,
    not_read: i64,
    read: i64,
    unreadable: i64,
    orphaned: i64,
}

// The transition function, part one: before reading. True when the stored stat equals the file's.
fn stat_same(k: Known, st: fs::Stat) -> bool {
    return k.present && k.seen && k.seen_size == st.size && k.seen_mtime_ms == st.mtime_ms;
}

// Part two: after reading. same_hash and same_title compare with the row's stored values.
fn decide(k: Known, same_hash: bool, same_title: bool) -> Effect {
    if !k.present { return Effect.Insert; }
    if !same_hash { return Effect.Replace; }
    if !same_title { return Effect.Retitle; }
    return Effect.Touch;
}

// The prepared statements, one per SQL step, made once per run.
struct Stmts {
    find: u64,
    content_ins: u64,
    doc_upsert: u64,
    doc_id: u64,
    doc_retitle: u64,
    doc_replace: u64,
    fts_sel: u64,
    fts_del: u64,
    fts_ins: u64,
    seen_set: u64,
    live_ins: u64,
}

fn prepare_all(db: u64) -> Stmts, bool {
    var s = Stmts { .. };
    s.find = sql::prepare(db, """
        SELECT d.id, d.hash, d.title, s.size, s.mtime_ms
        FROM documents d
        LEFT JOIN gqmd_seen s ON s.collection = d.collection AND s.path = d.path
        WHERE d.collection = ? AND d.path = ? AND d.active = 1
        """);
    s.content_ins = sql::prepare(db, "INSERT OR IGNORE INTO content (hash, doc, created_at) VALUES (?, ?, ?)");
    s.doc_upsert = sql::prepare(db, """
        INSERT INTO documents (collection, path, title, hash, created_at, modified_at, active)
        VALUES (?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(collection, path) DO UPDATE SET
          title = excluded.title,
          hash = excluded.hash,
          modified_at = excluded.modified_at,
          active = 1
        """);
    s.doc_id = sql::prepare(db, "SELECT id FROM documents WHERE collection = ? AND path = ?");
    s.doc_retitle = sql::prepare(db, "UPDATE documents SET title = ?, modified_at = ? WHERE id = ?");
    s.doc_replace = sql::prepare(db, "UPDATE documents SET title = ?, hash = ?, modified_at = ? WHERE id = ?");
    s.fts_sel = sql::prepare(db, """
        SELECT d.id, d.collection, d.path, d.title, content.doc
        FROM documents d JOIN content ON content.hash = d.hash
        WHERE d.id = ? AND d.active = 1
        """);
    s.fts_del = sql::prepare(db, "DELETE FROM documents_fts WHERE rowid = ?");
    s.fts_ins = sql::prepare(db, "INSERT INTO documents_fts(rowid, filepath, title, body) VALUES (?, ?, ?, ?)");
    s.seen_set = sql::prepare(db, "INSERT OR REPLACE INTO gqmd_seen (collection, path, size, mtime_ms) VALUES (?, ?, ?, ?)");
    s.live_ins = sql::prepare(db, "INSERT OR IGNORE INTO gqmd_live (path) VALUES (?)");
    let ok = s.find != 0 && s.content_ins != 0 && s.doc_upsert != 0 && s.doc_id != 0 && s.doc_retitle != 0
        && s.doc_replace != 0 && s.fts_sel != 0 && s.fts_del != 0 && s.fts_ins != 0 && s.seen_set != 0 && s.live_ins != 0;
    return s, ok;
}

fn finalize_all(s: Stmts) {
    sql::finalize(s.find);
    sql::finalize(s.content_ins);
    sql::finalize(s.doc_upsert);
    sql::finalize(s.doc_id);
    sql::finalize(s.doc_retitle);
    sql::finalize(s.doc_replace);
    sql::finalize(s.fts_sel);
    sql::finalize(s.fts_del);
    sql::finalize(s.fts_ins);
    sql::finalize(s.seen_set);
    sql::finalize(s.live_ins);
}

// rebuildDocumentFTS: replace the document's FTS row with one whose CJK is spaced out (the triggers write raw text first).
fn rebuild_fts(s: Stmts, id: i64) {
    sql::reset(s.fts_sel);
    sql::bind_int(s.fts_sel, 1, id);
    var path: u8[>..] = [];
    var title: u8[>..] = [];
    var body: u8[>..] = [];
    var have = false;
    if sql::step(s.fts_sel) == sql::ROW {
        have = true;
        sql::col_text(s.fts_sel, 1, path);
        path.push('/');
        sql::col_text(s.fts_sel, 2, path);
        sql::col_text(s.fts_sel, 3, title);
        sql::col_text(s.fts_sel, 4, body);
    }
    sql::reset(s.fts_sel);
    sql::reset(s.fts_del);
    sql::bind_int(s.fts_del, 1, id);
    sql::step(s.fts_del);
    sql::reset(s.fts_del);
    if !have { return; }
    var npath: u8[>..] = [];
    var ntitle: u8[>..] = [];
    var nbody: u8[>..] = [];
    text::normalize_cjk(path, npath);
    text::normalize_cjk(title, ntitle);
    text::normalize_cjk(body, nbody);
    sql::reset(s.fts_ins);
    sql::bind_int(s.fts_ins, 1, id);
    sql::bind_text(s.fts_ins, 2, npath);
    sql::bind_text(s.fts_ins, 3, ntitle);
    sql::bind_text(s.fts_ins, 4, nbody);
    sql::step(s.fts_ins);
    sql::reset(s.fts_ins);
}

fn insert_content(s: Stmts, hex: u8[:], body: u8[:], now: u8[:]) {
    sql::reset(s.content_ins);
    sql::bind_text(s.content_ins, 1, hex);
    sql::bind_text(s.content_ins, 2, body);
    sql::bind_text(s.content_ins, 3, now);
    sql::step(s.content_ins);
    sql::reset(s.content_ins);
}

// recordStat: the stat the file had before it was read. A mtime within 2 s of the scan clock may not move on a later write, so it is not trusted.
fn record_stat(s: Stmts, collection: u8[:], path: u8[:], st: fs::Stat, scan_start_ms: i64) {
    sql::reset(s.seen_set);
    sql::bind_text(s.seen_set, 1, collection);
    sql::bind_text(s.seen_set, 2, path);
    sql::bind_int(s.seen_set, 3, st.size);
    if scan_start_ms - st.mtime_ms >= 2000 {
        sql::bind_int(s.seen_set, 4, st.mtime_ms);
    } else {
        sql::bind_null(s.seen_set, 4);
    }
    sql::step(s.seen_set);
    sql::reset(s.seen_set);
}

fn load_known(s: Stmts, collection: u8[:], path: u8[:], hash_out: u8[>..]&, title_out: u8[>..]&) -> Known {
    var k = Known { present: false, id: 0, seen: false, seen_size: 0, seen_mtime_ms: 0 };
    sql::reset(s.find);
    sql::bind_text(s.find, 1, collection);
    sql::bind_text(s.find, 2, path);
    if sql::step(s.find) == sql::ROW {
        k.present = true;
        k.id = sql::col_int(s.find, 0);
        sql::col_text(s.find, 1, hash_out);
        sql::col_text(s.find, 2, title_out);
        if !sql::is_null(s.find, 4) {
            k.seen = true;
            k.seen_size = sql::col_int(s.find, 3);
            k.seen_mtime_ms = sql::col_int(s.find, 4);
        }
    }
    sql::reset(s.find);
    return k;
}

// reindexCollection. ignores are the collection's ignore patterns. Returns false if the walk or a write failed.
fn reindex(db: u64, s: Stmts, name: u8[:], root: u8[:], pattern: u8[:], ignores: u8[][:], c: Counts&) -> bool {
    let scan_start_ms = time_ns() / 1000000;
    var now: u8[>..] = [];
    fs::iso(scan_start_ms, now);

    var files: u8[>..] = [];
    fs::walk(root, pattern, ignores, files);

    sql::exec(db, "DELETE FROM gqmd_live");
    sql::exec(db, "BEGIN IMMEDIATE");
    var in_chunk = 0;
    each_split(files, '\n') {
        let rel = it;
        if rel.len > 0 {
            sql::reset(s.live_ins);
            sql::bind_text(s.live_ins, 1, rel);
            sql::step(s.live_ins);
            sql::reset(s.live_ins);

            var full: u8[>..] = [];
            full.append(root);
            full.push('/');
            full.append(rel);
            let st = fs::lstat(full);

            var old_hash: u8[>..] = [];
            var old_title: u8[>..] = [];
            let k = load_known(s, name, rel, old_hash, old_title);

            if stat_same(k, st) {
                c.not_read += 1;
                c.unchanged += 1;
            } else {
                c.read += 1;
                var raw: u8[>..] = [];
                if !read_file(full, raw) {
                    c.unreadable += 1;
                    write_stderr(str("gqmd: cannot read ", full, "\n"));
                } else {
                    var body: u8[>..] = [];
                    text::decode(raw, body);
                    if text::trim_js(body).len > 0 {
                        var hex: u8[>..] = [];
                        hash::sha256_hex(body, hex);
                        let title = text::extract_title(body, rel);
                        let effect = decide(k, hex == old_hash, title == old_title);
                        var mtime_iso: u8[>..] = [];
                        fs::iso(st.mtime_ms, mtime_iso);
                        match effect {
                            Insert => {
                                c.indexed += 1;
                                insert_content(s, hex, body, now);
                                var btime_iso: u8[>..] = [];
                                fs::iso(st.btime_ms, btime_iso);
                                sql::reset(s.doc_upsert);
                                sql::bind_text(s.doc_upsert, 1, name);
                                sql::bind_text(s.doc_upsert, 2, rel);
                                sql::bind_text(s.doc_upsert, 3, title);
                                sql::bind_text(s.doc_upsert, 4, hex);
                                sql::bind_text(s.doc_upsert, 5, btime_iso);
                                sql::bind_text(s.doc_upsert, 6, mtime_iso);
                                sql::step(s.doc_upsert);
                                sql::reset(s.doc_upsert);
                                sql::reset(s.doc_id);
                                sql::bind_text(s.doc_id, 1, name);
                                sql::bind_text(s.doc_id, 2, rel);
                                if sql::step(s.doc_id) == sql::ROW { rebuild_fts(s, sql::col_int(s.doc_id, 0)); }
                                sql::reset(s.doc_id);
                            },
                            Replace => {
                                c.updated += 1;
                                insert_content(s, hex, body, now);
                                sql::reset(s.doc_replace);
                                sql::bind_text(s.doc_replace, 1, title);
                                sql::bind_text(s.doc_replace, 2, hex);
                                sql::bind_text(s.doc_replace, 3, mtime_iso);
                                sql::bind_int(s.doc_replace, 4, k.id);
                                sql::step(s.doc_replace);
                                sql::reset(s.doc_replace);
                                rebuild_fts(s, k.id);
                            },
                            Retitle => {
                                c.updated += 1;
                                sql::reset(s.doc_retitle);
                                sql::bind_text(s.doc_retitle, 1, title);
                                sql::bind_text(s.doc_retitle, 2, now);
                                sql::bind_int(s.doc_retitle, 3, k.id);
                                sql::step(s.doc_retitle);
                                sql::reset(s.doc_retitle);
                                rebuild_fts(s, k.id);
                            },
                            Touch => { c.unchanged += 1; },
                            Skip => { },
                        }
                        record_stat(s, name, rel, st, scan_start_ms);
                    }
                }
            }
            in_chunk += 1;
            if in_chunk >= 500 {
                sql::exec(db, "COMMIT");
                sql::exec(db, "BEGIN IMMEDIATE");
                in_chunk = 0;
            }
        }
    };
    sql::exec(db, "COMMIT");

    // Deactivate documents whose files are gone. The documents_au trigger drops their FTS rows.
    sql::exec(db, "BEGIN IMMEDIATE");
    let del = sql::prepare(db, "UPDATE documents SET active = 0 WHERE collection = ? AND active = 1 AND path NOT IN (SELECT path FROM gqmd_live)");
    sql::bind_text(del, 1, name);
    sql::step(del);
    c.removed += sql::changes(db);
    sql::finalize(del);
    let del2 = sql::prepare(db, "DELETE FROM gqmd_seen WHERE collection = ? AND path NOT IN (SELECT path FROM gqmd_live)");
    sql::bind_text(del2, 1, name);
    sql::step(del2);
    sql::finalize(del2);
    sql::exec(db, "COMMIT");
    return true;
}
