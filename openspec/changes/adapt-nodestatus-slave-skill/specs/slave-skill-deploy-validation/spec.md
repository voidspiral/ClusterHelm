## ADDED Requirements

### Requirement: Deployment validates local skill assets
The Slave deployment script MUST validate the nodestatus skill bundle, its
OpenCode metadata, Slave-agent permission, and required nodestatus
configuration keys before copying `.opencode` to a gateway.

#### Scenario: Skill file is missing
- **WHEN** any of `SKILL.md`, `SKILL.zh.md`, `reference.md`, or `README.zh.md` is absent
- **THEN** deployment exits with an error naming the missing file before any remote copy

#### Scenario: Agent permission is missing
- **WHEN** `slave-agent.md` does not grant `nodestatus: allow`
- **THEN** deployment exits before copying an unusable skill bundle

#### Scenario: Required runtime key is missing
- **WHEN** `slave.conf` lacks a required nodestatus key or its value is empty
- **THEN** deployment exits with an error naming that key

### Requirement: Deployment verifies remote OpenCode copy
After copying `.opencode`, the deployment script MUST confirm that the remote
gateway contains all nodestatus skill files and the Slave agent permission
before continuing with configuration and runtime-script deployment.

#### Scenario: Remote transfer is incomplete
- **WHEN** one or more expected skill files are absent after the copy
- **THEN** deployment exits before copying Slave configuration or runtime scripts

#### Scenario: Remote agent definition is stale
- **WHEN** the remote `slave-agent.md` lacks `nodestatus: allow` after the copy
- **THEN** deployment exits before continuing

### Requirement: Validation adds no runtime dependency
Deployment validation SHALL use tools already required by the Bash deployment
environment and SHALL NOT require the nodestatus daemon to be running.

#### Scenario: nodestatus is intentionally disabled
- **WHEN** `nodestatus_enabled` is present and set to `false`
- **THEN** bundle validation succeeds if all assets and configuration keys are structurally complete
