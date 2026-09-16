#!/bin/sh
# publish.sh —— 把 astronvim_v5 打成可分发的发布包
#
# 它是 wtool.xml 里 <publish kind="script" script="publish.sh"/> 指的那个脚本。
# wtool publish 会带着这些环境变量调它：
#   WTOOL_PUBLISH_PROJECT  项目 id
#   WTOOL_PUBLISH_ROOT     项目目录
#   WTOOL_PUBLISH_WS       wtool 工作区根
#   WTOOL_PUBLISH_REPO     目标仓 owner/repo
#   WTOOL_PUBLISH_TAG      release tag
#   WTOOL_PUBLISH_OUT      产物目录（引擎负责把这个目录里的文件传上去）
# 全部都有默认值，所以也能脱开 wtool 直接跑：   ./publish.sh --target=ubuntu-24.04
#
# 它做的事：
#   1. 问你要哪个目标系统（glibc 单向兼容，一个包通吃不了）
#   2. docker pull 对应镜像
#   3. 起容器，把工作区**只读**挂进去，在容器里跑 scripts/build.sh + scripts/install.sh
#      —— 装到容器的 $HOME 下，不是你的 $HOME
#   4. 按 install.sh 写的安装清单把容器的 $HOME 薅出来
#      （清单驱动，不靠猜：猜漏一个文件，到了公司机器上是启动报错，
#        而且报得莫名其妙，很难归因）
#   5. 分卷 + 写 dist.json
#   6. 产物留在 $WTOOL_PUBLISH_OUT，由 wtool 上传到本仓 release
#
# 为什么要在容器里跑：nvim 是半静态链接（ldd 只剩 libc/libm/libgcc_s），
# 唯一的外部依赖就是 glibc，而 glibc 只保证向前兼容。在 ubuntu:24.04 里编，
# 就只能在 >= 24.04 的机器上跑；要给 22.04 用就得在 22.04 的镜像里编。
# 这就是"目标系统"必须问出来的原因。
set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)          # = <项目>/scripts
PROJECT_DIR=$(cd -- "$HERE/.." && pwd)             # = <项目>

# 默认值：脱开 wtool 也能直接跑
WTOOL_PUBLISH_PROJECT=${WTOOL_PUBLISH_PROJECT:-editor/astronvim_v5}
WTOOL_PUBLISH_ROOT=${WTOOL_PUBLISH_ROOT:-$HERE}
WTOOL_PUBLISH_WS=${WTOOL_PUBLISH_WS:-$(cd -- "$PROJECT_DIR/../.." && pwd)}
WTOOL_PUBLISH_OUT=${WTOOL_PUBLISH_OUT:-${TMPDIR:-/tmp}/astronvim_v5-release}
WTOOL_PUBLISH_REPO=${WTOOL_PUBLISH_REPO:-allinkernel/wtool-astronvim_v5}
WTOOL_PUBLISH_TAG=${WTOOL_PUBLISH_TAG:-snapshot-$(date +%Y-%m-%d)}
WTOOL_PUBLISH_DATE=${WTOOL_PUBLISH_DATE:-$(date +%Y-%m-%d)}

# 引擎调脚本时不会传命令行参数，所以这几个也从环境变量兜底：
#   WTOOL_PUBLISH_TARGET=ubuntu-24.04 wtool publish astronvim_v5
TARGET=${WTOOL_PUBLISH_TARGET:-}
IMAGE=${WTOOL_PUBLISH_IMAGE:-}
NVIM_REF=${WTOOL_PUBLISH_NVIM_REF:-}
VOLUME_SIZE=${VOLUME_SIZE:-300M}
KEEP=0
DRY_RUN=0
NO_CACHE=0
SOURCE_ONLY=0
NETWORK=""

