#!/usr/bin/env bash
# 无网络、无 root、无真实包管理操作的安装器回归测试。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/assets"

# 拦截所有可能修改系统/输入法配置的命令；curl 只读取本地夹具。
cat > "$work/bin/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
name=${0##*/}
case "$name" in
  sudo) exec "$@" ;;
  curl)
    output= url=
    while (($#)); do
      case "$1" in
        -o) output=$2; shift 2 ;;
        *) url=$1; shift ;;
      esac
    done
    printf 'curl %s\n' "$url" >> "$FIXTURE_FETCH_LOG"
    case "$url" in
      file://*) cp -- "${url#file://}" "$output" ;;
      https://github.com/Gloridust/WowType/releases/latest)
        printf '%s\n' https://github.com/Gloridust/WowType/releases/tag/v0.3.8 ;;
      *) printf '测试禁止联网：%s\n' "$url" >&2; exit 1 ;;
    esac
    ;;
  pgrep) exit 1 ;;
  im-config) [[ "${1:-}" != -m ]] || printf 'fcitx5\nfcitx5\n' ;;
  apt-get|pacman|dnf|wowtype-config)
    printf '%s' "$name" >> "$FIXTURE_LOG"
    printf ' %q' "$@" >> "$FIXTURE_LOG"
    printf '\n' >> "$FIXTURE_LOG"
    ;;
  *) printf '意外命令：%s\n' "$name" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/mock"
for name in sudo curl apt-get pacman dnf pgrep im-config wowtype-config; do
  ln -s mock "$work/bin/$name"
done

test_arch=x86_64
test_version=v0.3.8
count=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$*"; }
run() {
  env -u SUDO_USER PATH="$work/bin:$PATH" \
    FIXTURE_LOG="$work/commands" FIXTURE_FETCH_LOG="$work/fetches" \
    WOWTYPE_OS_RELEASE="$work/os-release" WOWTYPE_ARCH="$test_arch" \
    WOWTYPE_VERSION="$test_version" WOWTYPE_REPO=Gloridust/WowType \
    WOWTYPE_BASE_URL="file://$work/assets" WOWTYPE_YES=1 \
    WOWTYPE_NO_IM_CONFIG=1 WOWTYPE_NO_RESTART=1 XDG_CURRENT_DESKTOP= \
    bash "$root/install.sh" "$@"
}
reset() {
  : > "$work/commands"
  : > "$work/fetches"
  rm -f "$work/assets/"*
  test_arch=x86_64
  test_version=v0.3.8
  printf '%s\n' "$1" > "$work/os-release"
}
asset() {
  printf 'WowType fixture for %s\n' "$1" > "$work/assets/$1"
  (cd "$work/assets" && sha256sum "$1") >> "$work/assets/SHA256SUMS"
}
plan() {
  reset "$1"
  local result
  result=$(run --print-plan) || fail "计划失败：$1"
  [[ "$result" == *"$2"* ]] || fail "包选择错误：$result"
  [[ "$result" == *"包管理器：$3"* ]] || fail "包管理器错误：$result"
  [[ ! -s "$work/commands" && ! -s "$work/fetches" ]] || fail '--print-plan 有副作用'
  pass "$4"
}
rejected() {
  reset "$1"
  if run --print-plan > "$work/output" 2>&1; then fail "不应支持：$1"; fi
  grep -Fq "$2" "$work/output" || fail "缺少有效指引：$(cat "$work/output")"
  [[ ! -s "$work/commands" && ! -s "$work/fetches" ]] || fail '拒绝平台时有副作用'
  pass "$3"
}
assert_log() { grep -Fq -- "$1" "$work/commands" || fail "缺少命令：$1"; }
assert_no_install() {
  if grep -Eq '^(apt-get|pacman|dnf) ' "$work/commands"; then fail '校验失败仍运行包管理器'; fi
}

