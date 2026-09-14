#!/bin/sh
# install.sh —— 装 astronvim_v5。
#
# 这一个脚本有两个执行环境，而且它自己不需要知道在哪个里面：
#
#   宿主机（你的开发机、公司的机器）  $HOME = 你的家目录
#   容器（publish.sh 起的 ubuntu 镜像）$HOME = /root
#
# 唯一的差别就是 $HOME 指向哪。publish.sh 之所以能做得那么薄——起容器、跑
# 这个脚本、把容器的 $HOME 薅出来打包——就是因为这份脚本对环境无感。
#
# 为了这条成立，脚本必须满足四条硬约束（改这个文件时别破坏它们）：
#   1. 自足     不依赖 wtool 存在（容器里没有 wtool）
#   2. 无交互   容器里没人应答 [y/N]，apt 也会被 debconf 挂死
#   3. 可重入   重跑不炸（docker 里跑一半失败是常态）
#   4. 产物可枚举  装完写一份清单，说清往 $HOME 放了哪几条路径
#                （publish.sh 照清单薅，不用猜；猜错会静默漏文件）
#
# 两种模式：
#   build    下载 + 编译（nvim 源码、插件、mason 包、treesitter parser）
#   deploy   用旁边的分卷铺开，不需要网络（公司那台只能浏览器下载的机器）
#
# 模式自动判定：脚本旁边有 dist.json 和分卷 → deploy；否则 → build。
#
# 用法：
#   install.sh [--build|--deploy] [--target=ubuntu-24.04] [--from=DIR]
#              [--nvim-src=DIR] [--nvim-ref=REF] [--build-dir=DIR] [--prefix=DIR]
#              [--no-shell] [--no-deps] [--jobs=N] [--dry-run] [--uninstall]
set -eu

APPNAME=astronvim_v5
SELF=$(readlink -f -- "$0" 2>/dev/null || echo "$0")
HERE=$(dirname -- "$SELF")

# --------------------------------------------------------------------------
# 日志 / 小工具
# --------------------------------------------------------------------------
say()  { printf 'astronvim_v5: %s\n' "$*"; }
warn() { printf 'astronvim_v5: 警告: %s\n' "$*" >&2; }
die()  { printf 'astronvim_v5: 错误: %s\n' "$*" >&2; exit 1; }
step() { printf 'astronvim_v5:   - %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# 参数
# --------------------------------------------------------------------------
MODE=""
TARGET=""
FROM="$HERE"
NVIM_SRC=""
NVIM_REF=""
NVIM_BUILD_DIR=""
PREFIX=""
NO_SHELL=0
JOBS=""
DRY_RUN=0
UNINSTALL=0
NO_DEPS=0

while [ $# -gt 0 ]; do
    case $1 in
        --build)      MODE=build ;;
        --deploy)     MODE=deploy ;;
        --from=*)     FROM=${1#--from=} ;;
        --target=*)   TARGET=${1#--target=} ;;
        --nvim-src=*) NVIM_SRC=${1#--nvim-src=} ;;
        --nvim-ref=*) NVIM_REF=${1#--nvim-ref=} ;;
        --build-dir=*) NVIM_BUILD_DIR=${1#--build-dir=} ;;
        --prefix=*)   PREFIX=${1#--prefix=} ;;
        --jobs=*)     JOBS=${1#--jobs=} ;;
        --no-shell)   NO_SHELL=1 ;;
        --no-deps)    NO_DEPS=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --uninstall)  UNINSTALL=1 ;;
        -h|--help)    sed -n '2,40p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "未知参数: $1（--help 看用法）" ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# 环境探测
# --------------------------------------------------------------------------
HOME_DIR=${HOME:-/root}
[ -n "$HOME_DIR" ] || die "HOME 没设置"
PREFIX=${PREFIX:-$HOME_DIR/.local}
JOBS=${JOBS:-$( (nproc 2>/dev/null || echo 4) )}
XDG_CONFIG=${XDG_CONFIG_HOME:-$HOME_DIR/.config}
XDG_DATA=${XDG_DATA_HOME:-$HOME_DIR/.local/share}
XDG_STATE=${XDG_STATE_HOME:-$HOME_DIR/.local/state}

