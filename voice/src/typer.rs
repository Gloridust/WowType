//! 边说边上屏：记录已打出的文本，按公共前缀退格后补打差异。
//!
//! 这样识别结果不断修正时，不会重复插入或依赖剪贴板。

#[derive(Debug, Default)]
pub struct Typer {
    typed: Vec<char>,
    done: bool,
}

/// 一次更新需要的动作
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Update {
    pub backspaces: usize,
    pub insert: String,
}

impl Update {
    pub fn is_empty(&self) -> bool {
        self.backspaces == 0 && self.insert.is_empty()
    }
}

impl Typer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn typed(&self) -> String {
        self.typed.iter().collect()
    }

    pub fn finish(&mut self) {
        self.done = true;
    }

    /// 把屏幕上的文本修正为 next，返回需要执行的退格/插入
    pub fn update(&mut self, next: &str) -> Update {
        if self.done {
            return Update::default();
        }
        let nxt: Vec<char> = next.chars().collect();
        let common = self
            .typed
            .iter()
            .zip(nxt.iter())
            .take_while(|(a, b)| a == b)
            .count();
        let update = Update {
            backspaces: self.typed.len() - common,
            insert: nxt[common..].iter().collect(),
        };
        self.typed = nxt;
        update
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_only() {
        let mut t = Typer::new();
        assert_eq!(
            t.update("你好"),
            Update {
                backspaces: 0,
                insert: "你好".into()
            }
        );
        assert_eq!(
            t.update("你好世界"),
            Update {
                backspaces: 0,
                insert: "世界".into()
            }
        );
    }

    #[test]
    fn revise_tail() {
        let mut t = Typer::new();
        t.update("你好世界");
        assert_eq!(
            t.update("你好"),
            Update {
                backspaces: 2,
                insert: String::new()
            }
        );
        assert_eq!(t.typed(), "你好");
    }

    #[test]
    fn replace_all() {
        let mut t = Typer::new();
        t.update("今天天气");
        let u = t.update("明天");
        assert_eq!(u.backspaces, 4);
        assert_eq!(u.insert, "明天");
    }

    #[test]
    fn finish_freezes() {
        let mut t = Typer::new();
        t.update("abc");
        t.finish();
        assert!(t.update("abcd").is_empty());
    }
}
