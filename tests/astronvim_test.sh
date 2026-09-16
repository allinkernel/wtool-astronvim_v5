#!/bin/sh
# astronvim_test.sh —— 测 install.sh 的代码路径
#
# 不碰真 $HOME、不碰真系统、不需要 docker、不需要 root。
# 覆盖的是"公司那台只能浏览器下载的机器"要走的那条路（deploy），
# 因为那条路的正确性最关键：校验漏了就会装出个跑不起来还报错莫名其妙的环境。
#
# docker 那条路（build）测不了——agent 环境用不了 docker socket，
# 只能由人在自己机器上跑 publish.sh 验证。这里只做 dry-run 看计划。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
proj=$(cd -- "$here/.." && pwd)
SH="$proj/scripts/install.sh"
BUILD="$proj/scripts/build.sh"
PUB="$proj/scripts/publish.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }
has() { if [ -e "$2" ]; then ok "$1"; else bad "$1（$2 不存在）"; fi; }
hasnt(){ if [ ! -e "$2" ]; then ok "$1"; else bad "$1（$2 不该存在）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/astrotest.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

HOSTTARGET=$(. /etc/os-release && printf '%s-%s' "$ID" "$VERSION_ID")

echo "== 1. build.sh 的 dry-run：只出计划，零副作用 =="
H="$T/h1"; mkdir -p "$H"
env HOME="$H" "$BUILD" --no-deps --dry-run --nvim-ref=v0.11.0 > "$T/log1" 2>&1 || {
    bad "dry-run 退出码非 0"; sed 's/^/     /' "$T/log1"; }
grep -q '模式     : build' "$T/log1" && ok "build.sh 认出自己是构建" || bad "模式判定不对"
# 原来断言的是日志里出现 'cmake'。换了构建方式后就假报警了，
# 而且它锁的是"某个词出现过"，不是"命令对不对"。
# 真正踩过的坑是：**必须走 make**，用裸 cmake 会因为
# cmake.deps 没被构建而报 "Failed to find a Lua 5.1-compatible interpreter"。
grep -q 'make -C .*-j' "$T/log1" && ok "计划里走 make 编 nvim（不是裸 cmake）" \
    || { bad "计划里没有 make 编译步骤"; sed 's/^/     /' "$T/log1" | head -20; }
grep -q 'cmake\.deps\|make -C' "$T/log1" && ok "计划里有依赖子构建" || bad "计划里缺依赖子构建"
grep -q 'CMAKE_INSTALL_PREFIX' "$T/log1" && ok "计划里指定了安装前缀" || bad "计划里没指定安装前缀"
grep -q 'dry-run' "$T/log1" && ok "确实说了 dry-run" || bad "没说 dry-run"
hasnt "dry-run 没有建 \$HOME/.local/bin/nvim" "$H/.local/bin/nvim"
hasnt "dry-run 没有写 .zshrc" "$H/.zshrc"
chk "dry-run 没写清单" "$([ -f "$H/.local/state/astronvim_v5/install-manifest.tsv" ] && echo 有 || echo 无)" "无"

echo "== 1b. ★install.sh 不构建：没构建过就明确拒绝 =="
# 这条线是这次重构的核心——install.sh 必须能在没网、没编译器的机器上跑，
# 一旦它偷偷开始编译，这个前提就没了。
_rc=0
env HOME="$H" "$SH" --no-shell --no-deps > "$T/log1b" 2>&1 || _rc=$?
chk "没构建过时拒绝安装（退出码 3）" "$_rc" "3"
grep -q '先跑构建' "$T/log1b" && ok "告诉用户先去构建" || bad "没说怎么办"
grep -q 'wtool build astronvim_v5' "$T/log1b" && ok "给了具体命令" || bad "没给命令"
grep -qE 'cmake|apt-get install' "$T/log1b" && bad "install.sh 居然在编译" || ok "install.sh 里没有构建动作"

echo "== 1c. publish.sh 走的是 build.sh + install.sh 两步 =="
grep -q 'build.sh' "$PUB" && grep -q 'install.sh' "$PUB" \
    && ok "publish.sh 两步都调" || bad "publish.sh 没有两步走"
grep -qE '\./scripts/install\.sh --build' "$PUB" && bad "publish.sh 还在用已删除的 --build" \
    || ok "没有残留的 install.sh --build"


echo "== 2. 造一个发布了的分卷包 =="
SRC="$T/src"; mkdir -p "$SRC"
mkdir -p "$SRC/home/.local/bin" "$SRC/home/.config/astronvim_v5/lua" \
         "$SRC/home/.local/share/astronvim_v5/lazy/fake-plugin"
printf '#!/bin/sh\necho nvim\n' > "$SRC/home/.local/bin/nvim"
chmod +x "$SRC/home/.local/bin/nvim"
echo 'return {}' > "$SRC/home/.config/astronvim_v5/init.lua"
echo 'lua/plugins' > "$SRC/home/.config/astronvim_v5/lua/marker"
echo 'x' > "$SRC/home/.local/share/astronvim_v5/lazy/fake-plugin/init.lua"
# 塞点不可压缩的数据，保证 gzip 后仍然够大、split 能真的切出多卷
head -c 40000 /dev/urandom > "$SRC/home/.local/share/astronvim_v5/lazy/fake-plugin/blob.bin"
cat > "$SRC/OWNED.tsv" <<'EOF'
payload	.config/astronvim_v5
payload	.local/share/astronvim_v5
payload	.local/bin/nvim
EOF

REL="$T/rel"; mkdir -p "$REL"
( cd -- "$SRC" && tar -cf - home OWNED.tsv ) | gzip -9 > "$REL/stream.gz"
# 切成两卷，验证"多分卷按顺序拼回"这条路径
split -b 8000 -d -a 2 "$REL/stream.gz" "$REL/astro-vol"
rm -f "$REL/stream.gz"

# 分卷数由 split 决定，不能写死两个。写死的话 dist.json 只列前两卷，
# 拼回来是个截断的流，会拿"校验逻辑正确报错"误判成安装失败。
python3 - "$REL" "$HOSTTARGET" <<'PYVOL'
import glob, hashlib, json, os, sys
rel, target = sys.argv[1], sys.argv[2]
vols = []
for path in sorted(glob.glob(os.path.join(rel, "astro-vol*"))):
    with open(path, "rb") as fh:
        data = fh.read()
    vols.append({"name": os.path.basename(path),
                 "sha256": hashlib.sha256(data).hexdigest(),
                 "bytes": len(data)})
with open(os.path.join(rel, "dist.json"), "w", encoding="utf-8") as fh:
    json.dump({"project": "editor/astronvim_v5", "target": target,
               "compression": "gzip", "built_at": "2026-09-15T02:00:00+0800",
               "volumes": vols}, fh, indent=2)
print("  分卷数: %d，共 %d 字节" % (len(vols), sum(v["bytes"] for v in vols)))
PYVOL
cp "$SH" "$REL/install.sh"; chmod +x "$REL/install.sh"
ok "分卷包已造好"

echo "== 3. deploy：正常铺开 =="
H2="$T/h2"; mkdir -p "$H2"
env HOME="$H2" "$REL/install.sh" --deploy --from="$REL" --no-deps > "$T/log3" 2>&1 || {
    bad "deploy 退出码非 0"; sed 's/^/     /' "$T/log3"; }
grep -q '模式     : deploy' "$T/log3" && ok "自动判定为 deploy（旁边有 dist.json 和分卷）" || bad "模式判定不对"
has "nvim 落到了 \$HOME/.local/bin/nvim" "$H2/.local/bin/nvim"
has "配置落到了 \$HOME/.config/astronvim_v5" "$H2/.config/astronvim_v5/init.lua"
has "插件落到了 \$HOME/.local/share/astronvim_v5" "$H2/.local/share/astronvim_v5/lazy/fake-plugin/init.lua"
[ -x "$H2/.local/bin/nvim" ] && ok "nvim 保留了可执行位" || bad "可执行位丢了"
has "写了安装清单" "$H2/.local/state/astronvim_v5/install-manifest.tsv"
M="$H2/.local/state/astronvim_v5/install-manifest.tsv"
chk "清单里有 .config/astronvim_v5" "$(awk -F'\t' '$1=="payload" && $2==".config/astronvim_v5"' "$M" | wc -l)" "1"
chk "清单里有 .local/bin/nvim" "$(awk -F'\t' '$1=="payload" && $2==".local/bin/nvim"' "$M" | wc -l)" "1"
has "写了 shell 托管块" "$H2/.zshrc"
grep -q 'NVIM_APPNAME=astronvim_v5' "$H2/.zshrc" && ok "托管块里设了 NVIM_APPNAME" || bad "托管块内容不对"

echo "== 4. deploy 的可重入性：再跑一遍 =="
env HOME="$H2" "$REL/install.sh" --deploy --from="$REL" --no-deps > "$T/log4" 2>&1 || {
    bad "第二遍 deploy 失败"; sed 's/^/     /' "$T/log4"; }
chk "托管块没有重复追加" "$(grep -c '>>> astronvim_v5 >>>' "$H2/.zshrc")" "1"
chk "清单没有重复行" "$(sort "$M" | uniq -d | grep -c . || true)" "0"

echo "== 5. 目标系统不匹配必须拒绝（glibc 单向兼容）=="
H3="$T/h3"; mkdir -p "$H3"
BAD="$T/rel-bad"; cp -r "$REL" "$BAD"
python3 -W ignore - "$BAD/dist.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p,encoding="utf-8"))
d["target"]="ubuntu-22.04"
json.dump(d,open(p,"w",encoding="utf-8"),indent=2)
PY
env HOME="$H3" "$BAD/install.sh" --deploy --from="$BAD" --no-deps > "$T/log5" 2>&1 && _rc=0 || _rc=$?
chk "拒绝时退出码非 0" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q 'glibc' "$T/log5" && ok "错误信息解释了 glibc 单向兼容" || bad "错误信息没说清原因"
hasnt "没有铺开任何文件" "$H3/.config/astronvim_v5"
hasnt "没有写 shell 块" "$H3/.zshrc"

echo "== 6. 分卷损坏必须被拒绝（这条漏了就会装出个坏环境）=="
H4="$T/h4"; mkdir -p "$H4"
COR="$T/rel-cor"; cp -r "$REL" "$COR"
printf 'xxxxxxxx' | dd of="$COR/astro-vol01" bs=1 seek=100 conv=notrunc 2>/dev/null
env HOME="$H4" "$COR/install.sh" --deploy --from="$COR" --no-deps > "$T/log6" 2>&1 && _rc=0 || _rc=$?
chk "拒绝时退出码非 0" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q '校验失败' "$T/log6" && ok "报了"校验失败"" || bad "没报校验失败"
grep -q 'sha256\|期望' "$T/log6" && ok "给出了期望/实际的哈希" || bad "没给哈希对比"
hasnt "损坏的包没有铺开任何文件" "$H4/.config/astronvim_v5"

echo "== 7. 缺分卷必须被拒绝 =="
H5="$T/h5"; mkdir -p "$H5"
MISS="$T/rel-miss"; cp -r "$REL" "$MISS"; rm -f "$MISS/astro-vol01"
env HOME="$H5" "$MISS/install.sh" --deploy --from="$MISS" --no-deps > "$T/log7" 2>&1 && _rc=0 || _rc=$?
chk "拒绝时退出码非 0" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q '缺少分卷' "$T/log7" && ok "指出缺哪个分卷" || bad "没指出缺哪个"

echo "== 8. 卸载：照清单逆着来 =="
env HOME="$H2" "$REL/install.sh" --uninstall > "$T/log8" 2>&1 || {
    bad "uninstall 失败"; sed 's/^/     /' "$T/log8"; }
hasnt "配置被删了" "$H2/.config/astronvim_v5"
hasnt "插件目录被删了" "$H2/.local/share/astronvim_v5"
hasnt "nvim 被删了" "$H2/.local/bin/nvim"
if [ -f "$H2/.zshrc" ]; then
    chk "shell 托管块被清掉了" "$(grep -c 'astronvim_v5' "$H2/.zshrc" || true)" "0"
else
    ok "shell 托管块被清掉了"
fi
hasnt "安装清单被删了" "$M"

echo "== 9. 清单与快照文件都在 =="
has "mason-packages.txt" "$proj/mason-packages.txt"
has "treesitter-parsers.txt" "$proj/treesitter-parsers.txt"
has "mason-versions.json" "$proj/mason-versions.json"
# 这里原来写的是"清单里有 75 个包 / 251 个 parser"。
# 那种**数字快照**式断言是错的：清单本身就是要按需增删的东西，
# 一改就假报警，改的人只好顺手把数字改掉——测试就退化成
# "文件没被动过"，完全测不到"内容对不对"。
# 真正该锁的是**一致性**：配置里启用的 server/parser 必须在清单里，
# 清单里的也必须真的被用到。数量多少是结果，不是契约。
echo "== 9b. 清单和配置必须对得上 =="
_servers=$(sed -n '/servers *= *{/,/}/p' \
    "$proj/astronvim_v5_config/lua/plugins/astrolsp.lua" 2>/dev/null |
    tr -d '"{},' | grep -oE '[A-Za-z_][A-Za-z0-9_-]*' |
    grep -vE '^(servers|local)$' | sort -u)
if [ -z "$_servers" ]; then
    bad "读不出 astrolsp.lua 里启用的 LSP server"
else
    _miss=""
    for _s in $_servers; do
        # 名字两边不总一样，这层映射必须显式写出来：
        # lspconfig 的 server 名 ≠ mason 的包名。
        # 归一化时去掉 - 和 _：rust_analyzer ↔ rust-analyzer
        _mason=$_s
        case $_s in
            bashls) _mason="bash-language-server" ;;
        esac
        _norm=$(printf '%s' "$_mason" | tr -d '_-' | tr 'A-Z' 'a-z')
        if ! grep -vE '^[[:space:]]*(#|$)' "$proj/mason-packages.txt" |
             tr -d '_-' | tr 'A-Z' 'a-z' | grep -qx -- "$_norm"; then
            _miss="$_miss $_mason"
        fi
    done
    if [ -z "$_miss" ]; then
        ok "astrolsp 启用的 $(printf '%s' "$_servers" | wc -w | tr -d ' ') 个 server 都在 mason 清单里"
    else
        bad "这些 server 配置里启用了但清单里没有:$_miss"
    fi
