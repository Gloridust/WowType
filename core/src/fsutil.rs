//! 写学习数据用的小工具。

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// 整份写进 `path`，不会留下写了一半的文件：先写同目录的临时文件、刷到盘上，再改名盖过去。
///
/// 临时文件名带进程号：升级时新旧两个输入法进程、或者自检和输入法同时存，不会写进同一个临时文件。
/// 写失败时 `path` 原来的内容不动，临时文件删掉。
pub fn write_atomic(path: &Path, contents: &[u8]) -> Result<()> {
    let tmp = temp_path(path);
    let written = (|| -> std::io::Result<()> {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(contents)?;
        file.sync_all()
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(e).with_context(|| format!("写入 {}", tmp.display()));
    }
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e).with_context(|| format!("改名为 {}", path.display()));
    }
    Ok(())
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
    fn failed_write_keeps_old_file() {
        // 目标所在目录不存在：临时文件建不出来，原文件（在别处）不受影响，报错
        let dir = std::env::temp_dir().join(format!("wowtype-fsutil-missing-{}", std::process::id()));
        let path = dir.join("nope").join("user.tsv");
        assert!(write_atomic(&path, b"x").is_err());
        assert!(!path.exists());
    }
}
