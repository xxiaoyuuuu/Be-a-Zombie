#!/bin/bash
# Installs Be a Zombie: the two Claude skills and, on a Mac, the ZombiePet desktop pet.
#
#   bash install.sh               install everything and start the pet
#   bash install.sh --no-launch   install everything, do not start the pet
#   bash install.sh --skills      install only the skills
#
# Running it again upgrades in place. A zombie profile you already filled in
# (preferences.md) and your plan and progress in ~/.zombie are kept.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

SKILLS="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
APPS="${ZOMBIE_APP_DIR:-$HOME/Applications}"
DATA="${ZOMBIE_HOME:-$HOME/.zombie}"
APP="$APPS/ZombiePet.app"

LAUNCH=1
PET=1
for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        --skills) PET=0 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# Messages follow the terminal's language; when the terminal does not say,
# they follow the Mac's first system language.
ZH=0
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    zh*) ZH=1 ;;
    ""|C|POSIX|C.*)
        if [ "$(uname)" = Darwin ] &&
           defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q 'zh'; then
            ZH=1
        fi ;;
esac
say() { if [ "$ZH" = 1 ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }
short() { printf '%s' "${1/#$HOME/~}"; }

say "🧟 Be a Zombie 安装" "🧟 Installing Be a Zombie"
echo

# 1. Skills ------------------------------------------------------------------

say "[1/3] 安装 skill → $(short "$SKILLS")" "[1/3] Skills → $(short "$SKILLS")"
install_skill() {
    local name="$1" zh="$2" en="$3" dst="$SKILLS/$1" kept=""
    mkdir -p "$dst"
    cp "$ROOT/skills/$name/SKILL.md" "$dst/SKILL.md"
    if [ -f "$dst/preferences.md" ]; then
        kept=1
    else
        cp "$ROOT/skills/$name/preferences.md" "$dst/preferences.md"
    fi
    if [ -n "$kept" ]; then
        say "      ✓ $name($zh,保留了已有的僵尸档案)" "      ✓ $name ($en, kept your zombie profile)"
    else
        say "      ✓ $name($zh)" "      ✓ $name ($en)"
    fi
}
install_skill be-a-zombie-cn "中文" "Chinese"
install_skill be-a-zombie "英文" "English"

# The skills write the day's plan here only when this folder exists.
mkdir -p "$DATA"

next_steps() {
    echo
    say "接下来:" "Next:"
    say "  1. 打开 Claude Code(桌面 app 的 Code 标签,或终端里的 claude)" \
        "  1. Open Claude Code (the Code tab of the desktop app, or claude in a terminal)"
    say "  2. 说:僵尸模式。今天要做……(把想做的事全倒出来)" \
        "  2. Say: zombie mode. Today I need to ... (dump everything you want to do)"
    if [ "${1:-}" = pet ]; then
        say "  3. 计划排好后,桌面上的小僵尸会自己醒过来" \
            "  3. Once the plan is written, the zombie on your desktop wakes up by itself"
    fi
}

# 2. Desktop pet -------------------------------------------------------------

if [ "$PET" = 0 ]; then
    say "[2/3] 跳过小僵尸(--skills)" "[2/3] Skipping the desktop pet (--skills)"
    say "[3/3] 跳过" "[3/3] Skipped"
    next_steps
    exit 0
fi

if [ "$(uname)" != Darwin ]; then
    say "[2/3] 小僵尸只支持 Mac,已跳过。skill 可以单独使用。" \
        "[2/3] The desktop pet is Mac only, skipped. The skills work on their own."
    say "[3/3] 跳过" "[3/3] Skipped"
    next_steps
    exit 0
fi

OSMAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OSMAJOR" -lt 13 ]; then
    say "[2/3] 小僵尸需要 macOS 13 或更新的系统(这台是 $(sw_vers -productVersion)),已跳过。" \
        "[2/3] The desktop pet needs macOS 13 or later (this Mac has $(sw_vers -productVersion)), skipped."
    say "[3/3] 跳过" "[3/3] Skipped"
    next_steps
    exit 0
fi

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun -f swiftc >/dev/null 2>&1; then
    say "[2/3] 编译小僵尸需要苹果的命令行工具,这台 Mac 还没装。" \
        "[2/3] Building the pet needs Apple's Command Line Tools, which this Mac does not have yet."
    say "      先运行:xcode-select --install" "      Run:  xcode-select --install"
    say "      装好后再运行一次 bash install.sh。skill 已经装好,现在就能用。" \
        "      Then run bash install.sh again. The skills are installed and usable now."
    exit 1
fi

say "[2/3] 编译小僵尸(通常不到一分钟)…" "[2/3] Building the desktop pet (usually under a minute)…"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
# Run through bash: files uploaded on the GitHub website lose their "executable" flag.
if ! ZOMBIE_APP_DIR="$APPS" bash "$ROOT/build.sh" >"$LOG" 2>&1; then
    say "      ✗ 编译失败,输出如下:" "      ✗ The build failed. Output:"
    cat "$LOG" >&2
    exit 1
fi
say "      ✓ $(short "$APP")" "      ✓ $(short "$APP")"

# 3. Start -------------------------------------------------------------------

if [ "$LAUNCH" = 0 ]; then
    say "[3/3] 没有启动(--no-launch)。想启动时运行:open \"$APP\"" \
        "[3/3] Not started (--no-launch). To start it: open \"$APP\""
else
    say "[3/3] 启动小僵尸" "[3/3] Starting the pet"
    # An older copy that is still running would keep showing the old version.
    pkill -f "$APP/Contents/MacOS/ZombiePet" 2>/dev/null && sleep 1 || true
    open "$APP"
    say "      ✓ 它在屏幕右下角,可以拖到别处" "      ✓ It is at the bottom right of your screen; drag it anywhere"
fi

echo
say "装好了。" "Done."
next_steps pet
