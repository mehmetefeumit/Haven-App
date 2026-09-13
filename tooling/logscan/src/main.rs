//! `haven-logscan` — thin shell over [`haven_logscan::cli`].
//!
//! Everything testable lives in the library so the in-crate tests can drive the
//! real argument parsing and the real output paths; this file only wires stdio to
//! it and turns the verdict into an exit code.

use std::io::Write;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    let mut out = stdout.lock();
    let mut err = stderr.lock();
    let rc = haven_logscan::cli::run(&args, &mut out, &mut err);
    let _ = out.flush();
    let _ = err.flush();
    std::process::exit(rc);
}
