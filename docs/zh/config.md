# 配置文件说明（Source of Truth）

分区与网关登记在 **Master**；Slave 运行时配置在 **Slave**。agent 规则只描述行为，不重复节点列表。

## 文件一览

| 文件 | 维护者 | 作用 |
|------|--------|------|
| `master/config/partitions.conf` | 集群管理员（Master SoT） | 逻辑分区名 → 节点集，如 `test cn[1-10]` |
| `master/config/slaves.conf` | 集群管理员（Master SoT） | Slave 注册表：网关 → 逻辑分区 |
| `master/config/master.conf` | Master | 默认网关/分区、SSH 超时 |
| `slave/config/slave.conf` | Slave 网关 | 节点排除、agent CLI、MPI 路径 |
| `slave/scripts/resolve-partition.py` | — | 解析 `test` → 节点集；读 `config/partitions.conf`（部署自 Master） |
| `master/scripts/list-slaves.py` | — | 列出 Slave；`--partition test` 查网关 |

`deploy-slave.sh` 会把 `master/config/partitions.conf` 拷到网关 `config/`（**不**部署 `slaves.conf`）。

## 查看当前 Slave 注册表

```bash
./master/scripts/list-slaves.py
./master/scripts/list-slaves.py --json
./master/scripts/list-slaves.py --partition test   # → cn1
```

## 新增 Slave 网关

1. 在 `master/config/partitions.conf` 增加逻辑分区（或复用 `test`）
2. 在 `master/config/slaves.conf` 增加一行：`cn26 gpu cn[26-50]`
3. `./scripts/deploy/deploy-slave.sh cn26`
4. 若需内存 CLI：`./scripts/monitor/deploy-monitor.sh cn26`
5. `list-slaves.py` 确认

## 修改 test 分区节点范围

改 `master/config/partitions.conf` 中 `test` 行，同步 `master/config/slaves.conf` 第三列（展示用），再 `deploy-slave.sh` 到对应网关。
