//! 写学习数据用的小工具。

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// 整份写进 `path`，不会留下写了一半的文件：先写同目录的临时文件、刷到盘上，再改名盖过去。
///
/// 临时文件名带进程号：升级时新旧两个输入法进程、或者自检和输入法同时存，不会写进同一个临时文件。
/// 写失败时 `path` 原来的内容不动，临时文件删掉。成功以后顺手删掉以前被杀的进程留下的旧临时文件。
pub fn write_atomic(path: &Path, contents: &[u8]) -> Result<()> {
    write(path, contents, true)
}

/// 和 [`write_atomic`] 一样不会留下写了一半的文件，但不等刷到盘上：丢了也无所谓的小文件
/// （最近用过的 emoji）用，免得在按键的线程上等磁盘。
pub fn write_replace(path: &Path, contents: &[u8]) -> Result<()> {
    write(path, contents, false)
}

fn write(path: &Path, contents: &[u8], sync: bool) -> Result<()> {
    let tmp = temp_path(path);
    let written = (|| -> std::io::Result<()> {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(contents)?;
        if sync {
            file.sync_all()?;
        }
        Ok(())
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(e).with_context(|| format!("写入 {}", tmp.display()));
    }
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e).with_context(|| format!("改名为 {}", path.display()));
    }
    remove_stale_temps(path);
    Ok(())
}

/// 临时文件放了这么久还在，就是写的进程在改名之前被杀了（注销、升级、内存不够），不会再有人用。
const STALE_TEMP: std::time::Duration = std::time::Duration::from_secs(3600);

/// 删掉同一个文件以前留下的临时文件（`.<名字>.<进程号>.tmp`，不是自己的、放了一小时以上的）。
/// 别的进程正在写的临时文件是新的，不会动；出错不管。
fn remove_stale_temps(path: &Path) {
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return;
    };
    let prefix = format!(".{}.", name.to_string_lossy());
    let mine = temp_path(path);
    let dir = if dir.as_os_str().is_empty() {
        Path::new(".")
    } else {
        dir
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let file = entry.file_name();
        let file = file.to_string_lossy();
        let Some(pid) = file
            .strip_prefix(&prefix)
            .and_then(|rest| rest.strip_suffix(".tmp"))
        else {
            continue;
        };
        if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) || entry.path() == mine {
            continue;
        }
        let old = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age > STALE_TEMP);
        if old {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

fn temp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    path.with_file_name(format!(".{name}.{}.tmp", std::process::id()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_whole_file_and_leaves_no_temp() {
        let dir = std::env::temp_dir().join(format!("wowtype-fsutil-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("user.tsv");
        std::fs::write(&path, "旧内容，比新的长很多很多很多\n").unwrap();
        write_atomic(&path, "新\n".as_bytes()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "新\n");
        let left: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".tmp"))
            .collect();
        assert!(left.is_empty(), "临时文件没删：{left:?}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn removes_stale_temps_but_not_fresh_ones() {
        let dir = std::env::temp_dir().join(format!("wowtype-fsutil-stale-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("user.tsv");
        // 两小时前被杀的进程留下的；另一个进程刚建的（正在写）；别的文件的临时文件
        let stale = dir.join(".user.tsv.11111.tmp");
        let fresh = dir.join(".user.tsv.22222.tmp");
        let other = dir.join(".history.tsv.33333.tmp");
        for f in [&stale, &fresh, &other] {
            std::fs::write(f, "x").unwrap();
        }
        let two_hours_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(7200);
        for f in [&stale, &other] {
            std::fs::File::options()
                .write(true)
                .open(f)
                .unwrap()
                .set_modified(two_hours_ago)
                .unwrap();
        }
        write_atomic(&path, b"new\n").unwrap();
        assert!(!stale.exists(), "放了很久的旧临时文件删掉");
        assert!(fresh.exists(), "别的进程正在写的不动");
        assert!(other.exists(), "别的文件的临时文件不动");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn write_replace_writes_whole_file() {
        let dir =
            std::env::temp_dir().join(format!("wowtype-fsutil-replace-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("emoji-recent.txt");
        std::fs::write(&path, "旧的很长很长的内容\n").unwrap();
        write_replace(&path, "😀\n".as_bytes()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "😀\n");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn failed_write_keeps_old_file() {
        // 目标所在目录不存在：临时文件建不出来，原文件（在别处）不受影响，报错
        let dir =
            std::env::temp_dir().join(format!("wowtype-fsutil-missing-{}", std::process::id()));
        let path = dir.join("nope").join("user.tsv");
        assert!(write_atomic(&path, b"x").is_err());
        assert!(!path.exists());
    }
}
