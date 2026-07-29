## ADDED Requirements

### Requirement: Preflight attempts nodestatus first
Every agent-mode and script-mode preflight SHALL query the partition-local
nodestatus daemon before running ping or SSH for non-excluded nodes.

#### Scenario: Fresh online evidence exists
- **WHEN** nodestatus returns a fresh online result for an owned node
- **THEN** preflight marks the node reachable without ping or SSH

#### Scenario: Nodestatus cannot establish availability
- **WHEN** nodestatus is disabled, unavailable, incomplete, or stale after probe
- **THEN** preflight runs the existing ping/SSH fallback for that node

### Requirement: Nodestatus attempts are observable
The job JSON SHALL record a top-level nodestatus snapshot for every preflight,
including whether query and probe were attempted, their classified outcomes,
and bounded diagnostics.

#### Scenario: CLI exits unsuccessfully
- **WHEN** the nodestatus CLI returns a non-zero exit status
- **THEN** the snapshot records `command_failed` and the job records that legacy fallback was used

#### Scenario: Nodestatus is disabled
- **WHEN** `nodestatus_enabled` is false
- **THEN** the snapshot records `disabled` rather than implying no attempt

### Requirement: Per-node evidence survives fallback
When nodestatus returns a node object, preflight SHALL retain that object and a
fallback reason even if ping/SSH determines final availability.

#### Scenario: Stale probe does not recover
- **WHEN** a node remains stale after a targeted probe
- **THEN** its job record contains the stale nodestatus evidence, uses
  `status_source=legacy`, and identifies the stale-after-probe fallback reason

### Requirement: Deployed runtime matches configured paths and topology
Slave deployment SHALL verify the configured OpenCode and nodestatus
executables and SHALL render the gateway nodeset from the authoritative
`partitions.conf` mapping.

#### Scenario: Installed binaries use system paths
- **WHEN** cn1 provides OpenCode and nodestatus under `/usr/local/bin`
- **THEN** deployed `slave.conf`, preflight, and the gateway service use those paths

#### Scenario: Gateway topology is stale
- **WHEN** the existing gateway configuration has a nodeset different from `partitions.conf`
- **THEN** deployment rewrites the gateway configuration and restarts the service with the authoritative nodeset
