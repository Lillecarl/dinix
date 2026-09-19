//! Makes the directories a service tree needs before dinit starts it.
//!
//! There is deliberately no way to run a program from here. The whole point of
//! this binary over a shell is that an image containing it gains nothing that
//! can execute anything else. Adding an `exec` step would throw that away.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::ExitCode;

mod spec;

use spec::{Kind, Step};

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);
    let Some(spec_path) = args.next() else {
        eprintln!("dinix-init: usage: dinix-init <spec-file>");
        return ExitCode::FAILURE;
    };
    if args.next().is_some() {
        eprintln!("dinix-init: takes exactly one spec file");
        return ExitCode::FAILURE;
    }

    let spec_path = Path::new(&spec_path);
    let source = match fs::read_to_string(spec_path) {
        Ok(source) => source,
        Err(error) => {
            eprintln!("dinix-init: reading {}: {error}", spec_path.display());
            return ExitCode::FAILURE;
        }
    };

    let steps = match spec::parse(&source) {
        Ok(steps) => steps,
        Err(error) => {
            eprintln!("dinix-init: {}: {error}", spec_path.display());
            return ExitCode::FAILURE;
        }
    };

    for step in &steps {
        if let Err(error) = apply(step) {
            eprintln!("dinix-init: {error}");
            return ExitCode::FAILURE;
        }
    }

    ExitCode::SUCCESS
}

/// Whether every owner the spec names already holds, so a chown would
/// change nothing and is skipped rather than attempted.
fn owner_matches(
    current_uid: u32,
    current_gid: u32,
    want_uid: Option<u32>,
    want_gid: Option<u32>,
) -> bool {
    want_uid.map_or(true, |wanted| current_uid == wanted)
        && want_gid.map_or(true, |wanted| current_gid == wanted)
}

fn apply(step: &Step) -> Result<(), String> {    match step {
        Step::Dir {
            path,
            mode,
            uid,
            gid,
        } => {
            let shown = path.display();

            fs::create_dir_all(path).map_err(|error| format!("creating {shown}: {error}"))?;

            // create_dir_all is happy when the path is a symlink to a
            // directory, and both set_permissions and chown follow symlinks.
            // Together that lets anything able to plant a symlink here choose
            // what gets chowned instead. Refuse rather than follow.
            let found = fs::symlink_metadata(path)
                .map_err(|error| format!("checking {shown}: {error}"))?
                .file_type();
            if found.is_symlink() {
                return Err(format!(
                    "{shown} is a symlink, refusing to touch its target"
                ));
            }
            if !found.is_dir() {
                return Err(format!("{shown} exists and is not a directory"));
            }

            fs::set_permissions(path, fs::Permissions::from_mode(*mode))
                .map_err(|error| format!("setting mode on {shown}: {error}"))?;

            if uid.is_some() || gid.is_some() {
                let current = fs::metadata(path)
                    .map_err(|error| format!("checking owner on {shown}: {error}"))?;
                // A chown that would change nothing is skipped rather than
                // attempted. A non-root init cannot chown at all — not even
                // to the owner the path already has, which the kernel still
                // refuses — so attempting it would fail a step that is
                // already satisfied. Anything else is still an error below.
                if !owner_matches(current.uid(), current.gid(), *uid, *gid) {
                    std::os::unix::fs::chown(path, *uid, *gid).map_err(|error| {
                        format!("setting owner on {shown}: {error} (only root may do this)")
                    })?;
                }
            }

            Ok(())
        }

        Step::MustExist { path, kind } => {
            let shown = path.display();

            // Follows symlinks on purpose: the question is whether something
            // usable is there, not how it got there.
            let found = match fs::metadata(path) {
                Ok(found) => found,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    return Err(format!(
                        "{shown} must exist and does not. \
                         Nothing creates it, so a volume that should provide it \
                         is probably not mounted."
                    ))
                }
                Err(error) => return Err(format!("checking {shown}: {error}")),
            };

            let ok = match kind {
                Kind::Any => true,
                Kind::Dir => found.is_dir(),
                Kind::File => found.is_file(),
            };
            if !ok {
                return Err(format!("{shown} must be {}, and is not", kind.describe()));
            }

            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_owner_is_no_chown() {
        assert!(owner_matches(1000, 100, Some(1000), Some(100)));
    }

    #[test]
    fn unnamed_half_always_matches() {
        assert!(owner_matches(1000, 100, Some(1000), None));
        assert!(owner_matches(1000, 100, None, Some(100)));
        assert!(owner_matches(1000, 100, None, None));
    }

    #[test]
    fn differing_owner_needs_chown() {
        assert!(!owner_matches(1000, 100, Some(0), Some(100)));
        assert!(!owner_matches(1000, 100, Some(1000), Some(0)));
    }

    #[test]
    fn dir_step_with_own_owner_applies() {
        // Exercises the stat-and-skip path end to end. A directory just
        // made is owned by whoever runs this, so the spec below always
        // matches and the chown is skipped: whatever user runs this — the
        // Nix sandbox builds without privilege — only mkdir and chmod run.
        let dir = std::env::temp_dir().join(format!("dinix-init-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let me = fs::metadata(&dir).unwrap().uid();
        apply(&Step::Dir {
            path: dir.clone(),
            mode: 0o700,
            uid: Some(me),
            gid: None,
        })
        .unwrap();
        fs::remove_dir(&dir).unwrap();
    }
}
