// text: the string rules qmd 2.8.3 gets from JavaScript, done byte for byte.
// Every function here has a TypeScript twin in qmd's src/store.ts; its name is in the comment.
import std;
import cjk;
namespace text;

// The bytes of a file as Node's readFileSync(path, "utf-8") would hand them to qmd:
// malformed sequences become U+FFFD (WHATWG decoder), a byte order mark is kept.
// The result is valid UTF-8, so every function below may assume it.
fn decode(raw: u8[:], out: u8[>..]&) {
    each_utf8(raw) { push_utf8(out, it); };
}

// The length in bytes of the JavaScript whitespace character at i (what \s and String.trim use), or 0.
// Tab to CR, space, NBSP, U+1680, U+2000..U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF.
fn ws_at(s: u8[:], i: i64) -> i64 {
    let b: i64 = s[i];
    if b == 32 || (b >= 9 && b <= 13) { return 1; }
    if b < 0xC2 { return 0; }
    if b == 0xC2 {
        if i + 1 < s.len && s[i + 1] == 0xA0 { return 2; }
        return 0;
    }
    if i + 2 >= s.len { return 0; }
    let c1: i64 = s[i + 1];
    let c2: i64 = s[i + 2];
    if b == 0xE1 && c1 == 0x9A && c2 == 0x80 { return 3; }
    if b == 0xE2 && c1 == 0x80 && ((c2 >= 0x80 && c2 <= 0x8A) || c2 == 0xA8 || c2 == 0xA9 || c2 == 0xAF) { return 3; }
    if b == 0xE2 && c1 == 0x81 && c2 == 0x9F { return 3; }
    if b == 0xE3 && c1 == 0x80 && c2 == 0x80 { return 3; }
    if b == 0xEF && c1 == 0xBB && c2 == 0xBF { return 3; }
    return 0;
}

// The length of the JavaScript line terminator at i (LF, CR, U+2028, U+2029), or 0. These end a line for ^, $ and . in a /m regex.
fn lt_at(s: u8[:], i: i64) -> i64 {
    let b: i64 = s[i];
    if b == 10 || b == 13 { return 1; }
    if b == 0xE2 && i + 2 < s.len && s[i + 1] == 0x80 && (s[i + 2] == 0xA8 || s[i + 2] == 0xA9) { return 3; }
    return 0;
}

// String.prototype.trim.
fn trim_js(s: u8[:]) -> u8[:] {
    var a = 0;
    while a < s.len {
        let n = ws_at(s, a);
        if n == 0 { break; }
        a += n;
    }
    var e = s.len;
    while e > a {
        var cut = 0;
        if e - 3 >= a && ws_at(s, e - 3) == 3 {
            cut = 3;
        } else if e - 2 >= a && ws_at(s, e - 2) == 2 {
            cut = 2;
        } else if ws_at(s, e - 1) == 1 {
            cut = 1;
        }
        if cut == 0 { break; }
        e -= cut;
    }
    return s[a..e];
}

// The first line of s that /^##?\s+(.+)$/m (two_only false) or /^##\s+(.+)$/m (two_only true) matches:
// the byte range of the capture, untrimmed. \s+ may run across line ends, as in JavaScript, so
// "#\n\nTitle" captures "Title". Matching is deterministic here: the regex never has to backtrack
// except at the very end of the text, where the capture would be whitespace and nothing follows.
fn heading(s: u8[:], two_only: bool) -> i64, i64, bool {
    var p = 0;
    while p < s.len {
        if s[p] == '#' {
            var after = p + 1;
            let second = after < s.len && s[after] == '#';
            if second { after += 1; }
            if second || !two_only {
                var w = after;
                while w < s.len {
                    let n = ws_at(s, w);
                    if n == 0 { break; }
                    w += n;
                }
                if w > after && w < s.len {
                    var e = w;
                    while e < s.len && lt_at(s, e) == 0 { e += 1; }
                    return w, e, true;
                }
            }
        }
        var q = p;
        var next = -1;
        while q < s.len {
            let n = lt_at(s, q);
            if n > 0 { next = q + n; break; }
            q += 1;
        }
        if next < 0 { break; }
        p = next;
    }
    return 0, 0, false;
}

