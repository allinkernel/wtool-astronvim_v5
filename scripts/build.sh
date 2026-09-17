#!/bin/sh
# build.sh —— 编译 / 下载 astronvim_v5 需要的一切。
#
# 和 install.sh 的分工（这条线要守住，否则两个脚本会长成一团）：
#   build.sh    需要网络、需要编译器的活：装系统依赖、编 nvim、
#               拉 lazy 插件、装 mason 包、编 treesitter parser（数量看各自的清单文件）
#   install.sh  不需要网络也不需要编译器：铺配置、写 shell 集成、
#               记安装清单、从发布分卷部署、卸载
#
# 为什么 build 要直接写进 $HOME 而不是先做个 staging：
#   lazy / mason / nvim 的安装位置都是从 XDG 和可执行文件位置推出来的，
#   想重定向得同时骗过三个工具，脆而且没必要。所以 build 就地生产，
#   install 负责"登记 + 收尾"。
#
# 由 `wtool build astronvim_v5` 调用，也可以直接跑。容器里也是它。
#
# 用法：
#   scripts/build.sh [--nvim-src=DIR] [--nvim-ref=REF] [--build-dir=DIR]
#            [--prefix=DIR] [--jobs=N] [--no-deps] [--dry-run]
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
NVIM_SRC=""
NVIM_REF=""
NVIM_BUILD_DIR=""
PREFIX=""
JOBS=""
NO_DEPS=0
DRY_RUN=${WTOOL_DRY_RUN:-0}

