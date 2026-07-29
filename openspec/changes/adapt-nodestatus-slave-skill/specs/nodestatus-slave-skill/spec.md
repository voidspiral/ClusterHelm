## ADDED Requirements

### Requirement: Slave exposes a nodestatus skill
The Slave OpenCode bundle SHALL provide a `nodestatus` skill with English and
Chinese operational instructions, structured-output reference material, and a
short Chinese entry document.

#### Scenario: Agent routes a node-status request
- **WHEN** a user asks the Slave about partition health, node reachability, freshness, metrics, or exclusions
- **THEN** the Slave loads the `nodestatus` skill and uses the gateway-local nodestatus daemon

### Requirement: Skill uses ClusterHelm runtime configuration
The skill SHALL resolve the nodestatus binary, Unix socket, and query timeout
from deployed `slave.conf`, and SHALL accept only a partition defined by
deployed `partitions.conf`.

#### Scenario: Runtime paths differ from defaults
- **WHEN** `slave.conf` configures a non-default nodestatus binary or Unix socket
- **THEN** the skill command uses the configured value rather than a documented default

#### Scenario: Requested partition is not owned
- **WHEN** a request names a partition absent from the Slave's `partitions.conf`
- **THEN** the agent refuses the query or mutation without invoking nodestatus

### Requirement: Queries use the local daemon directly
The Slave SHALL run `summary`, `list`, and targeted `probe` operations through
the gateway Unix socket without creating a distributed workflow job.

#### Scenario: Aggregate status is requested
- **WHEN** a user asks for partition-level status
- **THEN** the agent invokes `summary` and reports state and freshness counts

#### Scenario: Stale node evidence needs refresh
- **WHEN** a selected owned node is stale or unknown and current evidence is required
- **THEN** the agent invokes one targeted `probe` and reports the refreshed result

### Requirement: Status mutations are explicit and bounded
The Slave MUST perform `exclude` or `clear` only after an explicit user request,
for exactly one host owned by the selected partition, with a concrete reason,
followed by one list verification.

#### Scenario: Explicit single-host exclusion
- **WHEN** a user explicitly requests exclusion of one owned host and supplies a reason
- **THEN** the agent excludes that host and verifies its effective state once

#### Scenario: Implicit or broad mutation
- **WHEN** a request does not explicitly authorize mutation or targets multiple hosts
- **THEN** the agent does not run `exclude` or `clear`

### Requirement: Reports preserve status semantics
The Slave SHALL report effective state, health state, freshness, exclusions,
and diagnostics in a consolidated `partition_report` style and SHALL NOT treat
stale online evidence as proof that a node is runnable.

#### Scenario: Exclusion overrides an offline health state
- **WHEN** a node has `state=excluded` and `health_state=offline`
- **THEN** the report identifies both the active exclusion and underlying health state

#### Scenario: Daemon query fails
- **WHEN** the local daemon query times out or returns an error
- **THEN** the interactive skill reports nodestatus as unavailable and does not create an ad-hoc SSH loop

### Requirement: Existing fallback remains authoritative
Normal job preflight SHALL continue to use its existing ping/SSH fallback when
nodestatus is disabled or unavailable, and exclusion persistence SHALL continue
to use daemon-first writes with a legacy rollback projection.

#### Scenario: nodestatus is disabled
- **WHEN** `nodestatus_enabled` is false
- **THEN** normal preflight follows the existing legacy availability path without requiring the skill to emulate it
