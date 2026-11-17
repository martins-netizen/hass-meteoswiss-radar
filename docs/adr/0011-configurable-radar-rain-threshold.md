# ADR-0011: Configurable radar rain threshold

- **Status:** Accepted
- **Date:** 2026-10-22
- **Updated:** 2026-10-26, following review on #244

## Context

ADR-0009 uses a fixed 1 mm/h threshold to exclude unreliable weak echoes.
Sensitive awnings may need the lowest precipitation band too. Issue #195
explicitly left a public option for later. The pure classifier already
accepts a threshold, but the coordinator always uses its default.

## Decision

Add the flat config-entry option `rain_threshold_mm_h`, shown in a dedicated
*Radar rain detection* section. Default to 1.0 on new and existing entries.
Offer a fixed choice of 1 mm/h (standard) or 0 mm/h (include the weakest
band), with translated selector labels. Keep the stored option numeric:
convert the selector's string to a float when flattening the form. Accept
only numeric 0 or 1 when reading it, excluding booleans; every other value
falls back to 1.0. Existing numeric 0 and 1 values need no migration.

Pass the resolved value into every `frame_is_wet_at_grid_point` call through
the coordinator's existing executor path. Compare the band's lower bound
against it; 0 includes the weakest recognised precipitation band. Keep the
positional legend mapping, colour validation and unknown-data behaviour.

The option tunes all radar-derived samples. Weather-entity forecasts retain
their separate thresholds (ADR-0010), and never feed the protection signal.
Reuse the existing options-update reload; expose the effective value in
diagnostics. No new upstream request or dependency is introduced.

## Consequences

An installation can opt into weak echoes without a locally patched constant.
This increases false alarms from virga and clutter, so the UI and guide say
so. Sub-band precision is unavailable, and higher thresholds could silently
exclude meaningful rain from protection; neither is offered. Saving reloads
the entry and applies the choice without restarting Home Assistant. Entity
identities stay unchanged.

## Amendment 2026-11-17: preserve existing fork thresholds

Scope: compatibility for the maintenance fork during upstream synchronization.

This fork already accepted finite numeric thresholds from 0 to 60 mm/h
(PR #4). Replacing such a stored value with 1 mm/h during setup, reload or
an unrelated options edit would silently change an existing protection
decision. Preserve those valid values, including their exact numeric value;
booleans, non-numeric values, non-finite values and values outside the range
still resolve to the default of 1 mm/h. The upper bound is the highest band's
lower bound in `FORMAT.md` and the animation fixture.

Use the upstream translated 0/1 selector for new entries and entries already
using 0 or 1. Only an entry with another valid stored threshold retains the
previous numeric editor, prefilled with that value and bounded to 0..60.
Saving another option keeps the threshold; intentionally selecting 0 or 1
returns subsequent dialogs to the standard selector. The stored key and
config-entry version stay unchanged, and no automatic migration rewrites
options.

Higher legacy thresholds can exclude meaningful rain and sub-band precision
is still unavailable. The options description and local-nowcast guide
explain that trade-off. Runtime regression tests cover legacy preservation,
normal choice round-trips and the deliberate return to the standard selector.
All radar-only protection, minimum-hold, forecast and unknown-data rules from
the original decision remain unchanged.
