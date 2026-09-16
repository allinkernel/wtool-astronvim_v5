#!/bin/sh
# download.sh —— 从发布页拿编好的 astronvim_v5，代替自己编
#
# 由 `wtool download astronvim_v5` 调用。和 scripts/build.sh 是**一对**：
#
#   build.sh     在容器里从源码编（nvim + 插件 + parser），半小时到几小时
#   download.sh  从 GitHub Release 拿别人编好的，解到**同样的位置**
#
# 两条路必须等价 —— 之后的 `wtool install` 完全不关心产物是编出来的
# 还是下下来的。产物位置（两边必须一致，改一个就得改另一个）：
#   .local/bin/nvim
#   .local/share/nvim
#   .local/lib/nvim
#   .config/astronvim_v5
#   .local/share/astronvim_v5
#
# 引擎保证的环境变量见 bootstrap/docs/spec.md；这里用到：
#   WTOOL_PROJECT_ID / WTOOL_ARTIFACTS / WTOOL_STATE_DIR
set -eu

PROJECT_ID=${WTOOL_PROJECT_ID:-editor/astronvim_v5}
ARTIFACTS=${WTOOL_ARTIFACTS:-${WTOOL_STATE_DIR:-$HOME/.local/state/wtool/$PROJECT_ID}/artifacts.tsv}
REPO=${WTOOL_DL_REPO:-allinkernel/wtool-astronvim_v5}
TAG=${WTOOL_DL_TAG:-snapshot-$(date +%Y-%m-%d)}
CACHE=${WTOOL_DL_CACHE:-${WTOOL_STATE_DIR:-$HOME/.local/state/wtool/$PROJECT_ID}/pkg}

say()  { printf '%s: %s\n' "$PROJECT_ID" "$*"; }
warn() { printf '%s: 警告: %s\n' "$PROJECT_ID" "$*" >&2; }
die()  { printf '%s: 错误: %s\n' "$PROJECT_ID" "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "需要 curl"

# --------------------------------------------------------------------------
# 0. 选 tag，拼出下载 URL。
#
# **不依赖 gh。** 原来这里用 `gh release download`，但 gh 在 Ubuntu 20.04
# 的官方源里根本没有（22.04 之后才进 universe），而 bootstrap 也不会装它 ——
# 于是"装完基础组件"和"能下载"之间断了一截：
# 基础组件装好了，download 却报"需要 gh"。
# Release 资产本来就是公开 URL，curl 就够，而 curl 是基础组件里已有的。
#
# 只有"列 tag"这一步用 API；取不到就要求显式指定 TAG。
# --------------------------------------------------------------------------
API=https://api.github.com/repos/$REPO
DLBASE=https://github.com/$REPO/releases/download

if [ -z "${WTOOL_DL_TAG:-}" ]; then
    # 公开仓库匿名可用；带上 GITHUB_TOKEN 可以避免匿名限流（60 次/小时）
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        _tags=$(curl -fsSL --max-time 25 -H "Authorization: Bearer $GITHUB_TOKEN" \
                    "$API/releases?per_page=30" 2>/dev/null)
    else
        _tags=$(curl -fsSL --max-time 25 "$API/releases?per_page=30" 2>/dev/null)
    fi
    TAG=$(printf '%s' "${_tags:-}" | python3 -c '
import json, sys
try:
    rs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rs:
    t = r.get("tag_name", "")
    if not r.get("draft") and t.startswith("snapshot-"):
        print(t); break
' 2>/dev/null) || true
fi
[ -n "${TAG:-}" ] || die "取不到 $REPO 的 release 列表。显式指定即可：
    WTOOL_DL_TAG=snapshot-2026-09-16 wtool download astronvim_v5"
say "发布页 : $REPO @ $TAG"
say "下载源 : $DLBASE/$TAG"

# 统一取文件：断点续传 + 重试。
# -C - 很关键：这条链路只有 200 多 KB/s，一个 32MB 的分卷要传两分多钟，
# 中途断掉时从断点接着传，而不是从头再来一遍。
fetch() {
    _url=$1; _out=$2; _try=0
    while :; do
        _try=$((_try + 1))
        curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 900 \
             -C - -o "$_out" "$_url" 2>/dev/null && return 0
        [ "$_try" -ge 8 ] && return 1
        sleep 10
    done
}


# --------------------------------------------------------------------------
# 2. 先拿 dist.json —— 里面有分卷清单和每个卷的 sha256，下载和校验都按它来
# --------------------------------------------------------------------------
mkdir -p -- "$CACHE"
cd -- "$CACHE" || die "进不去缓存目录 $CACHE"

say "取 dist.json"
fetch "$DLBASE/$TAG/dist.json" "$CACHE/dist.json" || die "下载 dist.json 失败"

python3 - "$CACHE/dist.json" > "$CACHE/.vols.tsv" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
for v in d.get("volumes", []):
    print("%s\t%s\t%s" % (v["name"], v.get("sha256", "?"), v.get("bytes", 0)))
PY
[ -s "$CACHE/.vols.tsv" ] || die "dist.json 里没有 volumes"

_nvol=$(awk 'END{print NR}' "$CACHE/.vols.tsv")
say "分卷   : $_nvol 个（来自 dist.json）"

# --------------------------------------------------------------------------
# 3. 逐个下载 + 校验。
#    每个卷单独重试，**不是整包重来** —— 分卷的意义就在这里：
#    网断在第 12 个卷，只需要重下第 12 个。
# --------------------------------------------------------------------------
while IFS='	' read -r _name _sha _bytes; do
    [ -n "$_name" ] || continue
    if [ -f "$_name" ] && [ "$(sha256sum "$_name" | cut -d' ' -f1)" = "$_sha" ]; then
        say "  已有 $_name（校验通过）"
        continue
    fi
    _try=0
    while :; do
        _try=$((_try + 1))
        if fetch "$DLBASE/$TAG/$_name" "$CACHE/$_name"; then
            _got=$(sha256sum "$_name" 2>/dev/null | cut -d' ' -f1)
            # 下全了才可能校验通过。网断时 curl 会留下一个**截断的文件**，
            # 不校验的话后面解压会报一句莫名其妙的 tar 错误。
            [ "$_got" = "$_sha" ] && { say "  ok $_name"; break; }
            warn "  $_name 校验不过（第 $_try 次），重下"
        else
            warn "  $_name 下载失败（第 $_try 次）"
        fi
        [ "$_try" -ge 8 ] && die "$_name 试了 8 次都不行，放弃（网络太差？）"
        rm -f -- "$_name"
        sleep 10
    done
done < "$CACHE/.vols.tsv"

# --------------------------------------------------------------------------
# 4. 按顺序拼回一个流，解开，铺到 $HOME
#    分卷是同一个压缩流的切片，cat 起来就是一个完整的包。
# --------------------------------------------------------------------------
_comp=$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8")).get("compression","gzip"))
' "$CACHE/dist.json")
case $_comp in
    gzip) _dec="gzip -dc" ;;
    zstd) command -v zstd >/dev/null 2>&1 || die "包是 zstd 压的，本机没有 zstd"
          _dec="zstd -dc" ;;
    none) _dec="cat" ;;
    *)    die "dist.json 里的 compression=$_comp 不认识" ;;
