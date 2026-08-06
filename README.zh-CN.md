# 不怕 Codex 罢工

这是一个给普通用户使用的 Codex 本地备份与迁移工具，支持 macOS 和 Windows 每日备份，并优先支持 Mac → Mac 合并恢复。

它每天晚上 23:50 由电脑系统直接执行，不启动 Codex，不调用模型，所以自动备份消耗 **0 token**。

## 最简单安装方法

先从 [Releases](https://github.com/jianhong001/codex-backup-portable-kit/releases/latest) 下载最新版并解压。

Mac 用户双击：

```text
安装-macOS.command
```

Windows 用户双击：

```text
安装-Windows.cmd
```

安装后不用每天操作。成功或失败时，电脑会显示本机通知。

Mac 第一次自动运行时，系统可能询问是否允许“终端”访问“文稿”文件夹。请选择允许，否则项目目录无法进入备份。

## 备份保存在哪里

Mac：

```text
~/Documents/不怕codex罢工
```

Windows：

```text
文档\不怕codex罢工
```

默认只保留最新一份成功备份。新备份没有验证成功以前，旧备份绝对不会删除。

## 换 Mac 或换 OpenAI 账号

Mac → Mac 已提供离线双击恢复，不需要安装 Python、Homebrew 或 npm，也不会调用模型。

### 旧 Mac

1. 完全退出 Codex App。
2. 插入 U 盘或移动硬盘。
3. 双击 `第1步-旧Mac制作迁移包.command`，按提示选择硬盘。

硬盘里会生成一个 `不怕Codex罢工-迁移到新Mac` 文件夹，里面已经放好最新 ZIP、SHA-256 和新 Mac 恢复程序。再次制作时，只有新 ZIP 验证成功后才会删除旧 ZIP。

### 新 Mac

1. 安装 Codex，登录新的 OpenAI 账号，至少打开一次 Codex。
2. 完全退出 Codex App。
3. 插入硬盘，打开 `不怕Codex罢工-迁移到新Mac` 文件夹。
4. 双击 `第2步-新Mac恢复聊天.command`。
5. 显示“恢复成功”后重新打开 Codex。

恢复采用合并方式：

- 新 Mac 已有聊天不会被覆盖。
- 旧 Mac 聊天会加入左侧任务列表，可以继续打开和对话。
- 同一个任务 ID 如果两边内容已经分叉，会生成一个稳定的新 ID，让两个版本都可见；重复恢复不会不断复制。
- memory 文档和数据库、goals、skills、项目、附件与生成文件会合并。
- 旧 Mac 的绝对项目路径会改成新 Mac 的用户目录。
- `auth.json`、Cookie、旧账号登录状态和旧 `config.toml` 不会写入新 Mac。

写入前程序会创建“恢复前安全备份”，任何中途失败都会自动回滚。安全备份和文件冲突包都只保留最新一份。

## 会保存什么

- Codex 聊天和 session 本地文件
- memory
- skills
- Codex 设置和必要状态
- `Documents/Codex` 里的代码、文档、输出文件和 Git 历史
- 生成图片与附件
- 一份备份内容清单和 SHA-256 校验文件

## 默认不保存什么

- `auth.json` 登录令牌
- 可以重新下载的 Codex 安装组件
- 大型运行日志和缓存
- 浏览器 Cookie、Login Data 等敏感应用数据
- 项目中的 `.venv`、`node_modules` 和开发缓存

排除这些内容不会删除电脑上的原文件，只是每天不重复把它们装进备份 ZIP。

## 为什么比旧版省空间

旧版会先完整复制一份数据，再压缩成 ZIP。新版直接把文件逐个写入 ZIP，不再生成整份暂存副本。

在开发新版的实际电脑上，压缩前需要处理的数据从接近 6GB 降到约 1.5GB。每台电脑的数据不同，最终大小会有差异。

## 想马上备份

Mac 双击：

```text
立即备份-macOS.command
```

Windows 双击：

```text
立即备份-Windows.cmd
```

## 想关闭每天自动备份

Mac 双击：

```text
卸载-macOS.command
```

Windows 双击：

```text
卸载-Windows.cmd
```

关闭定时任务不会删除现有备份，手动备份仍然可以使用。

## 重要说明

Mac → Mac 恢复会按当前 Codex 本地格式合并 `state_5.sqlite`、会话 JSONL 和 `session_index.jsonl`。它解决的是本地任务可见性，不会把旧账号的云端权限、套餐、远程任务或服务端数据迁到新账号。

备份中可能包含私人聊天、memory、代码和工作文件。不要上传到公开 GitHub、公开网盘或发送给别人。

Windows 每日备份仍然受支持；自动合并并重新显示左侧任务的恢复流程目前先支持 Mac → Mac，不把 Mac 应用状态强行写到 Windows。

恢复逻辑参考并核对了社区项目 [codex-history-sync-tool](https://github.com/GODGOD126/codex-history-sync-tool) 与 [codex-threadripper](https://github.com/Wangnov/codex-threadripper) 对 provider、SQLite 和 JSONL 元数据的处理方式，同时增加了跨电脑传输、合并、冲突副本和回滚保护。

## 高级参数

Mac：

```bash
zsh codex_backup.sh --dry-run
zsh codex_backup.sh --include-dependencies
zsh codex_backup.sh --keep 3
zsh codex_restore_macos.sh --archive /Volumes/你的硬盘/codex-local-backup.zip --dry-run --yes
```

Windows：

```powershell
.\codex_backup.ps1 -DryRun
.\codex_backup.ps1 -IncludeDependencies
.\codex_backup.ps1 -Keep 3
```

默认仍建议使用 `Keep 1`，最省硬盘。
