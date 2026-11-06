# Neovim 配置

面向 WSL / Linux 的 Python、Rust 开发配置，使用 Neovim 0.12.6 验证。
包含自定义模式与按键、语法高亮、语言服务、代码折叠、自动保存、Oil 文件管理、单栏 Git diff 和项目终端。

## 文档入口

- [模式与快捷键](KEYMAPS.md)：各模式的进入与退出、完整按键表、同一按键在不同界面中的含义。
- [安装与迁移](INSTALL.md)：新环境依赖、插件与语法解析器安装、版本维护。
- 本页：功能概览、自动保存与外部同步、语言服务及配置文件位置。

终端运行 `nvim 文件路径` 或 `nvim .`。编辑器中 `:NvimGuide` 打开本页，
`:view ~/.config/nvim/KEYMAPS.md` 打开快捷键文档。
本配置禁用了许多 Vim 默认普通模式按键，首次使用请先阅读快捷键文档。

## 主要界面

- 代码编辑：普通、插入、可视模式；查看文档和定义源码时使用浮窗。
- Git diff：当前文件的完整单栏预览，红色删除、绿色新增；对比暂存区与当前缓冲区，包含未保存修改。
- 项目终端：底部约占编辑区域 60% 高度，隐藏后保留运行进程和输出。
- Oil：以编辑目录条目的方式管理文件，修改通过 `:w` 提交；删除不送回收站。

各界面的快捷键不同，具体操作见 [模式与快捷键](KEYMAPS.md)。

## 自动保存与外部同步

退出 Insert 模式（通常按 Esc）时，自动保存当前有改动、有文件路径且可写的普通文件。
已命名的新文件也会保存；未命名缓冲区、只读文件、Oil 面板、diff 和其他插件面板不会自动保存。
普通模式下的 `dd`、`u/U`、剪切、粘贴和 `f` 格式化不单独触发保存，可以用 `:w`，或在下次退出 Insert 时保存。

回到窗口、切换文件、普通模式光标停留及进入/退出 Insert 时，会检查磁盘上的外部变化。
当前缓冲区没有未保存修改时自动重新加载。它不是多人实时协同编辑，也不会拉取远程 Git。

如果你和外部程序都修改了文件，自动保存会暂停并提示，保留编辑器中的修改和磁盘版本，
不会自动合并或强制覆盖。检查冲突后再手动处理和保存。写入失败也会提示并保留未保存内容。
Git diff 预览仍是快照，关闭后重新按 `g` 刷新。

## Rust / Python

使用 Tokyo Night 配色、Treesitter 语法高亮和 LSP 语义高亮。
Rust 由 rust-analyzer 提供跳转、文档、补全和诊断；项目应有 Cargo.toml。
已为当前 stable 工具链安装 rust-analyzer、rust-src、rustfmt。
如果项目指定其他工具链，请在项目目录运行 `rustup component add rust-analyzer rust-src rustfmt`。
首次打开大型项目需要等待索引及 Cargo 检查。

Python 使用 Pyright。按顺序选择已激活的 virtualenv、Conda 环境、项目 `.venv` / `venv`，最后使用系统 python3。
推荐先运行 `source .venv/bin/activate`，再启动 Neovim。
已安装 Ruff 0.17.4（通过 `uv tool install ruff`），与 Pyright 同时启用。
Pyright 继续负责补全、定义跳转、文档和类型检查；Ruff 提供规范检查、代码操作及格式化。
Ruff 的 hover 已关闭，`q` 的文档和类型说明仍由 Pyright 提供。

普通模式按 `f` 格式化当前整个文件。Python 只调用 Ruff；Rust 等其他语言调用已连接且支持格式化的语言服务。
Ruff 遵循项目的 `pyproject.toml`、`ruff.toml` 或 `.ruff.toml` 配置。
`f` 只格式化，不执行批量 lint 修复或自动删除未使用的导入；可以按 `u` 撤销格式化。
格式化后用 `:w` 保存，或在下次退出 Insert 时自动保存。没有配置保存时自动格式化。

## 配置与维护

- 模式与快捷键：[KEYMAPS.md](KEYMAPS.md)
- 安装与迁移：[INSTALL.md](INSTALL.md)
- 主配置：`~/.config/nvim/init.lua`
- 项目终端：`~/.config/nvim/lua/project_terminal.lua`
- 自动保存与外部变化检查：`~/.config/nvim/lua/file_sync.lua`
- 当前文件单栏 diff：`~/.config/nvim/lua/inline_diff.lua`
- 精简按键与源码预览：`~/.config/nvim/lua/minimal_keys.lua`
- 插件版本锁：`~/.config/nvim/lazy-lock.json`
- 插件目录：`~/.local/share/nvim/lazy/`
- 查看插件：`:Lazy`；更新插件：`:Lazy sync`；更新语法解析器：`:TSUpdate`
- 查看语言服务：`:checkhealth vim.lsp`；整体检查：`:checkhealth`
- 更新 Ruff：`uv tool upgrade ruff`
- 更新 Pyright：`npm install -g --prefix ~/.local pyright`

日常启动和已安装的语言功能使用本地依赖。插件更新、下载解析器和未缓存的 Cargo 依赖需要网络。
