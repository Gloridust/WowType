//! 音节图：把输入串切成所有合法音节序列（DAG）。
//!
//! 每条边消耗一个音节（全拼）或一个首字母（简拼）。隔音符产生的强制边界
//! 会禁止跨过该位置的边；儿化边会消耗掉尾部的 r，并把音节标记为儿化。

use crate::syllable::{
    is_jianpin_letter, parse, ParsedInput, Syllable, SyllableQuery, MAX_SYLLABLE_LEN,
};

/// 建图模式。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphMode {
    /// 只允许完整音节。
    Full,
    /// 只允许每个音节取首字母。
    Jianpin,
    /// 同时允许两种边（会产生较多路径，默认不用于 Engine）。
    Mixed,
}

/// 建图选项。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GraphOptions {
    pub mode: GraphMode,
    pub allow_erhua: bool,
}

impl Default for GraphOptions {
    fn default() -> Self {
        Self {
            mode: GraphMode::Full,
            allow_erhua: true,
        }
    }
}

/// 一条边。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Edge {
    pub start: usize,
    pub end: usize,
    pub kind: EdgeKind,
}

/// 边的类型。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EdgeKind {
    Full { syllable: Syllable, erhua: bool },
    Jianpin { letter: u8 },
}

impl Edge {
    pub fn query(&self) -> SyllableQuery {
        match self.kind {
            EdgeKind::Full { syllable, erhua } => SyllableQuery::Full {
                id: syllable.id,
                erhua,
            },
            EdgeKind::Jianpin { letter } => SyllableQuery::Jianpin { letter },
        }
    }

    pub fn is_jianpin(&self) -> bool {
        matches!(self.kind, EdgeKind::Jianpin { .. })
    }

    /// 供日志/未知词兜底使用的文本。
    pub fn display(&self) -> String {
        self.query().display()
    }

    pub fn syllable_count(&self) -> usize {
        1
    }
}

/// 音节图。
#[derive(Clone, Debug)]
pub struct SyllableGraph {
    input: ParsedInput,
    edges: Vec<Vec<Edge>>,
    mode: GraphMode,
}

impl SyllableGraph {
    /// 从输入串直接建图。
    pub fn from_str(
        input: &str,
        options: GraphOptions,
    ) -> Result<Self, crate::syllable::ParseError> {
        let parsed = parse(input)?;
        Ok(Self::build(&parsed, options))
    }

    /// 用已解析的输入建图。
    pub fn build(input: &ParsedInput, options: GraphOptions) -> Self {
        let n = input.len();
        let mut edges = vec![Vec::new(); n + 1];

        if matches!(options.mode, GraphMode::Full | GraphMode::Mixed) {
            build_full_edges(input, options.allow_erhua, &mut edges);
        }
        if matches!(options.mode, GraphMode::Jianpin | GraphMode::Mixed) {
            build_jianpin_edges(input, &mut edges);
        }

        Self {
            input: input.clone(),
            edges,
            mode: options.mode,
        }
    }

    /// 输入长度（节点数 = len + 1）。
    pub fn len(&self) -> usize {
        self.input.len()
    }

    pub fn is_empty(&self) -> bool {
        self.input.is_empty()
    }

    pub fn mode(&self) -> GraphMode {
        self.mode
    }

    pub fn input(&self) -> &ParsedInput {
        &self.input
    }

    pub fn edges_from(&self, pos: usize) -> &[Edge] {
        self.edges.get(pos).map(Vec::as_slice).unwrap_or(&[])
    }

    /// 是否存在从 0 到 n 的完整路径。
    pub fn has_complete_path(&self) -> bool {
        let n = self.input.len();
        if n == 0 {
            return true;
        }
        let mut reachable = vec![false; n + 1];
        reachable[n] = true;
        for pos in (0..n).rev() {
            reachable[pos] = self.edges[pos].iter().any(|e| reachable[e.end]);
        }
        reachable[0]
    }

    /// 枚举全部完整切分（最多 limit 条，避免歧义输入爆炸）。
    pub fn segmentations(&self, limit: usize) -> Vec<Vec<Edge>> {
        let mut out = Vec::new();
        if limit == 0 || !self.has_complete_path() {
            return out;
        }
        let mut path = Vec::new();
        self.dfs(0, &mut path, &mut out, limit);
        out
    }

    fn dfs(&self, pos: usize, path: &mut Vec<Edge>, out: &mut Vec<Vec<Edge>>, limit: usize) {
        if out.len() >= limit {
            return;
        }
        if pos == self.input.len() {
            out.push(path.clone());
            return;
        }
        for edge in self.edges_from(pos) {
            path.push(*edge);
            self.dfs(edge.end, path, out, limit);
            path.pop();
            if out.len() >= limit {
                return;
            }
        }
    }
}