plan $'ID=ubuntu\nVERSION_ID="24.04"' wowtype_0.3.8_ubuntu24.04_amd64.deb apt-get 'Ubuntu 24.04'
plan $'ID=ubuntu\nVERSION_ID="26.04"' wowtype_0.3.8_ubuntu26.04_amd64.deb apt-get 'Ubuntu 26.04'
plan $'ID=debian\nVERSION_ID="13.1"' wowtype_0.3.8_debian13_amd64.deb apt-get 'Debian 13 point release'
plan $'ID=linuxmint\nVERSION_ID="22.1"\nID_LIKE="ubuntu debian"\nUBUNTU_CODENAME=noble' ubuntu24.04 apt-get 'Linux Mint uses Ubuntu base'
plan $'ID=pop\nVERSION_ID="24.04"\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=noble' ubuntu24.04 apt-get 'Pop!_OS uses explicit base'
plan $'ID=example\nID_LIKE=debian\nDEBIAN_CODENAME=trixie' debian13 apt-get 'Debian derivative with explicit trixie base'
plan 'ID=arch' wowtype-0.3.8-1-x86_64.pkg.tar.zst pacman 'Arch Linux'
plan $'ID=endeavouros\nID_LIKE=arch' pkg.tar.zst pacman 'EndeavourOS'
plan $'ID=garuda\nID_LIKE=arch' pkg.tar.zst pacman 'Garuda'
plan $'ID=cachyos\nID_LIKE=arch' pkg.tar.zst pacman 'CachyOS'
plan $'ID=fedora\nVERSION_ID=43' wowtype-0.3.8-1.fc43.x86_64.rpm dnf 'Fedora version-specific RPM'
rejected $'ID=ubuntu\nVERSION_ID=22.04' '源码' 'Ubuntu 22.04 is not silently upgraded to a newer binary'
rejected $'ID=linuxmint\nVERSION_ID=22\nID_LIKE="ubuntu debian"' '基线' 'Unknown derivative base rejected'
rejected $'ID=manjaro\nID_LIKE=arch' 'package-arch.sh' 'Manjaro uses native source package'
rejected $'ID=example\nID_LIKE="arch manjaro"' 'package-arch.sh' 'Manjaro derivative rejected'
rejected $'ID=fedora\nVERSION_ID=43\nVARIANT_ID=silverblue' 'rpm-ostree' 'Silverblue uses rpm-ostree'
rejected $'ID=fedora\nVERSION_ID=43\nVARIANT_ID=sway-atomic' 'rpm-ostree' 'Fedora Atomic uses rpm-ostree'
rejected 'ID=nixos' 'flake' 'NixOS uses flake'
rejected $'ID=opensuse-tumbleweed\nID_LIKE=suse' '源码' 'openSUSE source guidance'
rejected $'ID=rocky\nID_LIKE="rhel centos fedora"\nVERSION_ID=9' '源码' 'RHEL derivative is not treated as Fedora'
rejected 'ID=alpine' '源码' 'Alpine source guidance'

reset 'ID=arch'
test_arch=aarch64
if run --print-plan > "$work/output" 2>&1; then fail 'Unexpected aarch64 binary'; fi
grep -Fq '源码' "$work/output" || fail 'Missing architecture guidance'
pass 'Architecture mismatch rejected'

reset "ID=\$(touch $work/unexpected)"
if run --print-plan > "$work/output" 2>&1; then fail 'Unsafe os-release accepted'; fi
[[ ! -e "$work/unexpected" ]] || fail 'os-release shell code executed'
pass 'os-release is parsed as data'

reset 'ID=arch'
test_version=
result=$(run --print-plan)
[[ "$result" == *'wowtype-<版本>-1-x86_64.pkg.tar.zst'* && ! -s "$work/fetches" ]] || fail 'Default plan needs network'
pass 'Plan with unspecified version stays offline'

reset $'ID=ubuntu\nVERSION_ID=24.04'
asset wowtype_0.3.8_ubuntu24.04_amd64.deb
asset wowtype-data-rime-ice_20260101_all.deb
run > "$work/output" 2>&1 || fail "apt install: $(cat "$work/output")"
assert_log 'apt-get update -qq'
assert_log 'apt-get install -y'
assert_log 'fcitx5-config-qt fcitx5-frontend-all im-config'
assert_log 'python3-gi gir1.2-gtk-4.0 gir1.2-adw-1'
assert_log 'wowtype_0.3.8_ubuntu24.04_amd64.deb'
assert_log 'wowtype-data-rime-ice_20260101_all.deb'
assert_log 'wowtype-config --add-to-group'
pass 'APT installs verified local packages and legacy data'

