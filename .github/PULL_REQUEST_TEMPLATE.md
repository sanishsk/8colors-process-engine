## Summary

<!-- One sentence: what this PR does and why. -->

## Type

- [ ] New agent
- [ ] New command
- [ ] New skill
- [ ] New hook
- [ ] New doctrine doc
- [ ] Bug fix
- [ ] Refactor / cleanup
- [ ] Docs only

## Generalizability check

<!-- The CONTRIBUTING.md bar is "this generalizes the doctrine without
watering it down." -->

- [ ] No project-specific code (no `8colors`, `8CStudio`, `BTW`, `Razorpay`, `Zitadel`, etc.)
- [ ] No hard service deps (no required cloud provider, paid API as the default path, etc.)
- [ ] No watered-down doctrine (OSS-first rule still binding; code-reviewer still mandatory; etc.)

## Test plan

<!-- How you verified this works. For new install paths, smoke-test
against a tmp dir. -->

- [ ] `pe doctor` clean
- [ ] `pe install /tmp/some-test-project` succeeds
- [ ] (if launchd / systemd / Task Scheduler changes) plist / unit / .ps1 syntax validated
- [ ] (if hook changes) tested on a real commit

## Version impact

- [ ] No version bump needed (docs / typo fix)
- [ ] Patch (vX.Y.Z+1): bug fix, no surface change
- [ ] Minor (vX.Y+1.0): new feature, backwards-compatible
- [ ] Major (vX+1.0.0): breaking change

If a version bump is needed, did you:

- [ ] Update `VERSION`
- [ ] Update `plugin.json` `version`
- [ ] Update the README version badge
- [ ] Add a `## [<version>] — YYYY-MM-DD` block to `CHANGELOG.md`
