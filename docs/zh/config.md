# 配置文件说明（Source of Truth）

Master / Slave 的**分区、网关、超时**以本目录配置文件为准；`.cursor/rules/*.mdc` 只描述行为，**不重复**具体节点列表。

## 文件一览

| 文件 | 维护者 | 作用 |
|------|--------|------|
| `partitions.conf` | 集群管理员 | 逻辑分区名 → 节点集，如 `test cn[1-10]` |
| `slaves.conf` | 集群管理员 | Slave 注册表：网关 → 逻辑分区 |
| `master.conf` | Master 项目 | 默认网关/分区、轮询退避、SSH 超时 |
| `slave.conf` | Slave 网关 | 节点排除阈值、TTL、持久化文件名 |
| `node_exclude.py` | — | 排除列表读写；`list` / `clear` / `check` |
| `resolve-partition.py` | — | 解析 `test` → `cn[1-10]`，校验子集 |
| `list-slaves.py` | — | 列出 Slave；`--partition test` 查网关 |

## 查看当前 Slave 注册表

```bash
./scripts/jobs/list-slaves.py
./scripts/jobs/list-slaves.py --json
./scripts/jobs/list-slaves.py --partition test   # → cn1
```

## 新增 Slave 网关

1. 在 `partitions.conf` 增加逻辑分区（或复用 `test`）
2. 在 `slaves.conf` 增加一行：`cn26 gpu cn[26-50]`
3. 在 Master 工作区对目标网关执行 `./scripts/jobs/deploy-slave.sh cn26`（rules + skills + slave 脚本）
4. 若需网关内存 CLI，另执行 `./scripts/monitor/deploy-monitor.sh cn26`
5. Master 侧无需改 rules，运行 `list-slaves.py` 确认

## 修改 test 分区节点范围

只改 `partitions.conf` 中 `test` 行，并同步 `slaves.conf` 第三列（展示用），然后重新 deploy 到对应网关。
