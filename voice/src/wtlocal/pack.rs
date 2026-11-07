//! 官方离线语音包（微信输入法资源 CDN）：外层签名 zip 内嵌 ime_asr_decoder_model.zip。
//!
//! 解包用系统 `unzip`，避免为这一个用途引入 zip 依赖；缺失时给出明确提示。

use super::Model;
use anyhow::{bail, Context, Result};
use std::fs;
use std::path::Path;
use std::process::Command;

pub const URL: &str = "https://download.z.weixin.qq.com/publish_words/v1/ime_asr_decoder_model/20260710220526250_ime_asr_decoder_model.apk";
pub const SIZE: u64 = 102_920_639;
pub const MD5: &str = "28386481eb94ff73b28ee3949c0cf690";
const INNER: &str = "ime_asr_decoder_model.zip";
const DICT: &str = "dict.decoder.utf8.txt";

fn unzip(args: &[&str]) -> Result<()> {
    let out = Command::new("unzip")
        .args(args)
        .output()
        .context("需要系统安装 unzip（sudo apt install unzip）")?;
    if !out.status.success() {
        bail!(
            "unzip 失败: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// 解出模型与词表到 `dir`：先写临时目录并试加载，成功后整体改名。
pub fn unpack(pack: &Path, dir: &Path) -> Result<()> {
    let tmp = dir.with_extension("tmp");
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp)?;
    let pack = pack.to_str().context("路径含非 UTF-8 字符")?;
    let tmp_s = tmp.to_str().context("路径含非 UTF-8 字符")?;

    // 外层是签名 zip（扩展名 .apk），只取内嵌的模型包
    unzip(&["-o", "-q", pack, INNER, "-d", tmp_s])?;
    let inner = tmp.join(INNER);
    if !inner.is_file() {
        bail!("语音包里没有 {INNER}");
    }
    // 内层扁平解出来，只保留模型和词表
    unzip(&["-o", "-q", "-j", inner.to_str().unwrap(), "-d", tmp_s])?;
    let _ = fs::remove_file(&inner);

    // 清掉其它文件，只留模型与词表
    for entry in fs::read_dir(&tmp)?.flatten() {
        let p = entry.path();
        let keep = p
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with(".xnet") || n == DICT);
        if !keep {
            let _ = fs::remove_file(&p);
        }
    }
    if !tmp.join(DICT).is_file() || !has_xnet(&tmp) {
        bail!("语音包内容不完整");
    }
    // 先验证能加载，再替换正式目录
    drop(Model::load(&tmp)?);
    let _ = fs::remove_dir_all(dir);
    fs::rename(&tmp, dir)?;
    Ok(())
}

pub fn has_xnet(dir: &Path) -> bool {
    fs::read_dir(dir)
        .map(|it| {
            it.flatten()
                .any(|e| e.path().extension().is_some_and(|x| x == "xnet"))
        })
        .unwrap_or(false)
}
