## 1. Slave workflow contract

- [x] 1.1 Add JSON workflow definitions for `node-command`, `hostname-check`, `memory-monitor`, and `fullcore-mpi`
- [x] 1.2 Define typed arguments, deterministic implementations, success policy, and `max_attempts`
- [x] 1.3 Add tests for catalog loading, unknown workflows, and argument validation

## 2. Aggregated workflow runner

- [x] 2.1 Implement `workflow-runner.py list|describe|run`
- [x] 2.2 Reuse `run-slave.sh submit` plus blocking `wait` for deterministic execution
- [x] 2.3 Return structured `outcome`, `reason_code`, attempt, job, and preserved `partition_report`
- [x] 2.4 Add tests for success, execution failure, timeout, contract failure, exclusion-only partial, and retry budget

## 3. Deployment

- [x] 3.1 Deploy workflow registry and runner with Slave assets
- [x] 3.2 Deploy or validate the monitor and MPI implementations referenced by built-in workflows

## 4. Slave agent policy

- [x] 4.1 Add mandatory normalize → match → run once → report state machine to `slave-agent.md`
- [x] 4.2 Forbid exploratory happy-path commands, per-node SSH, LLM-managed polling, and post-success extra checks
- [x] 4.3 Permit only one diagnosis and one targeted retry after an exception; preserve the deterministic report

## 5. Documentation and verification

- [x] 5.1 Update Slave Chinese docs and Slave-related architecture text without changing Master routing policy
- [x] 5.2 Verify known success, known failure, and missing-implementation flows
- [x] 5.3 Run test suite and `openspec validate slave-predefined-flow`