while [ $# -gt 0 ]; do
    case $1 in
        --nvim-src=*)  NVIM_SRC=${1#--nvim-src=} ;;
        --nvim-ref=*)  NVIM_REF=${1#--nvim-ref=} ;;
        --build-dir=*) NVIM_BUILD_DIR=${1#--build-dir=} ;;
        --prefix=*)    PREFIX=${1#--prefix=} ;;
        --jobs=*)      JOBS=${1#--jobs=} ;;
        --no-deps)     NO_DEPS=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     sed -n '2,26p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "未知参数: $1（--help 看用法）" ;;
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
# 只保证清单文件存在，不清空——install.sh 也会往里追加
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
# --------------------------------------------------------------------------
# install_deps
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
    #
    # 两个细节都是踩过坑才加的：
    #   * 重试一次。代理后面网络抖一下很常见，实测有一批整个失败、
    #     紧接着手工跑同样的命令却一次成功。
    #   * 失败时必须把 apt 的输出露出来。原来 >/dev/null 2>&1 吞掉错误，
    #     只留一句"这批没装上"，只能靠猜——白白浪费一轮几十分钟的构建。
    #   * DPkg::Lock::Timeout：并发或上一批的触发器还没收尾时，
    #     让 apt 等锁而不是直接报失败。
    #   * Acquire::*::Timeout / Retries：**这条是后来补的，代价是浪费了一整轮构建**。
    #     原来只写了"失败就重试"，但 apt 默认没有下载超时 ——
    #     代理后面的连接**停滞**不算失败，apt 会一直挂着等，
    #     重试和换源那段代码永远轮不到执行。
    #     实测一批包挂了 20 分钟、一个字节都没下，进程还在。
    #     加上超时，"卡住"就会变成"失败"，退路逻辑才真正生效。
    _apt() {
        if [ "$DRY_RUN" = 1 ]; then step "[dry-run] apt-get install $*"; return 0; fi
        _aptlog="$STATE_DIR/.apt.log"
        _try=0
        while [ "$_try" -lt 2 ]; do
            _try=$((_try + 1))
            if DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    --no-install-recommends -o DPkg::Lock::Timeout=120 \
                    -o Acquire::http::Timeout=20 \
                    -o Acquire::https::Timeout=20 \
                    -o Acquire::Retries=3 "$@" \
                    >"$_aptlog" 2>&1; then
                return 0
            fi
            if [ "$_try" -lt 2 ]; then
                warn "这批没装上（可能是下载停滞、20s 超时已触发），10 秒后换源重试: $*"
                sleep 10
                # 直接强制换源：索引好不代表包能下来，别再问 update 的意见
                _apt_switch_mirror
            fi
        done
        warn "这批最终没装上: $*"
        warn "apt 最后的输出："
        tail -15 "$_aptlog" 2>/dev/null | sed 's/^/    /' >&2
        # 这里原来是"继续，但后面可能出错"。那是错的：
        # 缺了编译器/解释器，错误会在十分钟后以一句看不懂的
        # 编译报错冒出来，没人能从那句话倒推回"其实是 apt 没装上"。
        # 现在直接死在这里，错因就在眼前。
        die "构建依赖没装上，无法继续：$*"
    }

    # 换源退路：宿主代理走 archive.ubuntu.com / security.ubuntu.com 经常 502
    # （实测只有 171 kB/s，还会整批失败）。第一轮失败就换国内镜像重来。
    _apt_mirror=${WTOOL_APT_MIRROR:-http://mirrors.ustc.edu.cn/ubuntu}
    _apt_prepare() {
        if [ "$DRY_RUN" = 1 ]; then return 0; fi
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq \
            -o Acquire::http::Timeout=20 \
            -o Acquire::https::Timeout=20 \
            -o Acquire::Retries=3 >/dev/null 2>&1 && return 0
        [ "$_apt_switched" = 1 ] && return 1
        _apt_switch_mirror
    }

    # 真正换源。必须能**被强制调用**：
    # 索引（apt-get update）好好的、坏的是**包下载**，这种情况
    # _apt_prepare 会认为"源没问题"而拒绝换源，于是重试还是走同一个
    # 卡死的源，白等一轮。所以 _apt 重试时直接调这个，不问 update 的意见。
    _apt_switch_mirror() {
        [ "$_apt_switched" = 1 ] && return 0
        warn "换成国内镜像重试: $_apt_mirror"
        _apt_switched=1
        . /etc/os-release 2>/dev/null || true
        mkdir -p /etc/apt/sources.list.d

        # 关键：让 apt 访问国内镜像时**不要走代理**。
        # 容器里 HTTP_PROXY 是设着的，apt 默认对所有 http 都走它 ——
        # 于是请求 mirrors.ustc.edu.cn 也被塞进 127.0.0.1:7897，
        # 实测报 `502 Bad Gateway [IP: 127.0.0.1 7897]`。
        # 国内镜像本来就是直连最快，绕代理只会又慢又容易断。
        # no_proxy 里要放主机名（IP 是 127.0.0.1 那种，跟镜像无关）。
        _mhost=$(printf '%s' "$_apt_mirror" | sed -e 's|^[a-z]*://||' -e 's|/.*$||')
        if [ -n "$_mhost" ]; then
            for _v in no_proxy NO_PROXY; do
                eval "_cur=\${$_v:-}"
                case ",$_cur," in
                    *",$_mhost,"*) ;;
                    *) export "$_v=${_cur:+$_cur,}$_mhost" ;;
                esac
            done
            # apt 自己也认这个配置，双保险（apt 对 no_proxy 的处理各版本不一）
            mkdir -p /etc/apt/apt.conf.d
            printf 'Acquire::http::Proxy::%s "DIRECT";\n' "$_mhost" \
                > /etc/apt/apt.conf.d/99wtool-noproxy
        fi
        # 用一行式格式。**注意：不是因为 focal 不认 deb822。**
        # 我原先在这里写"20.04 的 apt 2.0 不认 deb822"，那是错的 ——
        # 实测 focal 的 apt 2.0.10 完全读得懂 .sources（deb822 支持在
        # apt 1.1 就有了，2.4 变的只是默认值）。
        # 真正踩到的坑是：同一个 URI 出现**两份**配置文件、Signed-By 不一致时，
        # apt 会拒绝读取整份源列表：
        #   E: Conflicting values set for option Signed-By regarding source ...
        # 表现是 apt 彻底瘫痪，连"包不存在"都报不出来。
        # 一行式在这里更省事：不容易和别人写的 .sources 撞车。
        cat > /etc/apt/sources.list.d/wtool-mirror.list <<EOF
