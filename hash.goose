// hash: sha256 of a document's text, as lowercase hex, the way qmd's hashContent writes it.
namespace hash;

extern "crypto" {
    fn SHA256(data: const u8&, n: u64, md: u8&) -> u64;
}

// The 64 hex digits of the sha256 of s, appended to out. s must not be empty.
fn sha256_hex(s: u8[:], out: u8[>..]&) {
    var md: u8[32] = [0; 32];
    SHA256(s[0], s.len as u64, md[0]);
    for i in 32 {
        let b: i64 = md[i];
        out.push(hex_digit(b >> 4));
        out.push(hex_digit(b & 15));
    }
}

fn hex_digit(v: i64) -> u8 {
    if v < 10 { return ('0' as i64 + v) as! u8; }
    return ('a' as i64 + v - 10) as! u8;
}
