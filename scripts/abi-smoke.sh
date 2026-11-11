#!/usr/bin/env bash
# 构建并运行 C ABI 冒烟测试（模拟 fcitx5 插件的调用序列）。
set -euo pipefail
cd "$(dirname "$0")/.."

cargo build --release -p wowtype-core

LEXICON=${1:-/tmp/wowtype_abi.tsv}
# 旧版本生成的词库可能缺条目，内容不对就重建
if [[ ! -f "$LEXICON" ]] || ! grep -q 'zhi dao' "$LEXICON" 2>/dev/null; then
  printf '# abi smoke\nni hao\t你好\t100000\ntian\t天\t5000\ntian\t田\t2000\nzhong guo\t中国\t8000\nzhi dao\t知道\t6000\n' > "$LEXICON"
fi

BIGRAM=${2:-/tmp/wowtype_abi_bigram.tsv}
if [[ ! -f "$BIGRAM" ]]; then
  printf '# prev<TAB>cur<TAB>count\n今天\t天\t8\n今天\t田\t1\n' > "$BIGRAM"
fi

INCLUDE=core/include
LIBDIR=target/release
case "$(uname -s)" in
  Darwin) LIB=libwowtype_core.dylib; RUNENV="DYLD_LIBRARY_PATH=$LIBDIR" ;;
  *)      LIB=libwowtype_core.so;    RUNENV="LD_LIBRARY_PATH=$LIBDIR" ;;
esac

# 头文件里声明的每个函数都要在库里导出，不然前端链接时才发现（漏了 #[no_mangle] 或改了名）
HEADER_FUNCS=$(perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$INCLUDE/wowtype_core.h" \
  | grep -oE '\bwowtype_[a-z0-9_]+[[:space:]]*\(' | sed -E 's/[[:space:]]*\($//' | sort -u)
case "$(uname -s)" in
  Darwin) EXPORTED=$(nm -gU "$LIBDIR/$LIB" | awk '{print $NF}' | sed 's/^_//' | sort -u) ;;
  *)      EXPORTED=$(nm -D --defined-only "$LIBDIR/$LIB" | awk '{print $NF}' | sort -u) ;;
esac
MISSING=$(comm -23 <(echo "$HEADER_FUNCS") <(echo "$EXPORTED"))
if [[ -n "$MISSING" ]]; then
  echo "wowtype_core.h 里声明了、$LIB 没导出的函数：" >&2
  echo "$MISSING" | sed 's/^/  /' >&2
  exit 1
fi
echo "头文件和库一致：$(echo "$HEADER_FUNCS" | wc -l | tr -d ' ') 个函数都已导出"

# 库要放在源文件后面：Ubuntu 默认 --as-needed，放前面会被丢掉
cc -O2 -I"$INCLUDE" -o /tmp/wowtype_abi_smoke tools/abi_smoke.c -L"$LIBDIR" -lwowtype_core
S2T="$PWD/core/data/s2t.tsv"
env $RUNENV /tmp/wowtype_abi_smoke "$LEXICON" "$BIGRAM" "$S2T"
