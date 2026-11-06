//! 上屏后端：把识别文本送进当前焦点输入框。

use std::io::Write;

pub trait TextSink: Send {
    fn insert(&mut self, text: &str);
    fn backspace(&mut self, count: usize);
    /// 应用边说边上屏的增量
    fn apply(&mut self, update: crate::typer::Update) {
        if update.backspaces > 0 {
            self.backspace(update.backspaces);
        }
        if !update.insert.is_empty() {
            self.insert(&update.insert);
        }
    }
}

/// 打印到 stdout，用于测试和调试
#[derive(Default)]
pub struct StdoutSink;

impl TextSink for StdoutSink {
    fn insert(&mut self, text: &str) {
        print!("{}", text);
        let _ = std::io::stdout().flush();
    }
    fn backspace(&mut self, count: usize) {
        for _ in 0..count {
            print!("<BS>");
        }
        let _ = std::io::stdout().flush();
    }
}

/// 通过命令行工具注入按键的通用后端。
///
/// Linux 上：
/// - X11 用 xdotool / xvkbd
/// - Wayland 用 wtype（wlroots 系）或 ydotool（uinput，需要守护进程）
#[derive(Debug)]
pub struct CommandSink {
    pub type_cmd: Vec<String>,
    pub backspace_cmd: Vec<String>,
}

impl CommandSink {
    /// wtype：Wayland (wlroots)
    pub fn wtype() -> Self {
        Self {
            type_cmd: vec!["wtype".into()],
            backspace_cmd: vec!["wtype".into(), "-k".into(), "BackSpace".into()],
        }
    }

    /// ydotool：需要 ydotool 守护进程 + uinput 权限
    pub fn ydotool() -> Self {
        Self {
            type_cmd: vec!["ydotool".into(), "type".into()],
            backspace_cmd: vec!["ydotool".into(), "key".into(), "14:1".into(), "14:0".into()],
        }
    }

    fn run(mut cmd: Vec<String>, extra: &str) {
        if let Some((bin, args)) = cmd.split_first_mut() {
            let mut command = std::process::Command::new(bin);
            command.args(args.iter());
            // 空串不能作为参数传进去，否则 ydotool key 14:1 14:0 "" 会报错
            if !extra.is_empty() {
                command.arg(extra);
            }
            let _ = command.status();
        }
    }
}

impl TextSink for CommandSink {
    fn insert(&mut self, text: &str) {
        Self::run(self.type_cmd.clone(), text);
    }
    fn backspace(&mut self, count: usize) {
        for _ in 0..count {
            Self::run(self.backspace_cmd.clone(), "");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_sink_feeds_copy_command() {
        let path = std::env::temp_dir().join(format!("wowtype_clip_{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let mut sink = ClipboardSink {
            copy_cmd: vec![
                "sh".into(),
                "-c".into(),
                format!("cat > {}", path.display()),
            ],
            paste_cmd: vec!["true".into()],
            backspace_cmd: vec!["true".into()],
        };
        sink.insert("你好");
        let written = std::fs::read_to_string(&path).expect("应当写入文件");
        assert_eq!(written, "你好");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn stdout_sink_applies_update() {
        let mut s = StdoutSink;
        s.apply(crate::typer::Update {
            backspaces: 1,
            insert: "x".into(),
        });
    }
}

/// 剪贴板后端：写入剪贴板后模拟粘贴。
///
/// 中文必须走这条：ydotool 的 type 是通过键码模拟按键的，没有对应的
/// keysym 就发不出汉字；wtype 虽然支持 Unicode，但在非 wlroots 的
/// Wayland 合成器上不能用。剪贴板 + Ctrl+V 是最通用的方案。
#[derive(Debug)]
pub struct ClipboardSink {
    pub copy_cmd: Vec<String>,
    pub paste_cmd: Vec<String>,
    pub backspace_cmd: Vec<String>,
}

impl ClipboardSink {
    /// Wayland：wl-copy + wtype 粘贴
    pub fn wl() -> Self {
        Self {
            copy_cmd: vec!["wl-copy".into()],
            paste_cmd: vec![
                "wtype".into(),
                "-M".into(),
                "ctrl".into(),
                "-k".into(),
                "v".into(),
                "-m".into(),
                "ctrl".into(),
            ],
            backspace_cmd: vec!["wtype".into(), "-k".into(), "BackSpace".into()],
        }
    }

    /// X11：xclip + xdotool 粘贴
    pub fn x11() -> Self {
        Self {
            copy_cmd: vec!["xclip".into(), "-selection".into(), "clipboard".into()],
            paste_cmd: vec!["xdotool".into(), "key".into(), "ctrl+v".into()],
            backspace_cmd: vec!["xdotool".into(), "key".into(), "BackSpace".into()],
        }
    }

    fn run(cmd: &[String]) {
        if let Some((bin, args)) = cmd.split_first() {
            let _ = std::process::Command::new(bin).args(args).status();
        }
    }
}

impl TextSink for ClipboardSink {
    fn insert(&mut self, text: &str) {
        if let Some((bin, args)) = self.copy_cmd.split_first() {
            let child = std::process::Command::new(bin)
                .args(args)
                .stdin(std::process::Stdio::piped())
                .spawn();
            if let Ok(mut child) = child {
                if let Some(stdin) = child.stdin.as_mut() {
                    let _ = std::io::Write::write_all(stdin, text.as_bytes());
                }
                let _ = child.wait();
            }
        }
        Self::run(&self.paste_cmd);
    }

    fn backspace(&mut self, count: usize) {
        for _ in 0..count {
            Self::run(&self.backspace_cmd);
        }
    }
}