deb $_apt_mirror/ ${VERSION_CODENAME} main restricted universe multiverse
deb $_apt_mirror/ ${VERSION_CODENAME}-updates main restricted universe multiverse
deb $_apt_mirror/ ${VERSION_CODENAME}-backports main restricted universe multiverse
deb $_apt_mirror/ ${VERSION_CODENAME}-security main restricted universe multiverse
EOF
        # 镜像自带的是 ubuntu.sources（不是 .list），必须一起删 ——
        # 只删 .list 的话那个 502 的源还挂着，update 照样失败
        for _f in /etc/apt/sources.list.d/*; do
            case $_f in
                */wtool-mirror.list) ;;
                *) rm -f -- "$_f" 2>/dev/null || true ;;
            esac
        done
        rm -f /etc/apt/sources.list 2>/dev/null || true
        apt-get update -qq \
            -o Acquire::http::Timeout=20 \
            -o Acquire::https::Timeout=20 \
            -o Acquire::Retries=3 >/dev/null 2>&1
    }
    _apt_switched=0
    _apt_prepare || warn "apt-get update 失败（继续，可能用不了）"

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
# build_nvim
# --------------------------------------------------------------------------
build_nvim() {
    _src=$NVIM_SRC
    if [ -z "$_src" ]; then
        # 默认找同级目录下的 nvim（repo sync 出来的位置）
        if [ -d "$PROJECT_DIR/nvim" ] && [ -n "$(ls -A "$PROJECT_DIR/nvim" 2>/dev/null)" ]; then
            _src=$PROJECT_DIR/nvim
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
    # nvim 的构建**必须先编它的 cmake.deps**（会联网拉 luajit/libuv/msgpack…）。
    # 直接 `cmake -S . -B build` 会报 "Failed to find a Lua 5.1-compatible
    # interpreter" —— 这个错我踩过两次，第一次只修了自己的测量脚本，
    # 没回头修这里。用 nvim 自己的 Makefile 最稳，它会把 deps 那一步带上。
    #
    # 而且工作区是**只读挂载**的，make 会往源码树里写 .deps/ 和 build/，
    # 所以先把源码复制到可写的地方。
    _bld_src=$HOME_DIR/.cache/astronvim_v5/nvim-src
    _bld=${NVIM_BUILD_DIR:-$HOME_DIR/.cache/astronvim_v5/nvim-build}

    if [ "$DRY_RUN" = 1 ]; then
        step "[dry-run] cp -a $_src $_bld_src   # 源码树是只读挂载，复制出来才能编"
        step "[dry-run] make -C $_bld_src -j$JOBS CMAKE_BUILD_TYPE=Release CMAKE_EXTRA_FLAGS=-DCMAKE_INSTALL_PREFIX=$PREFIX"
        step "[dry-run] make -C $_bld_src install"
        step "[dry-run] 之后记入清单: .local/bin/nvim .local/share/nvim"
        return 0
    fi

    [ -d "$_src" ] || die "nvim 源码目录不存在: $_src"
    # 容器里是 root、源码在只读挂载上属于别人，git 会以"属主不一致"拒绝。
    # 拿版本号前先放行（container-shell.sh 里也是这么干的）。
    git config --global --add safe.directory '*' 2>/dev/null || true
    _ref=$(git -C "$_src" rev-parse HEAD 2>/dev/null || echo unknown)
    say "编译 nvim（源码 $_src @ $(printf '%s' "$_ref" | cut -c1-10)，-j$JOBS）"

    have cmake || die "没有 cmake，装不了 nvim"
    _src_real=$(cd -- "$_src" && pwd)
    case $_src_real in
        "$_bld_src") ;;
        *)  say "  复制源码到可写位置: $_bld_src"
            rm -rf -- "$_bld_src"
            mkdir -p -- "$(dirname -- "$_bld_src")"
            cp -a -- "$_src_real" "$_bld_src" || die "复制源码失败"
            ;;
    esac
    _bld=$_bld_src/build

    have make || die "没有 make，装不了 nvim"
    ( cd -- "$_bld_src" && make -j"$JOBS" CMAKE_BUILD_TYPE=Release \
        CMAKE_EXTRA_FLAGS="-DCMAKE_INSTALL_PREFIX=$PREFIX" ) >/dev/null \
        || die "nvim 编译失败"
    ( cd -- "$_bld_src" && make install ) >/dev/null || die "nvim 安装失败"

    manifest_add payload ".local/bin/nvim"
    [ -d "$XDG_DATA/nvim" ] && manifest_add payload ".local/share/nvim"
    [ -d "$PREFIX/lib/nvim" ] && manifest_add payload ".local/lib/nvim"

    "$PREFIX/bin/nvim" --version 2>/dev/null | head -1 | sed 's/^/astronvim_v5:   /' || true
}
# --------------------------------------------------------------------------
# install_config
# --------------------------------------------------------------------------
install_config() {
    say "铺配置到 $CONFIG_DIR"
    _src="$PROJECT_DIR/astronvim_v5_config"
    [ -d "$_src" ] || die "找不到配置目录: $_src（应该是本仓的子目录）"
    if [ "$DRY_RUN" = 1 ]; then step "[dry-run] 复制 $_src → $CONFIG_DIR"; return 0; fi
    mkdir -p -- "$CONFIG_DIR"
    # 用 -a 保时间戳；不要 --delete，用户可能有自己的调试文件
    ( cd -- "$_src" && tar --exclude='.git' -cf - . ) | ( cd -- "$CONFIG_DIR" && tar -xf - )
    manifest_add payload ".config/$APPNAME"
}
# --------------------------------------------------------------------------
# install_plugins
# --------------------------------------------------------------------------
install_plugins() {
    say "装 lazy 插件（按 lazy-lock.json 钉住的版本）"
    # 查**源**配置目录里的 lock，不是已经铺过去的目标目录：
    # dry-run 下目标目录还没建，查那边会误报"没有 lazy-lock.json"
    _lock="$PROJECT_DIR/astronvim_v5_config/lazy-lock.json"
    if [ -f "$_lock" ]; then
        step "插件 $(grep -c '"branch"' "$_lock" 2>/dev/null || echo '?') 个，版本已锁定"
    else
        warn "源配置里没有 lazy-lock.json，插件版本会漂"
    fi
    if [ "$DRY_RUN" = 1 ]; then
        step "[dry-run] Lazy! restore"
    else
        # 第一次跑会把 lazy.nvim 自己 clone 下来（init.lua 里做的事），
        # 所以先裸跑一次让引导完成，再 restore。
        NVIM_APPNAME=$APPNAME XDG_CONFIG_HOME=$XDG_CONFIG_REAL XDG_DATA_HOME=$XDG_DATA_REAL "$PREFIX/bin/nvim" --headless -c 'qa!' >/dev/null 2>&1 || true
        NVIM_APPNAME=$APPNAME XDG_CONFIG_HOME=$XDG_CONFIG_REAL XDG_DATA_HOME=$XDG_DATA_REAL "$PREFIX/bin/nvim" --headless \
            -c 'Lazy! restore' -c 'qa!' >/dev/null 2>&1 || warn "Lazy restore 返回非 0（继续）"
        NVIM_APPNAME=$APPNAME XDG_CONFIG_HOME=$XDG_CONFIG_REAL XDG_DATA_HOME=$XDG_DATA_REAL "$PREFIX/bin/nvim" --headless \
            -c 'Lazy! restore' -c 'qa!' >/dev/null 2>&1 || true
    fi
    manifest_add payload ".local/share/$APPNAME"
}
# --------------------------------------------------------------------------
# install_mason
# --------------------------------------------------------------------------
install_mason() {
    say "装 mason 包（清单 mason-packages.txt；mason 不支持锁版本）"
    _list="$PROJECT_DIR/mason-packages.txt"
    if [ ! -f "$_list" ]; then warn "没有 mason-packages.txt，跳过"; return 0; fi

    _names=$(grep -v '^#' "$_list" | grep -v '^$' | tr '\n' ' ')
    _n=$(printf '%s' "$_names" | wc -w)
    say "  共 $_n 个包，这一步最慢（按清单里实际数量，不是写死的总量）"

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
    NVIM_APPNAME=$APPNAME XDG_CONFIG_HOME=$XDG_CONFIG_REAL XDG_DATA_HOME=$XDG_DATA_REAL "$PREFIX/bin/nvim" --headless \
        -c "luafile $STATE_DIR/.mason-install.lua" >/dev/null 2>&1 \
        || warn "mason 批量安装返回非 0（继续）"
    rm -f -- "$STATE_DIR/.mason-install.lua"

    if [ -f "$STATE_DIR/mason-failed.txt" ]; then
        _nf=$(grep -c . "$STATE_DIR/mason-failed.txt" || true)
        warn "$_nf 个 mason 包装失败（清单见 $STATE_DIR/mason-failed.txt，不影响其余的）"
    fi
}
# --------------------------------------------------------------------------
# install_treesitter
# --------------------------------------------------------------------------
install_treesitter() {
    _list="$PROJECT_DIR/treesitter-parsers.txt"
    if [ ! -f "$_list" ]; then warn "没有 treesitter-parsers.txt，跳过"; return 0; fi
    _names=$(grep -v '^#' "$_list" | grep -v '^$' | tr '\n' ' ')
    # 数量从清单现算。原来这里写死"251 个"，清单减到 15 之后
    # 它还在喊 251 —— 日志说谎比没日志更坏，会让人以为漏跑了什么。
    say "编译 treesitter parser（$(printf '%s\n' $_names | wc -l | tr -d ' ') 个，最耗时的一步）"

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
    NVIM_APPNAME=$APPNAME XDG_CONFIG_HOME=$XDG_CONFIG_REAL XDG_DATA_HOME=$XDG_DATA_REAL "$PREFIX/bin/nvim" --headless \
        -c "luafile $STATE_DIR/.ts-install.lua" >/dev/null 2>&1 \
        || warn "treesitter 安装返回非 0（单个 parser 失败不致命，继续）"
    rm -f -- "$STATE_DIR/.ts-install.lua"

    _have=$(find "$DATA_DIR/lazy/nvim-treesitter/parser" -name '*.so' 2>/dev/null | wc -l)
    say "  现在有 $_have 个 parser（清单里 $(printf '%s\n' $_names | wc -l | tr -d ' ') 个）"
}

# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------
main() {
    say "模式     : build"
    say "HOME     : $HOME_DIR"
    say "前缀     : $PREFIX"
    say "本机系统 : $HOST_TARGET"
    say "并发     : $JOBS"

    [ "$DRY_RUN" = 0 ] && mkdir -p -- "$STATE_DIR"
    # 清单是 append 的：install.sh 也会往里写（shell 集成那几条），
    # 所以这里不能重置，只能保证文件存在
    [ "$DRY_RUN" = 0 ] && [ -f "$MANIFEST" ] || manifest_touch

    install_deps
    build_nvim
    install_config
    install_plugins
    install_mason
    install_treesitter

    if [ "$DRY_RUN" = 0 ]; then
        printf 'build_at\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$STATE_DIR/build.txt"
        printf 'target\t%s\n' "$HOST_TARGET" >> "$STATE_DIR/build.txt"
        printf 'nvim\t%s\n' "$("$PREFIX/bin/nvim" --version 2>/dev/null | head -1 || echo unknown)"             >> "$STATE_DIR/build.txt"
    fi

    say ""
    say "构建完成。下一步：wtool install astronvim_v5"
    say "（或直接跑 "$HERE/install.sh"）"
}

main
