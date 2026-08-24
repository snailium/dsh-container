# dsh 会话/工作区迁移指南 (session-migration.md)

> 适用的 dsh 版本：`@deepseek-ai/dsh` 全局包（本仓库 0.1.1-rc.x）
> 写于 2026-08-23，基于一次真实的容器化迁移实践。

本指南解决一个核心问题：**更换 dsh 的工作区路径后，历史会话如何迁移（而不被归到 "Ungrouped"/未分组）**。

---

## 1. 背景：会话如何存储与归类

### 1.1 存储位置
每个会话是一个目录，日志是 `session.jsonl.zstd`：

```
$DSH_HOME/sessions/<项目目录>/session-<会话id>/session.jsonl.zstd
```

- `$DSH_HOME` —— dsh 数据根（本镜像为 `/dsh-home`，宿主 bind mount）。
- `<项目目录>` —— 由会话的 **cwd** 编码而来（见下）。
- 日志为 zstd 压缩的多帧 JSONL（见 §3 格式坑）。

### 1.2 会话的"身份" = header 里的 `cwd` 字段
会话日志首行是一个 header JSON：

```json
{"type":"session","version":0,"id":"session-xxx","cwd":"/workspace/deepseek-harness", ...}
```

`cwd` 是**创建会话那一刻固化的绝对路径，终生不变**。它是会话归属工作区的**唯一依据**。

### 1.3 工作区归类是"派生"的，不是存储移动
dsh 启动时扫描所有会话 header：

1. 有效 cwd（目录存在）→ `sessionPath = realpath(cwd)`
2. 按 cwd 归组 → 每个 cwd 生成一个 **workspace 实体**，`workspace.path = 该组 cwd`
3. `workspace.sessionIds` = 筛选 `sessionPath(id) === workspace.path` 的会话
4. **无 cwd 或 cwd 目录缺失** → 会话变成 "stray" → 在 UI 归入 **Ungrouped / 未分组**

### 1.4 核心结论
**「换工作区路径而导致旧会话进 ungrouped」是必然的**，除非把旧会话 header 里的 `cwd` 改成新路径，并同时把物理目录名改对。

---

## 2. 迁移方案总览

迁移 = 两个必须**原子同步**的动作（否则触发 corrupt 校验，见 §4）：

| 动作 | 内容 |
|---|---|
| **改 cwd** | 会话日志 `header.cwd` 从旧路径改为新路径 |
| **改物理目录名** | `sessions/<旧编码>/` 改名为 `<新编码>/`（编码规则见 §3.2）|

> ⚠️ dsh 的 `assertStoredIdentity` 校验：`header.cwd 算出的 logPath === 实际存储路径`。**cwd 和目录名必须一致**，否则报 `corrupt session log: header id and cwd identify <path>`。

### 2.1 典型场景
以下文档基于一个具体案例（可推广到任意路径变更）：

| 项 | 旧值 | 新值 |
|---|---|---|
| 工作区宿主目录 | `/home/user/deepseek-harness` | `/home/user/deepseek-workspace/deepseek-harness` |
| 容器内挂载 | 同路径 bind | 宿主 `/home/user/deepseek-workspace` → 容器 `/workspace` |
| 会话 cwd | `/home/user/deepseek-harness`（或旧 workdir）| `/workspace/deepseek-harness` |

---

## 3. 关键格式知识（必读，避免踩坑）

### 3.1 会话日志是"多帧 zstd"，不是单帧
**每个 JSONL 记录批是一个独立的 zstd frame**，多个 frame 拼接成一个文件：

```
[frame: header 一行+\n][frame: 事件批1][frame: 事件批2]...
```

- **header 帧** 解压后必须恰好是 `header JSON + 一个 \n`（index.js 的 `assertZstdHeaderFrame` 校验）。
- **body 帧** 的明文必须整好落在**完整 JSONL 记录批的边界**上，不能有"半个记录"被截断在帧边界（否则 `committedBytes !== inputBytes`，报 torn JSONL record）。

> 🔴 **铁律：迁移时绝不要"整文件解压→按行重压"**。这样会破坏 body 帧边界，dsh 读取时必然报 `complete frame contains a torn JSONL record`。
>
> ✅ **正确做法：只重建 header 帧（改 cwd），body 帧字节级原样保留**。

### 3.2 项目目录名编码规则
dsh 把 cwd 绝对路径编码为目录名（`projectKey`）：

