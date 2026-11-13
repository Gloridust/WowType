# 评测数据与基线数字

这里放公开语料生成的评测用例怎么来、以及当前基线，方便改排序/LM 时对比。

## 生成用例

```bash
# Tatoeba 中文句子（CC BY 2.0）：https://downloads.tatoeba.org/exports/per_language/cmn/
python3 tools/make_corpus_eval.py --tatoeba cmn_sentences.tsv.bz2 \
    --split /tmp/train.tsv:3000 /tmp/test.tsv:500

# 或者一行一句的纯文本
python3 tools/make_corpus_eval.py --text sentences.txt --out cases.tsv --count 2000
```

## 跑评测

```bash
# 词库 + 词级 LM
cargo run --bin wowtype-eval -- --lexicon lexicon.tsv --eval /tmp/test.tsv \
    --lm words.lm --k 1

# 再加上字级神经语言模型（从本机微信输入法里取，见 tools/install_wetype_nnlm.py）
cargo run --bin wowtype-eval -- --lexicon lexicon.tsv --eval /tmp/test.tsv \
    --lm words.lm --nnlm nlrgpt2_nnlm.bin --k 1
```

## 基线（本机 macOS，debug 构建，2026-11）

词库：雾凇拼音 + jieba 词频合并（936,662 条），LM：`words.lm`。

| 用例集 | 不开 NNLM | 开 NNLM |
|---|---|---|
| Tatoeba 留出 500 句 | 61.4% | **65.2%** |
| Tatoeba 留出 100 句 | 53.0% | **62.0%** |
| 另一组留出 100 句（与训练不重叠） | 68.0% | **75.0%** |
| 手写日常句 138 句 | 84.8% | **91.3%** |

其他观察：

- `--beam 32/48` 基本不变（61.6%）
- `--lm-weight 0.5~0.7` 在 Tatoeba 上略好，但日常句会掉；默认 1.0 是折中
- 500 句里约 31% 的正确句子连 top50 都进不去：瓶颈是覆盖/切分，不是排序权重

## 注意

- Tatoeba 句子只用于本地评测，不提交
- NNLM 是腾讯的模型，仓库不分发；`tools/install_wetype_nnlm.py` 从本机安装里取