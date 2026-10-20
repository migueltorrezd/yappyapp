## Summary

## Privacy / Permission Impact

- [ ] No change to microphone handling
- [ ] No change to transcript/audio storage
- [ ] No change to clipboard or paste behavior
- [ ] No change to network/model downloads
- [ ] No change to signing, launch-at-login, or Accessibility behavior

## Verification

- [ ] `./scripts/doctor.sh`
- [ ] `./scripts/run_tests.sh`
- [ ] `./scripts/package_app.sh`
- [ ] `./scripts/create_dmg.sh`
- [ ] `./scripts/dmg_smoke.sh`
- [ ] `./scripts/release_artifacts_smoke.sh`
- [ ] `./scripts/check_packaged_notices.sh`
- [ ] `./scripts/check_ignore_policy.sh`
- [ ] `./scripts/check_docs_links.sh`
- [ ] `./scripts/check_model_catalog_sync.sh`
- [ ] `./scripts/check_no_model_weights.sh`
- [ ] `./scripts/check_privacy_artifacts.sh`
- [ ] `./scripts/check_network_policy.sh`
- [ ] `./scripts/support_report.sh`
- [ ] `codesign --verify --deep --strict --verbose=2 dist/YappYapp.app`

## Manual QA Notes
