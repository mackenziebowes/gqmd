// json: the one JSON shape gqmd reads, an object of string keys and string values (qmd's collection contexts).
// Anything else (a nested value, a bad escape, a number, text after the object) gives false, so the caller can
// hand the command to TypeScript qmd.
import std;
namespace json;

fn hex_val(b: u8) -> i64 {
    if b >= '0' && b <= '9' { return b as i64 - 48; }
    if b >= 'a' && b <= 'f' { return b as i64 - 87; }
    if b >= 'A' && b <= 'F' { return b as i64 - 55; }
    return -1;
}

// Four hex digits at s[i..i+4] as a number, or -1.
fn hex4(s: u8[:], i: i64) -> i64 {
    if i + 4 > s.len { return -1; }
    var v = 0;
    for k in 4 {
        let h = hex_val(s[i + k]);
        if h < 0 { return -1; }
        v = v * 16 + h;
    }
    return v;
}

fn skip_ws(s: u8[:], i: i64) -> i64 {
    var k = i;
    while k < s.len && (s[k] == ' ' || s[k] == '\n' || s[k] == '\t' || s[k] == '\r') { k += 1; }
    return k;
}

// A JSON string starting at the quote s[i]. Appends its UTF-8 text to out and returns the index after the closing quote, or -1.
fn read_string(s: u8[:], i: i64, out: u8[>..]&) -> i64 {
    if i >= s.len || s[i] != '"' { return -1; }
    var k = i + 1;
    while k < s.len {
        let b = s[k];
        if b == '"' { return k + 1; }
        if b < 32 { return -1; }
        if b != '\\' {
            out.push(b);
            k += 1;
        } else {
            k += 1;
            if k >= s.len { return -1; }
            let e = s[k];
            k += 1;
            if e == '"' || e == '\\' || e == '/' { out.push(e); }
            else if e == 'n' { out.push(10); }
            else if e == 't' { out.push(9); }
            else if e == 'r' { out.push(13); }
            else if e == 'b' { out.push(8); }
            else if e == 'f' { out.push(12); }
            else if e == 'u' {
                var cp = hex4(s, k);
                if cp < 0 { return -1; }
                k += 4;
                if cp >= 0xD800 && cp <= 0xDBFF {
                    // a high surrogate needs its low half
                    if k + 6 <= s.len && s[k] == '\\' && s[k + 1] == 'u' {
                        let lo = hex4(s, k + 2);
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            k += 6;
                        } else { return -1; }
                    } else { return -1; }
                } else if cp >= 0xDC00 && cp <= 0xDFFF {
                    return -1;
                }
                push_utf8(out, cp);
            } else { return -1; }
        }
    }
    return -1;
}

// {"key":"value",...} into two parallel lists, in the order written. "" or "{}" give two empty lists.
fn read_flat_object(text: u8[:], keys: u8[][>..]&, vals: u8[][>..]&) -> bool {
    var i = skip_ws(text, 0);
    if i >= text.len { return true; }
    if text[i] != '{' { return false; }
    i = skip_ws(text, i + 1);
    if i < text.len && text[i] == '}' { return skip_ws(text, i + 1) == text.len; }
    while true {
        var k: u8[>..] = [];
        var v: u8[>..] = [];
        i = read_string(text, skip_ws(text, i), k);
        if i < 0 { return false; }
        i = skip_ws(text, i);
        if i >= text.len || text[i] != ':' { return false; }
        i = read_string(text, skip_ws(text, i + 1), v);
        if i < 0 { return false; }
        keys.push(copy(k));
        vals.push(copy(v));
        i = skip_ws(text, i);
        if i >= text.len { return false; }
        if text[i] == ',' { i += 1; }
        else if text[i] == '}' { return skip_ws(text, i + 1) == text.len; }
        else { return false; }
    }
    return false;
}
