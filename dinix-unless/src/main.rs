//! Run a program once: exec it only when a marker path is absent.
//!
//! ```text
//! dinix-unless <marker> <program> [argument ...]
//! ```
//!
//! This exists for one shape that nothing else in dinix answers. A service
//! that initialises its own data directory has to do it exactly once:
//! `initdb` exits 1 on a directory that is not empty, and so do MySQL's and
//! MongoDB's equivalents. "Do it if it has not been done" is a conditional,
//! and a conditional is what a shell is usually dragged in for — an
//! interpreter and a few hundred commands, in an image that otherwise has
//! neither.
//!
//! **This is a separate binary from `dinix-init` on purpose.** `dinix-init`
//! cannot run a program and must stay that way, because it is in every dinix
//! image. This one is in the closure of the services that ask for it and no
//! others.
//!
//! It is not a small shell. It reads no configuration, searches no `PATH`,
//! expands nothing, and interprets no argument: the program is `argv[2]` and
//! its arguments are the rest, passed through untouched. dinit has already
//! substituted variables in the command line by the time this runs, so the
//! marker and the program arrive as ordinary paths. Anything able to choose
//! what this executes could have written the service description instead,
//! which is strictly more.
//!
//! The marker is tested with `symlink_metadata`, so a symlink counts as
//! present whatever it points at: the question is whether initialisation has
//! happened, and a planted symlink is not a way to make it happen twice.

use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, ExitCode};

/// Whether the marker says the work has already been done.
///
/// `symlink_metadata`, so a symlink counts as present whatever it points at:
/// the question is whether initialisation happened, and a planted symlink is
/// not a way to make it happen twice.
fn already_done(marker: &Path) -> bool {
    marker.symlink_metadata().is_ok()
}

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);

    let Some(marker) = args.next() else {
        eprintln!("dinix-unless: usage: dinix-unless <marker> <program> [argument ...]");
        return ExitCode::FAILURE;
    };
    let Some(program) = args.next() else {
        eprintln!("dinix-unless: no program to run; usage: dinix-unless <marker> <program> [argument ...]");
        return ExitCode::FAILURE;
    };

    if already_done(Path::new(&marker)) {
        // Already done. Said out loud, because a service that silently does
        // nothing is indistinguishable from one that silently failed.
        eprintln!(
            "dinix-unless: {} exists, so {} is not run",
            Path::new(&marker).display(),
            Path::new(&program).display()
        );
        return ExitCode::SUCCESS;
    }

    // Absolute only. A relative program would be looked up against a working
    // directory this does not control, and there is no PATH search here at
    // all -- a dinix command names a store path.
    if !Path::new(&program).is_absolute() {
        eprintln!(
            "dinix-unless: {} is not an absolute path",
            Path::new(&program).display()
        );
        return ExitCode::FAILURE;
    }

    // exec, not spawn: the program replaces this process, so it keeps the pid
    // dinit is supervising and dinit's signals reach it rather than a wrapper.
    let error = Command::new(&program).args(args).exec();

    eprintln!(
        "dinix-unless: running {}: {error}",
        Path::new(&program).display()
    );
    ExitCode::FAILURE
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("dinix-unless-{}-{name}", std::process::id()))
    }

    #[test]
    fn an_absent_marker_means_run() {
        assert!(!already_done(&scratch("absent")));
    }

    #[test]
    fn a_present_marker_means_skip() {
        let path = scratch("present");
        std::fs::write(&path, b"").unwrap();
        assert!(already_done(&path));
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn a_directory_counts_as_a_marker() {
        // initdb's marker is a file, but nothing here insists on one: a
        // service may just as well point at the data directory it fills.
        let path = scratch("dir");
        std::fs::create_dir_all(&path).unwrap();
        assert!(already_done(&path));
        std::fs::remove_dir(&path).unwrap();
    }

    #[test]
    fn a_dangling_symlink_still_counts() {
        // symlink_metadata, not metadata: something is there. Following it
        // would let a broken link re-run an initialisation that already
        // happened, which is the one thing this must not do.
        let path = scratch("dangling");
        std::os::unix::fs::symlink("/nowhere-at-all", &path).unwrap();
        assert!(already_done(&path));
        std::fs::remove_file(&path).unwrap();
    }
}
