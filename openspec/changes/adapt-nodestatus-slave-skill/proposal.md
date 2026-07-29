## Why

ClusterHelm already deploys and consumes the partition-local nodestatus daemon,
but the Slave LLM has no skill contract for querying or safely managing it.
Without that contract, node-status requests can bypass the configured binary,
socket, partition boundary, exclusion projection, and reporting policy.

## What Changes

- Add a Slave-only `nodestatus` OpenCode skill generated in the standard
  add-tools2 four-file layout.
- Route node health, freshness, exclusion, summary, and targeted-probe requests
  through the gateway-local nodestatus Unix socket.
- Permit explicit single-host `exclude` and `clear` operations with partition,
  reason, and post-operation verification guards.
- Register the skill in `slave-agent` and define nodestatus as a direct
  daemon-query exception to distributed workflow execution.
- Document the mapping between nodestat gateway settings and ClusterHelm's
  `slave.conf`, partition source of truth, and legacy fallback.
- Add deployment-stage checks that reject incomplete skill assets, missing
  agent permission, or incomplete nodestatus configuration before and after
  `.opencode` synchronization.

## Capabilities

### New Capabilities

- `nodestatus-slave-skill`: Slave-agent routing, safe command behavior,
  configuration ownership, reporting, and controlled status mutations.
- `slave-skill-deploy-validation`: Fail-fast validation of deployable OpenCode
  skill assets, agent permission, and required nodestatus runtime settings.

### Modified Capabilities

- (none; the repository has no matching baseline capability under
  `openspec/specs/`)

## Impact

- **Slave OpenCode assets:** new
  `slave/.opencode/skills/nodestatus/` documentation and policy.
- **Slave agent:** `slave/.opencode/agents/slave-agent.md` gains skill
  permission, routing, daemon-query behavior, and mutation safeguards.
- **Deployment:** `scripts/deploy/deploy-slave.sh` validates the source bundle
  and verifies remote `.opencode` files before continuing.
- **Configuration:** existing `slave/config/slave.conf`,
  `master/config/partitions.conf`, generated gateway configuration, Python
  preflight client, and exclusion bridge remain authoritative and compatible.
- **Runtime API:** no nodestatus binary or HTTP/Unix API changes.
