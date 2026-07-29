## 1. Tests

- [x] 1.1 Add failing tests for query failure classification and top-level attempt metadata
- [x] 1.2 Add failing tests for stale evidence preservation and fallback reasons
- [x] 1.3 Add policy tests for generated Slave prompt and Master delegation

## 2. Preflight

- [x] 2.1 Add backward-compatible detailed nodestatus query and probe results
- [x] 2.2 Persist top-level attempt metadata and per-node nodestatus evidence
- [x] 2.3 Classify final decision source and fallback reason
- [x] 2.4 Align deployed runtime paths and gateway topology with configuration SoT

## 3. Agent routing

- [x] 3.1 Align the generated Slave prompt with nodestatus-first preflight
- [x] 3.2 Require skill loading for explicit status intents
- [x] 3.3 Add Master nodestatus delegation policy and example

## 4. Verification and rollout

- [x] 4.1 Run targeted tests and static diagnostics
- [ ] 4.2 Validate the OpenSpec change
- [ ] 4.3 Deploy Slave assets to cn1 and verify a status-intent job
