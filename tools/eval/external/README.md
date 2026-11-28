# 外部盲测集

别人写的用例，只用来**量**，不拿来调：自家的评测集（`tools/eval/*.tsv`）是照着我们的词库生成、照着它调过权重的，
`daily.tsv` 带整句增强模型有 94%，同样的配置放到这里的整句上只有 60% 出头。差的那一截是自家评测集看不出来的问题。

```bash
scripts/eval-external.sh <数据目录> --nnlm <nnlm.bin>            # 每组一行，最后一行合计
scripts/eval-external.sh <数据目录> --nnlm <nnlm.bin> --misses   # 列出没通过的用例
```

CI 不跑，没有基线和门槛。规矩（照 chime 自己对这份数据的要求）：

- 可以看哪一**类**差、差在什么机制上（束搜索留不住句中的另一种写法、的地得……），据此改通用的算法；
- **不**照着某一条用例加词、加规则、调权重，也不把这里的句子放进训练语料。改了以后自家评测集和这里要一起涨才算数。

## chime-holdout（1010 条）

来源：[tyrchen/chime](https://github.com/tyrchen/chime) 的 `benchmarks/test_holdout.tsv`（提交 d0f5da2，2026-11-27），
Copyright (c) 2026 Tian Chen，MIT OR Apache-2.0。用 `chime2wt.py` 转成 `wowtype-eval` 的格式，按分类拆成 17 个文件，
内容没有改（包括里面标错的几条，比如 `ouer` 的期望写成了「偶然」）。

几类和我们的默认配置对不上，数字要分开看：

| 分类 | 说明 |
|---|---|
| `code_switch_mixed` | 句子里夹英文（`bangworeviewzhegepr` → 帮我 review 这个 PR）：WowType 没有这个功能，0% |
| `fuzzy_dialect` | 要开模糊音：默认关着时 15%，加 `--fuzzy` 是 92.5% |
| `shuangpin_schemes_*` | 双拼（`sp=` 属性），照常算 |

带 `nnlm.bin`（2026.11.17.0）、词库 2026.11.11.8：

| | top1 | top3 | top9 |
|---|---:|---:|---:|
| 0.7.15（束搜索每个末词只留一条历史，`--histories 1`） | 59.5% | 63.4% | 64.8% |
| 每个末词留 3 条（`BeamConfig::histories_per_word`） | 63.6% | 69.8% | 72.6% |

chime 自己（0.15，190 MB 的蒸馏模型，Apple 芯片的 GPU 上跑）报的是 90.6%；它只用词图、不带神经模型时是 42.9%。
