//! `haven-wire-planes` — oracle C8: every relay plane received only its own
//! traffic, judged over a wire journal. A thin shell over
//! [`haven_local_relay::planes::cli::run`], which the crate's fixture suite
//! calls in-process; see that module for the CLI and the exit codes.

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rc =
        haven_local_relay::planes::cli::run(&args, &mut std::io::stdout(), &mut std::io::stderr());
    ExitCode::from(u8::try_from(rc).unwrap_or(u8::MAX))
}
