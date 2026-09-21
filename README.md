# OpenList 目录备份

`backup.sh` 将多个服务器目录合并成一个 `tar.gz`，计算 SHA-256 后通过 OpenList API 上传。远端同名文件不会被覆盖；上传成功后删除本地归档，并默认只保留 OpenList 中最近 7 份同机备份。

## 配置

脚本依赖 Bash 5、GNU tar、gzip、curl 7.71+、flock 和常见 GNU coreutils。远端清理还需要 JSON 解析器，但不要求预先安装：脚本会依次尝试系统 `jq`、`python3`、Python 3 版本的 `python`；都不可用时自动下载并校验 jq。

先创建仅当前用户可读的配置：

```bash
cd /home/simon/backup
cp .env.example .env
chmod 600 .env
```

编辑 `.env`：

- `OPENLIST_URL`：OpenList 服务地址，例如 `https://list.example.com`，末尾不要加 `/`。
- `OPENLIST_TOKEN`：可向 `/api/fs/put` 上传文件的 API Token。
- `OPENLIST_REMOTE_DIR`：OpenList 中已经存在且允许写入的目标目录。
- `BACKUP_ID`：稳定且唯一的服务器标识，用于归档名称和远端清理范围；部署后不要随意修改。省略时使用规范化后的主机名。
- `REMOTE_KEEP_COUNT`：OpenList 中保留的最新备份数量，默认 `7`；设为 `0` 可关闭远端清理。
- `SOURCE_DIRS`：多行字符串，每行一个绝对目录；目录名可以包含空格。
- `WORK_DIR`：本地临时归档目录，不能位于任何源目录内部；脚本要求它由运行用户拥有且权限不宽于 `700`。

`.env` 是会由 Bash 加载的受信任配置文件，因此脚本要求它由运行用户拥有且权限不得宽于 `600`。即使备份范围包含 `/home/simon/backup`，脚本也会从归档中排除 `.env`，避免上传 Token。

## 手动运行

```bash
chmod +x /home/simon/backup/backup.sh
/home/simon/backup/backup.sh
```

脚本用 `flock` 阻止同一时间运行多个实例。归档名称包含 `BACKUP_ID`，例如：

```text
backup-server1-20260921T020000Z.tar.gz
```

源目录会以去掉开头 `/` 的完整路径保存。例如 `/etc/nginx` 在归档中是 `etc/nginx`。脚本不跟随目录中的符号链接，配置的源目录本身也不能是符号链接。

上传使用以下 OpenList v4 接口：

```text
PUT /api/fs/put
Authorization: <token>
File-Path: <URL 编码后的目标完整路径>
Overwrite: false
X-File-Sha256: <归档校验值>
```

OpenList 的部分业务错误仍使用 HTTP 200，因此脚本还会检查 JSON 响应中的 `code` 是否为 `200`。
Token 通过权限为 `600` 的临时请求头文件交给 curl，不会出现在 curl 的命令行参数或正常日志中。

## 远端保留与解析器回退

上传成功后，脚本通过 `POST /api/fs/list` 列出目标目录，只选择严格匹配以下格式且 `BACKUP_ID` 相同的普通文件：

```text
backup-<BACKUP_ID>-YYYYMMDDTHHMMSSZ.tar.gz
```

文件名按 UTC 时间倒序排列，通过 `POST /api/fs/remove` 删除超出 `REMOTE_KEEP_COUNT` 的旧备份。其他服务器的备份、子目录和人工上传文件不会被删除。OpenList Token 必须具有目标目录的列表、上传和删除权限。

JSON 解析器按以下顺序选择：

1. 系统 `jq`。
2. 系统 `python3`。
3. 命令名为 `python`、但版本为 Python 3.6 或更高的解释器。
4. 下载官方 jq 1.8.2 到 `WORK_DIR/.tools`。

自动下载不需要 root 权限，支持 Linux x86_64、arm64、armv7、armv5/armv6 和 i386。脚本内置对应官方发布文件的 SHA-256；校验失败或下载中断时不会执行该文件。验证成功的文件会缓存，后续运行不再下载。不支持的架构需要手动安装 jq 或 Python 3。

`BACKUP_ID` 一旦改变，旧标识对应的归档不会继续被自动清理，应先在 OpenList 中人工确认和处理。

## 每天定时运行

当前服务器的 cron 服务未启用，且没有 `crontab` 命令。Debian/Ubuntu 可以先安装并启动：

```bash
sudo apt-get install cron
sudo systemctl enable --now cron
```

以当前用户执行 `crontab -e`，添加每天 UTC 时间 02:00 运行的任务：

```cron
0 2 * * * /home/simon/backup/backup.sh >> /home/simon/backup/backup.log 2>&1
```

cron 使用服务器时区；当前服务器时区是 UTC。如果将来更改服务器时区，02:00 会随之变化。

运行 cron 的用户必须能遍历并读取所有源目录。如果必须使用 root，不要让 root 定时执行位于普通用户可写目录中的脚本；应把脚本复制到 root 拥有的 `/usr/local/sbin`，把配置放到 root 拥有且权限为 `600` 的 `/etc/openlist-backup.env`，并在任务中设置：

```cron
0 2 * * * BACKUP_ENV_FILE=/etc/openlist-backup.env /usr/local/sbin/openlist-backup >> /var/log/openlist-backup.log 2>&1
```

## 失败处理与恢复

- 配置缺失、任一源目录不存在或不可读、空间耗尽、压缩失败、认证失败及上传失败都会返回非零状态。
- 未完成的 `.partial` 文件会自动删除；完整但上传失败的归档会保留在 `WORK_DIR`，不会自动清理。
- 新备份上传成功后才清理旧远端备份。若列表、解析或删除失败，新备份仍保留在 OpenList，本地归档按成功上传策略删除，但脚本返回非零状态以便 cron 日志告警。
- 如果请求成功但客户端没有收到响应，OpenList 上可能已有文件。由于禁止覆盖，先检查远端文件和 SHA-256，再决定是否删除本地副本。
- 脚本直接读取普通文件，不会暂停服务或导出数据库；正在写入的数据不具备应用级一致性。数据库应先用对应工具生成一致性导出，再把导出目录加入备份。

查看归档内容和恢复示例：

```bash
tar -tzf /var/tmp/openlist-backup/backup-server1-20260921T020000Z.tar.gz
mkdir -p /tmp/restore
tar -xzf /var/tmp/openlist-backup/backup-server1-20260921T020000Z.tar.gz -C /tmp/restore
```

不要未经检查直接解压到 `/`，以免覆盖当前系统文件。
