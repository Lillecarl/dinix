use std::fmt;
use std::path::PathBuf;

/// One thing to make before the services start.
#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    Dir {
        path: PathBuf,
        mode: u32,
        uid: Option<u32>,
        gid: Option<u32>,
    },
}

#[derive(Debug)]
pub struct ParseError {
    pub line_number: usize,
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line_number, self.message)
    }
}

/// Parse a spec.
///
/// The format is one step per line, tab separated, because Nix writes it and
/// nothing else does. A tab separator keeps spaces in paths working without
/// quoting rules. `#` starts a comment and blank lines are skipped.
///
/// ```text
/// dir	/run/sshd	0755	0	0
/// dir	/var/log	0755	-	-
/// ```
///
/// A `-` for uid or gid leaves that owner alone.
pub fn parse(input: &str) -> Result<Vec<Step>, ParseError> {
    let mut steps = Vec::new();

    for (index, raw) in input.lines().enumerate() {
        let line_number = index + 1;
        let line = raw.trim_end_matches(['\r']);
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let fields: Vec<&str> = line.split('\t').collect();
        let fail = |message: String| ParseError {
            line_number,
            message,
        };

        match fields[0] {
            "dir" => {
                if fields.len() != 5 {
                    return Err(fail(format!(
                        "dir takes 4 fields (path, mode, uid, gid), got {}",
                        fields.len() - 1
                    )));
                }
                if fields[1].is_empty() {
                    return Err(fail("empty path".to_string()));
                }
                steps.push(Step::Dir {
                    path: PathBuf::from(fields[1]),
                    mode: u32::from_str_radix(fields[2], 8)
                        .map_err(|_| fail(format!("mode {:?} is not octal", fields[2])))?,
                    uid: parse_id(fields[3]).map_err(fail)?,
                    gid: parse_id(fields[4]).map_err(fail)?,
                });
            }
            other => return Err(fail(format!("unknown step {other:?}"))),
        }
    }

    Ok(steps)
}

fn parse_id(field: &str) -> Result<Option<u32>, String> {
    if field == "-" {
        return Ok(None);
    }
    field
        .parse()
        .map(Some)
        .map_err(|_| format!("{field:?} is not a number or \"-\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_dir() {
        let steps = parse("dir\t/run/sshd\t0755\t0\t0").unwrap();
        assert_eq!(
            steps,
            vec![Step::Dir {
                path: PathBuf::from("/run/sshd"),
                mode: 0o755,
                uid: Some(0),
                gid: Some(0),
            }]
        );
    }

    #[test]
    fn keeps_owner_when_dashed() {
        let steps = parse("dir\t/var/log\t0700\t-\t-").unwrap();
        assert!(matches!(
            steps[0],
            Step::Dir {
                uid: None,
                gid: None,
                ..
            }
        ));
    }

    #[test]
    fn mode_is_octal_not_decimal() {
        let Step::Dir { mode, .. } = parse("dir\t/x\t0644\t-\t-").unwrap().remove(0);
        assert_eq!(mode, 0o644);
    }

    #[test]
    fn allows_spaces_in_paths() {
        let Step::Dir { path, .. } = parse("dir\t/var/a b\t0755\t-\t-").unwrap().remove(0);
        assert_eq!(path, PathBuf::from("/var/a b"));
    }

    #[test]
    fn skips_blanks_and_comments() {
        assert!(parse("# a comment\n\n").unwrap().is_empty());
    }

    #[test]
    fn rejects_unknown_steps() {
        assert!(parse("exec\t/bin/sh").is_err());
    }

    #[test]
    fn rejects_a_short_line() {
        assert!(parse("dir\t/run\t0755").is_err());
    }

    #[test]
    fn reports_the_line_number() {
        let error = parse("dir\t/a\t0755\t-\t-\nnonsense").unwrap_err();
        assert_eq!(error.line_number, 2);
    }
}
