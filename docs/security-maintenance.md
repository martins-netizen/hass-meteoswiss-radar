# Developer tooling security maintenance

The fork retains the tooling protections from PR #5 while synchronizing
upstream runtime changes. See [fork-maintenance.md](fork-maintenance.md) for
the imported upstream baseline and the separate configurable-rain-threshold
review branch. A source synchronization is not a Home Assistant deployment.

## CI dependencies

Python tools are installed from `.github/requirements-ci.txt` with
`--only-binary=:all:` and `--require-hashes`. Every direct and transitive
dependency has a fixed version and allowed distribution hashes. The initial
versions come from the successful Python job in CI run
[39808062732](https://github.com/martins-netizen/hass-meteoswiss-radar/actions/runs/39808062732).
Hashes authenticate the selected distributions; they do not prove that the
upstream packages themselves are harmless.

To update, review the versions in `.github/requirements-ci.in`, regenerate
the lock file using `uv`, inspect the diff, and run the same lint and tests:

```sh
uv pip compile --python-version 3.13 --generate-hashes --only-binary=:all: \
  --no-header --no-annotate --index-url https://pypi.org/simple \
  .github/requirements-ci.in -o .github/requirements-ci.txt
python -m pip install --only-binary=:all: --require-hashes \
  -r .github/requirements-ci.txt
ruff check custom_components tests scripts/generate_brands_icon.py
pytest -q -k "not test_zip_release_asset_is_wired_end_to_end"
```

The existing fork-only release-test selection is unchanged. npm continues
to use `package-lock.json` through `npm ci`, now with `--ignore-scripts`.
Installation lifecycle hooks are disabled; the explicit `npm run check`
and `npm test` commands still run. Changes to dependency versions must be
reviewed and tested rather than restored to unpinned installs.

## Icon generator

`scripts/generate_brands_icon.py` is manually invoked by a local operator;
its `--out` argument is not supplied by a Home Assistant HTTP request or
by downloaded artwork. Custom preview directories remain supported.

The generator rejects parent traversal and symlink destinations, checks
both fixed icon filenames before writing, and requires `--overwrite` for
existing regular files. Complete temporary files are published with an
exclusive hard link by default, or an atomic replacement when overwriting
was explicitly requested. Replacing a hard-linked icon leaves its other
link untouched. This protects against mistaken CLI paths and target-file
races; it is not a privilege boundary against an attacker who controls the
operator's account or can replace ancestor directories.

## Sonar analysis configuration

The operator has already enabled SonarQube Cloud Automatic Analysis for
`martins-netizen_hass-meteoswiss-radar`. `.sonarcloud.properties` configures
that existing analysis: tests are identified separately, Python versions
are explicit, and all current source roots remain included, including
scripts, `.github` workflows and the imported `.claude` tooling. Only the
vendored Leaflet JS and CSS are
excluded; first-party code is not suppressed.

Automatic Analysis reads this file from the default branch. Individual
warnings and findings require a subsequent analysis to confirm resolution.
It does not accept Python or JS coverage reports. The fork's existing
deployment has no CI-based Sonar workflow; synchronization preserves that
choice rather than silently restoring the upstream scanner. This does not
establish compliance with ADR-0007's upstream coverage requirements. A future
switch to CI-based analysis must preserve those requirements.

`sonar-project.properties` retains the CI-based settings for a future scan,
with this fork's project identity and the same Python versions. The two
analysis methods must not run concurrently against the same project.

Sonar findings remain open until reanalysis or a documented review
confirms their disposition. Code changes alone are not evidence of a
successful quality gate.
