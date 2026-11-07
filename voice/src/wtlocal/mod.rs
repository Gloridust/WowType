//! 微信输入法离线识别：加载官方模型包（`.xnet`），纯 Rust 推理，不依赖官方程序。
//!
//! 来源：J3n5en/voicekey 的 `crates/wtlocal`，经作者同意后引入并适配（见仓库 README 的引用）。
//! 适配点：
//! - 去掉 rayon / memmap2 / zip / tokio，改为标准库并行、整文件读入、系统 `unzip`
//! - 引擎接口改为本项目的 [`AsrChannel`]，同步喂 PCM、同步取结果

mod fbank;
mod kernels;
mod model;
pub mod pack;
mod parallel;
mod stream;
mod xnet;

pub mod download;

pub use model::Model;
pub use stream::Stream;

use anyhow::Result;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::asr::AsrChannel;

/// 中间结果的最小间隔（特征帧，10ms/帧）；同时要求距上次计算耗时的 3 倍，
/// 慢机器上自动降低刷新频率，避免解码把录音线程拖死。
const PARTIAL_EVERY: usize = 30;

static CACHE: Mutex<Option<(PathBuf, Arc<Model>)>> = Mutex::new(None);

/// 加载（并缓存）模型。同一目录重复调用只解析一次。
pub fn load(dir: &Path) -> Result<Arc<Model>> {
    let mut cache = CACHE.lock().unwrap();
    if let Some((cached, model)) = cache.as_ref() {
        if cached == dir {
            return Ok(model.clone());
        }
    }
    let model = Arc::new(Model::load(dir)?);
    *cache = Some((dir.to_path_buf(), model.clone()));
    Ok(model)
}

/// 离线识别渠道：喂 16kHz 单声道 PCM，结束时取文本。
pub struct WtLocalChannel {
    stream: Stream,
    last: String,
    computed: Instant,
    cost: Duration,
}

impl WtLocalChannel {
    pub fn new(dir: impl Into<PathBuf>) -> Result<Self> {
        let model = load(&dir.into())?;
        Ok(Self {
            stream: Stream::new(model),
            last: String::new(),
            computed: Instant::now(),
            cost: Duration::ZERO,
        })
    }
}

impl AsrChannel for WtLocalChannel {
    fn name(&self) -> &str {
        "wtlocal"
    }

    fn feed(&mut self, pcm: &[i16]) {
        self.stream.push(pcm);
        if self.stream.fresh() >= PARTIAL_EVERY && self.computed.elapsed() >= self.cost * 3 {
            let start = Instant::now();
            let text = self.stream.partial();
            self.cost = start.elapsed();
            self.computed = Instant::now();
            if !text.is_empty() && text != self.last {
                self.last = text;
            }
        }
    }

    fn partial(&self) -> Option<&str> {
        if self.last.is_empty() {
            None
        } else {
            Some(self.last.as_str())
        }
    }

    fn finish(&mut self) -> Option<String> {
        let text = self.stream.finish();
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }
}
