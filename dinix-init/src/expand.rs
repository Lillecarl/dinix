//! Environment variable substitution, the same subset dinit does.
//!
//! dinit substitutes variables in a service description when it loads it, so a
//! path written as `${DINIX_STATE_DIR:-/var/lib}/redis/main` resolves at
//! startup and one store path serves a container, an uncontained run and a
//! systemd unit alike. The spec this binary reads has to answer the same way,
//! or `dirs` would make a directory literally called `${DINIX_STATE_DIR...}`
//! while the service it exists for looks somewhere else.
//!
//! This is string expansion and nothing else. There is no command
//! substitution, no globbing and no way to run a program, which is the whole
//! reason this binary exists instead of a shell.
//!
//! The forms are dinit's, from `dinit-service(5)`:
//!
//! ```text
//! $NAME  ${NAME}  ${NAME:-word}  ${NAME-word}  ${NAME:+word}  ${NAME+word}
//! ```
//!
//! `:-` and `:+` treat an empty value as unset; `-` and `+` treat only a
//! missing variable as unset. `$$` is a literal `$`. An unset variable with no
//! `word` expands to nothing, as it does in dinit.

use std::fmt;

#[derive(Debug, PartialEq, Eq)]
pub struct ExpandError {
    pub message: String,
}

impl fmt::Display for ExpandError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

/// A name starts with a non-digit, non-punctuation character and continues
/// with those or `_`, which is dinit's rule.
fn is_name_start(c: char) -> bool {
    c.is_alphabetic() || c == '_'
}

fn is_name_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Expand `input`, reading variables through `lookup`.
///
/// `lookup` rather than the environment directly so that the tests below do
/// not depend on what is set around them.
pub fn expand(input: &str, lookup: &dyn Fn(&str) -> Option<String>) -> Result<String, ExpandError> {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();

    while let Some(c) = chars.next() {
        if c != '$' {
            out.push(c);
            continue;
        }

        match chars.peek() {
            // "$$" is a literal dollar.
            Some('$') => {
                chars.next();
                out.push('$');
            }
            Some('{') => {
                chars.next();
                let mut inner = String::new();
                let mut closed = false;
                for c in chars.by_ref() {
                    if c == '}' {
                        closed = true;
                        break;
                    }
                    inner.push(c);
                }
                if !closed {
                    return Err(ExpandError {
                        message: format!("unmatched '{{' in {input:?}"),
                    });
                }
                out.push_str(&expand_braced(&inner, lookup)?);
            }
            Some(&c) if is_name_start(c) => {
                let mut name = String::new();
                while let Some(&c) = chars.peek() {
                    if !is_name_char(c) {
                        break;
                    }
                    name.push(c);
                    chars.next();
                }
                out.push_str(&lookup(&name).unwrap_or_default());
            }
            // A dollar before anything else is a literal dollar, as in dinit.
            _ => out.push('$'),
        }
    }

    Ok(out)
}

fn expand_braced(
    inner: &str,
    lookup: &dyn Fn(&str) -> Option<String>,
) -> Result<String, ExpandError> {
    let bad = |message: String| ExpandError { message };

    // The operator is the first ':', '-' or '+' after the name.
    let split = inner.find([':', '-', '+']);
    let (name, operator, word) = match split {
        None => (inner, "", ""),
        Some(at) => {
            let (name, rest) = inner.split_at(at);
            let (operator, word) = if let Some(word) = rest.strip_prefix(":-") {
                (":-", word)
            } else if let Some(word) = rest.strip_prefix(":+") {
                (":+", word)
            } else if let Some(word) = rest.strip_prefix('-') {
                ("-", word)
            } else if let Some(word) = rest.strip_prefix('+') {
                ("+", word)
            } else {
                return Err(bad(format!("unknown substitution operator in {inner:?}")));
            };
            (name, operator, word)
        }
    };

    if name.is_empty() || !name.starts_with(is_name_start) || !name.chars().all(is_name_char) {
        return Err(bad(format!("{name:?} is not a variable name")));
    }

    let value = lookup(name);
    let set = value.is_some();
    let non_empty = value.as_deref().is_some_and(|value| !value.is_empty());

    Ok(match operator {
        "" => value.unwrap_or_default(),
        ":-" => {
            if non_empty {
                value.unwrap_or_default()
            } else {
                word.to_string()
            }
        }
        "-" => {
            if set {
                value.unwrap_or_default()
            } else {
                word.to_string()
            }
        }
        ":+" => {
            if non_empty {
                word.to_string()
            } else {
                String::new()
            }
        }
        _ => {
            if set {
                word.to_string()
            } else {
                String::new()
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + use<'a> {
        move |name: &str| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.to_string())
        }
    }

    fn expanded(input: &str, pairs: &[(&str, &str)]) -> String {
        expand(input, &env(pairs)).unwrap()
    }

    #[test]
    fn leaves_a_plain_path_alone() {
        assert_eq!(expanded("/var/lib/redis", &[]), "/var/lib/redis");
    }

    #[test]
    fn the_default_is_used_when_unset() {
        assert_eq!(
            expanded("${DINIX_STATE_DIR:-/var/lib}/redis", &[]),
            "/var/lib/redis"
        );
    }

    #[test]
    fn the_value_wins_when_set() {
        assert_eq!(
            expanded(
                "${DINIX_STATE_DIR:-/var/lib}/redis",
                &[("DINIX_STATE_DIR", "/srv/state")]
            ),
            "/srv/state/redis"
        );
    }

    #[test]
    fn colon_dash_treats_empty_as_unset() {
        assert_eq!(expanded("${X:-fallback}", &[("X", "")]), "fallback");
    }

    #[test]
    fn plain_dash_keeps_an_empty_value() {
        assert_eq!(expanded("${X-fallback}", &[("X", "")]), "");
    }

    #[test]
    fn plus_forms_replace_a_set_variable() {
        assert_eq!(expanded("${X:+yes}", &[("X", "v")]), "yes");
        assert_eq!(expanded("${X:+yes}", &[("X", "")]), "");
        assert_eq!(expanded("${X+yes}", &[("X", "")]), "yes");
        assert_eq!(expanded("${X+yes}", &[]), "");
    }

    #[test]
    fn bare_names_expand() {
        assert_eq!(expanded("$HOME/x", &[("HOME", "/root")]), "/root/x");
        assert_eq!(expanded("${HOME}x", &[("HOME", "/root")]), "/rootx");
    }

    #[test]
    fn an_unset_bare_name_expands_to_nothing() {
        assert_eq!(expanded("/a/$NOPE/b", &[]), "/a//b");
    }

    #[test]
    fn a_doubled_dollar_is_literal() {
        assert_eq!(expanded("/a/$$HOME", &[("HOME", "/root")]), "/a/$HOME");
    }

    #[test]
    fn a_dollar_before_punctuation_is_literal() {
        assert_eq!(expanded("/a/$/b", &[]), "/a/$/b");
    }

    #[test]
    fn rejects_an_unmatched_brace() {
        assert!(expand("${NOPE", &env(&[])).is_err());
    }

    #[test]
    fn rejects_a_name_that_is_not_one() {
        assert!(expand("${1X:-a}", &env(&[])).is_err());
    }
}