// titleExtractors['.md'] in store.ts. found is false where JavaScript returns null.
fn md_title(content: u8[:]) -> u8[:], bool {
    let a, b, ok = heading(content, false);
    if !ok { return content[0..0], false; }
    let t = trim_js(content[a..b]);
    if t == "Notes" || t == "\xF0\x9F\x93\x9D Notes" {
        let a2, b2, ok2 = heading(content, true);
        if ok2 { return trim_js(content[a2..b2]), true; }
    }
    return t, true;
}

// The file name without its last extension and directories: filename.replace(/\.[^.]+$/, "").split("/").pop() || filename
fn name_from_path(path: u8[:]) -> u8[:] {
    var dot = -1;
    var i = path.len - 1;
    while i >= 0 {
        if path[i] == '.' { dot = i; break; }
        i -= 1;
    }
    var stem = path;
    if dot >= 0 && dot < path.len - 1 { stem = path[0..dot]; }
    var slash = -1;
    i = stem.len - 1;
    while i >= 0 {
        if stem[i] == '/' { slash = i; break; }
        i -= 1;
    }
    let last = stem[slash + 1..];
    if last.len == 0 { return path; }
    return last;
}

// True when the path's extension, lowercased from its last dot, is ".md" (extractTitle's lookup key).
fn is_md(path: u8[:]) -> bool {
    var dot = -1;
    var i = path.len - 1;
    while i >= 0 {
        if path[i] == '.' { dot = i; break; }
        i -= 1;
    }
    if dot < 0 || path.len - dot != 3 { return false; }
    let m = path[dot + 1];
    let d = path[dot + 2];
    return (m == 'm' || m == 'M') && (d == 'd' || d == 'D');
}

// extractTitle(content, filename) for a file whose extension is .md; the caller keeps other extensions out.
fn extract_title(content: u8[:], path: u8[:]) -> u8[:] {
    if is_md(path) {
        let t, ok = md_title(content);
        if ok && t.len > 0 { return t; }
    }
    return name_from_path(path);
}

// The code point and byte length at i of valid UTF-8.
fn cp_at(s: u8[:], i: i64) -> i64, i64 {
    let b: i64 = s[i];
    if b < 0x80 { return b, 1; }
    if b < 0xE0 && i + 1 < s.len {
        let c1: i64 = s[i + 1];
        return ((b & 0x1F) << 6) | (c1 & 0x3F), 2;
    }
    if b < 0xF0 && i + 2 < s.len {
        let c1: i64 = s[i + 1];
        let c2: i64 = s[i + 2];
        return ((b & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F), 3;
    }
    if i + 3 < s.len {
        let c1: i64 = s[i + 1];
        let c2: i64 = s[i + 2];
        let c3: i64 = s[i + 3];
        return ((b & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F), 4;
    }
    return 0xFFFD, 1;
}

fn is_cjk(cp: i64) -> bool {
    if cp < 0x1100 { return false; }
    var lo = 0;
    var hi = cjk::RANGES.len / 2 - 1;
    while lo <= hi {
        let mid = (lo + hi) / 2;
        if cp < cjk::RANGES[mid * 2] {
            hi = mid - 1;
        } else if cp > cjk::RANGES[mid * 2 + 1] {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

// normalizeCjkForFTS: each run of Han, Hiragana, Katakana or Hangul becomes " c h a r s ", one space between characters and one on each side.
fn normalize_cjk(s: u8[:], out: u8[>..]&) {
    var i = 0;
    while i < s.len {
        let cp, n = cp_at(s, i);
        if is_cjk(cp) {
            out.push(' ');
            var first = true;
            while i < s.len {
                let cp2, n2 = cp_at(s, i);
                if !is_cjk(cp2) { break; }
                if !first { out.push(' '); }
                out.append(s[i..i + n2]);
                first = false;
                i += n2;
            }
            out.push(' ');
        } else {
            out.append(s[i..i + n]);
            i += n;
        }
    }
}
