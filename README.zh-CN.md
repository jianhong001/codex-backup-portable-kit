# 不怕 Codex 罢工

**这是一个不需要每天操作的 Codex 本地备份工具。每天 23:50 由电脑系统直接备份，不启动 Codex，不调用模型，自动备份消耗 0 token。**

它解决的是本地资料不见、换电脑、换账号后历史任务不显示时的后路：聊天、memory、skills、项目和生成内容仍留在你自己手里。

## 先做这两步

**只想带走一个项目或一条聊天？** 在完整工具包内双击 `转移选定聊天-macOS.command`：旧 Mac 选择导出，新 Mac 选择导入，只传一个 ZIP，不需要安装每日备份或输入配对码。默认包含聊天和实际项目文件，不包含其他聊天或全局 memory/skills。完整步骤与限制见 [怎么用.md](怎么用.md)。此入口为当前源码新增功能，未发布的源码不代表 GitHub 最新 Release 已包含它。

以下是整机每日备份的安装步骤：

1. 从 [Releases](https://github.com/jianhong001/codex-backup-portable-kit/releases/latest) 下载最新版并解压。
2. Mac 双击 `安装-macOS.command`，Windows 双击 `安装-Windows.cmd`。

之后不需要每天点。备份会放在：

```text
Mac：文稿/不怕codex罢工
Windows：文档/不怕codex罢工
```

新 ZIP 必须完整校验成功，才会成为新的正式备份。任何失败都不会删除你的原文件，也不会删掉上一份已验证备份。

## 默认保存什么

- 本地聊天 JSONL、侧栏索引、SQLite 状态、memory、skills
- `Documents/Codex` 里的代码、文档、输出文件和 Git 历史
- `~/.agents/skills` 里的共享 skills
- 生成图片、附件、自动化、可视化等不能重新下载的本地内容

## 默认不保存什么

- `auth.json`、`config.toml`、`.env`、私钥、凭据文件、Git 远程配置
- Cookie、浏览器登录数据和 Codex App 浏览器资料
- 可以重新下载的 Codex 组件、大型日志、缓存和临时文件
- 项目里的 `.venv`、`venv`、`node_modules`、`__pycache__` 和常见开发缓存

这些只是“不装进 ZIP”，不会删除电脑里的原文件。需要依赖时可用高级参数 `--include-dependencies` 或 `-IncludeDependencies`。普通备份也保留 `--include-auth`，但它会包含登录令牌，必须私下保管；Mac 迁移包永远不会包含账号凭据。

## 换 Mac 或换 OpenAI 账号

Mac → Mac 提供离线合并恢复。它是“本地资料迁移”，不是 OpenAI 官方账号迁移：只在新旧 Mac 的本地 Codex 索引格式兼容时合并，并且不会迁移云端权限、订阅或服务端数据。

### 旧 Mac 怎么做

1. 打开 `文稿/不怕codex罢工`，双击 `第1步-旧Mac制作迁移包.command`。
2. 程序会请求 Codex 安全退出，保证迁移包一致。
3. 完成后，在 `文稿/不怕codex罢工/迁移包` 会出现一组文件。
4. 把其中唯一的 `codex-migration-*.zip`、同名 `.sha256`、同名 `.signature` 复制到 U 盘、移动硬盘或其他私密传输方式。
5. 记下旧 Mac 显示的配对码。第一次在新 Mac 导入这台旧 Mac 时要输入一次。

外接硬盘只负责带数据，里面不需要、也不应该运行任何脚本。

### 新 Mac 怎么做

1. 先安装最新版“不怕 Codex 罢工”。再登录目标 OpenAI 账号，打开 Codex 一次，然后完全退出 Codex。
2. 把旧 Mac 的 ZIP、`.sha256`、`.signature` 三个文件都复制到 `文稿/不怕codex罢工/待恢复`。里面只能有一个 ZIP。
3. 在新 Mac 本机的 `文稿/不怕codex罢工` 双击 `第2步-新Mac恢复聊天.command`。
4. 如果是第一次导入这台旧 Mac，输入刚才记下的配对码。

程序会先验证签名、配对码、磁盘空间和本地数据结构，再建立可回滚事务和“恢复前安全备份”。恢复后会马上创建并校验一份新的本机备份。只有这份新备份成功，`待恢复` 里的三个迁移文件才会自动删除。

恢复结果：

- 新 Mac 已有聊天、项目、账号设置不会被覆盖。
- 同一个任务 ID 两边内容不同，会保留两个可见副本；重复恢复不会无限复制。
- 旧 Mac 的项目单独放到 `旧 Mac 导入项目/<旧设备编号>`，侧栏名称会自动带旧 Mac 电脑名。
- 新 Mac 原有同名项目仍是独立项目。
- `auth.json`、`config.toml`、Cookie、旧账号登录状态和订阅不会写入新 Mac。

## 为什么不太占硬盘

程序逐文件写入 `*.partial.zip`，不会先复制出一整份临时资料。SQLite 在系统有 `sqlite3` 时会先做一致性快照。校验文件先准备好，最后一步才把临时 ZIP 改为正式 ZIP。

默认只保留最新一份“校验正确”的正式备份。旧的损坏 ZIP 或老版本 ZIP 不会被偷偷删除，只会不参与自动淘汰，方便你自己检查。

定时备份、迁移、恢复和安装共用互斥锁，不会同时改聊天数据库。日志只保留一份 `last-run.log`，不会越积越大。

## Windows 说明

Windows 同样支持每天 23:50、0 token、流式 ZIP、敏感文件排除、SHA-256 校验、只保留最新有效备份，以及错过时间后由任务计划程序补做。

当前“把旧聊天重新合并到 Codex 左侧任务栏”的自动恢复只优先支持 Mac → Mac。Windows 备份仍然可以保存和带走本地资料，但不承诺跨系统侧栏恢复。

## 想手动操作

立即备份：双击 `立即备份-macOS.command` 或 `立即备份-Windows.cmd`。

关闭每天自动备份：双击 `卸载-macOS.command` 或 `卸载-Windows.cmd`。关闭不会删除已有 ZIP。

高级参数：

```bash
zsh codex_backup.sh --dry-run
zsh codex_backup.sh --include-dependencies
zsh codex_backup.sh --keep 3
zsh codex_backup.sh --migration --dest ~/Documents/不怕codex罢工/迁移包
```

```powershell
.\codex_backup.ps1 -DryRun
.\codex_backup.ps1 -IncludeDependencies
.\codex_backup.ps1 -Keep 3
```

## 重要安全边界

备份可能包含私人聊天、memory、代码和工作文件。不要上传到公开 GitHub、公开网盘或发送给不可信的人。

这个工具保护的是本地资料和可验证的迁移包，不保证 OpenAI 云端聊天、套餐、权限或未来 Codex 版本的内部格式一定可迁移。更多说明见 [SECURITY.md](SECURITY.md)。