- `/` `\` `:` → `-`（**连续分隔符折叠为单个 `-`**）
- 字母数字 `._-` 保留
- **其它字符（含字面 `~`）** → `~XXXX`（UTF-16 十六进制大写）——保留集显式排除 `~`
- **结果截断到 251 字符**
- 包在 `--` 中

例子：
```
/workspace                      → --workspace--
/workspace/deepseek-harness     → --workspace-deepseek-harness--
/home/user/deepseek-harness     → --home-user-deepseek-harness--
```

### 3.3 压缩参数
dsh 用 `node:zlib.zstdCompressSync(input, { params: { ZSTD_c_checksumFlag: 1 } })`，即**带 checksum 的标准 zstd frame**。`zstd` CLI 默认兼容。但重压仅限 header 帧。

---

## 4. 完整迁移步骤

> 前置：**永远先备份**。本文假设已有完整备份可用。

### 4.0 备份
```bash
BK=/backup/migrate-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"
cp -a $DSH_HOME/sessions "$BK/sessions"          # 会话全量(含zstd)
cp -a $DSH_HOME/storages/workspace.json "$BK/"   # workspace registry
cp -a $DSH_HOME/storages/session_projcache.json "$BK/"
cp -a $DSH_HOME/integrations/*/workspaces.json "$BK/" 2>/dev/null   # 仅 when 装了 dsh-im(Telegram) 插件才存在, 可选
cp -a .env "$BK/.env"                             # compose 配置
```

### 4.1 停容器（避免迁移期间并发写）
```bash
cd <repo> && docker compose stop
```

### 4.2 迁移宿主目录（按你的方案）
```bash
mkdir -p /home/user/deepseek-workspace
mv /home/user/deepseek-harness /home/user/deepseek-workspace/deepseek-harness
```

### 4.3 迁移会话（核心）
用附录的 `fix_header_only.js`，**对每个会话**：

1. 读原文件，定位第一帧（header 帧）的压缩长度
2. 解压 header 帧 → 改 `cwd` → 重新压缩（带 checksum）
3. body 帧字节级原样拼接，**原地**写回该会话目录（脚本只改 header，不搬目录）
4. 随后把会话目录 `--<旧key>--/<session-id>/` 移入 `--<新key>--/`（目录改名由你来做，必须与 header 的新 cwd 一致）

```bash
# for each session dir: 先原地改 header, 再移到新 projectKey 目录
# ⚠️ `--` 前缀目录名会被 shell 当 option, 用 `./` 前缀 + glob
for sd in ${DSH_HOME}/sessions/./--<旧key>--/session-*; do
  node fix_header_only.js "$sd" <old_cwd> <new_cwd>          # 原地改 cwd
  mkdir -p ${DSH_HOME}/sessions/--<新key>--
  mv "$sd" ${DSH_HOME}/sessions/--<新key>--/                 # 移入新目录
done
rm -rf ${DSH_HOME}/sessions/--<旧key>--                      # 旧目录清空后删除
```

### 4.4 同步注册表
- `$DSH_HOME/storages/workspace.json`：把旧 path 的 workspace 记录 `path` 改新路径
- `$DSH_HOME/storages/session_projcache.json`：把迁移会话的 `identity.cwd` 改新路径
- `$DSH_HOME/integrations/<bot>/workspaces.json`：**仅 when 装了 dsh-im(Telegram) 插件**——把 bot 的工作区绑定改新路径（用**容器内**路径，如 `/workspace/deepseek-harness`）。没有该插件则忽略此条。

### 4.5 更新 .env 与 compose 挂载
```bash
DSH_WORKSPACE_DIR=/home/user/deepseek-workspace   # 挂到容器 /workspace
```
确认 compose：`${DSH_WORKSPACE_DIR}:/workspace`。

### 4.6 启动并验证
```bash
docker compose up -d
# 1) 容器 healthy, 日志无 corrupt/torn
# 2) workspace.json 含新 path 且收编正确会话
# 3) 用附录 scan_verify.js 对每个迁移会话做 scanner 校验
# 4) UI 实际加载历史对话(终极验证)
```

---

## 5. 迁移检查清单

- [ ] 迁移**前**完整备份（sessions + 3个 storages + workspaces.json + .env）
- [ ] 停容器
- [ ] **只重建 header 帧**，body 原样（绝不逐行重压）
- [ ] cwd 和物理目录名**原子同步**（编码规则一致）
- [ ] workspace.json / session_projcache.json / workspaces.json 全部同步
- [ ] .env 的 DSH_WORKSPACE_DIR 正确
- [ ] 启动后 scanner 校验零 torn
- [ ] UI 实际加载历史对话成功

---

## 6. 常见坑与教训

| # | 坑 | 症状 | 修复 |
|---|---|---|---|
| 1 | `zstd | head -1` 管道触发 SIGPIPE | 迁移脚本中途退出，部分会话漏迁 | 校验时不要用 `head` 提前关管道；改用全读 |
| 2 | 整文件解压后逐行重压 | `complete frame contains a torn JSONL record` | **只重建 header 帧，body 原样** |
| 3 | 改 cwd 但没同步目录名 | `corrupt session log ... header id and cwd identify` | 目录名用 projectKey(新cwd) 重命名 |
| 4 | 旧 workspace registry path 没更新 | 会话挂在容器内不存在的老路径 | 同步改 workspace.json |

---

## 附录 A：`fix_header_only.js`（只重建 header 帧）

<details>
<summary>展开脚本</summary>

```js
#!/usr/bin/env node
// 只重建 header 帧(改cwd), body 帧原样保留。
// 用法: node fix_header_only.js <dir> <old_cwd> <new_cwd>
// ⚠️ 脚本原地改 dir 里的 session.jsonl.zstd 的 header; 目录改名(移入 --<新key>-- 目录)
// 由调用方完成(见 §4.3)。frameLen() 靠扫下一帧 magic(0xFD2FB528) 定帧长是启发式——误判时
// 解压/header 校验会在写入前抛错并安全中止(不会留下半改文件)。
const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");
const CHECKSUM = { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } };

function frameLen(buf, start) {
  for (let i = start + 1; i + 4 <= buf.length; i++)
    if (buf.readUInt32LE(i) === 0xFD2FB528) return i - start;
  return buf.length - start;
}

const dir = process.argv[2], oldCwd = process.argv[3], newCwd = process.argv[4];
const log = path.join(dir, "session.jsonl.zstd");
const raw = fs.readFileSync(log);
const hlen = frameLen(raw, 0);
const headerText = zlib.zstdDecompressSync(raw.subarray(0, hlen)).toString("utf8");
if (headerText.indexOf("\n") !== headerText.length - 1) throw new Error("首帧非完整 header 行");
const hdr = JSON.parse(headerText.trim());
if (hdr.cwd !== oldCwd) throw new Error(`cwd 不匹配: ${hdr.cwd} != ${oldCwd}`);
hdr.cwd = newCwd;
const newHeaderFrame = zlib.zstdCompressSync(
  Buffer.from(JSON.stringify(hdr, undefined, 0) + "\n", "utf8"), CHECKSUM);
const newBuf = Buffer.concat([newHeaderFrame, raw.subarray(hlen)]); // body 原样
fs.writeFileSync(log + ".fix", newBuf);
fs.renameSync(log + ".fix", log);
console.log(`✓ ${path.basename(dir)} cwd ${oldCwd}->${newCwd}`);
```

</details>

---

## 附录 B：`scan_verify.js`（scanner 严格校验，验证历史可加载）

<details>
<summary>展开脚本</summary>

```js
#!/usr/bin/env node
// 用 dsh SessionLogScanner 逻辑校验: 每会话 body 帧无 torn。用尽 dsh 相同规则。
const zlib = require("node:zlib"), fs = require("node:fs"), path = require("node:path");
function frameLen(buf, start){for(let i=start+1;i+4<=buf.length;i++)if(buf.readUInt32LE(i)===0xFD2FB528)return i-start;return buf.length-start}
function decodeFrames(buf){const f=[];let o=0;while(o+4<=buf.length){if(buf.readUInt32LE(o)!==0xFD2FB528)break;try{f.push(zlib.zstdDecompressSync(buf.subarray(o)));o+=frameLen(buf,o)}catch{o=buf.length}}return f}
function scan(frames){let buf="",committed=0;for(const f of frames){buf+=f.toString("utf8");let nl;while((nl=buf.indexOf("\n"))!==-1){buf=buf.slice(nl+1);committed++}}return{committed,pending:buf.length}}
const root=process.argv[2]||"/dsh-home/sessions";let fail=0;
for(const proj of fs.readdirSync(root)){const p=path.join(root,proj);if(!fs.statSync(p).isDirectory())continue;
  for(const sid of fs.readdirSync(p)){if(!sid.startsWith("session-"))continue;
    const b=fs.readFileSync(path.join(p,sid,"session.jsonl.zstd"));
    const frames=decodeFrames(b);if(!frames.length){console.log(`✗ ${sid} 空/解码失败`);fail++;continue}
    const hdrT=frames[0].toString("utf8");const hdrOk=hdrT.indexOf("\n")===hdrT.length-1;
    const s=scan(frames.slice(1));const ok=hdrOk&&s.pending===0;
    if(!ok)fail++;console.log(`${ok?"✓":"✗"} ${sid} header整行:${hdrOk} body${s.committed}记录 无torn:${s.pending===0}`)}}
console.log(`\n${fail===0?"全部通过(dsh历史可加载)":fail+" 个失败"}`);process.exit(fail?1:0);
```

</details>

---

## 附注：为什么这是 dsh 的行为

- header.cwd 在会话创建时固化（`toHeaderLine`）。
- `assertStoredIdentity` 强校验 cwd ↔ 存储路径一致（`dsh-session-persistence-jsonl`）。
- `dsh-workspace` 的 `bootstrap()` 按 cwd 归组生成 workspace；`workspace.sessionIds` 筛选 `sessionPath === path`。无 cwd 会话成 stray → Ungrouped。

如需在「迁移会话到新工作区的同时，旧工作区数据也搬移」，把 §4.2 的目录 mv 和 §4.3 的会话迁移配套执行即可。