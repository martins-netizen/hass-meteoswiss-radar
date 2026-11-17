# Maintaining this personal fork

The source project is
[`chriguschneider/hass-meteoswiss-radar`](https://github.com/chriguschneider/hass-meteoswiss-radar).
This fork keeps local maintenance changes and reviews features for contribution
upstream. It does not publish releases automatically.

## Synchronization baseline

This synchronization imports upstream `master` at
`80cc7969c525456c20a7816e5ab81110bfc83ddd`, including the v0.17.0 runtime
and the subsequent upstream maintenance commits. The fork parent is
`08ef3ceb5503d10539c581649f66048966ee1696`, including the weather-source
readiness fix from
[PR #10](https://github.com/martins-netizen/hass-meteoswiss-radar/pull/10).
The local source version follows upstream's 0.17.0 metadata; this import does
not itself publish a fork release or install anything in Home Assistant.

[PR #7](https://github.com/martins-netizen/hass-meteoswiss-radar/pull/7)
previously imported upstream `master` at
`82f4ba065ff65ea7d241c3ff05be9965cbddf546` (including v0.16.0).
Before that synchronization, the fork's `master` was based on v0.14.0.
The merge retained upstream ancestry and the fixes from PRs #5 and #6.

The fork retains the configurable rain threshold reviewed in
[PR #4](https://github.com/martins-netizen/hass-meteoswiss-radar/pull/4),
with upstream's translated 0/1 selector for standard settings. Existing valid
custom numeric thresholds from 0 to 60 mm/h remain unchanged and editable;
setup, reload and saving other options must not silently replace them with 1.
The dated amendment to ADR-0011 records that compatibility rule. The default
is still 1 mm/h; selecting 0 explicitly includes the weakest recognized band.
The upstream card-startup recovery and the fork's separate weather-source
readiness guard both remain in place. Nowcast protection, minimum hold,
weather-entity display forecasts and diagnostics keep their existing roles.
See [LOCAL_NOWCAST.md](../LOCAL_NOWCAST.md).

## Review each upstream merge

1. Fetch the full histories of this fork and upstream. Inspect
   `git log --left-right master...upstream/master` and the changes since their
   merge base; a shallow checkout can give misleading ancestry results.
2. Create a branch from the fork's current `master` and merge upstream with
   `--no-ff`. Resolve conflicts by preserving upstream runtime behavior and
   the fork policies below. Keep both parent commits.
3. Run the existing fork CI, CodeQL and Sonar analysis, and review the runtime
   changes and remaining differences against upstream.
4. Merge the synchronization PR with **Create a merge commit**, not squash or
   rebase. Squashing loses upstream ancestry and makes the next synchronization
   treat already imported commits as missing.
5. Check that the imported upstream commit is an ancestor of the resulting
   `master`. Then update feature PRs to target the synchronized `master`.

Do this review before starting a new feature or preparing an installation.
Importing upstream code, tagging a release and installing it in Home Assistant
are separate actions. Before an installation, read the current stored rain
threshold and other protection options, and verify that the prepared package
preserves them. A historical diagnostics report is not a live configuration
check. Use the combined verified fork source, including its readiness and
threshold compatibility fixes, rather than an earlier synchronization commit
or the upstream release alone.

## Existing fork policies to preserve

- Keep only `ci.yml` and `codeql.yml` enabled. The fork deliberately removed
  inherited agent, release, smoke-test and CI-based Sonar workflows. Do not
  restore them or introduce issue-writing CI-watch or badge-publishing
  automation during a sync. Keep the existing README badge sources; do not
  assume a fork `badges` branch is populated by an enabled workflow.
  Upstream documentation and ADRs still describe those upstream services;
  this section describes the fork's actual deployment.
- Keep CI permissions, timeouts, disabled persisted checkout credentials,
  hash-verified Python tools and `npm ci --ignore-scripts`. Update pinned
  Actions using reviewed upstream commit SHAs. Keep the existing single
  release-workflow test deselection; do not skip runtime tests.
- Keep the `martins-netizen_hass-meteoswiss-radar` Sonar project identity and
  the existing Automatic Analysis configuration. Do not also activate the
  upstream CI scanner against that project. Automatic Analysis cannot import
  coverage; a passed check is not evidence of measured coverage compliance.
  A future switch to CI scanning must retain the upstream quality and coverage
  requirements and be configured separately.
- Preserve icon-output protections and explicit overwrite behavior, handled
  card Promise failures, Bash conditions and reload-safe entry setup. Port
  those fixes onto upstream's implementation rather than replacing newer
  runtime code with older fork files.
- Keep upstream's proxy boundary, radar-only protection decision, classic
  card script and redacted diagnostics (ADRs 0001, 0002, 0009 and 0010).

See [security-maintenance.md](security-maintenance.md) for dependency and
analysis details. The upstream release and automation documentation remains
useful for contributions, but it does not enable those services in this fork.
