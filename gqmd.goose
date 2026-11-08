// gqmd: qmd's hot commands in Goose, on the same SQLite index file TypeScript qmd 2.8.3 writes.
// Commands: update. Anything else is refused with exit 2, so a caller can hand it to qmd.
import std;
import os;
import sql;
import text;
import fs;
import update;
import search;

let USAGE = "usage: gqmd [--index NAME] update | collection list | search [-n N] [-c NAME] QUERY\n";

// The index file: $XDG_CACHE_HOME/qmd/<name>.sqlite, or ~/.cache/qmd/<name>.sqlite. Same rule as qmd.
fn index_path(name: u8[:], out: u8[>..]&) -> bool {
    var base: u8[>..] = [];
    if env("XDG_CACHE_HOME", base) && base.len > 0 {
        // use as is
    } else {
        base.clear();
        var home: u8[>..] = [];
        if !env("HOME", home) || home.len == 0 { return false; }
        base.append(home);
        base.append("/.cache");
    }
    out.append(base);
    out.append("/qmd/");
    out.append(name);
    out.append(".sqlite");
    return true;
}

// The strings of a JSON array of plain strings, e.g. ["**/target/**","library/**"]. False if it holds anything else (an escape, a non-string).
fn json_strings(s: u8[:], out: u8[][>..]&) -> bool {
    let t = trim(s);
    if t.len == 0 { return true; }
    if t[0] != '[' || t[t.len - 1] != ']' { return false; }
    var i = 1;
    while i < t.len - 1 {
        let ch = t[i];
        if ch == '"' {
            var j = i + 1;
            while j < t.len - 1 && t[j] != '"' {
                if t[j] == '\\' { return false; }
                j += 1;
            }
            if j >= t.len - 1 { return false; }
            out.push(t[i + 1..j]);
            i = j + 1;
        } else if ch == ',' || ch == ' ' || ch == '\n' {
            i += 1;
        } else {
            return false;
        }
    }
    return true;
}

// The index is ours to write only if it carries what qmd 2.8.3 writes: schema version 1 and the three FTS triggers.
fn check_index(db: u64) -> bool {
    let st = sql::prepare(db, "SELECT (SELECT user_version FROM pragma_user_version), (SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name IN ('documents_ai', 'documents_ad', 'documents_au')), (SELECT count(*) FROM sqlite_master WHERE name IN ('documents', 'content', 'documents_fts', 'store_collections'))");
    if st == 0 { return false; }
    var ok = false;
    if sql::step(st) == sql::ROW {
        ok = sql::col_int(st, 0) == 1 && sql::col_int(st, 1) == 3 && sql::col_int(st, 2) >= 4;
    }
    sql::finalize(st);
    return ok;
}

// Variable-size elements cannot be indexed, so the i-th one is found by walking.
fn nth(list: u8[][:], i: i64, out: u8[>..]&) {
    var k = 0;
    for x in list {
        if k == i { out.append(x); return; }
        k += 1;
    }
}