say()  { printf 'publish: %s\n' "$*"; }
warn() { printf 'publish: 警告: %s\n' "$*" >&2; }
die()  { printf 'publish: 错误: %s\n' "$*" >&2; exit 1; }
step() { printf 'publish:   - %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
    case $1 in
        --target=*)   TARGET=${1#--target=} ;;
        --image=*)    IMAGE=${1#--image=} ;;
        --nvim-ref=*) NVIM_REF=${1#--nvim-ref=} ;;
        --volume-size=*) VOLUME_SIZE=${1#--volume-size=} ;;
        --repo=*)     WTOOL_PUBLISH_REPO=${1#--repo=} ;;
        --tag=*)      WTOOL_PUBLISH_TAG=${1#--tag=} ;;
        --out=*)      WTOOL_PUBLISH_OUT=${1#--out=} ;;
        --keep)       KEEP=1 ;;
        --source-only) SOURCE_ONLY=1 ;;
        --network=*)  NETWORK=${1#--network=} ;;
        --no-cache)   NO_CACHE=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "未知参数: $1（--help 看用法）" ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# 0. 前置检查
# --------------------------------------------------------------------------
say "项目     : $WTOOL_PUBLISH_PROJECT"
say "工作区   : $WTOOL_PUBLISH_WS"
say "产物目录 : $WTOOL_PUBLISH_OUT"
say "目标仓   : $WTOOL_PUBLISH_REPO"
say "tag      : $WTOOL_PUBLISH_TAG"

[ -d "$WTOOL_PUBLISH_ROOT" ] || die "项目目录不存在: $WTOOL_PUBLISH_ROOT"
[ -x "$WTOOL_PUBLISH_ROOT/scripts/install.sh" ] \
    || die "找不到 scripts/install.sh（脚本都住在 scripts/ 下）"
[ -x "$WTOOL_PUBLISH_ROOT/scripts/build.sh" ] \
    || die "找不到 scripts/build.sh"
[ -f "$WTOOL_PUBLISH_ROOT/astronvim_v5_config/lazy-lock.json" ] \
    || warn "配置仓里没有 lazy-lock.json，插件版本会漂"

