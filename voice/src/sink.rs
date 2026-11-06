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
            let _ = std::process::Command::new(bin)
                .args(args.iter())
                .arg(extra)
                .status();
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
    fn stdout_sink_applies_update() {
        let mut s = StdoutSink;
        s.apply(crate::typer::Update {
            backspaces: 1,
            insert: "x".into(),
        });
    }
}
