## 1. Slave skill assets

- [x] 1.1 Add the English and Chinese nodestatus operational skill files
- [x] 1.2 Add JSON, state, path, fallback, and configuration mapping reference documentation

## 2. Slave agent policy

- [x] 2.1 Register nodestatus skill permission and intent routing
- [x] 2.2 Add the local daemon-query exception and guarded single-host mutation policy
- [x] 2.3 Align availability and exclusion guidance with nodestatus-first preflight and legacy fallback

## 3. Deployment integrity

- [x] 3.1 Validate local nodestatus skill assets, metadata, agent permission, and configuration keys
- [x] 3.2 Verify remote nodestatus skill assets and agent permission after `.opencode` copy

## 4. Verification

- [x] 4.1 Check edited files for static diagnostics and review the deployment script syntax without deploying
- [x] 4.2 Validate the OpenSpec change without running the project test suite
