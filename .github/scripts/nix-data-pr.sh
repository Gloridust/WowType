#!/usr/bin/env bash
# 发版后，这一版换了词库时：把 nix/package.nix 改成指向这次发布页上的词库包，推到 bot/nix-data-<版本>
# 分支，开 PR 到 main。同一个词库版本再发版时只更新这个分支（PR 跟着变），不重复开。
#
# Actions 不能开 PR 时（仓库设置 Actions → General →「Allow GitHub Actions to create and approve pull
# requests」没开），退回开 issue，附上已经推好的分支的对比链接，点一下就能开 PR。
#
# 用法：nix-data-pr.sh <词库包路径>；要 GITHUB_REPOSITORY、GITHUB_REF_NAME、GH_TOKEN。
# NIX_DATA_PR_DRY_RUN=1 时只改文件、不推送不开 PR（本机试用）。
set -euo pipefail

tarball_path=$1
tarball=$(basename "$tarball_path")
built=${tarball#wowtype-data-rime-ice-}
built=${built%.tar.gz}
nix=nix/package.nix
repo=$GITHUB_REPOSITORY
tag=$GITHUB_REF_NAME
dry=${NIX_DATA_PR_DRY_RUN:-}

git fetch -q origin +refs/heads/main:refs/remotes/origin/main
pinned=$(git show "origin/main:$nix" | sed -n 's/^ *dataVersion = "\(.*\)";/\1/p')
if [ "$built" = "$pinned" ]; then
  echo "main 上 Nix 包的词库已经是 ${built}"
  exit 0
fi

hex=$(sha256sum "$tarball_path" | cut -d' ' -f1)
url="https://github.com/${repo}/releases/download/${tag}/${tarball}"
if [ -z "$dry" ]; then
  # 和发布页上的文件再对一次：Nix 下载的是那一份
  remote=$(curl -fsSL --retry 3 "$url" | sha256sum | cut -d' ' -f1)
  if [ "$remote" != "$hex" ]; then
    echo "::error title=Nix 词库::发布页上的 ${tarball}（${remote}）和本地算 hash 的（${hex}）不一样"
    exit 1
  fi
fi
sri=$(python3 -c 'import base64, sys; print("sha256-" + base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$hex")

branch="bot/nix-data-${built}"
git switch -q -C "$branch" origin/main
python3 - "$nix" "$built" "$tag" "$sri" <<'PY'
import re, sys
path, built, tag, sri = sys.argv[1:]
s = open(path, encoding="utf-8").read()
subs = [
    (r'(\n *dataVersion = )"[^"]*";', rf'\1"{built}";'),
    (r'(releases/download/)[^/"]+(/wowtype-data-rime-ice-\$\{dataVersion\}\.tar\.gz")', rf'\g<1>{tag}\2'),
    # data = fetchurl { 里面那行 hash（网址里有 ${dataVersion}，不能按花括号找结尾，按缩进逐行找）
    (r'(\n  data = fetchurl \{(?:\n    [^\n]*)*?\n    hash = )"[^"]*";', rf'\1"{sri}";'),
]
for pattern, repl in subs:
    s, n = re.subn(pattern, repl, s, count=1)
    if n != 1:
        sys.exit(f"nix/package.nix 里找不到要改的那行：{pattern}")
open(path, "w", encoding="utf-8").write(s)
PY
if [ "$(git diff --numstat -- "$nix")" != "$(printf '3\t3\t%s' "$nix")" ]; then
  echo "::error title=Nix 词库::nix/package.nix 改动不是预期的 3 行"
  git diff -- "$nix"
  exit 1
fi
git diff -- "$nix"
[ -n "$dry" ] && exit 0

git -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "Nix 包的词库更新到 ${built}" -m "${tag} 发布页上的 ${tarball}。" -- "$nix"
git push -q --force origin "$branch"

title="Nix 包的词库更新到 ${built}"
existing=$(gh pr list --repo "$repo" --head "$branch" --state open --json number -q '.[0].number // empty')
if [ -n "$existing" ]; then
  echo "PR #${existing} 已经开着，分支已更新到 ${tag} 的词库包"
  exit 0
fi

cat > nix-pr.md <<MD
${tag} 的词库是 \`${built}\`，main 上的 nix/package.nix 还固定在 \`${pinned}\`，NixOS 用户拿到的是旧词库。

这个 PR 由发布流程自动生成，只改 nix/package.nix 的三行：

\`\`\`nix
dataVersion = "${built}";
url = "${url}";
hash = "${sri}";
\`\`\`

hash 是按上传到发布页的那个文件算的，并已重新下载核对过。合进 main 后，跟 release 分支的 NixOS 用户在下一次发版时拿到新词库。

Actions 开的 PR 不会自动跑 CI；要跑的话关掉再重新打开这个 PR。
MD
if gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file nix-pr.md; then
  exit 0
fi

echo "::warning title=Nix 词库::开不了 PR（仓库没允许 Actions 创建 PR），改开 issue"
if [ -n "$(gh issue list --repo "$repo" --state open --search "\"${title}\" in:title" --json number -q '.[0].number // empty')" ]; then
  echo "同名 issue 已经开着"
  exit 0
fi
{
  cat nix-pr.md
  echo
  echo "分支已经推好，点这里开 PR：https://github.com/${repo}/compare/main...${branch}?expand=1"
} > nix-issue.md
gh issue create --repo "$repo" --title "$title" --body-file nix-issue.md
