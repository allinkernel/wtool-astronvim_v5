#!/bin/sh
# extract.sh —— 把发布包解开铺到 $HOME。**不装、不检查系统版本。**
#
# 给"只能用浏览器下载"的机器用：把 dist.json、extract.sh 和所有 -volNN
# 放在同一个目录，然后：
#
#     sh extract.sh
#     wtool install editor/astronvim_v5
#
# 为什么不是 install.sh：
#   原来发布包里放的 install.sh 会**校验目标系统**，dist.json 里写着
#   target=ubuntu-20.04，于是在 22.04 上直接拒绝安装。
#   但 glibc 是单向兼容的 —— 在最老的那个系统里编出来的包，新的全都能跑
#   （实测：20.04 编的 nvim + 编译出来的 treesitter parser，在
#   22.04/24.04/26.04 上全部正常）。那个检查是错的，它挡住的全是本该能装的机器。
#
#   而且"装"这个动作本来就该由 wtool 负责（登记、软链、shell 集成、
#   能卸载）。发布包只该负责**把文件铺到位**。职责分开之后，
#   这个脚本不碰 $HOME 以外的东西，也不写任何状态。
set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
DIST="$HERE/dist.json"

say()  { printf '解压: %s\n' "$*"; }
warn() { printf '解压: 警告: %s\n' "$*" >&2; }
die()  { printf '解压: 错误: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "需要 python3（读 dist.json）"
[ -f "$DIST" ] || die "同目录下没有 dist.json —— 所有文件要放在一起"

# 中间文件一律写临时目录：发布包所在目录（HERE）**可能是只读的**
# （从只读挂载、或者解压到只读位置跑），写那儿会直接失败
TMP=$(mktemp -d "${TMPDIR:-/tmp}/astro-extract.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT INT TERM

PROJECT=$(python3 -c '
import json,sys
with open(sys.argv[1],encoding="utf-8") as fh: print(json.load(fh)["project"])
' "$DIST")

say "项目   : $PROJECT"
say "目标   : $(python3 -c '
import json,sys
with open(sys.argv[1],encoding="utf-8") as fh: d=json.load(fh)
print(d.get("target","?"))
' "$DIST")"

# 分卷清单：名字 / sha256 / 字节数
python3 - "$DIST" > "$TMP/.vols.tsv" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
for v in d.get("volumes", []):
    print("%s\t%s\t%s" % (v["name"], v.get("sha256", "?"), v.get("bytes", 0)))
PY
[ -s "$TMP/.vols.tsv" ] || die "dist.json 里没有 volumes"
_n=$(awk 'END{print NR}' "$TMP/.vols.tsv")

# ── 1. 校验。缺一个都别往下走 ──
say "校验 $_n 个分卷的 sha256"
_idx=0
while IFS='	' read -r _name _sha _bytes; do
    _idx=$((_idx + 1))
    [ -f "$HERE/$_name" ] || die "缺文件 $_name（$_idx/$_n）"
    _got=$(sha256sum "$HERE/$_name" | cut -d' ' -f1)
    [ "$_got" = "$_sha" ] || die "$_name 校验不过（$_idx/$_n）—— 下载不完整或文件被改过"
done < "$TMP/.vols.tsv"
say "  全部通过"

# ── 2. 拼接 + 解压 ──
_comp=$(python3 -c '
import json,sys
with open(sys.argv[1],encoding="utf-8") as fh: print(json.load(fh).get("compression","gzip"))
' "$DIST")
case $_comp in
    gzip) _dec="gzip -dc" ;;
    zstd) command -v zstd >/dev/null 2>&1 || die "包是 zstd 压的，本机没有 zstd"
          _dec="zstd -dc" ;;
    none) _dec="cat" ;;
    *)    die "dist.json 里的 compression=$_comp 不认识" ;;
esac

say "解开（$_n 个分卷拼回一个流）"
# 用 if ! 包住整条管道：任何一段失败都要能抓到 ——
# 分卷坏了却只报一句不相干的 tar 错误，是最难查的那种
if ! { while IFS='	' read -r _name _sha _bytes; do
          [ -n "$_name" ] || continue
          cat -- "$HERE/$_name" || exit 1
       done < "$TMP/.vols.tsv"; } | $_dec | tar -xf - -C "$TMP"; then
    die "解压失败：分卷可能不完整"
fi
[ -d "$TMP/home" ] || die "包里没有 home/，结构不对"

# ── 3. 铺到 $HOME ──
# 包里的 home/ 就是目标机 $HOME 的样子，一一对应铺过去。
# 这是**唯一**改动的地方：只往 $HOME 里写，不碰 /etc、不装包、不要 root。
say "铺到 \$HOME（$HOME）"
( cd -- "$TMP/home" && tar -cf - . ) | ( cd -- "$HOME" && tar -xf - ) \
    || die "铺开失败（\$HOME 写不进去？）"

# 列一下铺了哪些顶层项，让人知道多了什么
say "铺好的内容："
if [ -f "$TMP/OWNED.tsv" ]; then
    awk -F'	' '$1=="payload"{printf "  %s\n", $2}' "$TMP/OWNED.tsv"
else
    ( cd -- "$TMP/home" && ls -A ) | sed 's/^/  /'
fi

cat <<TIP

完事了。接下来交给 wtool 去登记和做 shell 集成（能卸载）：

    wtool install $PROJECT

还没装 wtool 的话，见发布页/仓库里的安装说明。
TIP
