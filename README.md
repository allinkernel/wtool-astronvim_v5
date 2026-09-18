# wtool-astronvim_v5

astronvim_v5 的**伞项目**。它自己没有代码可发布——它的价值是替整棵子树负责构建和发布。

## 这棵树

```
editor/astronvim_v5/                     ← 本仓：构建/发布逻辑（有 wtool.xml）
├── astronvim_v5_config/                 ← allinkernel/wtool-astronvim_v5_config（独立项目）
├── nvim/                                ← neovim/neovim（上游源码，独立项目）
├── install.sh                           安装器
├── publish.sh                           打包器
├── wtool.xml                            publish 声明
├── mason-packages.txt                   9 个 mason 包（按 config 的实际引用手写维护）
├── treesitter-parsers.txt               15 个 parser（同上）
├── mason-versions.json                  某台机器上的版本快照（仅供比对，构建不读它）
└── tools/snapshot.sh                    从实机重新抓上面三份清单（**慎用**，见「可复现性」）
```

`nvim/` 和 `astronvim_v5_config/` 由 repo manifest 单独管理，本仓的 `.gitignore` 把它们排除了。

## publish 是怎么分工的

`wtool publish editor/astronvim_v5` 会调本仓的 `publish.sh`：

1. **问目标系统**——glibc 只保证向前兼容，一个包通吃不了，见下
2. `docker pull` 对应镜像
3. 起容器，把工作区**只读**挂进去，在容器里跑 `install.sh`
4. 按 `install.sh` 写的安装清单把容器的 `$HOME` 薅出来（**清单驱动，不靠猜**）
5. 分卷 + 写 `dist.json`
6. 产物交给 wtool 上传到本仓的 release

子树里另外两个项目不需要在这里表态：`astronvim_v5_config` 走默认源码发布，`nvim` 是上游仓、我们既没权限推也不能往里塞 `wtool.xml`，所以在 `wtool.xml` 里由本仓用 `<sub path="nvim" kind="none"/>` 替它声明。

## install.sh 的双重身份

`install.sh` 在同一份代码下跑在两个地方，而且它自己不需要知道在哪：

| 环境 | `$HOME` |
|---|---|
| 宿主机 | 你的家目录 |
| 容器 | `/root` |

唯一差别就是 `$HOME` 指向哪。publish.sh 之所以能做得那么薄，就是因为这个。代价是 `install.sh` 必须：自足（不依赖 wtool）、无交互、可重入、**产物可枚举**（写安装清单，否则 publish.sh 只能靠猜，猜漏一个文件就是启动时报莫名其妙的错）。

## 两种安装模式

**deploy** —— 公司那台只能浏览器下载的机器走这条。脚本旁边有 `dist.json` 和分卷时自动选它，不需要网络：

```sh
# 把 install.sh、dist.json、所有 -volNN 放在同一个目录
bash install.sh
```

它会校验目标系统、逐个校验分卷 sha256，不匹配就明确报错，而不是装出个坏环境。

**build** —— 有网有 proxy 的机器：

```sh
./install.sh --build                     # 用工作区里的 nvim 源码
./install.sh --build --nvim-ref=<commit> # 或者让脚本自己克隆（禁止浮动分支）
```

其他标志：`--dry-run`、`--uninstall`、`--no-shell`、`--no-deps`、`--jobs=N`。

## 为什么目标系统必须问

nvim 是半静态链接，`ldd` 出来只剩 `libc`、`libm`、`libgcc_s`——**唯一的外部依赖就是 glibc**。而 glibc 只保证向前兼容：在 24.04 上编的在 22.04 上一定跑不起来，反过来才行。

所以 release 里是矩阵，资产名带目标系统，`install.sh` 在目标机上会先比对，不匹配直接拒绝并说明原因。

## 什么进包、什么不进

| | 进包？ | 为什么 |
|---|---|---|
| nvim 二进制 | ✅ | 编译慢，且只依赖 glibc |
| `~/.config/astronvim_v5` | ✅ | 配置仓 |
| `~/.local/share/astronvim_v5/lazy` | ✅ | 56 个插件，含 `treesitter-parsers.txt` 里那些 `.so` 和 blink 的 Rust 库 |
| `~/.local/share/astronvim_v5/mason` | ✅ | 9 个包，公司机器下不动 |
| apt 装的系统依赖 | ❌ | **必须和本机 libc/发行版匹配**，带过去也不能用，只能目标机现场装 |
| `~/.local/state/.../log` | ❌ | 本机上是 8.2G 的调试日志 |

## 可复现性到什么程度

| 东西 | 锁定方式 |
|---|---|
| 56 个 lazy 插件 | `lazy-lock.json` 钉到 commit ✅ |
| nvim 源码 | manifest 的 revision ✅ |
| mason 包 | **只能固定"装哪些"**——mason 没有版本锁定机制（没有 `mason-lock.json`，`Package:install` 不收 version，`:MasonInstall` 不支持 `pkg@version`）。装到什么版本由打包那一刻决定，记进 release 里的 `versions.txt` 供比对 |
| treesitter parser | 同上，且 `.so` 是本地编译的，**不能跨机器直接复制**，换机器必须重编 |

两份清单是**从配置推出来的**，不是从实机抓的。规则只有一条：

> 配置里引用到的工具必须在这两份清单里；清单里的每个包也必须能在配置里指到出处。

`mason-packages.txt` 的每个包都在文件里写了出处（哪一行 `ensure_installed` / 哪个
`servers` 条目）；`treesitter-parsers.txt` 对应各 pack 的 `ensure_installed`。
两边都要跟着 `astronvim_v5_config/` 走。

`tools/snapshot.sh` 走的是**反方向**（从一台装好的机器反推清单），它曾经抓出
75 个 mason 包 + 251 个 parser —— 那是历次 `:Mason` 浏览顺手装的，绝大部分
config 里根本没有引用。后来有人把 mason 清单砍到 5 个，却只砍了 LSP，
`stylua` / `selene` / `codelldb` / `lua-language-server` 被连带砍掉，
而配置仍然引用它们，于是每次启动都刷 `mason-tool-installer: xxx: installing`。

**所以：要改清单，先改配置，再从配置推清单。别用 snapshot.sh 覆盖它。**

## 测试

```sh
tests/astronvim_test.sh     # 52 条：deploy/校验/拒绝坏包/可重入/卸载/清单与配置一致
```

docker 那条路（build）在 agent 环境里测不了（用不了 docker socket），只能人在自己机器上跑 `publish.sh` 验证。
