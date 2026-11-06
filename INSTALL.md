# 安装与迁移

这是 Neovim 配置仓库，不包含 Neovim 本体、语言服务、插件源码或编译后的语法解析器。
当前配置在 WSL Ubuntu 24.04、Neovim 0.12.6 上验证；锁定的 Treesitter 插件要求 Neovim 0.12 或更高版本。

## 1. 准备依赖

需要先安装 Neovim、Git、curl、tar、C 编译器、Node.js/npm、Python 3、uv 和 Rust/rustup。
确认 `nvim`、`git`、`cc`、`node`、`npm`、`python3`、`uv`、`cargo` 在 PATH 中。

安装语言服务和解析器构建工具：

```bash
npm install -g --prefix "$HOME/.local" pyright
uv tool install ruff
rustup component add rust-analyzer rust-src rustfmt
cargo install --locked tree-sitter-cli
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
```

Tree-sitter CLI 需要 0.26.1 或更新版本；本机使用 0.27.1。Python 服务验证版本为 Pyright 1.1.414、Ruff 0.17.4。
Neovim 启动时会把 `~/.local/bin` 和 `~/.cargo/bin` 添加到自身 PATH。
若项目通过 `rust-toolchain.toml` 指定工具链，请在该项目目录再次安装对应工具链的 Rust 组件。

## 2. 克隆配置

如果已有 `~/.config/nvim`，先将旧目录移到其他位置备份。下面的克隆命令要求目标目录不存在：

```bash
git clone git@github.com:zerohao-cmd/neovim-config.git "$HOME/.config/nvim"
```

未配置 GitHub SSH 身份验证时，可以使用仓库的 HTTPS 地址（私有仓库仍需相应访问权限）。

## 3. 安装插件及语法解析器

首次运行需要访问 GitHub 和解析器下载源。先按版本锁安装插件：

```bash
nvim --headless '+Lazy! restore' +qa
```

然后安装配置中使用的语法解析器：

```bash
nvim --headless '+lua require("nvim-treesitter").install({ "rust", "python", "lua", "toml", "json", "bash", "markdown", "markdown_inline" }):wait(300000)' +qa
```

插件由 `lazy-lock.json` 锁定；解析器和插件保存在 Neovim 的数据目录，不提交到本仓库。
使用 `:Lazy restore` 恢复锁定版本，使用 `:Lazy sync` 主动更新；更新后可提交新的版本锁。

## 4. 检查与使用

```bash
nvim --version
pyright --version
ruff --version
rust-analyzer --version
tree-sitter --version
```

打开项目中的 Python/Rust 文件，使用 `:checkhealth vim.lsp` 检查语言服务。
Python 建议先激活项目虚拟环境，再启动 Neovim。配置也会尝试检测项目的 `.venv` 或 `venv`。

本配置使用自定义普通模式按键，许多 Vim 默认键位已禁用。完整按键表见 [README.md](README.md)，
在编辑器中也可以通过 `:NvimGuide` 查看。退出插入模式会自动保存可写的普通文件；冲突时会暂停保存。

## 后续维护

直接在配置目录中管理版本：

```bash
cd "$HOME/.config/nvim"
git status
git pull --ff-only
```

有本地修改时先检查并提交或妥善保存，再拉取远端更新。修改配置后重启 Neovim。
