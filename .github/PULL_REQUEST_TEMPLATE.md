## What & why

<!-- What does this PR change, and what problem does it solve? Link the issue if there is one. -->

## Checklist

- [ ] Relevant `./scripts/unit-tests.sh -- …` checks passed; exact commands, exclusions and unavailable checks are reported (docs-only: not applicable)
- [ ] New behavior has tests; bug fixes have a test/scenario that reproduces the bug without the fix
- [ ] New features / changed behavior: e2e scenario added or updated and passing (`./scripts/e2e-test.sh --scenario "Name"`)
- [ ] No locally generated e2e screenshot baselines committed (CI owns baselines)
- [ ] New SwiftUI views have `#Preview`s
- [ ] Owning documentation updated; source paths/commands verified (`docs/README.md` index, `AGENTS.md` rules, CLI help + `ctrlx` skill when applicable)
- [ ] Formatting and boundary checks run when applicable; not assumed to have run via an AI-specific hook
- [ ] Changes stay in the assigned worktree; no unrelated edits or unrequested install/deploy/publish