reset 'ID=arch'
asset wowtype-0.3.8-1-x86_64.pkg.tar.zst
asset wowtype-data-rime-ice_20260101_all.deb
run > "$work/output" 2>&1 || fail "pacman install: $(cat "$work/output")"
assert_log 'pacman -S --needed --noconfirm'
if grep -q 'pacman -Syu' "$work/commands"; then fail 'installer ran a full system upgrade'; fi
assert_log 'python-gobject gtk4 libadwaita'
assert_log 'pacman -U --noconfirm'
if grep -q 'wowtype-data-rime-ice' "$work/fetches"; then fail 'Arch fetched a Debian data package'; fi
pass 'Pacman installs GUI dependencies and local package without -Syu'

reset $'ID=fedora\nVERSION_ID=43'
asset wowtype-0.3.8-1.fc43.x86_64.rpm
run > "$work/output" 2>&1 || fail "dnf install: $(cat "$work/output")"
assert_log 'dnf install -y'
assert_log 'wowtype-0.3.8-1.fc43.x86_64.rpm'
assert_log 'fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6'
pass 'DNF installs exact Fedora RPM and GTK/Qt frontends'

reset 'ID=arch'
asset wowtype-0.3.8-1-x86_64.pkg.tar.zst
printf 'corruption\n' >> "$work/assets/wowtype-0.3.8-1-x86_64.pkg.tar.zst"
if run > "$work/output" 2>&1; then fail 'Corrupted asset accepted'; fi
assert_no_install
pass 'Checksum mismatch prevents all package operations'

reset 'ID=arch'
asset wowtype-0.3.8-1-x86_64.pkg.tar.zst
cat "$work/assets/SHA256SUMS" > "$work/duplicate"
cat "$work/duplicate" >> "$work/assets/SHA256SUMS"
if run > "$work/output" 2>&1; then fail 'Duplicate hashes accepted'; fi
assert_no_install
pass 'Duplicate manifest entries rejected'

reset 'ID=arch'
asset wowtype-0.3.8-1-x86_64.pkg.tar.zst
printf 'bad  wowtype-0.3.8-1-x86_64.pkg.tar.zst\n' > "$work/assets/SHA256SUMS"
if run > "$work/output" 2>&1; then fail 'Malformed hash accepted'; fi
assert_no_install
pass 'Malformed manifest hash rejected'

reset $'ID=fedora\nVERSION_ID=44'
asset wowtype-0.3.8-1.fc43.x86_64.rpm
if run > "$work/output" 2>&1; then fail 'Wrong Fedora version accepted'; fi
assert_no_install
pass 'Missing target release asset fails before package operations'

reset 'ID=arch'
asset wowtype-0.3.8-1-x86_64.pkg.tar.zst
rm "$work/assets/wowtype-0.3.8-1-x86_64.pkg.tar.zst"
if run > "$work/output" 2>&1; then fail 'Missing asset accepted'; fi
assert_no_install
pass 'Failed asset download prevents package operations'

reset 'ID=arch'
asset wowtype-0.3.8-1-x86_64.pkg.tar.zst
sed -i 's/  / */' "$work/assets/SHA256SUMS"
run > "$work/output" 2>&1 || fail 'Binary-mode checksum line rejected'
pass 'Binary-mode SHA256SUMS supported'

reset 'ID=arch'
asset wowtype-0.3.8-1-x86_64.pkg.tar.zst
test_version=
run > "$work/output" 2>&1 || fail 'Latest release resolution failed'
grep -Fq 'https://github.com/Gloridust/WowType/releases/latest' "$work/fetches" || fail 'Wrong release repository'
pass 'Latest release uses the upstream repository'

printf '%s installer checks passed\n' "$count"
