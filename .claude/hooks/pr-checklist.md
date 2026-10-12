Complete the applicable PR checks before stopping:

Follow `CONTRIBUTING.md` and `.github/PULL_REQUEST_TEMPLATE.md`. This reminder
does not grant permission to expand the task, delegate, install, publish or deploy.

1. Update the owning technical topic when behavior changes. Use `docs/README.md`
   to find it; update `AGENTS.md` only when repository-wide instructions change.
2. For CLI changes, update the CLI reference and bundled `ctrlx` skill. If a new
   CLI command might be useful but is outside the agreed scope, report it as a
   follow-up instead of implementing it automatically.
3. Run the checks appropriate to the change in `CONTRIBUTING.md`. Record exact
   commands, results and exclusions; documentation-only changes need no app build.
4. For changed app interactions, add or update a targeted end-to-end scenario
   and inspect the result. Bug fixes need a regression that demonstrates the
   failure and the fix. Follow `docs/e2e-testing.md` for screenshots, `--record`
   and proof-video attachment to the PR; attach failing evidence before recording
   again, because a new run can overwrite it. Honor real-device-only constraints.
5. Do not commit locally generated screenshot baselines or videos. Baselines are
   CI-generated; remove obsolete baselines only for intentionally changed scenes.
6. Add useful `#Preview` states for new SwiftUI views where feasible.

Do not assume GUI permissions, devices or signing identities are available.
Check the relevant prerequisites and report actual blockers and unrun checks;
never describe compilation or old evidence as fresh runtime acceptance.
