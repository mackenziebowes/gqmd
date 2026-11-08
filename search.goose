// search: `qmd search "words"` as qmd 2.8.3 prints it with no colour (stdout is not a terminal).
// Every function has a twin in qmd's src (store.ts buildFTS5Query, searchFTS, extractSnippet, getContextForFile;
// cli/qmd.ts search, outputResults). Scope: an ASCII query, the cli format, -n and -c. Anything else is refused
// by the caller with exit 2 or 4 so a caller can hand it to qmd.
import std;
import os;
import sql;
import text;
import json;
namespace search;

fn is_alnum(b: u8) -> bool {
    return (b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z');
}

// JavaScript's \s on an ASCII byte.
fn is_ws(b: u8) -> bool { return b == 32 || (b >= 9 && b <= 13); }

// sanitizeFTS5Term on ASCII: keep letters, digits, ' and _, lower-cased.
fn sanitize_term(t: u8[:], out: u8[>..]&) {
    for b in t {
        if b >= 'A' && b <= 'Z' {
            out.push(b + 32);
        } else if is_alnum(b) || b == '\'' || b == '_' {
            out.push(b);
        }
    }
}

// isDottedToken: two or more non-empty parts of letters, digits and _, split on dots.
fn is_dotted(t: u8[:]) -> bool {
    var dots = 0;
    var len = 0;
    for b in t {
        if b == '.' {
            if len == 0 { return false; }
            dots += 1;
            len = 0;
        } else if is_alnum(b) || b == '_' {
            len += 1;
        } else {
            return false;
        }
    }
    return len > 0 && dots >= 1;
}

// isHyphenatedToken: /^[\p{L}\p{N}][\p{L}\p{N}'-]*-[\p{L}\p{N}][\p{L}\p{N}'-]*$/u
fn is_hyphenated(t: u8[:]) -> bool {
    if t.len < 3 || !is_alnum(t[0]) { return false; }
    var found = false;
    for j in t.len {
        let b = t[j];
        if !(is_alnum(b) || b == '\'' || b == '-') { return false; }
        if j >= 1 && b == '-' && j + 1 < t.len && is_alnum(t[j + 1]) { found = true; }
    }
    return found;
}

fn add_word(out: u8[>..]&, w: u8[:]) {
    if w.len == 0 { return; }
    if out.len > 0 { out.push(' '); }
    out.append(w);
}

// sanitizeFTS5Phrase on ASCII: words split on whitespace, dotted words split into parts, each part sanitized.
fn sanitize_phrase(phrase: u8[:], out: u8[>..]&) {
    var i = 0;
    while i < phrase.len {
        while i < phrase.len && is_ws(phrase[i]) { i += 1; }
        let start = i;
        while i < phrase.len && !is_ws(phrase[i]) { i += 1; }
        if i > start {
            let word = phrase[start..i];
            if is_dotted(word) {
                for part in split(word, '.') {
                    var p: u8[>..] = [];
                    sanitize_term(part, p);
                    add_word(out, p);
                }
            } else {
                var p: u8[>..] = [];
                sanitize_term(word, p);
                add_word(out, p);
            }
        }
    }
}

// buildFTS5Query on an ASCII query. False when qmd would return no results without asking SQLite.
fn build_fts(query: u8[:], out: u8[>..]&) -> bool {
    let s = text::trim_js(query);
    var pos: u8[][>..] = [];
    var neg: u8[][>..] = [];
    var i = 0;
    while i < s.len {
        while i < s.len && is_ws(s[i]) { i += 1; }
        if i >= s.len { break; }
        let negated = s[i] == '-';
        if negated { i += 1; }
        if i < s.len && s[i] == '"' {
            let start = i + 1;
            i += 1;
            while i < s.len && s[i] != '"' { i += 1; }
            let phrase = text::trim_js(s[start..i]);
            i += 1;
            if phrase.len > 0 {
                var san: u8[>..] = [];
                sanitize_phrase(phrase, san);
                if san.len > 0 {
                    if negated { neg.push(str("\"", san, "\"")); } else { pos.push(str("\"", san, "\"")); }
                }
            }
        } else {
            let start = i;
            while i < s.len && !is_ws(s[i]) && s[i] != '"' { i += 1; }
            let term = s[start..i];
            if is_hyphenated(term) {
                var san: u8[>..] = [];
                for part in split(term, '-') {
                    var p: u8[>..] = [];
                    sanitize_term(part, p);
                    add_word(san, p);
                }
                if san.len > 0 {
                    if negated { neg.push(str("\"", san, "\"")); } else { pos.push(str("\"", san, "\"")); }
                }
            } else if is_dotted(term) {
                var joined: u8[>..] = [];
                for part in split(term, '.') {
                    var p: u8[>..] = [];
                    sanitize_term(part, p);
                    if p.len > 0 {
                        if negated {
                            if joined.len > 0 { joined.append(" AND "); }
                            joined.append(str("\"", p, "\"*"));
                        } else {
                            pos.push(str("\"", p, "\"*"));
                        }
                    }
                }
                if negated && joined.len > 0 { neg.push(str("(", joined, ")")); }
            } else {
                var san: u8[>..] = [];
                sanitize_term(term, san);
                if san.len > 0 {
                    if negated { neg.push(str("\"", san, "\"*")); } else { pos.push(str("\"", san, "\"*")); }
                }
            }
        }
    }
    if pos.len == 0 { return false; }
    var first = true;
    for p in pos {
        if !first { out.append(" AND "); }
        out.append(p);
        first = false;
    }
    for n in neg {
        out.append(" NOT ");
        out.append(n);
    }
    return true;
}

// String.prototype.toLowerCase as far as an ASCII search term can tell: ASCII letters, plus the two characters
// whose lower case holds an ASCII letter (U+212A Kelvin sign gives k, U+0130 gives i and a combining dot).
fn lower_js(s: u8[:], out: u8[>..]&) {
    var i = 0;
    while i < s.len {
        let b = s[i];
        if b >= 'A' && b <= 'Z' {
            out.push(b + 32);
            i += 1;
        } else if b == 0xE2 && i + 2 < s.len && s[i + 1] == 0x84 && s[i + 2] == 0xAA {
            out.push('k');
            i += 3;
        } else if b == 0xC4 && i + 1 < s.len && s[i + 1] == 0xB0 {
            out.push('i');
            out.push(0xCC);
            out.push(0x87);
            i += 2;
        } else {
            out.push(b);
            i += 1;
        }
    }
}

// The length of a string in UTF-16 units, as JavaScript counts it.
fn utf16_len(s: u8[:]) -> i64 {
    var n = 0;
    var i = 0;
    while i < s.len {
        let cp, w = text::cp_at(s, i);
        n += if cp >= 0x10000 { 2 } else { 1 };
        i += w;
    }
    return n;
}

// s.substring(0, n) on UTF-16 units. A cut through a surrogate pair leaves a lone surrogate, which output turns into U+FFFD.
fn cut16(s: u8[:], n: i64, out: u8[>..]&) {
    var units = 0;
    var i = 0;
    while i < s.len {
        let cp, w = text::cp_at(s, i);
        let u = if cp >= 0x10000 { 2 } else { 1 };
        if units + u > n {
            if u == 2 && units + 1 == n { push_utf8(out, 0xFFFD); }
            return;
        }
        out.append(s[i..i + w]);
        units += u;
        i += w;
    }
}

// extractSnippet(body, query, 500) with no chunk position. Appends the diff-style header, a newline and the text;
// returns the 1-based line of the best match.
fn extract_snippet(body: u8[:], terms: u8[][:], out: u8[>..]&) -> i64 {
    let lines = split(body, '\n');
    let total = lines.len;
    var best = 0;
    var best_score = -1;
    var low: u8[>..] = [];
    for li in total {
        low.clear();
        lower_js(lines[li], low);
        var score = 0;
        for t in terms {
            if find(low, t) >= 0 { score += 1; }
        }
        if score > best_score {
            best_score = score;
            best = li;
        }
    }
    let start = if best - 1 > 0 { best - 1 } else { 0 };
    let end = if best + 3 < total { best + 3 } else { total };
    var joined: u8[>..] = [];
    var k = start;
    while k < end {
        if k > start { joined.push(10); }
        joined.append(lines[k]);
        k += 1;
    }
    var shown: u8[>..] = [];
    if utf16_len(joined) > 500 {
        cut16(joined, 497, shown);
        shown.append("...");
    } else {
        shown.append(joined);
    }
    let abs_start = start + 1;
    let count = end - start;
    let before = abs_start - 1;
    let after = total - (abs_start + count - 1);
    out.append(str("@@ -", abs_start, ",", count, " @@ (", before, " before, ", after, " after)\n"));
    out.append(shown);
    return best + 1;
}

// (score * 100).toFixed(0): round half up on the exact value, as JavaScript does.
fn pct(score: f64) -> i64 {
    let x = score * 100.0;
    let n = x as! i64;
    let frac = x - (n as f64);
    return if frac >= 0.5 { n + 1 } else { n };
}

// getContextForFile: the global context, then every path context whose prefix the path starts with, shortest prefix first.
// False when a context is in a shape gqmd does not read.
fn context_for(db: u64, collection: u8[:], path: u8[:], out: u8[>..]&) -> bool {
    var parts: u8[][>..] = [];
    let g = sql::prepare(db, "SELECT value FROM store_config WHERE key = 'global_context'");
    if g == 0 { return false; }
    if sql::step(g) == sql::ROW {
        var v: u8[>..] = [];
        sql::col_text(g, 0, v);
        if v.len > 0 { parts.push(copy(v)); }
    }
    sql::finalize(g);

    let st = sql::prepare(db, "SELECT context FROM store_collections WHERE name = ?");
    if st == 0 { return false; }
    sql::bind_text(st, 1, collection);
    var keys: u8[][>..] = [];
    var vals: u8[][>..] = [];
    if sql::step(st) == sql::ROW && !sql::is_null(st, 0) {
        var raw: u8[>..] = [];
        sql::col_text(st, 0, raw);
        if raw.len > 0 && !json::read_flat_object(raw, keys, vals) { sql::finalize(st); return false; }
    }
    sql::finalize(st);

    var npath: u8[>..] = [];
    if path.len == 0 || path[0] != '/' { npath.push('/'); }
    npath.append(path);
    var plen: i64[>..] = [];
    var hit: u8[][>..] = [];
    for key in keys {
        // JavaScript lists integer-like keys first; gqmd does not reproduce that.
        var digits = key.len > 0;
        for b in key { if b < '0' || b > '9' { digits = false; } }
        if digits { return false; }
    }
    var vi = 0;
    for key in keys {
        var nk: u8[>..] = [];
        if key.len == 0 || key[0] != '/' { nk.push('/'); }
        nk.append(key);
        if starts_with(npath, nk) {
            plen.push(nk.len);
            var val: u8[>..] = [];
            var j = 0;
            for x in vals {
                if j == vi { val.append(x); }
                j += 1;
            }
            hit.push(copy(val));
        }
        vi += 1;
    }
    // stable order by prefix length
    var used: u8[>..] = [];
    for h in hit { used.push(0); }
    var taken = 0;
    while taken < hit.len {
        var pick = -1;
        var pick_len = 0;
        for q in plen.len {
            if used[q] == 0 && (pick < 0 || plen[q] < pick_len) {
                pick = q;
                pick_len = plen[q];
            }
        }
        used[pick] = 1;
        var j = 0;
        for x in hit {
            if j == pick { parts.push(copy(x)); }
            j += 1;
        }
        taken += 1;
    }
    var first = true;
    for p in parts {
        if !first { out.append("\n\n"); }
        out.append(p);
        first = false;
    }
    return true;
}

// qmd search. cnames are the -c names (empty: every collection included by default). Output goes to out.
// Returns 0, or 4 for a case gqmd does not read.
fn run(db: u64, query: u8[:], limit: i64, cnames: u8[][:], out: u8[>..]&) -> i32 {
    // collections to search, as searchFTS gets them
    var names: u8[][>..] = [];
    if cnames.len > 0 {
        for n in cnames {
            let chk = sql::prepare(db, "SELECT 1 FROM store_collections WHERE name = ?");
            if chk == 0 { return 4; }
            sql::bind_text(chk, 1, n);
            let found = sql::step(chk) == sql::ROW;
            sql::finalize(chk);
            if !found { return 4; }
            names.push(copy(n));
        }
    } else {
        let all = sql::prepare(db, "SELECT name FROM store_collections WHERE include_by_default IS NULL OR include_by_default <> 0");
        if all == 0 { return 4; }
        while sql::step(all) == sql::ROW {
            var nm: u8[>..] = [];
            sql::col_text(all, 0, nm);
            names.push(copy(nm));
        }
        sql::finalize(all);
    }

    var fts: u8[>..] = [];
    let has_query = build_fts(query, fts);
    let fetch = if limit * 2 > 50 { limit * 2 } else { 50 };

    sql::exec(db, "CREATE TEMP TABLE gqmd_res (seq INTEGER PRIMARY KEY AUTOINCREMENT, filepath TEXT, display_path TEXT, title TEXT, body TEXT, hash TEXT, score REAL)");
    if has_query {
        var scopes = names.len;
        if scopes == 0 { scopes = 1; }
        for si in scopes {
            let filtered = names.len > 0;
            let fts_limit = if filtered { fetch * 10 } else { fetch };
            let sqlt = str("WITH fts_matches AS (SELECT rowid, bm25(documents_fts, 1.5, 4.0, 1.0) AS bm25_score FROM documents_fts WHERE documents_fts MATCH ?1 ORDER BY bm25_score ASC LIMIT ", fts_limit, ") INSERT INTO gqmd_res (filepath, display_path, title, body, hash, score) SELECT 'qmd://' || d.collection || '/' || d.path, d.collection || '/' || d.path, d.title, content.doc, d.hash, abs(fm.bm25_score) / (1 + abs(fm.bm25_score)) FROM fts_matches fm JOIN documents d ON d.id = fm.rowid JOIN content ON content.hash = d.hash WHERE d.active = 1", if filtered { " AND d.collection = ?2" } else { "" }, " ORDER BY fm.bm25_score ASC LIMIT ", fetch);
            let ins = sql::prepare(db, sqlt);
            if ins == 0 { return 4; }
            sql::bind_text(ins, 1, fts);
            if filtered {
                var j = 0;
                for n in names {
                    if j == si { sql::bind_text(ins, 2, n); }
                    j += 1;
                }
            }
            sql::step(ins);
            sql::finalize(ins);
        }
    }

    var terms: u8[][>..] = [];
    var lowq: u8[>..] = [];
    lower_js(query, lowq);
    for w in split(lowq, ' ') {
        // /\s+/ on an ASCII query: split on every whitespace byte
        var cur: u8[>..] = [];
        for b in w {
            if is_ws(b) {
                if cur.len > 0 { terms.push(copy(cur)); cur.clear(); }
            } else { cur.push(b); }
        }
        if cur.len > 0 { terms.push(copy(cur)); }
    }

    let sel = sql::prepare(db, str("SELECT filepath, display_path, title, body, hash, score FROM gqmd_res ORDER BY score DESC, seq ASC LIMIT ", limit));
    if sel == 0 { return 4; }
    var rows = 0;
    while sql::step(sel) == sql::ROW {
        var filepath: u8[>..] = [];
        var display: u8[>..] = [];
        var title: u8[>..] = [];
        var body: u8[>..] = [];
        var hash: u8[>..] = [];
        sql::col_text(sel, 0, filepath);
        sql::col_text(sel, 1, display);
        sql::col_text(sel, 2, title);
        sql::col_text(sel, 3, body);
        sql::col_text(sel, 4, hash);
        let score = sql::col_flt(sel, 5);
        if rows > 0 { out.append("\n\n"); }
        rows += 1;

        var snippet: u8[>..] = [];
        let line = extract_snippet(body, terms, snippet);
        // only show :line when a query term is in the snippet below its header line
        var below: u8[>..] = [];
        var seen_nl = false;
        for b in snippet { if seen_nl { below.push(b); } else if b == 10 { seen_nl = true; } }
        var below_low: u8[>..] = [];
        lower_js(below, below_low);
        var has_match = false;
        for t in terms { if find(below_low, t) >= 0 { has_match = true; } }

        var docid: u8[>..] = [];
        var di = 0;
        while di < 6 && di < hash.len { docid.push(hash[di]); di += 1; }
        out.append(filepath);
        if has_match { out.append(str(":", line)); }
        out.append(str(" #", docid, "\n"));
        if title.len > 0 { out.append(str("Title: ", title, "\n")); }

        // the collection is the part of the display path before the first slash
        var coll: u8[>..] = [];
        var rest: u8[>..] = [];
        var past = false;
        for b in display {
            if past { rest.push(b); } else if b == '/' { past = true; } else { coll.push(b); }
        }
        var ctx: u8[>..] = [];
        if !context_for(db, coll, rest, ctx) { sql::finalize(sel); return 4; }
        if ctx.len > 0 { out.append(str("Context: ", ctx, "\n")); }

        var p = str(pct(score));
        out.append("Score: ");
        var padn = 3 - p.len;
        while padn > 0 { out.push(' '); padn -= 1; }
        out.append(str(p, "%\n\n"));
        out.append(snippet);
        out.push(10);
    }
    sql::finalize(sel);
    if rows == 0 { out.append("No results found.\n"); }
    return 0;
}