fn run_update(db: u64) -> i32 {
    if !check_index(db) {
        write_stderr("gqmd: this index is not the schema qmd 2.8.3 writes (user_version 1, three FTS triggers); run qmd once to migrate it, or use qmd update\n");
        return 3;
    }
    sql::exec(db, "PRAGMA foreign_keys = ON");
    sql::exec(db, "CREATE TABLE IF NOT EXISTS gqmd_seen (collection TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, mtime_ms INTEGER, PRIMARY KEY (collection, path))");
    sql::exec(db, "CREATE TEMP TABLE IF NOT EXISTS gqmd_live (path TEXT PRIMARY KEY)");
    sql::exec(db, "DELETE FROM llm_cache");

    let cols = sql::prepare(db, "SELECT name, path, pattern, ignore_patterns, update_command FROM store_collections");
    if cols == 0 {
        write_stderr(str("gqmd: ", sql::message(db), "\n"));
        return 3;
    }
    var names: u8[][>..] = [];
    var paths: u8[][>..] = [];
    var patterns: u8[][>..] = [];
    var ignore_json: u8[][>..] = [];
    var hooked = false;
    while sql::step(cols) == sql::ROW {
        var a: u8[>..] = [];
        var b: u8[>..] = [];
        var c: u8[>..] = [];
        var d: u8[>..] = [];
        var e: u8[>..] = [];
        sql::col_text(cols, 0, a);
        sql::col_text(cols, 1, b);
        sql::col_text(cols, 2, c);
        sql::col_text(cols, 3, d);
        sql::col_text(cols, 4, e);
        names.push(copy(a));
        paths.push(copy(b));
        patterns.push(copy(c));
        ignore_json.push(copy(d));
        if e.len > 0 { hooked = true; }
    }
    sql::finalize(cols);
    if names.len == 0 {
        write_stdout("No collections found. Run 'qmd collection add .' to index markdown files.\n");
        return 0;
    }

    // Anything gqmd does not reproduce is refused before any write, so a caller can run qmd instead.
    if hooked {
        write_stderr("gqmd: a collection has an update command; use qmd update\n");
        return 4;
    }
    for i in names.len {
        var cname: u8[>..] = [];
        var cpath: u8[>..] = [];
        var cpattern: u8[>..] = [];
        var cignore: u8[>..] = [];
        nth(names, i, cname);
        nth(paths, i, cpath);
        nth(patterns, i, cpattern);
        nth(ignore_json, i, cignore);
        if !fs::supported(cpattern) {
            write_stderr(str("gqmd: collection ", cname, " has a pattern gqmd does not read (", cpattern, "); use qmd update\n"));
            return 4;
        }
        var ig: u8[][>..] = [];
        if !json_strings(cignore, ig) {
            write_stderr(str("gqmd: collection ", cname, " has ignore patterns gqmd does not read; use qmd update\n"));
            return 4;
        }
        for p in ig {
            if !fs::supported(p) {
                write_stderr(str("gqmd: collection ", cname, " has an ignore pattern gqmd does not read (", p, "); use qmd update\n"));
                return 4;
            }
        }
    }

    let stmts, ok = update::prepare_all(db);
    if !ok {
        write_stderr(str("gqmd: ", sql::message(db), "\n"));
        return 3;
    }
    write_stdout(str("Updating ", names.len, " collection(s)...\n\n"));
    var total_unreadable = 0;
    for i in names.len {
        var cname: u8[>..] = [];
        var cpath: u8[>..] = [];
        var cpattern: u8[>..] = [];
        var cignore: u8[>..] = [];
        nth(names, i, cname);
        nth(paths, i, cpath);
        nth(patterns, i, cpattern);
        nth(ignore_json, i, cignore);
        write_stdout(str("[", i + 1, "/", names.len, "] ", cname, " (", cpattern, ")\n"));
        write_stdout(str("Collection: ", cpath, " (", cpattern, ")\n"));
        var ig: u8[][>..] = [];
        json_strings(cignore, ig);
        var counts = update::Counts { .. };
        update::reindex(db, stmts, cname, cpath, cpattern, ig, counts);
        // cleanupOrphanedContent
        let del = sql::prepare(db, "DELETE FROM content WHERE hash NOT IN (SELECT DISTINCT hash FROM documents)");
        sql::step(del);
        counts.orphaned = sql::changes(db);
        sql::finalize(del);
        write_stdout(str("\nIndexed: ", counts.indexed, " new, ", counts.updated, " updated, ", counts.unchanged, " unchanged, ", counts.removed, " removed (read ", counts.read, ", not read ", counts.not_read, ")\n"));
        if counts.unreadable > 0 { write_stdout(str("Skipped ", counts.unreadable, " file(s) that could not be read\n")); }
        if counts.orphaned > 0 { write_stdout(str("Cleaned up ", counts.orphaned, " orphaned content hash(es)\n")); }
        write_stdout("\n");
        total_unreadable += counts.unreadable;
    }
    update::finalize_all(stmts);
    write_stdout("\xE2\x9C\x93 All collections updated.\n");
    return 0;
}

// qmd's formatTimeAgo.
fn time_ago(seconds: i64) -> u8[>..] {
    var s = seconds;
    if s < 0 { s = 0; }
    if s < 60 { return str(s, "s ago"); }
    let m = s / 60;
    if m < 60 { return str(m, "m ago"); }
    let h = m / 60;
    if h < 24 { return str(h, "h ago"); }
    return str(h / 24, "d ago");
}

