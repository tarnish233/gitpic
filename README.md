# gitpic

**简体中文** | [English](./README.en.md)

把本地或剪贴板里的图片上传到 GitHub 仓库（当图床），一键生成 Markdown 链接，并自动复制到剪贴板。

终端里对人友好，加 `--json` 后对脚本 / AI Agent 友好。单个静态二进制，无需运行时。

## 演示

```console
$ gitpic init
✓ saved config to ~/.config/gitpic/config.toml

$ gitpic ~/Desktop/shot.png
✓ uploaded shot  📋 已复制到剪贴板
![shot](https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png)

$ pbpaste                       # 剪贴板里已是上面的 markdown

$ gitpic list
2026-07-23  shot
  https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png
```

> 提示：录制动图可用 [asciinema](https://asciinema.org/)：`asciinema rec demo.cast`，
> 跑几条上面的命令后 `Ctrl-D` 结束，再上传获取分享链接放到这里。

## 安装

**Homebrew（推荐，自动进 PATH、自动装补全）**

```bash
brew install tarnish233/tap/gitpic
```

**下载预编译二进制**

到 [Releases](https://github.com/tarnish233/gitpic-cli/releases) 下载对应平台的压缩包，解压得到 `gitpic`。macOS 首次运行需解除隔离：

```bash
tar -xzf gitpic-aarch64-apple-darwin.tar.gz     # Apple Silicon
xattr -d com.apple.quarantine ./gitpic 2>/dev/null
chmod +x ./gitpic && mv ./gitpic ~/.local/bin/  # 确保 ~/.local/bin 在 PATH
```

> Intel Mac 用 `x86_64-apple-darwin`，Linux 用 `x86_64-unknown-linux-gnu`，Windows 是 `.zip`（解压得到 `gitpic.exe`）。

**从源码**

```bash
cargo install --path .
```

## 配置

需要一个 GitHub 细粒度 token（对图床仓库有 `Contents: Read/Write` 权限）。

交互式：

```bash
gitpic init
```

或直接手写 `~/.config/gitpic/config.toml`（遵循 `$XDG_CONFIG_HOME`）：

```toml
[github]
token  = "github_pat_xxx"
owner  = "your-name"
repo   = "img"
branch = "main"

[upload]
path_template = "images/{year}/{month}/{hash8}-{name}.{ext}"
link_kind     = "cdn"   # cdn (jsDelivr) | raw
dedup         = true
auto_copy     = true
compress      = false
max_width     = 0        # 0 = 不缩放
quality       = 82       # 压缩时的 JPEG 质量
```

或用环境变量（不落盘，优先级高于配置文件）：

```bash
export GITPIC_TOKEN="github_pat_xxx"
export GITPIC_REPO="your-name/img"     # owner/name
export GITPIC_BRANCH="main"            # 可选
export GITPIC_LINK="cdn"               # 可选：cdn | raw
```

上传历史保存在 `~/.local/share/gitpic/history.jsonl`（遵循 `$XDG_DATA_HOME`）。

## 使用

```bash
gitpic screenshot.png            # 上传 → 打印 markdown → 复制到剪贴板
gitpic a.png b.png               # 批量上传
gitpic paste                     # 上传剪贴板里的图片（截图后直接用）
cat img.png | gitpic --stdin --name shot.png
gitpic doctor                    # 检查 token 与仓库权限
gitpic list                      # 查看最近上传（本地历史）
gitpic completion zsh            # 打印 shell 补全脚本

# 输出控制
gitpic photo.jpg -q -f url       # 只打印 URL
gitpic photo.jpg --json          # 结构化 JSON（脚本 / agent）
gitpic photo.jpg --link raw      # 用 raw.githubusercontent.com

# 压缩 / 缩放
gitpic big.png --compress                    # 上传前压缩
gitpic big.png --compress --max-width 1600   # 缩放到宽度 <= 1600
gitpic big.jpg --compress --quality 80       # JPEG 质量
```

## 配置管理

```bash
gitpic config path                       # 打印配置文件路径
gitpic config get                        # 查看全部配置
gitpic config set github.repo owner/name # 修改某项
gitpic config set upload.link_kind raw
gitpic config set upload.compress true
gitpic config set upload.max_width 1600
gitpic config edit                       # 用 $EDITOR 打开配置文件
```

`path_template` 占位符：`{year} {month} {day} {hash} {hash8} {name} {ext}`

## Shell 补全

用 Homebrew 安装时会**自动装好** bash / zsh / fish 补全（zsh 用户新开终端即可生效）。手动安装可自己生成：

```bash
gitpic completion zsh  > ~/.zfunc/_gitpic
gitpic completion bash > /etc/bash_completion.d/gitpic
gitpic completion fish > ~/.config/fish/completions/gitpic.fish
```

## 退出码

`0` 成功 · `2` 参数错误 · `3` 缺少配置 · `4` 认证失败 · `5` 网络错误 · `6` 文件不存在

## Agent 集成

见 [`SKILL.md`](./SKILL.md)。调用时始终带上 `--json --no-copy`。

## 更新日志

见 [CHANGELOG.md](./CHANGELOG.md)。

## 许可证

MIT
