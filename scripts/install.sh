#!/bin/sh
# install.sh —— 把 astronvim_v5 装到位。
#
# **这个脚本不构建。** 需要编译/下载的活全在 build.sh 里。
# 分工见 build.sh 顶部；一句话：build 生产，install 登记和收尾。
#
# 两种用法：
#
#   从发布包装（公司那台只能浏览器下载的机器走这条）
#     把 install.sh、dist.json 和所有分卷放同一个目录，然后 bash install.sh
#     脚本旁边有 dist.json 时自动走 deploy：校验目标系统、逐个校验分卷
#     sha256、铺开到 $HOME。不需要网络，也不需要 wtool。
#
#   在本机装（已经跑过 build.sh）
#     ./install.sh            用 build.sh 产出的东西，写 shell 集成和安装清单
#     没跑过 build 会明确报错告诉你去跑，而不是装出个半成品。
#
# 由 `wtool install astronvim_v5` 调用时，wtool 会先设好 WTOOL_PROJECT_ID。
# 注意本脚本**不会**再回头调 wtool —— 那会变成无限递归。
#
# 用法：
#   scripts/install.sh [--deploy|--local] [--target=ubuntu-24.04] [--from=DIR]
#              [--no-shell] [--no-deps] [--dry-run] [--uninstall]
set -eu

APPNAME=astronvim_v5
SELF=$(readlink -f -- "$0" 2>/dev/null || echo "$0")
HERE=$(dirname -- "$SELF")                 # = <项目>/scripts
PROJECT_DIR=$(cd -- "$HERE/.." && pwd)    # = <项目>


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
FROM="$PROJECT_DIR"
PREFIX=""
NO_SHELL=0
NO_DEPS=0
DRY_RUN=${WTOOL_DRY_RUN:-0}
UNINSTALL=0

while [ $# -gt 0 ]; do
    case $1 in
        --deploy)     MODE=deploy ;;
        --local)      MODE=local ;;
        --from=*)     FROM=${1#--from=} ;;
        --target=*)   TARGET=${1#--target=} ;;
        --prefix=*)   PREFIX=${1#--prefix=} ;;
        --no-shell)   NO_SHELL=1 ;;
        --no-deps)    NO_DEPS=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --uninstall)  UNINSTALL=1 ;;
        -h|--help)    sed -n '2,30p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "未知参数: $1（--help 看用法）" ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# 环境探测
# --------------------------------------------------------------------------
HOME_DIR=${HOME:-/root}
[ -n "$HOME_DIR" ] || die "HOME 没设置"
PREFIX=${PREFIX:-${WTOOL_PREFIX:-$HOME_DIR/.wtool/usr}}
JOBS=${JOBS:-$( (nproc 2>/dev/null || echo 4) )}
XDG_CONFIG=${XDG_CONFIG_HOME:-$HOME_DIR/.config}
XDG_DATA=${XDG_DATA_HOME:-$HOME_DIR/.local/share}
XDG_STATE=${XDG_STATE_HOME:-$HOME_DIR/.local/state}

# 真正的内容一律放 $WTOOL_PREFIX（默认 ~/.wtool/usr）下面 —— 这是 wtool 的契约，
# 见 harness/notes/01-context.md §3.1。原来放 $HOME/.local 有两个后果：
#   · `wtool uninstall` 撤不掉：东西不在 wtool 拥有的路径里，journal 里没有
#   · 和用户、别的工具抢 ~/.local/bin、~/.config 这些公共目录
#
# nvim 二进制/运行时由 `make install --prefix=$PREFIX` 落到 $PREFIX/{bin,share,lib}；
# 配置和插件数据放 $PREFIX/share/<app>/{config,data}。
#
# **$HOME 里只留软链**（见 install.sh 的 link_into_home）：软链是 wtool 管的、
# 可撤销的，删掉不留痕。nvim 靠 NVIM_APPNAME 去 $XDG_CONFIG_HOME/$APPNAME
# 和 $XDG_DATA_HOME/$APPNAME 找东西，软链正好把这两个点接过去。
# 两个独立根，符合 XDG 语义：nvim 找的是
#   $XDG_CONFIG_HOME/$APPNAME  和  $XDG_DATA_HOME/$APPNAME
# 所以只要把 XDG_*_HOME 指到下面这两个目录，路径自然就对上了。
XDG_CONFIG_REAL="$PREFIX/config"
XDG_DATA_REAL="$PREFIX/share"
CONFIG_DIR="$XDG_CONFIG_REAL/$APPNAME"
DATA_DIR="$XDG_DATA_REAL/$APPNAME"
STATE_DIR="$XDG_STATE/$APPNAME"
MANIFEST="$STATE_DIR/install-manifest.tsv"