fn add_edge(edges: &mut [Vec<Edge>], edge: Edge) {
    let bucket = &mut edges[edge.start];
    if !bucket
        .iter()
        .any(|e| e.end == edge.end && e.kind == edge.kind)
    {
        bucket.push(edge);
    }
}

fn build_full_edges(input: &ParsedInput, allow_erhua: bool, edges: &mut [Vec<Edge>]) {
    let n = input.len();
    for start in 0..n {
        let max_end = (start + MAX_SYLLABLE_LEN).min(n);
        for end in (start + 1)..=max_end {
            if input.forced_between(start, end) {
                continue;
            }
            // parse 保证是 ASCII，这里可以安全地做字节切片。
            let text = std::str::from_utf8(&input.letters[start..end]).expect("ASCII 输入");
            if let Some(syllable) = Syllable::from_text(text) {
                add_edge(
                    edges,
                    Edge {
                        start,
                        end,
                        kind: EdgeKind::Full {
                            syllable,
                            erhua: false,
                        },
                    },
                );
                if input.has_erhua(end) {
                    add_edge(
                        edges,
                        Edge {
                            start,
                            end,
                            kind: EdgeKind::Full {
                                syllable,
                                erhua: true,
                            },
                        },
                    );
                }
            }

            // 尾部 r 儿化：huar -> hua + 儿化。er 本身是独立音节，不当作 e 的儿化。
            if allow_erhua && text.len() > 1 && text.ends_with('r') && text != "er" {
                let stem = &text[..text.len() - 1];
                if let Some(syllable) = Syllable::from_text(stem) {
                    add_edge(
                        edges,
                        Edge {
                            start,
                            end,
                            kind: EdgeKind::Full {
                                syllable,
                                erhua: true,
                            },
                        },
                    );
                }
            }
        }
    }
}

fn build_jianpin_edges(input: &ParsedInput, edges: &mut [Vec<Edge>]) {
    for (pos, &letter) in input.letters.iter().enumerate() {
        if is_jianpin_letter(letter) {
            add_edge(
                edges,
                Edge {
                    start: pos,
                    end: pos + 1,
                    kind: EdgeKind::Jianpin { letter },
                },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn graph(text: &str, mode: GraphMode) -> SyllableGraph {
        let parsed = parse(text).unwrap();
        SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode,
                allow_erhua: true,
            },
        )
    }

    fn texts(path: &[Edge]) -> Vec<String> {
        path.iter().map(Edge::display).collect()
    }

    #[test]
    fn xian_has_two_segmentations() {
        let g = graph("xian", GraphMode::Full);
        let segs = g.segmentations(16);
        assert_eq!(
            segs.len(),
            2,
            "xian 应有 xian 与 xi+an 两种切分: {:?}",
            segs
        );
        assert!(segs.iter().any(|p| texts(p) == vec!["xian"]));
        assert!(segs.iter().any(|p| texts(p) == vec!["xi", "an"]));
    }

    #[test]
    fn apostrophe_forces_xi_an() {
        let g = graph("xi'an", GraphMode::Full);
        let segs = g.segmentations(16);
        assert_eq!(segs.len(), 1);
        assert_eq!(texts(&segs[0]), vec!["xi", "an"]);
    }

    #[test]
    fn jianpin_zg() {
        let g = graph("zg", GraphMode::Jianpin);
        assert!(g.has_complete_path());
        let segs = g.segmentations(8);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].len(), 2);
        assert_eq!(segs[0][0].query(), SyllableQuery::Jianpin { letter: b'z' });
        assert_eq!(segs[0][1].query(), SyllableQuery::Jianpin { letter: b'g' });
    }

    #[test]
    fn jianpin_rejects_non_initial() {
        let g = graph("za", GraphMode::Jianpin);
        assert!(!g.has_complete_path(), "a 不能作简拼首字母");
    }

    #[test]
    fn trailing_r_marks_erhua() {
        let g = graph("huar", GraphMode::Full);
        let segs = g.segmentations(16);
        assert!(
            segs.iter()
                .any(|p| p.len() == 1 && texts(p) == vec!["huar"]),
            "huar 应产生 hua 的儿化边: {:?}",
            segs
        );
    }

    #[test]
    fn apostrophe_r_marks_erhua() {
        let g = graph("hua'r", GraphMode::Full);
        let segs = g.segmentations(16);
        assert!(
            segs.iter()
                .any(|p| p.len() == 1 && texts(p) == vec!["huar"]),
            "hua'r 应产生 hua 的儿化边: {:?}",
            segs
        );
    }
}