esac

say "解开并铺到 \$HOME（$_nvol 个分卷）"
rm -rf -- "$CACHE/.payload"
mkdir -p -- "$CACHE/.payload"
# 用 if ! 包住整条管道：任何一段失败都要能抓到并报出来，
# 不能让 tar 的错误被管道吞掉（踩过：卷是坏的，却报了个不相干的错）
if ! { while IFS='	' read -r _name _sha _bytes; do
          [ -n "$_name" ] || continue
          cat -- "$CACHE/$_name" || exit 1
       done < "$CACHE/.vols.tsv"; } | $_dec | tar -xf - -C "$CACHE/.payload"; then
    rm -rf -- "$CACHE/.payload"
    die "解压失败：分卷可能不完整"
fi
[ -d "$CACHE/.payload/home" ] || die "包里没有 home/，结构不对"

# --------------------------------------------------------------------------
# 5. 记账。install.sh 之后照这个清单登记，所以格式必须和它一致。
# --------------------------------------------------------------------------
mkdir -p -- "$(dirname -- "$ARTIFACTS")"
: > "$ARTIFACTS"
_ts=$(date +%Y-%m-%dT%H:%M:%S%z)

# OWNED.tsv 是发布包里带的、由发布方写好的产物清单 —— 以它为准，
# 而不是自己 ls 一遍：这样"编出来的"和"下下来的"两条路的清单
# 是同一份，不会各说各话。
if [ -f "$CACHE/.payload/OWNED.tsv" ]; then
    while IFS='	' read -r _kind _rel; do
        [ "$_kind" = "payload" ] || continue
        [ -n "${_rel:-}" ] || continue
        case $_rel in /*|*..*) warn "清单里有可疑路径，跳过: $_rel"; continue ;; esac
        printf 'payload\t%s\t%s\t%s\n' "$_rel" "download:$TAG" "$_ts" >> "$ARTIFACTS"
    done < "$CACHE/.payload/OWNED.tsv"
else
    warn "包里没有 OWNED.tsv，退回按目录推断"
    for _d in .local/bin/nvim .local/share/nvim .local/lib/nvim \
              .config/astronvim_v5 .local/share/astronvim_v5; do
        [ -e "$CACHE/.payload/home/$_d" ] || continue
        printf 'payload\t%s\t%s\t%s\n' "$_d" "download:$TAG" "$_ts" >> "$ARTIFACTS"
    done
fi

# 铺开。tar 从 home/ 里面打，落到 $HOME 上 —— 和 build.sh 的落点一致
( cd -- "$CACHE/.payload/home" && tar -cf - . ) | ( cd -- "$HOME" && tar -xf - ) \
    || die "铺开失败（\$HOME 写不进去？）"

rm -rf -- "$CACHE/.payload"

_n=$(awk 'END{print NR}' "$ARTIFACTS" 2>/dev/null || echo 0)
say "下载完成（$_n 项产物，tag=$TAG）"
say "包缓存留在 $CACHE（$_nvol 个卷，约 $(du -sh "$CACHE" 2>/dev/null | cut -f1)）"
say "不想要了就删: rm -rf $CACHE"
say "下一步：wtool install $PROJECT_ID"
