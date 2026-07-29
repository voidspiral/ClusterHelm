## Why

Although nodestatus is deployed and queried by preflight, failures and stale
results are silently flattened into `status_source=legacy`. The generated
agent prompt also still describes ping/SSH as the primary path, so the Slave
can reasonably reuse legacy job fields without recognizing or reporting the
nodestatus attempt.

## What Changes

- Make nodestatus usage and fallback provenance explicit in every agent-mode
  preflight result.
- Preserve per-node nodestatus evidence even when legacy checks are required.
- Update the generated Slave prompt so node-status requests load the skill,
  while ordinary tasks consume the deterministic nodestatus-first preflight.
- Add Master routing instructions for node-status requests and delegation.
- Keep ping/SSH as a bounded fallback when nodestatus is disabled, unavailable,
  stale after probe, or incomplete.

## Capabilities

### New Capabilities

- `nodestatus-first-preflight`: Observable nodestatus-first availability checks,
  evidence preservation, and classified legacy fallback.
- `nodestatus-agent-routing`: Consistent Master-to-Slave routing and prompt
  behavior for interactive node-status requests.

### Modified Capabilities

- (none)

## Impact

- `slave/scripts/preflight/nodestatus_client.py`
- `slave/scripts/preflight/job_preflight.py`
- `slave/scripts/run-slave.sh`
- `slave/.opencode/agents/slave-agent.md`
- `master/.opencode/agents/master-agent.md`
- nodestatus integration and policy tests
