#!/bin/sh
# snapshot.sh —— 从当前机器上已装的 astronvim 抓出"装了什么"的清单
#
# 为什么需要它：
#   这个 astronvim 环境里有两样东西**没有任何声明来源**——
#     * 75 个 mason 包：config 里的 lua/plugins/mason.lua 是关着的
#       （`if true then return {} end`），这 75 个包是历次 :Mason 手动装出来的
#     * 251 个 treesitter parser：config 里的 treesitter.lua 同样是关着的
#   所以它们既不在 git 里，也不能从 config 推出来，只能从实机抓一份快照。
#
#   抓到的东西才是可复现的：容器里 install.sh 照这两份清单装，
#   装出来的环境和这台机器是同一个集合。
#
# 版本锁定：
#   插件有 lazy-lock.json（56 个，钉到 commit）✓
#   mason **没有**锁定机制——没有 mason-lock.json 这个文件（mason 里的 lockfile
#   是每包的 PID 锁，不是版本锁），Package:install 不收 version 参数，
#   :MasonInstall 也不支持 pkg@version。所以 mason 只能固定"装哪些"，
#   "装到什么版本"靠打包时把实际版本记进 dist.json 供比对。
#
# 用法：tools/snapshot.sh [astronvim 数据目录]
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
proj=$(cd -- "$here/.." && pwd)
data=${1:-$HOME/.local/share/astronvim_v5}
pkgs="$data/mason/packages"
parsers="$data/lazy/nvim-treesitter/parser"

[ -d "$data" ] || {
    printf '找不到 astronvim 数据目录: %s\n' "$data" >&2
    printf '用法: %s [astronvim 数据目录]\n' "$0" >&2
    exit 1
}

python3 - "$pkgs" "$parsers" "$proj" <<'PY'
import json, os, sys

pkgs_dir, parsers_dir, proj = sys.argv[1], sys.argv[2], sys.argv[3]

# ---- mason 包 ----
names, versions = [], {}
if os.path.isdir(pkgs_dir):
    for name in sorted(os.listdir(pkgs_dir)):
        receipt = os.path.join(pkgs_dir, name, "mason-receipt.json")
        if not os.path.isfile(receipt):
            continue
        names.append(name)
        try:
            with open(receipt, encoding="utf-8") as fh:
                src = (json.load(fh).get("source") or {}).get("id") or ""
            # 形如 pkg:github/luals/lua-language-server@3.18.1
            versions[name] = src.rsplit("@", 1)[-1] if "@" in src else "?"
        except Exception:
            versions[name] = "?"

with open(os.path.join(proj, "mason-packages.txt"), "w", encoding="utf-8") as fh:
    fh.write("# astronvim_v5 需要的 mason 包清单\n")
    fh.write("# 由 tools/snapshot.sh 生成。install.sh 照这份装；改动请重跑脚本，不要手改。\n")
    fh.write("# 注意：mason 没有版本锁定机制，这里固定的是\"装哪些\"，不是\"装到什么版本\"。\n")
    for n in names:
        fh.write(n + "\n")

with open(os.path.join(proj, "mason-versions.json"), "w", encoding="utf-8") as fh:
    json.dump(versions, fh, indent=2, sort_keys=True, ensure_ascii=False)
    fh.write("\n")

# ---- treesitter parser ----
parsers = []
if os.path.isdir(parsers_dir):
    for f in sorted(os.listdir(parsers_dir)):
        if f.endswith(".so"):
            parsers.append(f[:-3])

with open(os.path.join(proj, "treesitter-parsers.txt"), "w", encoding="utf-8") as fh:
    fh.write("# astronvim_v5 需要的 treesitter parser 清单\n")
    fh.write("# 由 tools/snapshot.sh 生成。install.sh 照这份现编；parser 必须和 nvim ABI 匹配。\n")
    fh.write("# 这些 .so 是本地编译产物，不能跨机器直接复制（换机器要重新编译）。\n")
    for p in parsers:
        fh.write(p + "\n")

print("mason 包      : %d" % len(names))
print("treesitter    : %d 个 parser" % len(parsers))
print("写出          : mason-packages.txt / mason-versions.json / treesitter-parsers.txt")
PY

# 顺带记一下插件和 nvim 的版本，方便比对两次构建的差异
if [ -f "$proj/astronvim_v5_config/lazy-lock.json" ]; then
    _n=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" \
             "$proj/astronvim_v5_config/lazy-lock.json")
    printf '插件(lazy-lock.json): %s 个\n' "$_n"
fi
