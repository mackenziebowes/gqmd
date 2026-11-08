// fs: what gqmd needs from the file system: statx, the directory walk with qmd's glob rules, ISO dates.
import std;
import os;
namespace fs;

extern "c" {
    fn statx(dirfd: i32, path: const u8&, flags: i32, mask: u32, buf: u64&) -> i32;
    fn _exit(code: i32);
}

// End the process with a status. Output is written unbuffered, so nothing is lost.
fn quit(code: i32) { _exit(code); }

// What a path is. Symbolic links are told apart, never followed (fast-glob runs with followSymbolicLinks false).
enum Kind { Missing, File, Dir, Link, Other }

struct Stat {
    kind: Kind,
    size: i64,
    mtime_ms: i64,
    btime_ms: i64,
}

// statx(2) without following a final symbolic link (AT_SYMLINK_NOFOLLOW).
// struct statx offsets: mask 0, mode 28, size 40, btime 80/88, mtime 112/120 (seconds, nanoseconds).
fn lstat(path: u8[:]) -> Stat {
    var nul: u8[>..] = [];
    nul.append(path);
    nul.push(0);
    var buf: u64[32] = [0; 32];
    let none = Stat { kind: Kind.Missing, size: 0, mtime_ms: 0, btime_ms: 0 };
    if statx(-100, nul[0], 0x100, 0xFFF, buf[0]) != 0 { return none; }
    let mode: i64 = ((buf[3] >> 32) & 0xFFFF) as! i64;
    let fmt = mode & 0xF000;
    let kind = if fmt == 0x8000 { Kind.File } else if fmt == 0x4000 { Kind.Dir } else if fmt == 0xA000 { Kind.Link } else { Kind.Other };
    let size: i64 = buf[5] as! i64;
    let msec: i64 = buf[14] as! i64;
    let mnsec: i64 = (buf[15] & 0xFFFFFFFF) as! i64;
    var bms = msec * 1000 + mnsec / 1000000;
    if (buf[0] & 0x800) != 0 {
        let bsec: i64 = buf[10] as! i64;
        let bnsec: i64 = (buf[11] & 0xFFFFFFFF) as! i64;
        bms = bsec * 1000 + bnsec / 1000000;
    }
    return Stat { kind: kind, size: size, mtime_ms: msec * 1000 + mnsec / 1000000, btime_ms: bms };
}

// new Date(ms).toISOString(), appended to out: 2026-11-08T15:29:41.123Z
fn iso(ms: i64, out: u8[>..]&) {
    var days = ms / 86400000;
    var rem = ms % 86400000;
    if rem < 0 { rem += 86400000; days -= 1; }
    // civil_from_days (Howard Hinnant)
    let z = days + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    if m <= 2 { y += 1; }
    format_int(out, y, 10, 4, '0');
    out.push('-');
    format_int(out, m, 10, 2, '0');
    out.push('-');
    format_int(out, d, 10, 2, '0');
    out.push('T');
    format_int(out, rem / 3600000, 10, 2, '0');
    out.push(':');
    format_int(out, rem / 60000 % 60, 10, 2, '0');
    out.push(':');
    format_int(out, rem / 1000 % 60, 10, 2, '0');
    out.push('.');
    format_int(out, rem % 1000, 10, 3, '0');
    out.push('Z');
}

// ---------------------------------------------------------------------------
// Glob: the part of fast-glob/micromatch that qmd's collections use. A pattern is
// segments split on '/'; a segment is "**" (zero or more directories) or text with '*' (anything but '/').
// Anything else (braces, brackets, '?', '!', a backslash, a comma) is not supported and `supported` says so,
// so the caller can hand the work to the TypeScript qmd instead of guessing.
// ---------------------------------------------------------------------------

fn supported(pattern: u8[:]) -> bool {
    if pattern.len == 0 { return false; }
    for c in pattern {
        if c == '{' || c == '}' || c == '[' || c == ']' || c == '(' || c == ')' || c == '?' || c == '!' || c == '\\' || c == ',' {
            return false;
        }
    }
    return true;
}

