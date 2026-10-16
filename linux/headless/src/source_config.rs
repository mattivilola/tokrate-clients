//! Explicit, bounded profile configuration. Never discovers other homes or running processes.
use crate::config::Result;
use std::{
    fs, io,
    path::{Component, Path, PathBuf},
};

pub(crate) fn codex_roots(default: &Path, extra: &[PathBuf]) -> Result<Vec<PathBuf>> {
    if extra.len() > 3 {
        return Err("At most three additional Codex session roots are supported".into());
    }
    let mut roots: Vec<PathBuf> = Vec::with_capacity(extra.len() + 1);
    for root in std::iter::once(default).chain(extra.iter().map(PathBuf::as_path)) {
        if !root.is_absolute()
            || root
                .components()
                .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        {
            return Err("Codex session roots must be absolute normalized directory paths".into());
        }
        let normalized = normalized_directory(root)?;
        if roots
            .iter()
            .any(|previous| previous.starts_with(&normalized) || normalized.starts_with(previous))
        {
            return Err("Codex session roots must not duplicate or overlap another profile".into());
        }
        roots.push(normalized);
    }
    Ok(roots)
}

fn normalized_directory(root: &Path) -> Result<PathBuf> {
    let mut ancestor = root;
    let mut suffix = Vec::new();
    loop {
        match fs::canonicalize(ancestor) {
            Ok(mut path) => {
                if !path.is_dir() {
                    return Err("A configured Codex session root is not a directory".into());
                }
                for part in suffix.into_iter().rev() {
                    path.push(part);
                }
                return Ok(path);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                suffix.push(
                    ancestor
                        .file_name()
                        .ok_or("Invalid Codex session root")?
                        .to_os_string(),
                );
                ancestor = ancestor.parent().ok_or("Invalid Codex session root")?;
            }
            Err(_) => return Err("A configured Codex session root is unreadable".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profile_roots_are_explicit_bounded_and_reject_aliases_or_overlap() {
        let dir = tempfile::tempdir().unwrap();
        let default = dir.path().join("default/sessions");
        let pm = dir.path().join("pm/sessions");
        fs::create_dir_all(&default).unwrap();
        fs::create_dir_all(&pm).unwrap();
        assert_eq!(
            codex_roots(&default, std::slice::from_ref(&pm)).unwrap(),
            vec![default.canonicalize().unwrap(), pm.canonicalize().unwrap()]
        );
        assert!(codex_roots(&default, std::slice::from_ref(&default)).is_err());
        assert!(codex_roots(&default, &[default.join("nested")]).is_err());
        assert!(codex_roots(&default, &[dir.path().to_path_buf()]).is_err());
        assert!(codex_roots(&default, &[PathBuf::from("relative")]).is_err());
        assert!(codex_roots(&default, &[pm.clone(), pm.clone(), pm.clone(), pm.clone()]).is_err());
        let alias = dir.path().join("alias");
        std::os::unix::fs::symlink(&default, &alias).unwrap();
        assert!(codex_roots(&default, &[alias]).is_err());
        let late = dir.path().join("later/sessions");
        assert_eq!(
            codex_roots(&default, std::slice::from_ref(&late))
                .unwrap()
                .last(),
            Some(&dir.path().canonicalize().unwrap().join("later/sessions"))
        );
    }
}