fi

_ft=$(grep -vE '^\s*(#|$)' "$proj/treesitter-parsers.txt" | sort -u)
if [ -n "$_ft" ]; then
    ok "treesitter 清单 $(printf '%s\n' "$_ft" | wc -l | tr -d ' ') 个 parser"
else
    bad "treesitter 清单是空的"
fi
# nvim 自带的 vim/vimdoc/lua 之外的解析器都得在清单里，否则打开文件没高亮
for _need in c lua python; do
    printf '%s\n' "$_ft" | grep -qx -- "$_need" && ok "parser 清单含 $_need" \
        || bad "parser 清单缺 $_need"
done

echo "== 10. 薅产物：docker cp 之前必须先建目标父目录 =="
# 真出过事，而且是"从来没成功过"那种：docker cp **不创建中间目录**，
# 目标父目录不存在时它报 invalid output path: directory "..." does not exist。
# publish.sh 只 mkdir 了 payload/home 一层，于是 .local/bin、.config
# 全都不存在，五条产物一条都复制不出来，最后死在
# "安装清单里一条 payload 都没有" —— 看起来像 install.sh 没产出东西，
# 其实是复制这一步的用法错了，排查方向整个被带偏。
# 完整的端到端验证要跑容器（人工），这里至少把**顺序**锁死。
_pub=$proj/scripts/publish.sh
_mk=$(grep -n 'mkdir -p -- "\$(dirname -- "\$WORK/payload/home/\$_rel")"' "$_pub" | head -1 | cut -d: -f1)
_cp=$(grep -n 'docker cp "\$CTR:/root/\$_rel"' "$_pub" | head -1 | cut -d: -f1)
if [ -z "$_mk" ]; then
    bad "publish.sh 里没有为目标父目录 mkdir -p（docker cp 会全部失败）"
elif [ -z "$_cp" ]; then
    bad "publish.sh 里找不到薅产物那行 docker cp（测试要跟着改）"
elif [ "$_mk" -lt "$_cp" ]; then
    ok "先建目标父目录（第 $_mk 行）再 docker cp（第 $_cp 行）"
else
    bad "顺序反了：docker cp 在第 $_cp 行，mkdir 在第 $_mk 行 —— 中间目录不存在，复制必失败"
fi
# 顺带确认失败时把 docker 的原始错误露出来，不然又只能靠猜
grep -q 'cp.err' "$_pub" && ok "复制失败时露出 docker 的原始报错" \
    || bad "复制失败了却吞掉 docker 的报错，只能靠猜"

echo
printf 'astronvim_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
