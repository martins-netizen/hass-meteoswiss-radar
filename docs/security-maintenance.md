# Developer tooling security maintenance

The fork retains the tooling protections from PR #5 while synchronizing
upstream runtime changes. See [fork-maintenance.md](fork-maintenance.md) for
the imported upstream baseline and the policies retained during synchronization.
A source synchronization is not a Home Assistant deployment.

## CI dependencies

Python tools are installed from `.github/requirements-ci.txt` with
`--only-binary=:all:` and `--require-hashes`. Every direct and transitive
dependency has a fixed version and allowed distribution hashes. The original
lock was based on the successful Python job in CI run
[39808062732](https://github.com/martins-netizen/hass-meteoswiss-radar/actions/runs/39808062732).
The 2026-11-17 refresh selects Ruff 0.17.5 and pytest 9.2.0 from PyPI;
the remaining Python dependencies were already current. Python 3.13 remains
the CI target, and the selected tools support it.
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

Vitest and its V8 coverage adapter are pinned together at 5.1.0. This was the
newest version available for both packages in npm on 2026-11-17; the GitHub
5.1.1 release did not yet have installable npm packages. The refreshed lock
uses Vite 8.3.8 and Rolldown 1.2.19, the newest release allowed by Vite's
`~1.2.18` dependency. Do not force Rolldown 1.3.x outside that supported range.
Vitest requires Node 22.12 or newer on the Node 22 line used by CI. These npm
packages are developer tools only: the shipped card remains a classic script
with no build step or npm runtime dependencies.

Actions remain pinned to reviewed commit SHAs: checkout 7.0.1, setup-node
7.1.0, setup-python 7.1.0, CodeQL 4.39.3 and the hassfest upstream commit
reviewed on 2026-11-17. Preserve minimal permissions, job timeouts and
`persist-credentials: false` when updating them.

### Open developer-tool advisory

The 2026-11-17 npm audit reports
[GHSA-fc5q-39xc-vjpf](https://github.com/advisories/GHSA-fc5q-39xc-vjpf)
against transitive `picomatch` 4.0.7: crafted repeated-extglob patterns can
cause regular-expression denial of service. npm lists six affected package
nodes for this one underlying advisory. The previous fork lock already used
the same `picomatch` version, and no patched npm release was available when
the dependency refresh was reviewed.

The package is confined to developer tools and is not shipped to Home
Assistant. CI runs `vitest run` with repository-controlled test and coverage
patterns; Home Assistant requests and weather data cannot supply those
patterns. Existing minimal permissions and the 15-minute job timeout limit
CI impact, but do not repair the dependency. Keep this finding visible until
a patched compatible release is available; do not report a clean npm audit
or downgrade the test stack using `npm audit fix --force`.

## Bundled map runtime

The bundled Leaflet 1.9.4 remains the latest stable release in both the
[official releases](https://github.com/Leaflet/Leaflet/releases/tag/v1.9.4)
and npm's `latest` tag as reviewed on 2026-11-17. Leaflet 2.0.0-beta.4 is a
prerelease, so this synchronization does not replace the stable vendor files.
Its [migration guide](https://github.com/Leaflet/Leaflet/blob/v2.0.0-beta.4/MIGRATION.md)
also requires API changes: the default distribution is an ES module and
lowercase factories such as `L.map` are removed. A global-script build still
exists, but using it would not avoid the API migration. Review a stable 2.x
release separately with the card's lifecycle, overlays and classic-script
architecture; changing the vendored files alone is insufficient.

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
