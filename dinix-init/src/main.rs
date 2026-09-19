//! Makes the directories a service tree needs before dinit starts it.
//!
//! There is deliberately no way to run a program from here. The whole point of
//! this binary over a shell is that an image containing it gains nothing that
//! can execute anything else. Adding an `exec` step would throw that away.

use std::fs;
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

fn apply(step: &Step) -> Result<(), String> {
    match step {
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
                std::os::unix::fs::chown(path, *uid, *gid).map_err(|error| {
                    format!("setting owner on {shown}: {error} (only root may do this)")
                })?;
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