# --------------------------------------------------------------------------
# 0.5 本项目自己的源码包
#
# 不管后面 docker 那步做不做，先把本仓的源码打出来。理由：伞项目自己的
# install.sh / publish.sh / wtool.xml 都在这个仓里，缺了它，
# "把各仓的 release 下载下来拼成工作区"这件事就拼不全——
# 缺的恰好是串起整棵树的那一环。
#
# 包的结构和引擎打的一样（第一层 wtool/ + .wtool-dist 标记），
# 这样解压出来的路径和 repo sync 一致，wtool 也认得出这个项目。
# --------------------------------------------------------------------------
pack_own_source() {
    _rel=${WTOOL_PUBLISH_PROJECT:-editor/astronvim_v5}
    _asset=$(printf '%s' "$_rel" | tr '/' '-')
    _out="$OUT/${_asset}-${WTOOL_PUBLISH_DATE}-src.tar.gz"

    say "打本项目源码包 → $(basename "$_out")"
    if [ "$DRY_RUN" = 1 ]; then
        step "[dry-run] git archive --prefix=wtool/$_rel/ HEAD | gzip > $_out"
        return 0
    fi

    _commit=$(git -C "$WTOOL_PUBLISH_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    [ -n "$_commit" ] || die "$WTOOL_PUBLISH_ROOT 不是 git 仓库，打不出源码包"
    _dirty=false
    [ -n "$(git -C "$WTOOL_PUBLISH_ROOT" status --porcelain 2>/dev/null)" ] && _dirty=true

    # 用 git archive 而不是 tar 目录，因为本目录里**嵌套着两个独立项目**
    # （nvim/ 和 astronvim_v5_config/，manifest 里各自是单独的 project）。
    # tar 会把它们整个卷进来——nvim/ 一旦 repo sync 下来就是整个 neovim
    # 源码树，伞项目的包会白白涨到几百兆，而且和别人自己的包重复。
    # git archive 只打本仓跟踪的文件，天然把它们排除掉（.gitignore 里也列了）。
    # 顺带：它按原样保存符号链接，不会像 tar --transform 那样改写指向。
    _stage=$(mktemp -d "${TMPDIR:-/tmp}/astro-src.XXXXXX")
    git -C "$WTOOL_PUBLISH_ROOT" archive --format=tar \
        --prefix="wtool/$_rel/" HEAD > "$_stage/base.tar" || {
        rm -rf -- "$_stage"; die "git archive 失败"
    }

    # 发布标记：解压出来的工作区靠它认人
    mkdir -p -- "$_stage/.wtool-dist"
    cat > "$_stage/.wtool-dist/${_asset}.json" <<EOF
{
  "project": "$_rel",
  "repo": "$WTOOL_PUBLISH_REPO",
  "commit": "$_commit",
  "dirty": $_dirty,
  "packed_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "view": "release",
  "layout": "wtool/$_rel"
}
EOF
    tar -C "$_stage" --transform='s|^|wtool/|S' --sort=name \
        --numeric-owner --owner=0 --group=0 -rf "$_stage/base.tar" .wtool-dist \
        || { rm -rf -- "$_stage"; die "追加发布标记失败"; }
    gzip -6 -c "$_stage/base.tar" > "$_out" || { rm -rf -- "$_stage"; die "压缩失败"; }
    rm -rf -- "$_stage"
    step "$(basename "$_out")  $(($(wc -c < "$_out") / 1024))K"
}

# 源码包先打，而且要在 docker 检查和"问目标系统"之前——
# --source-only 本来就不需要 docker，更没理由被问目标系统。
mkdir -p -- "$WTOOL_PUBLISH_OUT"
OUT=$(cd -- "$WTOOL_PUBLISH_OUT" && pwd)
pack_own_source
if [ "$SOURCE_ONLY" = 1 ]; then
    say ""
    say "--source-only：只出源码包，不起 docker"
    ls -la "$OUT" | tail -n +2 | sed 's/^/  /'
    exit 0
fi

# 分清两种情况，它们的处理完全不同：
#   环境不具备（没装 docker / 连不上 daemon）—— 源码包已经打好了，照样交出去，
#       并且大声说清楚缺的是什么，免得让人以为 payload 也有了
#   跑了但坏了（编译失败、薅产物失败）—— 那是真失败，非 0 退出，别上传半成品
# 所以这里只是 warn + 提前收工，不是 die。
if [ "$DRY_RUN" = 0 ]; then
    _no_docker=""
    have docker || _no_docker="没装 docker"
    if [ -z "$_no_docker" ] && ! docker info >/dev/null 2>&1; then
        _no_docker="连不上 docker daemon（在 docker 组之外？先 newgrp docker 或重登一次）"
    fi
    if [ -n "$_no_docker" ]; then
        warn "$_no_docker，做不了 payload 分卷包。"
        warn "这次只会发出本项目自己的源码包（install.sh / publish.sh / wtool.xml）。"
        warn "装好 docker 之后用同一个 tag 重跑，就会补上分卷包。"
        say ""
        say "产物：$OUT"
        ls -la "$OUT" | tail -n +2 | sed 's/^/  /'
        exit 0
    fi
fi

# --------------------------------------------------------------------------
# 1. 目标系统
# --------------------------------------------------------------------------
# 从 wtool.xml 的 <publish><target> 里读候选项；读不到就用内置的两个
targets_from_manifest() {
    python3 - "$WTOOL_PUBLISH_ROOT/wtool.xml" <<'PY' 2>/dev/null || true
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
for pub in root.iter("publish"):
    for t in pub.findall("target"):
        os_id, ver = t.get("os", ""), t.get("version", "")
        if os_id and ver:
            print("%s-%s\t%s\t%s" % (os_id, ver, t.get("codename") or "-", t.get("image") or ""))
PY
}

TARGETS=$(targets_from_manifest)
# 读不到就用内置的两个（注意是 printf 出的真制表符，字面 \t 会让 awk -F'\t' 匹配不上）
[ -n "$TARGETS" ] || TARGETS=$(printf 'ubuntu-24.04\tnoble\t\nubuntu-22.04\tjammy\t\n')

image_for_target() {
    _t=$1
    printf '%s\n' "$TARGETS" | awk -F'\t' -v w="$_t" '$1 == w { print $3; exit }'
}

if [ -z "$TARGET" ]; then
    # 没有终端还硬要问，就会把空答案当默认值用——自动化里这是"猜错了才知道"，
    # 而猜错的代价是打出一个在目标机上跑不起来的包。宁可在这里停下。
    if [ ! -t 0 ]; then
        warn "stdin 不是终端，没法问你要哪个目标系统"
        say  "请显式指定：publish.sh --target=ubuntu-24.04"
        printf '可选：\n'
        printf '%s\n' "$TARGETS" | awk -F'\t' 'NF {printf "  %s\n", $1}'
        exit 2
    fi
    echo
    say "要给哪个系统打包？（glibc 单向兼容，编出来的包只能在 >= 这个版本的机器上跑）"
    _i=0
    printf '%s\n' "$TARGETS" | while IFS='	' read -r _t _code _img; do
        [ -n "$_t" ] || continue
        _i=$((_i + 1))
        _host=""
        if [ -r /etc/os-release ]; then
            _h=$(. /etc/os-release && printf '%s-%s' "$ID" "$VERSION_ID")
            [ "$_h" = "$_t" ] && _host="   <- 本机就是这个"
        fi
        printf '  %d) %-16s %s%s\n' "$_i" "$_t" "${_code:-}" "$_host"
    done
    printf '选择 [1]: '
    read -r _choice || _choice=""
    [ -n "$_choice" ] || _choice=1
    TARGET=$(printf '%s\n' "$TARGETS" | sed -n "${_choice}p" | cut -f1)
    [ -n "$TARGET" ] || die "选择无效: $_choice"
fi

if [ -z "$IMAGE" ]; then
    IMAGE=$(image_for_target "$TARGET")
    [ -n "$IMAGE" ] || IMAGE="ubuntu:${TARGET#*-}"
fi

say "目标系统 : $TARGET"
say "镜像     : $IMAGE"

# --------------------------------------------------------------------------
# 2. nvim 源码
# --------------------------------------------------------------------------
NVIM_SRC_HOST="$WTOOL_PUBLISH_ROOT/nvim"
if [ -d "$NVIM_SRC_HOST" ] && [ -n "$(ls -A "$NVIM_SRC_HOST" 2>/dev/null)" ]; then
    say "nvim 源码 : $NVIM_SRC_HOST（工作区里的）"
    _nvim_args="--nvim-src=/wtool/editor/astronvim_v5/nvim"
else
    warn "工作区里没有 nvim 源码（$NVIM_SRC_HOST 是空的）"
    warn "先 repo sync 把 editor/astronvim_v5/nvim 拉下来；"
    warn "或者用 --nvim-ref=<commit> 让容器自己克隆（禁止浮动分支）"
    if [ -z "$NVIM_REF" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            warn "dry-run 先按 --nvim-ref=<未指定> 描述计划；真跑之前必须给出来"
            _nvim_args="--nvim-ref=<必须指定>"
        else
            die "没有 nvim 源码就必须给 --nvim-ref=<commit>"
        fi
    else
        _nvim_args="--nvim-ref=$NVIM_REF"
    fi
fi

if [ "$DRY_RUN" = 1 ]; then
    say ""
    say "[dry-run] 接下来会做："
    step "docker pull $IMAGE"
    step "docker run -d --name <ctr> [--network=host] -v $WTOOL_PUBLISH_WS:/wtool:ro $IMAGE sleep infinity"
    step "docker exec <ctr> /wtool/editor/astronvim_v5/scripts/build.sh $_nvim_args"
    step "docker exec <ctr> /wtool/editor/astronvim_v5/scripts/install.sh --no-shell"
    step "docker cp <ctr>:/root/... 按安装清单薅出来"
    step "分卷 $VOLUME_SIZE → $WTOOL_PUBLISH_OUT"
    exit 0
fi

mkdir -p -- "$WTOOL_PUBLISH_OUT"
OUT=$(cd -- "$WTOOL_PUBLISH_OUT" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/astro-publish.XXXXXX")
CTR="astro-build-$$"

cleanup() {
    if [ "$KEEP" = 1 ]; then
        warn "保留容器 $CTR 和目录 $WORK（--keep），调试完自己删：docker rm -f $CTR"
    else
        docker rm -f "$CTR" >/dev/null 2>&1 || true
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# 3. 起容器
# --------------------------------------------------------------------------
# 镜像已经在本地就不拉 —— 网络断的时候 docker pull 会直接失败，
# 而本地明明有能用的镜像。先查再拉。
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    say "镜像 $IMAGE 已在本地，跳过拉取"
else
    say "拉镜像 $IMAGE"
    docker pull "$IMAGE" >/dev/null || die "拉镜像失败: $IMAGE（本地没有，网络也不通）"
fi

# 网络模式。这里有个很容易踩的坑：
#   宿主机的代理通常是 http://127.0.0.1:7897，而 **容器里的 127.0.0.1
#   指的是容器自己**。直接 -e HTTP_PROXY 透传，容器里所有下载都会失败，
#   而且报的是"连接被拒绝"这种看不出根因的错。
#   --network=host 让容器共享宿主网络命名空间，127.0.0.1 就真的是宿主了。
if [ -z "$NETWORK" ]; then
    NETWORK=bridge
    for _v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy; do
        eval "_pv=\${$_v:-}"
        case $_pv in
            *127.0.0.1*|*localhost*|*"[::1]"*)
                NETWORK=host
                say "代理指向本机（$_pv），容器改用 --network=host（否则容器里的 127.0.0.1 是它自己）"
                break ;;
        esac
    done
fi
_net_args=""
[ "$NETWORK" != "bridge" ] && _net_args="--network=$NETWORK"

say "起容器 $CTR（网络：$NETWORK）"
# 工作区只读挂载：容器绝不能改你的工作区。install.sh 是树外构建，
# 就是为了这个（cmake 默认会把 build 写在源码树里）。
# shellcheck disable=SC2086
docker run -d --name "$CTR" $_net_args \
    -v "$WTOOL_PUBLISH_WS:/wtool:ro" \
    -e HTTP_PROXY -e HTTPS_PROXY -e http_proxy -e https_proxy \
    -e NO_PROXY -e no_proxy -e ALL_PROXY -e all_proxy \
    "$IMAGE" sleep infinity >/dev/null || {
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    die "起容器失败"
}

# 注：safe.directory 不在这里设 —— 此刻容器里还没装 git（镜像是干净的），
# 设了必然静默失败。build.sh 会在装完依赖之后自己设一次。
_proxy_note=""
for _v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    eval "_pv=\${$_v:-}"
    [ -n "$_pv" ] && _proxy_note="$_proxy_note $_v"
done
if [ -n "$_proxy_note" ]; then
    say "透传 proxy 变量:$_proxy_note"
else
    warn "没有检测到 proxy 环境变量。容器里下载 GitHub 会很慢或者失败，"
    warn "先 export HTTPS_PROXY=... 再跑，或者给 docker 配好代理。"
fi

# --------------------------------------------------------------------------
# 4. 在容器里跑 install.sh
#
# 这一步可能几十分钟（编 nvim + 拉插件 + 装 mason 包 + 编 parser）。
# 具体数量从清单现算，不写死 —— 写死的数字改了清单就会说谎。
# 日志直接透到终端，不然卡住了看不出卡在哪。
# --------------------------------------------------------------------------
say ""
_npkg=$(grep -cvE '^[[:space:]]*(#|$)' "$HERE/../mason-packages.txt" 2>/dev/null || echo "?")
_npar=$(grep -cvE '^[[:space:]]*(#|$)' "$HERE/../treesitter-parsers.txt" 2>/dev/null || echo "?")
say "在容器里安装（这一步很久：编 nvim、拉插件、装 $_npkg 个 mason 包、编 $_npar 个 parser）"
say "------------------------------------------------------------------------"
# 容器里两步走：build.sh 生产（编 nvim、拉插件、装 mason、编 parser），
# install.sh 登记和收尾（写安装清单、shell 集成）。
# 顺序不能反，也不能合成一个脚本——install.sh 要能在没网没编译器的机器上跑。
if ! docker exec "$CTR" bash -lc \
        "cd /wtool/editor/astronvim_v5 && ./scripts/build.sh $_nvim_args && ./scripts/install.sh --no-shell"; then
    warn "容器里的 install.sh 失败了。"
    warn "用 --keep 重跑一次保住容器，然后进去看：docker exec -it $CTR bash"
    exit 1
fi
say "------------------------------------------------------------------------"

# --------------------------------------------------------------------------
# 5. 按清单把容器的 $HOME 薅出来
# --------------------------------------------------------------------------
MANIFEST_IN_CTR=/root/.local/state/astronvim_v5/install-manifest.tsv
say "读安装清单"
if ! docker cp "$CTR:$MANIFEST_IN_CTR" "$WORK/manifest.tsv" >/dev/null 2>&1; then
    die "容器里没有安装清单 $MANIFEST_IN_CTR —— install.sh 没跑到最后？"
fi

mkdir -p -- "$WORK/payload/home"
: > "$WORK/payload/OWNED.tsv"

_n=0
while IFS='	' read -r _kind _rel _rest; do
    case $_kind in
        ''|\#*) continue ;;
    esac
    [ "$_kind" = "payload" ] || continue
    [ -n "${_rel:-}" ] || continue
    case $_rel in
        /*|*..*) warn "清单里有可疑路径，跳过: $_rel"; continue ;;
    esac

    # nvim 自己的运行时和二进制可能落在 .local/bin、.local/share/nvim、
    # .local/lib/nvim，都在清单里逐条列着，照抄就行
    #
    # **必须先建目标父目录**：docker cp 不创建中间目录，目标目录不存在时
    # 它直接报 invalid output path: directory "..." does not exist。
    # 原来只 mkdir 了 payload/home 这一层，于是 .local/bin、.config 全都不存在，
    # 五条产物**一条都复制不出来**，最后死在"一条 payload 都没有"，
    # 看起来像"install.sh 没产出东西"，其实是复制这一步的用法错了。
    # （实测：目标父目录存在就成功，不存在就报上面那句。）
    mkdir -p -- "$(dirname -- "$WORK/payload/home/$_rel")" || {
        warn "建不出目标目录，跳过: $_rel"; continue; }
    if ! docker cp "$CTR:/root/$_rel" "$WORK/payload/home/$_rel" 2>"$WORK/.cp.err"; then
        warn "薅不出来: $_rel"
        sed 's/^/      /' "$WORK/.cp.err" 2>/dev/null | head -3 >&2
        continue
    fi
    printf 'payload\t%s\n' "$_rel" >> "$WORK/payload/OWNED.tsv"
    _n=$((_n + 1))
    step "$_rel"
done < "$WORK/manifest.tsv"

[ "$_n" -gt 0 ] || die "安装清单里一条 payload 都没有，包会是空的"

# 版本快照，方便比对两次构建的差异
docker cp "$CTR:/root/.local/state/astronvim_v5/versions.txt" "$WORK/payload/versions.txt" \
    >/dev/null 2>&1 || true
docker cp "$CTR:/root/.local/state/astronvim_v5/mason-versions.txt" "$WORK/payload/mason-versions.txt" \
    >/dev/null 2>&1 || true

say "薅出来 $_n 项"
# 大小心里有数：这里应该 1G 往上。如果只有几百 K，说明薅漏了。
_du=$(du -sh "$WORK/payload/home" 2>/dev/null | cut -f1)
say "产物体积 : $_du"
case $_du in
    [0-9]*K|[0-9]*M) warn "体积偏小（$_du），可能薅漏了东西，检查上面的清单" ;;
esac

# --------------------------------------------------------------------------
# 6. 分卷 + dist.json
# --------------------------------------------------------------------------
ASSET="astronvim_v5-${TARGET}-${WTOOL_PUBLISH_DATE}"
say "分卷（每卷 $VOLUME_SIZE）→ $ASSET-volNN"

_comp=zstd
if have zstd; then
    _packer="zstd -T0 -3 -q -c"
elif have gzip; then
    _packer="gzip -6 -c"; _comp=gzip
else
    _packer="cat"; _comp=none
fi

rm -f -- "$OUT/$ASSET-vol"*
( cd -- "$WORK/payload" && tar -cf - home OWNED.tsv versions.txt 2>/dev/null || tar -cf - home OWNED.tsv ) \
    | $_packer | split -b "$VOLUME_SIZE" -d -a 2 - "$OUT/$ASSET-vol" \
    || die "分卷失败"

# install.sh 和 dist.json 是给"只能浏览器下载"的机器用的：
# 少了它们，下载回来一堆分卷没人知道怎么铺
# 自包含包里放的就是仓库里这两份脚本（不是另写一套）：
# 公司那台机器下完解压，跑 ./download.sh --from=. 再 ./install.sh
cp -f -- "$WTOOL_PUBLISH_ROOT/scripts/install.sh" "$OUT/install.sh"
cp -f -- "$WTOOL_PUBLISH_ROOT/scripts/download.sh" "$OUT/download.sh" 2>/dev/null || true
chmod +x -- "$OUT/install.sh" "$OUT/download.sh" 2>/dev/null || true

python3 - "$OUT" "$ASSET" "$TARGET" "$_comp" "$WTOOL_PUBLISH_TAG" \
        "$WTOOL_PUBLISH_DATE" "$WTOOL_PUBLISH_REPO" > "$OUT/dist.json" <<'PY'
import glob, hashlib, json, os, sys

out, asset, target, comp, tag, date, repo = sys.argv[1:8]
vols = []
for path in sorted(glob.glob(os.path.join(out, asset + "-vol*"))):
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    vols.append({"name": os.path.basename(path), "sha256": h.hexdigest(), "bytes": size})

dist = {
    "project": "editor/astronvim_v5",
    "repo": repo,
    "tag": tag,
    "built_at": date,
    "target": target,
    "compression": comp,
    "volume_size": os.environ.get("VOLUME_SIZE", "300M"),
    "volumes": vols,
    "install": {
        "how": "把 install.sh、dist.json 和所有 -volNN 放在同一个目录，然后：bash install.sh",
        "note": "install.sh 会校验目标系统和每个分卷的 sha256，不匹配会明确报错而不是装出个坏环境",
    },
}
print(json.dumps(dist, indent=2, ensure_ascii=False))
sys.stderr.write("分卷 %d 个，共 %.1f MB\n" % (len(vols), sum(v["bytes"] for v in vols) / 1048576))
PY

# --------------------------------------------------------------------------
# 7. 收尾
# --------------------------------------------------------------------------
say ""
say "产物在 $OUT"
ls -la "$OUT" | sed 's/^/  /' | tail -n +2
say ""
say "这些文件会由 wtool publish 传到 $WTOOL_PUBLISH_REPO 的 $WTOOL_PUBLISH_TAG。"
say "如果你是自己跑的（没经过 wtool），上传就是："
say "  gh release create $WTOOL_PUBLISH_TAG --repo $WTOOL_PUBLISH_REPO --title 'astronvim_v5 $WTOOL_PUBLISH_DATE'"
say "  gh release upload $WTOOL_PUBLISH_TAG --repo $WTOOL_PUBLISH_REPO --clobber $OUT/*"
