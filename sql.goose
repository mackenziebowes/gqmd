// sql: the few libsqlite3 calls gqmd needs, over the system library.
// A handle is a u64 the C library owns; text comes back by copy.
import ffi;
namespace sql;

extern "sqlite" {
    fn sqlite3_open_v2(path: const u8&, db: u64&, flags: i32, vfs: u64) -> i32;
    fn sqlite3_close(db: u64) -> i32;
    fn sqlite3_exec(db: u64, sql: const u8&, cb: u64, arg: u64, err: u64) -> i32;
    fn sqlite3_busy_timeout(db: u64, ms: i32) -> i32;
    fn sqlite3_errmsg(db: u64) -> u64;
    fn sqlite3_prepare_v2(db: u64, sql: const u8&, n: i32, stmt: u64&, tail: u64) -> i32;
    fn sqlite3_step(stmt: u64) -> i32;
    fn sqlite3_reset(stmt: u64) -> i32;
    fn sqlite3_finalize(stmt: u64) -> i32;
    fn sqlite3_bind_text(stmt: u64, i: i32, s: const u8&, n: i32, destructor: u64) -> i32;
    fn sqlite3_bind_int64(stmt: u64, i: i32, v: i64) -> i32;
    fn sqlite3_bind_null(stmt: u64, i: i32) -> i32;
    fn sqlite3_column_text(stmt: u64, i: i32) -> u64;
    fn sqlite3_column_bytes(stmt: u64, i: i32) -> i32;
    fn sqlite3_column_int64(stmt: u64, i: i32) -> i64;
    fn sqlite3_column_double(stmt: u64, i: i32) -> f64;
    fn sqlite3_column_type(stmt: u64, i: i32) -> i32;
    fn sqlite3_changes(db: u64) -> i32;
}

let READONLY: i32 = 1;
let READWRITE: i32 = 2;
let ROW: i32 = 100;
let DONE: i32 = 101;
let TRANSIENT: u64 = 18446744073709551615;   // SQLITE_TRANSIENT, (void*)-1: SQLite copies the text

// The handle of an open database, or 0 when it will not open.
fn open(path: u8[:], flags: i32) -> u64 {
    var nul: u8[>..] = [];
    nul.append(path);
    nul.push(0);
    var db: u64[1] = [0; 1];
    let rc = sqlite3_open_v2(nul[0], db[0], flags, 0);
    if rc != 0 {
        if db[0] != 0 { sqlite3_close(db[0]); }
        return 0;
    }
    // wait for a competing writer, as the TypeScript qmd does not need to: the caller keeps updates one at a time (one gqmd update per index)
    sqlite3_busy_timeout(db[0], 30000);
    return db[0];
}

fn close(db: u64) { sqlite3_close(db); }

fn message(db: u64) -> u8[>..] { ffi::cstr(sqlite3_errmsg(db)) }

// Run SQL that returns no rows. False on an error.
fn exec(db: u64, sql: u8[:]) -> bool {
    var nul: u8[>..] = [];
    nul.append(sql);
    nul.push(0);
    return sqlite3_exec(db, nul[0], 0, 0, 0) == 0;
}

// A prepared statement, or 0 on a SQL error.
fn prepare(db: u64, sql: u8[:]) -> u64 {
    var nul: u8[>..] = [];
    nul.append(sql);
    nul.push(0);
    var st: u64[1] = [0; 1];
    if sqlite3_prepare_v2(db, nul[0], -1, st[0], 0) != 0 { return 0; }
    return st[0];
}

fn finalize(st: u64) { sqlite3_finalize(st); }
fn reset(st: u64) { sqlite3_reset(st); }
fn step(st: u64) -> i32 { sqlite3_step(st) }
fn changes(db: u64) -> i64 { sqlite3_changes(db) as i64 }

// Parameters are numbered from 1, as SQLite numbers them.
fn bind_text(st: u64, i: i32, s: u8[:]) {
    if s.len == 0 {
        sqlite3_bind_text(st, i, "\0"[0], 0, TRANSIENT);
    } else {
        sqlite3_bind_text(st, i, s[0], s.len as i32, TRANSIENT);
    }
}
fn bind_int(st: u64, i: i32, v: i64) { sqlite3_bind_int64(st, i, v); }
fn bind_null(st: u64, i: i32) { sqlite3_bind_null(st, i); }

// Columns are numbered from 0.
fn is_null(st: u64, i: i32) -> bool { sqlite3_column_type(st, i) == 5 }
fn col_int(st: u64, i: i32) -> i64 { sqlite3_column_int64(st, i) }
fn col_flt(st: u64, i: i32) -> f64 { sqlite3_column_double(st, i) }
// The text of a column, appended to out. Exact length, so a NUL inside survives.
fn col_text(st: u64, i: i32, out: u8[>..]&) {
    let p = sqlite3_column_text(st, i);
    let n = sqlite3_column_bytes(st, i);
    if n > 0 { ffi::bytes(p, n as i64, out); }
}