CONFIG_DIR="$XDG_CONFIG/$APPNAME"
DATA_DIR="$XDG_DATA/$APPNAME"
STATE_DIR="$XDG_STATE/$APPNAME"
MANIFEST="$STATE_DIR/install-manifest.tsv"

# 本机系统标识，形如 ubuntu-24.04
detect_target() {
    _id=""; _ver=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        _id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
        _ver=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}")
    fi
    [ -n "$_id" ] || _id=unknown
    [ -n "$_ver" ] || _ver=unknown
    printf '%s-%s' "$_id" "$_ver"
}
HOST_TARGET=$(detect_target)

# --------------------------------------------------------------------------
# 模式判定
# --------------------------------------------------------------------------
if [ "$UNINSTALL" = 0 ] && [ -z "$MODE" ]; then
    if [ -f "$FROM/dist.json" ] && ls "$FROM"/*.tar.* >/dev/null 2>&1; then
        MODE=deploy
    else
        MODE=build
    fi
fi
[ "$UNINSTALL" = 1 ] && MODE=uninstall

# --------------------------------------------------------------------------
# 清单：往 $HOME 放了什么
#
# kind 的含义（publish.sh 只薅 payload 和 shell，deps 一条都不带走）：
#   payload  $HOME 下的实体文件/目录，必须打包
#   deps     系统依赖（apt/npm/pip 装的），目标机上必须现场再装一遍，
#            因为必须和本机 libc/发行版匹配，带过去也不能用
#   shell    写进 shell 配置的托管块
# --------------------------------------------------------------------------
manifest_reset() {
    [ "$DRY_RUN" = 1 ] && return 0
    mkdir -p -- "$STATE_DIR"
    cat > "$MANIFEST" <<EOF
# astronvim_v5 安装清单 —— 由 install.sh 生成，publish.sh 照这个薅产物
# 格式: kind<TAB>相对\$HOME的路径
#   改动这个文件不会改变已装的东西，只会让打包漏东西，别手改。
EOF
}
manifest_add() {
    [ "$DRY_RUN" = 1 ] && return 0
    printf '%s\t%s\n' "$1" "$2" >> "$MANIFEST"
}

# --------------------------------------------------------------------------
# deps：两种模式都要走。这些是"必须和本机匹配"的东西，永远不进包。
# --------------------------------------------------------------------------
install_deps() {
    if [ "$NO_DEPS" = 1 ]; then
        say "跳过系统依赖（--no-deps）"
        manifest_add deps -
        return 0
    fi
    say "安装系统依赖（不进发布包）"
    if ! have apt-get; then
        warn "没有 apt-get，跳过系统依赖（非 Debian 系需要自己准备）"
        return 0
    fi

    # 分批发，每批一个用途：一批装不上不会拖垮后面的
    # DEBIAN_FRONTEND=noninteractive 是必须的，否则 debconf 在容器里会挂死
    _apt() {
        if [ "$DRY_RUN" = 1 ]; then step "[dry-run] apt-get install $*"; return 0; fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" \
            >/dev/null 2>&1 || warn "这批没装上（继续）: $*"
    }

    if [ "$DRY_RUN" = 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 失败（继续，可能用不了）"
    fi

    # 编译 nvim 本身
    _apt build-essential cmake ninja-build gettext pkg-config \
         libtool libtool-bin autoconf automake unzip curl
    # 跑插件和 mason 包要用到的运行时
    _apt git python3 python3-pip python3-venv nodejs npm ripgrep fd-find
    # 编译 treesitter parser 要用到 C/C++ 编译器（build-essential 里有了）

    # Debian/Ubuntu 把 fd 装成 fdfind，但 astronvim 找的是 fd
    if have fdfind && ! have fd; then
        if [ "$DRY_RUN" = 1 ]; then
            step "[dry-run] 建 fd -> fdfind 软链"
        else
            _bindir=$PREFIX/bin
            mkdir -p -- "$_bindir"
            ln -sf -- "$(command -v fdfind)" "$_bindir/fd" 2>/dev/null || true
        fi
    fi

    for _d in git curl python3 pip3 node npm rg; do
        have "$_d" || warn "缺少 $_d，后面可能出错"
    done
    manifest_add deps -
}

# --------------------------------------------------------------------------
# build：下载 + 编译
# --------------------------------------------------------------------------
build_nvim() {
    _src=$NVIM_SRC
    if [ -z "$_src" ]; then
        # 默认找同级目录下的 nvim（repo sync 出来的位置）
        if [ -d "$HERE/nvim" ] && [ -n "$(ls -A "$HERE/nvim" 2>/dev/null)" ]; then
            _src=$HERE/nvim
        fi
    fi

    if [ -z "$_src" ]; then
        say "本地没有 nvim 源码，从 GitHub 克隆"
        # 这是输入校验而不是副作用检查，dry-run 也要过
        [ -n "$NVIM_REF" ] || die "远程克隆必须给 --nvim-ref=<commit>（禁止浮动分支）"
        _src=$HOME_DIR/.cache/astronvim_v5/nvim-src
        if [ "$DRY_RUN" = 1 ]; then
            step "[dry-run] git clone --filter=blob:none https://github.com/neovim/neovim.git $_src"
            step "[dry-run] git checkout $NVIM_REF"
        else
            [ -d "$_src/.git" ] || git clone --filter=blob:none \
                https://github.com/neovim/neovim.git "$_src" \
                || die "克隆 neovim 失败（网络/proxy？）"
            git -C "$_src" fetch --tags --depth=1 origin "$NVIM_REF" 2>/dev/null || true
            git -C "$_src" checkout -q "$NVIM_REF" || die "切不到 $NVIM_REF"
        fi
    fi

    # 树外构建。publish.sh 是把工作区**只读**挂进容器的，cmake 默认把 build
    # 目录写在源码树里（$_src/build），只读挂载下必然失败。
    _bld=${NVIM_BUILD_DIR:-$HOME_DIR/.cache/astronvim_v5/nvim-build}

    if [ "$DRY_RUN" = 1 ]; then
        # dry-run 只描述计划：源码还没落盘是正常的，别在这里判存在性
        step "[dry-run] cmake -S $_src -B $_bld -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX"
        step "[dry-run] cmake --build $_bld -j$JOBS && cmake --install $_bld"
        step "[dry-run] 之后记入清单: .local/bin/nvim .local/share/nvim"
        return 0
    fi

    [ -d "$_src" ] || die "nvim 源码目录不存在: $_src"
    _ref=$(git -C "$_src" rev-parse HEAD 2>/dev/null || echo unknown)
    say "编译 nvim（源码 $_src @ $(printf '%s' "$_ref" | cut -c1-10)，-j$JOBS）"

    have cmake || die "没有 cmake，装不了 nvim"
    mkdir -p -- "$_bld"
    cmake -S "$_src" -B "$_bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        >/dev/null || die "cmake 配置失败"
    cmake --build "$_bld" -j "$JOBS" >/dev/null || die "nvim 编译失败"
    cmake --install "$_bld" >/dev/null || die "nvim 安装失败"

    manifest_add payload ".local/bin/nvim"
    [ -d "$XDG_DATA/nvim" ] && manifest_add payload ".local/share/nvim"
    [ -d "$PREFIX/lib/nvim" ] && manifest_add payload ".local/lib/nvim"

    "$PREFIX/bin/nvim" --version 2>/dev/null | head -1 | sed 's/^/astronvim_v5:   /' || true
}

install_config() {
    say "铺配置到 $CONFIG_DIR"
    _src="$HERE/astronvim_v5_config"
    [ -d "$_src" ] || die "找不到配置目录: $_src（应该是本仓的子目录）"
    if [ "$DRY_RUN" = 1 ]; then step "[dry-run] 复制 $_src → $CONFIG_DIR"; return 0; fi
    mkdir -p -- "$CONFIG_DIR"
    # 用 -a 保时间戳；不要 --delete，用户可能有自己的调试文件
    ( cd -- "$_src" && tar --exclude='.git' -cf - . ) | ( cd -- "$CONFIG_DIR" && tar -xf - )
    manifest_add payload ".config/$APPNAME"
}

install_plugins() {
    say "装 lazy 插件（按 lazy-lock.json 钉住的版本）"
    _lock="$CONFIG_DIR/lazy-lock.json"
    [ -f "$_lock" ] || warn "没有 lazy-lock.json，插件版本会漂"
    if [ "$DRY_RUN" = 1 ]; then
        step "[dry-run] Lazy! restore"
    else
        # 第一次跑会把 lazy.nvim 自己 clone 下来（init.lua 里做的事），
        # 所以先裸跑一次让引导完成，再 restore。
        NVIM_APPNAME=$APPNAME "$PREFIX/bin/nvim" --headless -c 'qa!' >/dev/null 2>&1 || true
        NVIM_APPNAME=$APPNAME "$PREFIX/bin/nvim" --headless \
            -c 'Lazy! restore' -c 'qa!' >/dev/null 2>&1 || warn "Lazy restore 返回非 0（继续）"
        NVIM_APPNAME=$APPNAME "$PREFIX/bin/nvim" --headless \
            -c 'Lazy! restore' -c 'qa!' >/dev/null 2>&1 || true
    fi
    manifest_add payload ".local/share/$APPNAME"
}

install_mason() {
    say "装 mason 包（清单 mason-packages.txt；mason 不支持锁版本）"
    _list="$HERE/mason-packages.txt"
    if [ ! -f "$_list" ]; then warn "没有 mason-packages.txt，跳过"; return 0; fi

    _names=$(grep -v '^#' "$_list" | grep -v '^$' | tr '\n' ' ')
    _n=$(printf '%s' "$_names" | wc -w)
    say "  共 $_n 个包，这一步最慢（2.7G 下载量）"

    if [ "$DRY_RUN" = 1 ]; then step "[dry-run] MasonInstall $_n 个包"; return 0; fi

    # mason 的安装是异步的：直接 MasonInstall + qa 会在装完前退出。
    # 所以自己拿 registry 循环等，全部装完（或失败）才退出。
    cat > "$STATE_DIR/.mason-install.lua" <<LUA
local registry = require("mason-registry")
local want = vim.split([[$_names]], "%s+")
local pending, failed = 0, {}
registry.refresh(function()
  for _, name in ipairs(want) do
    if name == "" then goto continue end
    local ok, pkg = pcall(registry.get_package, name)
    if not ok then
      failed[#failed + 1] = name .. "(不在注册表)"
    elseif not pkg:is_installed() then
      pending = pending + 1
      pkg:install({}, function(success)
        if not success then failed[#failed + 1] = name end
        pending = pending - 1
      end)
    end
    ::continue::
  end
  vim.wait(6 * 60 * 60 * 1000, function() return pending == 0 end, 500)
  if #failed > 0 then
    vim.fn.writefile(failed, "$STATE_DIR/mason-failed.txt")
  end
  vim.cmd("qa!")
end)
LUA
    NVIM_APPNAME=$APPNAME "$PREFIX/bin/nvim" --headless \
        -c "luafile $STATE_DIR/.mason-install.lua" >/dev/null 2>&1 \
        || warn "mason 批量安装返回非 0（继续）"
    rm -f -- "$STATE_DIR/.mason-install.lua"

    if [ -f "$STATE_DIR/mason-failed.txt" ]; then
        _nf=$(grep -c . "$STATE_DIR/mason-failed.txt" || true)
        warn "$_nf 个 mason 包装失败（清单见 $STATE_DIR/mason-failed.txt，不影响其余的）"
    fi
}

install_treesitter() {
    say "编译 treesitter parser（251 个，最耗时的一步）"
    _list="$HERE/treesitter-parsers.txt"
    if [ ! -f "$_list" ]; then warn "没有 treesitter-parsers.txt，跳过"; return 0; fi
    _names=$(grep -v '^#' "$_list" | grep -v '^$' | tr '\n' ' ')

    if [ "$DRY_RUN" = 1 ]; then step "[dry-run] TSInstall $(printf '%s' "$_names" | wc -w) 个 parser"; return 0; fi

    # 用 ensure_installed_sync（同步版）：异步的 ensure_installed / TSInstall
    # 在 headless 里会在装完之前就 qa 掉，装一半就退出，而且不留痕迹。
    # 这个 commit 的 nvim-treesitter 是 master 分支（被钉在 lazy-lock 里）。
    cat > "$STATE_DIR/.ts-install.lua" <<LUA
local ok, ts = pcall(require, "nvim-treesitter.install")
if not ok then
  vim.fn.writefile({ "nvim-treesitter 没装上，跳过 parser" }, "$STATE_DIR/treesitter-note.txt")
  vim.cmd("qa!")
end
ts.ensure_installed_sync(vim.split([[$_names]], "%s+"))
vim.cmd("qa!")
LUA
    NVIM_APPNAME=$APPNAME "$PREFIX/bin/nvim" --headless \
        -c "luafile $STATE_DIR/.ts-install.lua" >/dev/null 2>&1 \
        || warn "treesitter 安装返回非 0（单个 parser 失败不致命，继续）"
    rm -f -- "$STATE_DIR/.ts-install.lua"

    _have=$(find "$DATA_DIR/lazy/nvim-treesitter/parser" -name '*.so' 2>/dev/null | wc -l)
    say "  现在有 $_have 个 parser（清单里 $_names 个）"
}

# --------------------------------------------------------------------------
# deploy：用旁边的分卷铺开，不需要网络
# --------------------------------------------------------------------------
sha256_of() {
    if have sha256sum; then sha256sum -- "$1" | cut -d' ' -f1
    elif have shasum; then shasum -a 256 -- "$1" | cut -d' ' -f1
    else printf '?'
    fi
}

deploy_payload() {
    [ -f "$FROM/dist.json" ] || die "找不到 $FROM/dist.json（deploy 模式必须有它）"

    say "校验目标系统"
    _want=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["target"])
' "$FROM/dist.json")
    say "  包的目标 : $_want"
    say "  本机     : $HOST_TARGET"
    if [ -n "$TARGET" ]; then
        [ "$TARGET" = "$_want" ] || die "--target=$TARGET 和包里的 $_want 不一致"
    fi
    if [ "$_want" != "$HOST_TARGET" ]; then
        die "包的 glibc 是按 $_want 编的，装到 $HOST_TARGET 上会跑不起来。
nvim 是半静态链接（只剩 glibc 是动态依赖），而 glibc 只保证向前兼容：
在 24.04 上编的在 22.04 上一定跑不起来，反过来才行。
要在这台机器上用，请拿 $_want 那台机器编的包，或者在本机跑 install.sh --build。"
    fi

    # 先把分卷列表和校验全做完，再解压。
    # 校验绝不能放进管道里——管道每段都是子 shell，die 只会杀掉子 shell，
    # 坏分卷会被静默吞掉，最后得到一堆缺文件的"装好了"。
    say "校验分卷完整性"
    python3 - "$FROM/dist.json" > "$FROM/.vols.tsv" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
for v in d.get("volumes", []):
    print("%s\t%s\t%s" % (v["name"], v.get("sha256", "?"), v.get("bytes", 0)))
PY
    [ -s "$FROM/.vols.tsv" ] || die "dist.json 里没有 volumes"

    _idx=0
    : > "$FROM/.vols.paths"
    while IFS='	' read -r _name _sha _bytes; do
        [ -n "$_name" ] || continue
        _idx=$((_idx + 1))
        _f="$FROM/$_name"
        [ -f "$_f" ] || die "缺少分卷: $_f（$(( _idx )) 个里缺第 $_idx 个）"
        _got=$(sha256_of "$_f")
        if [ "$_sha" != "?" ] && [ "$_got" != "$_sha" ]; then
            die "分卷校验失败: $_name
  期望 $_sha
  实际 $_got
下载不完整或者被改动过，重新下载这一个文件再试。"
        fi
        printf '%s\n' "$_f" >> "$FROM/.vols.paths"
        _mb=$(( $(wc -c < "$_f") / 1048576 ))
        step "[$_idx] $_name  ${_mb}M  校验通过"
    done < "$FROM/.vols.tsv"

    _comp=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh).get("compression", "zstd"))
' "$FROM/dist.json")
    case $_comp in
        zstd) have zstd || die "这个包是 zstd 压的，本机没有 zstd（apt install zstd）"
              _dec="zstd -dc" ;;
        gzip) _dec="gzip -dc" ;;
        none) _dec="cat" ;;
        *)    die "dist.json 里的 compression=$_comp 不认识" ;;
    esac

    say "解压（$_idx 个分卷，按顺序拼回一个流）"
    if [ "$DRY_RUN" = 1 ]; then
        step "[dry-run] cat 分卷 | $_dec | tar -xf - -C $FROM/.payload"
        return 0
    fi

    mkdir -p -- "$FROM/.payload"
    # 分卷是同一个压缩流的切片，按顺序拼回去就是一个完整的包。
    # 用 if ! 包住整条管道，任何一段失败都能被抓到并报出来。
    if ! { while IFS= read -r _p; do cat -- "$_p" || exit 1; done < "$FROM/.vols.paths"; } \
         | $_dec | tar -xf - -C "$FROM/.payload"; then
        rm -rf -- "$FROM/.payload" "$FROM/.vols.paths" "$FROM/.vols.tsv"
        die "解压失败：分卷可能不完整，或者下载时被改了内容"
    fi
    rm -f -- "$FROM/.vols.paths" "$FROM/.vols.tsv"

    [ -d "$FROM/.payload/home" ] || die "分卷里没有 payload/home，包结构不对"

    say "铺开到 \$HOME"
    ( cd -- "$FROM/.payload/home" && tar -cf - . ) | ( cd -- "$HOME_DIR" && tar -xf - ) \
        || die "铺开失败（\$HOME 写不进去？）"

    # 清单以包里的 OWNED.tsv 为准：打包那一刻装了什么，就是这些
    _owned="$FROM/.payload/OWNED.tsv"
    if [ -f "$_owned" ]; then
        while IFS='	' read -r _k _p; do
            [ -n "${_p:-}" ] || continue
            [ "$_k" = "payload" ] && manifest_add payload "$_p"
        done < "$_owned"
    else
        warn "包里的 OWNED.tsv 不在，只能按已知路径记清单"
        manifest_add payload ".config/$APPNAME"
        manifest_add payload ".local/share/$APPNAME"
        manifest_add payload ".local/bin/nvim"
    fi
    rm -rf -- "$FROM/.payload"
}

# --------------------------------------------------------------------------
# shell 集成
#
# 由本脚本自己管（不用 wtool 的托管块机制），因为公司那台机器上没有 wtool，
# 而 NVIM_APPNAME 是"装完就能用"的必要条件。两个写手写同一个 rc 迟早打架，
# 所以这里只允许一个写手：就是本脚本。
# --------------------------------------------------------------------------
MARK_BEGIN="# >>> astronvim_v5 >>>"
MARK_END="# <<< astronvim_v5 <<<"

shell_block() {
    cat <<EOF
$MARK_BEGIN
# 由 astronvim_v5/install.sh 写入。删掉这段就是卸载 shell 集成。
export NVIM_APPNAME=$APPNAME
$MARK_END
EOF
}

install_shell() {
    [ "$NO_SHELL" = 1 ] && { say "跳过 shell 集成（--no-shell）"; return 0; }
    _block=$(shell_block)
    for _rc in "$HOME_DIR/.zshrc" "$HOME_DIR/.bashrc"; do
        _sh=$([ "${_rc##*.}" = zsh ] && echo zsh || echo bash)
        # 只有对应 shell 存在（或 rc 已存在）才写，别在容器里瞎造文件
        if ! have "$_sh" && [ ! -f "$_rc" ]; then continue; fi
        if [ "$DRY_RUN" = 1 ]; then step "[dry-run] 写托管块到 $_rc"; continue; fi

        if [ -f "$_rc" ] && grep -qF "$MARK_BEGIN" "$_rc"; then
            # 已有块：原地替换（幂等，不重复追加）
            _tmp="$_rc.tmp.$$"
            awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v blk="$_block" '
                $0 == b { print blk; skip = 1; next }
                skip && $0 == e { skip = 0; next }
                skip { next }
                { print }
            ' "$_rc" > "$_tmp" && mv -f -- "$_tmp" "$_rc"
            step "更新 $_rc 里的托管块"
        else
            { [ -f "$_rc" ] && cat -- "$_rc"; printf '\n%s\n' "$_block"; } > "$_rc.tmp.$$" \
                && mv -f -- "$_rc.tmp.$$" "$_rc"
            step "写入 $_rc"
        fi
        manifest_add shell "$(basename -- "$_rc")"
    done
}

# --------------------------------------------------------------------------
# 卸载：照清单逆着来
# --------------------------------------------------------------------------
do_uninstall() {
    say "卸载"
    if [ ! -f "$MANIFEST" ]; then warn "没有安装清单，不知道装过什么：$MANIFEST"; return 0; fi

    # shell 块先拆
    for _rc in "$HOME_DIR/.zshrc" "$HOME_DIR/.bashrc"; do
        [ -f "$_rc" ] || continue
        grep -qF "$MARK_BEGIN" "$_rc" || continue
        _tmp="$_rc.tmp.$$"
        awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
            '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } skip { next } { print }' \
            "$_rc" > "$_tmp" && mv -f -- "$_tmp" "$_rc"
        step "清掉 $_rc 里的托管块"
    done

    # 再删文件。倒序删，先深后浅。
    grep -v '^#' "$MANIFEST" | grep -v '^$' | grep '^payload' | cut -f2 | sort -r |
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        case $_rel in
            /*|*..*) warn "清单里有可疑路径，跳过: $_rel"; continue ;;
        esac
        _abs="$HOME_DIR/$_rel"
        if [ -e "$_abs" ] || [ -L "$_abs" ]; then
            rm -rf -- "$_abs"
            step "删除 $_rel"
        fi
    done

    rm -f -- "$MANIFEST"
    rmdir -- "$STATE_DIR" 2>/dev/null || true
    say "卸载完成"
    say ""
    say "注意：系统依赖（apt 装的）没有动，因为可能别的软件也在用。"
    say "      要清就自己看着删，清单里 deps 那几行是空路径占位。"
}

# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------
main() {
    if [ "$UNINSTALL" = 1 ]; then do_uninstall; return 0; fi

    say "模式     : $MODE"
    say "HOME     : $HOME_DIR"
    say "前缀     : $PREFIX"
    say "本机系统 : $HOST_TARGET"
    say "并发     : $JOBS"

    [ "$DRY_RUN" = 0 ] && mkdir -p -- "$STATE_DIR"
    manifest_reset

    if [ "$MODE" = "deploy" ]; then
        # 部署模式不需要编译工具，系统依赖仍然要装：apt 装的东西带不进包，
        # 只能目标机现场装（这也是"什么该打包"的分界线）。
        install_deps
        deploy_payload
    else
        install_deps
        build_nvim
        install_config
        install_plugins
        install_mason
        install_treesitter
    fi

    mkdir -p -- "$STATE_DIR" 2>/dev/null || true
    install_shell

    # 版本快照：两个模式的产物未必一样，记下来才能比对
    if [ "$DRY_RUN" = 0 ]; then
        _nvimver=$("$PREFIX/bin/nvim" --version 2>/dev/null | head -1 || echo unknown)
        printf 'nvim\t%s\n' "$_nvimver" > "$STATE_DIR/versions.txt"
        printf 'target\t%s\n' "$HOST_TARGET" >> "$STATE_DIR/versions.txt"
        printf 'mode\t%s\n' "$MODE" >> "$STATE_DIR/versions.txt"
        printf 'built_at\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$STATE_DIR/versions.txt"
    fi

    say ""
    say "装完了。用之前先让 shell 认识 NVIM_APPNAME："
    say "    exec zsh        # 或者重开一个终端"
    say "    nvim"
    say ""
    say "安装清单: $MANIFEST"
    say "卸载    : $SELF --uninstall"
}

main
