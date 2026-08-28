# mpi-monitor Slave smoke prompts

Submit from `master/` with `./scripts/submit.sh --partition test --prompt '…'`.

## 1. CLI hard gate only (`--task mpi-monitor-gate`)

```
加载 mpi-monitor skill。先做 CLI 硬门禁：用 bash argv 数组（或 /home/cn1/agents/vendor/mpi-monitor/scripts/probe-cli.sh）探测 PATH 上的 mpi-monitor、/home/cn1/agents/vendor/mpi-monitor/.venv/bin/mpi-monitor、以及 PYTHONPATH=/home/cn1/agents/vendor/mpi-monitor/src 下的 import，然后 "${argv[@]}" probe。禁止把多词命令塞进 MPI_MON 再 "$MPI_MON"（会 No such file）。未安装则 status=failed 并立即停止（不要 preflight、不要 wrap、不要 pip）。已安装则报告 argv 实际列表、probe 输出、版本、探测命中哪一条路径。不要 wrap 作业。按契约输出 partition_report。
```

## 2. Wrap smoke (`--task mpi-monitor-wrap`)

`--match` 只匹配 comm/argv0（或 shebang argv1），**不要**用 `python3 -c "MARKER=1"`（`-c` 不会被当成可执行文件名）。

```
加载 mpi-monitor skill。先做 CLI 硬门禁（argv 数组 + probe，禁止 "$MPI_MON"），失败则立即 failed 停止。通过后对 test 分区 preflight。仅在本网关短主机名上 wrap 一个短进程（进程只跑在网关，--hosts 不要包含 cn2/cn3）：先写 /tmp/ClusterHelmMpiMonSmoke（内容：python  sleep 8）；--match ClusterHelmMpiMonSmoke；--interval 0.5；--output-dir 用 $AGENT_JOB_DIR/mpi-monitor（若无该变量则 /home/cn1/agents/var/agent-jobs/mpi-monitor）；命令：python3 /tmp/ClusterHelmMpiMonSmoke。汇报 meta.json（run_id、exit_code、hosts、match、collect_errors）、series 文件列表与样本数字段（host/pid/cpu_pct/rss_mb）。作业 JSON 用 mpi-monitor job-json（平铺 {AGENT_JOB_DIR}/{id}.json，不要套一层目录）。不要 dump 原始 JSONL，不要把 collect 扇出到 run-slave.sh --command。按契约输出 partition_report。
```
