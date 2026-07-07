# 不怕 Codex 罢工

Mac 上的 Codex 本地备份小工具。

## 最简单用法

1. 下载这个仓库。
2. 双击 `install.command`。
3. 以后每天晚上 23:50 自动备份。

备份保存到：

```text
~/Documents/不怕codex罢工
```

默认只保留最新 1 份备份。新备份成功以后才删除旧备份；如果新备份失败，旧备份会继续保留。

## 手动备份

双击：

```text
backup-now.command
```

## 关闭自动备份

双击：

```text
uninstall.command
```

关闭自动备份不会删除已有备份。

## 备份内容

- `~/.codex` 中的 Codex memory、sessions、skills、配置和日志
- `~/Documents/Codex` 中的工作区和输出文件
- `~/.agents/skills`
- Codex App 本地应用数据

默认不会备份 `auth.json` 登录令牌。

## 不要上传这些内容

不要把实际生成的 `codex-local-backup-*.zip` 上传到 GitHub。里面可能包含聊天记录、memory、项目文件和私人资料。