# --------------------------------------------------------------------------
# 本机系统标识，形如 ubuntu-24.04
# --------------------------------------------------------------------------
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
# 安装清单
# --------------------------------------------------------------------------
manifest_reset() {
    [ "$DRY_RUN" = 1 ] && return 0
    mkdir -p -- "$STATE_DIR"
    cat > "$MANIFEST" <<EOF
# astronvim_v5 安装清单 —— 由 install.sh 生成，publish.sh 照这个薅产物
# 格式: kind<TAB>相对\$HOME的路径
#   payload  必须打包进发布包的东西
#   deps     系统依赖，装到目标机上要现场重装，不进包
#   shell    写进 shell 配置的托管块
# 改动这个文件不会改变已装的东西，只会让打包漏东西，别手改。
EOF
}

manifest_touch() {
    [ "$DRY_RUN" = 1 ] && return 0
    mkdir -p -- "$STATE_DIR"
    [ -f "$MANIFEST" ] || cat > "$MANIFEST" <<EOF
# astronvim_v5 安装清单 —— build.sh / install.sh / 发布包共同维护
# 格式: kind<TAB>相对\$HOME的路径
#   payload  必须打包进发布包的东西
#   deps     系统依赖，装到目标机上要现场重装，不进包
#   shell    写进 shell 配置的托管块
# publish.sh 照这份清单薅产物；手改它只会让打包漏东西，别改。
EOF
}


manifest_add() {
    [ "$DRY_RUN" = 1 ] && return 0
    printf '%s\t%s\n' "$1" "$2" >> "$MANIFEST"
}