// One segment against one path segment. '*' matches any run of bytes.
fn seg_match(pat: u8[:], s: u8[:]) -> bool {
    var pi = 0;
    var si = 0;
    var star = -1;
    var mark = 0;
    while si < s.len {
        if pi < pat.len && pat[pi] == '*' {
            star = pi;
            mark = si;
            pi += 1;
        } else if pi < pat.len && pat[pi] == s[si] {
            pi += 1;
            si += 1;
        } else if star >= 0 {
            pi = star + 1;
            mark += 1;
            si = mark;
        } else {
            return false;
        }
    }
    while pi < pat.len && pat[pi] == '*' { pi += 1; }
    return pi == pat.len;
}

// True when the whole relative path (segments joined by '/') matches the pattern.
// The two-pointer walk of seg_match, one level up: a "**" segment is the star and matches any run of directories.
fn glob_match(pattern: u8[:], path: u8[:]) -> bool {
    let pat = split(pattern, '/');
    let segs = split(path, '/');
    var pi = 0;
    var si = 0;
    var star = -1;
    var mark = 0;
    while si < segs.len {
        if pi < pat.len && pat[pi] == "**" {
            star = pi;
            mark = si;
            pi += 1;
        } else if pi < pat.len && seg_match(pat[pi], segs[si]) {
            pi += 1;
            si += 1;
        } else if star >= 0 {
            pi = star + 1;
            mark += 1;
            si = mark;
        } else {
            return false;
        }
    }
    while pi < pat.len && pat[pi] == "**" { pi += 1; }
    return pi == pat.len;
}

// How deep a pattern without "**" can reach: its segment count. -1 when it has "**" (no limit).
fn depth_limit(pattern: u8[:]) -> i64 {
    let pat = split(pattern, '/');
    for seg in pat {
        if seg == "**" { return -1; }
    }
    return pat.len;
}

// qmd always skips these directory names (excludeDirs in reindexCollection).
fn excluded_dir(name: u8[:]) -> bool {
    return name == "node_modules" || name == ".git" || name == ".cache" || name == "vendor" || name == "dist" || name == "build";
}

// The files of a collection, as qmd's fast-glob call would list them: regular files only, no dot-named
// part, none under an excluded directory, none matching an ignore pattern, in no promised order.
// Each relative path is appended to out followed by '\n'. Returns the number of files.
fn walk(root: u8[:], pattern: u8[:], ignores: u8[][:], out: u8[>..]&) -> i64 {
    let limit = depth_limit(pattern);
    var count = 0;
    var queue: u8[>..] = [];       // directories still to read, relative, '\n' after each ("" is the root)
    queue.push('\n');
    var at = 0;
    while at < queue.len {
        var end = at;
        while queue[end] != '\n' { end += 1; }
        let rel = queue[at..end];
        at = end + 1;
        var dirpath: u8[>..] = [];
        dirpath.append(root);
        if rel.len > 0 { dirpath.push('/'); dirpath.append(rel); }
        var names: u8[>..] = [];
        if !list_dir(dirpath, names) { continue; }
        each_split(names, '\n') {
            let name = it;
            if name.len > 0 && name[0] != '.' {
                var childrel: u8[>..] = [];
                if rel.len > 0 { childrel.append(rel); childrel.push('/'); }
                childrel.append(name);
                var childpath: u8[>..] = [];
                childpath.append(root);
                childpath.push('/');
                childpath.append(childrel);
                let st = lstat(childpath);
                if st.kind == Kind.File {
                    var depth = 1;
                    for c in childrel { if c == '/' { depth += 1; } }
                    if (limit < 0 || depth == limit) && glob_match(pattern, childrel) {
                        var ignored = false;
                        for ig in ignores {
                            if glob_match(ig, childrel) { ignored = true; break; }
                        }
                        if !ignored {
                            out.append(childrel);
                            out.push('\n');
                            count += 1;
                        }
                    }
                } else if st.kind == Kind.Dir && !excluded_dir(name) {
                    var depth = 1;
                    for c in childrel { if c == '/' { depth += 1; } }
                    var prune = limit >= 0 && depth >= limit;
                    if !prune {
                        var probe: u8[>..] = [];
                        probe.append(childrel);
                        probe.append("/__gqmd_probe__");
                        for ig in ignores {
                            if glob_match(ig, probe) { prune = true; break; }
                        }
                    }
                    if !prune {
                        queue.append(childrel);
                        queue.push('\n');
                    }
                }
            }
        };
    }
    return count;
}
