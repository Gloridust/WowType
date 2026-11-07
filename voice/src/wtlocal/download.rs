//! 离线语音包的下载与缓存。
//!
//! 模型是腾讯的资源包，不随仓库分发：首次使用时从官方 CDN 下载并校验。
//! 这一步和用户自己安装微信输入法获取资源是同一性质。

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

use super::pack;

/// 默认目录：`$XDG_DATA_HOME/wowtype/wtlocal`，没有则 `~/.local/share/wowtype/wtlocal`。
pub fn default_dir() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("wowtype/wtlocal")
}

/// 模型与词表是否就位。
pub fn is_ready(dir: &Path) -> bool {
    pack::has_xnet(dir) && dir.join("dict.decoder.utf8.txt").is_file()
}

/// 确保模型可用：已存在直接返回，否则下载 + 校验 + 解包。
pub fn ensure(dir: &Path) -> Result<()> {
    if is_ready(dir) {
        return Ok(());
    }
    std::fs::create_dir_all(dir.parent().unwrap_or(dir))?;
    let pack_file = dir.with_extension("apk");
    if !pack_file.is_file() {
        download(&pack_file)?;
    }
    verify(&pack_file)?;
    pack::unpack(&pack_file, dir)?;
    let _ = std::fs::remove_file(&pack_file);
    Ok(())
}

fn download(dest: &Path) -> Result<()> {
    let part = dest.with_extension("part");
    let status = Command::new("curl")
        .args(["-L", "--fail", "--retry", "2", "-o"])
        .arg(&part)
        .arg(pack::URL)
        .status()
        .context("需要系统安装 curl")?;
    if !status.success() {
        let _ = std::fs::remove_file(&part);
        bail!("下载离线语音包失败（约 100MB）");
    }
    std::fs::rename(&part, dest)?;
    Ok(())
}

fn verify(path: &Path) -> Result<()> {
    let size = std::fs::metadata(path)?.len();
    if size != pack::SIZE {
        bail!("语音包大小不对：{size}，期望 {}", pack::SIZE);
    }
    let digest = md5(path)?;
    if !digest.eq_ignore_ascii_case(pack::MD5) {
        bail!("语音包校验失败：{digest}");
    }
    Ok(())
}

/// 优先 `md5sum`（Linux），退回 `md5 -q`（macOS）。
fn md5(path: &Path) -> Result<String> {
    for (cmd, args) in [("md5sum", &[][..]), ("md5", &["-q"][..])] {
        if let Ok(out) = Command::new(cmd).args(args).arg(path).output() {
            if out.status.success() {
                let text = String::from_utf8_lossy(&out.stdout);
                if let Some(first) = text.split_whitespace().next() {
                    if first.len() == 32 {
                        return Ok(first.to_string());
                    }
                }
            }
        }
    }
    bail!("找不到 md5 工具（md5sum 或 md5）")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_dir_ends_with_wtlocal() {
        assert!(default_dir().ends_with("wowtype/wtlocal"));
    }

    #[test]
    fn empty_dir_is_not_ready() {
        let dir = std::env::temp_dir().join(format!("wtlocal_ready_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!is_ready(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
