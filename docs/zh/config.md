# 配置文件说明（Source of Truth）

Master / Slave 的**分区、网关、超时**以配置文件为准；agent 规则只描述行为，**不重复**具体节点列表。

## 文件一览

| 文件 | 维护者 | 作用 |
|------|--------|------|
| `shared/partitions.conf` | 集群管理员 | 逻辑分区名 → 节点集，如 `test cn[1-10]` |
| `shared/slaves.conf` | 集群管理员 | Slave 注册表：网关 → 逻辑分区 |
| `master/config/master.conf` | Master 项目 | 默认网关/分区、SSH 超时 |
| `slave/config/slave.conf` | Slave 网关 | 节点排除阈值、TTL、持久化文件名、agent CLI |
| `slave/scripts/preflight/node_exclude.py` | — | 排除列表读写；`list` / `clear` / `check` |
| `shared/resolve-partition.py` | — | 解析 `test` → `cn[1-10]`，校验子集 |
| `master/scripts/list-slaves.py` | — | 列出 Slave；`--partition test` 查网关 |

## 查看当前 Slave 注册表

```bash
./master/scripts/list-slaves.py
./master/scripts/list-slaves.py --json
./master/scripts/list-slaves.py --partition test   # → cn1
```

## 新增 Slave 网关

1. 在 `shared/partitions.conf` 增加逻辑分区（或复用 `test`）
2. 在 `shared/slaves.conf` 增加一行：`cn26 gpu cn[26-50]`
3. 在 Master 工作区对目标网关执行 `./scripts/deploy/deploy-slave.sh cn26`（rules + skills + slave 脚本）
4. 若需网关内存 CLI，另执行 `./scripts/monitor/deploy-monitor.sh cn26`
5. Master 侧无需改 rules，运行 `list-slaves.py` 确认

## 修改 test 分区节点范围

只改 `shared/partitions.conf` 中 `test` 行，并同步 `shared/slaves.conf` 第三列（展示用），然后重新 deploy 到对应网关。
