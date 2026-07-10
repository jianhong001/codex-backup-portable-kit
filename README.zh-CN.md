# 不怕 Codex 罢工

这是一个给普通用户使用的 Codex 本地备份工具，支持 macOS 和 Windows。

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

这个工具保存的是本地资料，不保证换 Codex 账号后，旧任务一定自动显示在新账号界面中。

备份中可能包含私人聊天、memory、代码和工作文件。不要上传到公开 GitHub、公开网盘或发送给别人。

Mac 和 Windows 各自备份自己的数据。v2 不会把整包 Mac 应用状态强行覆盖到 Windows，也不会自动执行可能破坏现有数据的恢复操作。

## 高级参数

Mac：

```bash
zsh codex_backup.sh --dry-run
zsh codex_backup.sh --include-dependencies
zsh codex_backup.sh --keep 3
```

Windows：

```powershell
.\codex_backup.ps1 -DryRun
.\codex_backup.ps1 -IncludeDependencies
.\codex_backup.ps1 -Keep 3
```

默认仍建议使用 `Keep 1`，最省硬盘。