# deploy 模式也要装系统依赖：apt 装的东西带不进包（必须和本机 libc/发行版匹配），
# 只能目标机现场装。这也是"什么该打包"的分界线。

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
    #
    # 两个细节都是踩过坑才加的：
    #   * 重试一次。代理后面网络抖一下很常见，实测有一批整个失败、
    #     紧接着手工跑同样的命令却一次成功。
    #   * 失败时必须把 apt 的输出露出来。原来 >/dev/null 2>&1 吞掉错误，
    #     只留一句"这批没装上"，只能靠猜——白白浪费一轮几十分钟的构建。
    #   * DPkg::Lock::Timeout：并发或上一批的触发器还没收尾时，
    #     让 apt 等锁而不是直接报失败。
    _apt() {
        if [ "$DRY_RUN" = 1 ]; then step "[dry-run] apt-get install $*"; return 0; fi
        _aptlog="$STATE_DIR/.apt.log"
        _try=0
        while [ "$_try" -lt 2 ]; do
            _try=$((_try + 1))
            if DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    --no-install-recommends -o DPkg::Lock::Timeout=120 "$@" \
                    >"$_aptlog" 2>&1; then
                return 0
            fi
            if [ "$_try" -lt 2 ]; then
                warn "这批没装上，10 秒后重试: $*"
                sleep 10
            fi
        done
        warn "这批最终没装上（继续，但后面可能出错）: $*"
        warn "apt 最后的输出："
        tail -15 "$_aptlog" 2>/dev/null | sed 's/^/    /' >&2
        return 0
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
# 本地安装：确认 build.sh 真的跑过了
#
# 这里刻意不做"顺手帮你 build 一下"——install 要能在没网、没编译器的机器上跑，
# 一旦它偷偷开始编译，这个前提就没了。缺什么就明确说什么。
# --------------------------------------------------------------------------
require_build() {
    _missing=""
    [ -x "$PREFIX/bin/nvim" ] || _missing="$_missing nvim二进制"
    [ -d "$DATA_DIR/lazy" ]   || _missing="$_missing lazy插件"
    [ -d "$DATA_DIR/mason" ]  || _missing="$_missing mason包"

    if [ -n "$_missing" ]; then
        warn "还没构建过（缺:$_missing）"
        warn "先跑构建，再回来装："
        warn "    wtool build astronvim_v5"
        warn "  或者直接："$HERE/build.sh""
        exit 3
    fi
    _nv=$("$PREFIX/bin/nvim" --version 2>/dev/null | head -1 || echo '?')
    say "构建产物 : $_nv"
    _np=$(find "$DATA_DIR/lazy/nvim-treesitter/parser" -name '*.so' 2>/dev/null | wc -l)
    say "插件/parser: $(ls "$DATA_DIR/lazy" 2>/dev/null | wc -l) 个插件，$_np 个 parser"
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

# --------------------------------------------------------------------------
shell_block() {
    cat <<EOF
$MARK_BEGIN
# 由 astronvim_v5/install.sh 写入。删掉这段就是卸载 shell 集成。
export NVIM_APPNAME=$APPNAME
# PATH 必须带进来。原来只写了 NVIM_APPNAME ——
# 于是"装完了"，但新开的 shell 里敲 nvim 是 command not found，
# 而 ~/.config、~/.local/share 里却能看到东西，看起来像装了一半。
# 用 $PREFIX（安装时确定），不写死 ~/.wtool/usr：
# 用户可以 --prefix= 换地方。
case ":\$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) PATH="$PREFIX/bin:\$PATH" ;;
esac
export PATH
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
# $HOME 里只放软链
# --------------------------------------------------------------------------
# 真正的内容在 $CONFIG_DIR / $DATA_DIR（都在 $WTOOL_PREFIX 下）。
# nvim 靠 NVIM_APPNAME 去 $XDG_CONFIG_HOME/$APPNAME 和
# $XDG_DATA_HOME/$APPNAME 找东西，所以在这两个点上放软链接过去。
#
# 为什么不是直接把实体放 $HOME：
#   · 可撤销 —— 软链是 wtool 管的，删掉不留痕；实体撤起来要猜"这是谁放的"
#   · 不打架 —— ~/.config、~/.local/share 是用户和别的工具共用的
# 软链本身也登记成 payload，所以 --uninstall 会连它一起删。
link_into_home() {
    for _pair in "$XDG_CONFIG/$APPNAME:$CONFIG_DIR" "$XDG_DATA/$APPNAME:$DATA_DIR"; do
        _link=${_pair%%:*}
        _real=${_pair#*:}
        [ -d "$_real" ] || continue
        if [ "$DRY_RUN" = 1 ]; then step "[dry-run] 软链 $_link → $_real"; continue; fi
        # 已经是对的软链就别动（幂等，也避免把 mtime 搞乱）
        if [ -L "$_link" ] && [ "$(readlink -- "$_link")" = "$_real" ]; then
            continue
        fi
        # 目标位置有**实体**（老版本装法留下的）→ 说明是从老布局迁移过来。
        # 直接删有风险，所以先挪到一边并**大声说出来**，不静默丢用户数据。
        if [ -e "$_link" ] && [ ! -L "$_link" ]; then
            _bak="$_link.wtool-old.$$"
            warn "$_link 是实体（老版本装的），挪到 $_bak 后改成软链"
            mv -f -- "$_link" "$_bak" || die "挪不动 $_link"
        fi
        mkdir -p -- "$(dirname -- "$_link")"
        ln -sfn -- "$_real" "$_link" || die "建软链失败: $_link"
        step "软链 $_link → $_real"
        # 登记成 payload，--uninstall 才会连软链一起删。
        # 清单里的路径是**相对 $HOME** 的，所以要换算一下。
        case $_link in
            "$HOME_DIR"/*) manifest_add payload "${_link#"$HOME_DIR"/}" ;;
            *) warn "软链 $_link 不在 \$HOME 下，不进清单（卸载时不会删）" ;;
        esac
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

    # 旁边有 dist.json 和分卷就是 deploy，否则是本机安装
    if [ -z "$MODE" ]; then
        if [ -f "$FROM/dist.json" ] && ls "$FROM"/*.tar.* >/dev/null 2>&1; then
            MODE=deploy
        else
            MODE=local
        fi
    fi

    say "模式     : $MODE"
    say "HOME     : $HOME_DIR"
    say "前缀     : $PREFIX"
    say "本机系统 : $HOST_TARGET"

    [ "$DRY_RUN" = 0 ] && mkdir -p -- "$STATE_DIR"

    if [ "$MODE" = "deploy" ]; then
        manifest_reset
        install_deps
        deploy_payload
    else
        # 本机安装：build.sh 已经把清单开好了，这里只续写，别清空
        manifest_touch
        require_build
    fi

    # 产物已经在 $WTOOL_PREFIX 下了，这里在 $HOME 里接两个软链过去。
    # 必须在 install_shell 之前：shell 块里的 PATH 指向 $PREFIX/bin，
    # 得先保证那个目录真的有东西。
    link_into_home

    install_shell

    say ""
    say "装完了。用之前先让 shell 认识 NVIM_APPNAME："
    say "    exec zsh        # 或者重开一个终端"
    say "    nvim"
    say ""
    say "安装清单: $MANIFEST"
    say "卸载    : $SELF --uninstall"
}

main