// qmd collection list, as qmd prints it with no colour (output is not a terminal).
fn run_collection_list(db: u64) -> i32 {
    let n = sql::prepare(db, "SELECT count(*) FROM store_collections");
    if n == 0 { write_stderr(str("gqmd: ", sql::message(db), "\n")); return 3; }
    sql::step(n);
    let total = sql::col_int(n, 0);
    sql::finalize(n);
    if total == 0 {
        write_stdout("No collections found. Run 'qmd collection add .' to create one.\n");
        return 0;
    }
    let st = sql::prepare(db, "SELECT c.name, c.pattern, c.ignore_patterns, c.include_by_default, (SELECT count(*) FROM documents d WHERE d.collection = c.name AND d.active = 1), (SELECT CAST((julianday(max(d.modified_at)) - 2440587.5) * 86400000 AS INTEGER) FROM documents d WHERE d.collection = c.name) FROM store_collections c");
    if st == 0 { write_stderr(str("gqmd: ", sql::message(db), "\n")); return 3; }
    write_stdout(str("Collections (", total, "):\n\n"));
    let now_ms = (time() * 1000.0) as! i64;
    while sql::step(st) == sql::ROW {
        var name: u8[>..] = [];
        var pattern: u8[>..] = [];
        var ignore: u8[>..] = [];
        sql::col_text(st, 0, name);
        sql::col_text(st, 1, pattern);
        sql::col_text(st, 2, ignore);
        let excluded = !sql::is_null(st, 3) && sql::col_int(st, 3) == 0;
        let active = sql::col_int(st, 4);
        let ago = if sql::is_null(st, 5) { 0 } else { (now_ms - sql::col_int(st, 5)) / 1000 };
        write_stdout(str(name, " (qmd://", name, "/)", if excluded { " [excluded]" } else { "" }, "\n"));
        write_stdout(str("  Pattern:  ", pattern, "\n"));
        var ig: u8[][>..] = [];
        if json_strings(ignore, ig) && ig.len > 0 {
            var joined: u8[>..] = [];
            for p in ig {
                if joined.len > 0 { joined.append(", "); }
                joined.append(p);
            }
            write_stdout(str("  Ignore:   ", joined, "\n"));
        }
        write_stdout(str("  Files:    ", active, "\n"));
        write_stdout(str("  Updated:  ", time_ago(ago), "\n\n"));
    }
    sql::finalize(st);
    return 0;
}

fn real_main() -> i32 {
    var index = "index";
    var idx_name: u8[>..] = [];
    var first: u8[>..] = [];
    var rest: u8[>..] = [];
    var limit_text: u8[>..] = [];
    var cnames: u8[][>..] = [];
    var i = 1;
    while i < arg_count() {
        var a: u8[>..] = [];
        arg(i, a);
        if a == "--index" || a == "-i" {
            i += 1;
            if i >= arg_count() { write_stderr(USAGE); return 2; }
            arg(i, idx_name);
        } else if a == "-n" {
            i += 1;
            if i >= arg_count() { write_stderr(USAGE); return 2; }
            arg(i, limit_text);
        } else if a == "-c" {
            i += 1;
            if i >= arg_count() { write_stderr(USAGE); return 2; }
            var cn: u8[>..] = [];
            arg(i, cn);
            cnames.push(copy(cn));
        } else if a.len > 0 && a[0] == '-' {
            write_stderr(USAGE);
            return 2;
        } else if first.len == 0 {
            first.append(a);
        } else {
            if rest.len > 0 { rest.push(' '); }
            rest.append(a);
        }
        i += 1;
    }
    let is_update = first == "update" && rest.len == 0;
    let is_list = first == "collection" && rest == "list";
    let is_search = first == "search" && rest.len > 0;
    if !is_update && !is_list && !is_search {
        write_stderr(USAGE);
        return 2;
    }
    if !is_search && (limit_text.len > 0 || cnames.len > 0) {
        write_stderr(USAGE);
        return 2;
    }
    // qmd: parseInt(-n) || 5; gqmd reads only plain digits
    var limit = 5;
    if is_search && limit_text.len > 0 {
        let v, ok = parse_int(limit_text);
        if !ok || v < 0 || limit_text[0] == '+' { write_stderr(USAGE); return 2; }
        if v > 0 { limit = v; }
    }
    if is_search {
        for b in rest { if b >= 0x80 { write_stderr("gqmd: a query with non-ASCII text goes to qmd\n"); return 4; } }
    }
    var path: u8[>..] = [];
    if !index_path(if idx_name.len > 0 { idx_name } else { index }, path) {
        write_stderr("gqmd: cannot find the index folder: HOME is not set\n");
        return 2;
    }
    let db = sql::open(path, if is_update { sql::READWRITE } else { sql::READONLY });
    if db == 0 {
        write_stderr(str("gqmd: cannot open ", path, "\n"));
        return 3;
    }
    var rc: i32 = 0;
    if is_update {
        rc = run_update(db);
    } else if is_list {
        rc = run_collection_list(db);
    } else {
        var out: u8[>..] = [];
        rc = search::run(db, rest, limit, cnames, out);
        if rc == 0 { write_stdout(out); }
    }
    sql::close(db);
    return rc;
}

fn main() {
    exit(real_main());
}
