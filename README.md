# Cluster Agent Control Plane

Master/slave Cursor agents for async partition execution.

**中文：** [`docs/zh/README.md`](docs/zh/README.md) · [配置说明](docs/zh/config.md) · [Master](docs/zh/master-agent.md) · [Slave](docs/zh/slave-agent.md)

## Config vs rules

| Layer | Files | Role |
|-------|-------|------|
| **Facts** | `partitions.conf`, `slaves.conf`, `master.conf` | Partitions, slave registry, timeouts |
| **Behavior** | `.cursor/rules/*.mdc` | How to submit/poll/preflight; points at config |

```bash
./scripts/jobs/list-slaves.py          # show managed slaves
./scripts/jobs/list-slaves.py --json
```

## Layout

```
.cursor/rules/master-agent.mdc
deploy/cn1/.cursor/rules/slave-agent.mdc
scripts/jobs/
  partitions.conf    # test → cn[1-10]
  slaves.conf        # cn1 → test
  master.conf        # defaults, poll backoff
  list-slaves.py     # registry + routing
  submit.sh / poll.sh / run-slave.sh
var/agent-jobs/
```

## Quick start

```bash
./scripts/jobs/deploy-slave.sh cn1
./scripts/jobs/submit.sh --partition test --command 'hostname'
./scripts/jobs/poll.sh --job-id job-...
```

Gateway auto-selected from `slaves.conf` unless `--gateway` is set.
