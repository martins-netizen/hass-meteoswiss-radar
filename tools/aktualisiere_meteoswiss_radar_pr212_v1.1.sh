#!/usr/bin/env bash
set -euo pipefail

# Kontrollierter Live-Test von Issue #195 im review-bereiten PR #212.
# Installiert ausschliesslich den exakt gepinnten, vollstaendig getesteten
# Commit. Home Assistant Core, Dashboards und Automationen bleiben unveraendert.
# v1.1 prueft zusaetzlich die Migrationen aus #196 und #209, erstellt einen
# geschuetzten HA-Wiederherstellungspunkt und dokumentiert Markisen-Bezuege.
# Gegenueber v1.0 sind die beiden Dokumentpfade der PR-Umfangspruefung korrigiert.

umask 077

SOURCE_URL="https://github.com/martins-netizen/hass-meteoswiss-radar.git"
UPSTREAM_URL="https://github.com/chriguschneider/hass-meteoswiss-radar.git"
SOURCE_BRANCH="codex/195-legend-threshold"
SOURCE_COMMIT="d0eac73ffa105e37bce74ce72df83bf650eb57b0"
SOURCE_TREE="13dd575f731c3a20581091e876642b1cb623658e"
UPSTREAM_BASE_COMMIT="bf0411b778305408876f757eea0a6aa14606ce03"
EXPECTED_VERSION="0.15.0"
PR_NUMBER="212"

HA_TARGET="${HA_TARGET:-root@homeassistant.local}"
HA_CONFIG="${HA_CONFIG:-/config}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$HOME/Downloads/HA/03_Backups}"

STABLE_NOWCAST_KEYS="nowcast_status rain_in rain_start rain_protection"

TASK_TMP=""
SSH_SOCKET=""
REMOTE_STAGE=""
REMOTE_OLD=""
REMOTE_ARCHIVE=""
REMOTE_BACKUP_ROOT=""
CURRENT_COMPONENT=""
SWAP_STARTED=0
CORE_RESTARTED=0
INSTALL_COMMITTED=0
BACKUP_PASSWORD=""
BACKUP_PASSWORD_CONFIRM=""
HA_BACKUP_SLUG=""
CONFIG_ENTRY_ID=""
NOWCAST_OPTION_BEFORE=""
NOWCAST_OPTION_AFTER=""
BEFORE_DRY_ENTITY=""
EXPECTED_DRY_ENTITY=""
STATUS_ENTITY=""
RAIN_PROTECTION_STATE=""

fail() {
  printf 'Fehler: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 wird benoetigt."
}

sha256_file() {
  python3 - "$1" <<'PY'
from __future__ import annotations

import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with path.open("rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)
print(digest.hexdigest())
PY
}

close_ssh() {
  if [[ -n "$SSH_SOCKET" ]]; then
    ssh -S "$SSH_SOCKET" -O exit "$HA_TARGET" >/dev/null 2>&1 || true
    rm -f "$SSH_SOCKET"
  fi
}

cleanup_local() {
  BACKUP_PASSWORD=""
  BACKUP_PASSWORD_CONFIRM=""
  close_ssh
  if [[ -n "$TASK_TMP" && -d "$TASK_TMP" ]]; then
    rm -rf "$TASK_TMP"
  fi
}

rollback_if_needed() {
  if [[ "$SWAP_STARTED" -ne 1 || "$INSTALL_COMMITTED" -eq 1 ]]; then
    return 0
  fi

  printf '\nDie Installation wurde nicht abgeschlossen. Ruecksicherung wird geprueft ...\n' >&2
  ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s -- \
    "$CURRENT_COMPONENT" "$REMOTE_OLD" "$REMOTE_BACKUP_ROOT" "$CORE_RESTARTED" <<'REMOTE_ROLLBACK'
set -eu
current=$1
old=$2
backup_root=$3
core_restarted=$4

if [ ! -d "$old" ]; then
  echo "Keine ausstehende Dateiumstellung gefunden; nichts rueckzusichern." >&2
  exit 0
fi

failed="$backup_root/failed-pr212"
rm -rf "$failed"
if [ -d "$current" ]; then
  mv "$current" "$failed"
fi
mv "$old" "$current"

if ! ha core check; then
  echo "WARNUNG: Die rueckgesicherte Konfiguration konnte nicht bestaetigt werden." >&2
  exit 1
fi

if [ "$core_restarted" = "1" ]; then
  ha core restart
  echo "Vorherige Integration rueckgesichert; Home Assistant wird erneut gestartet." >&2
else
  echo "Vorherige Integration rueckgesichert; ein Neustart war nicht erforderlich." >&2
fi
REMOTE_ROLLBACK
}

on_exit() {
  local status=$1
  trap - EXIT INT TERM
  set +e
  if [[ "$status" -ne 0 ]]; then
    rollback_if_needed
  fi
  cleanup_local
  exit "$status"
}

trap 'on_exit $?' EXIT
trap 'exit 130' INT TERM

case "$HA_CONFIG" in
  /*) ;;
  *) fail "HA_CONFIG muss ein absoluter Pfad sein." ;;
esac
case "$HA_CONFIG" in
  *[!A-Za-z0-9_./-]*) fail "HA_CONFIG enthaelt nicht unterstuetzte Zeichen." ;;
esac

for required in git python3 tar ssh scp base64 cmp grep tail tr; do
  require_tool "$required"
done

TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/meteoswiss-radar-pr212.XXXXXX")"
SSH_SOCKET="/tmp/ha-msr-pr212-$$.sock"
SOURCE_DIR="$TASK_TMP/source"
PAYLOAD_DIR="$TASK_TMP/payload"
LOCAL_ARCHIVE="$TASK_TMP/meteoswiss-radar-pr212.tar.gz"
CHECKSUMS_FILE="$PAYLOAD_DIR/SHA256SUMS"
BEFORE_REGISTRY="$TASK_TMP/entity-registry-before.json"
AFTER_REGISTRY="$TASK_TMP/entity-registry-after.json"
BEFORE_CONFIG_ENTRIES="$TASK_TMP/config-entries-before.json"
AFTER_CONFIG_ENTRIES="$TASK_TMP/config-entries-after.json"
BEFORE_MAP="$TASK_TMP/entities-before.tsv"
AFTER_MAP="$TASK_TMP/entities-after.tsv"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CURRENT_COMPONENT="$HA_CONFIG/custom_components/meteoswiss_radar"
REMOTE_ARCHIVE="/tmp/meteoswiss-radar-pr212-nowcast-${STAMP}.tar.gz"
REMOTE_STAGE="$HA_CONFIG/.meteoswiss-radar-pr212-stage-${STAMP}"
REMOTE_OLD="$HA_CONFIG/.meteoswiss-radar-pr212-old-${STAMP}"
REMOTE_BACKUP_ROOT="$HA_CONFIG/backups/meteoswiss-radar-pr212-nowcast-${STAMP}"
REMOTE_COMPONENT_BACKUP="$REMOTE_BACKUP_ROOT/component-before.tar.gz"
LOCAL_RUN_DIR="$LOCAL_BACKUP_DIR/meteoswiss-radar-pr212-${STAMP}"
LOCAL_COMPONENT_BACKUP="$LOCAL_RUN_DIR/component-before.tar.gz"
AUTOMATION_AUDIT="$LOCAL_RUN_DIR/markisen-nowcast-bezuege.txt"
CORE_LOG="$LOCAL_RUN_DIR/home-assistant-core-nachher.log"
STATUS_JSON="$LOCAL_RUN_DIR/nowcast-status-nachher.json"
HA_BACKUP_CREATE_JSON="$LOCAL_RUN_DIR/home-assistant-backup-create.json"
HA_BACKUP_INFO_JSON="$LOCAL_RUN_DIR/home-assistant-backup-info.json"
SCRIPT_COPY="$LOCAL_RUN_DIR/aktualisiere_meteoswiss_radar_pr212_v1.1.sh"
BACKUP_NAME="MeteoSwiss Radar vor PR212 ${STAMP}"

printf '[1/10] Exakten PR-212-Quellstand laden und pruefen ...\n\n'
git clone --quiet --no-checkout "$SOURCE_URL" "$SOURCE_DIR"
git -C "$SOURCE_DIR" show-ref --verify --quiet "refs/remotes/origin/$SOURCE_BRANCH" \
  || fail "Der erwartete Nowcast-Branch $SOURCE_BRANCH fehlt."
git -C "$SOURCE_DIR" checkout --quiet --detach "$SOURCE_COMMIT"

actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
actual_tree="$(git -C "$SOURCE_DIR" rev-parse 'HEAD^{tree}')"
branch_head="$(git -C "$SOURCE_DIR" rev-parse "refs/remotes/origin/$SOURCE_BRANCH")"
upstream_record="$(git ls-remote "$UPSTREAM_URL" refs/heads/master)"
upstream_head="${upstream_record%%$'\t'*}"
[[ "$actual_commit" == "$SOURCE_COMMIT" ]] \
  || fail "Unerwarteter Quell-Commit: $actual_commit"
[[ "$actual_tree" == "$SOURCE_TREE" ]] \
  || fail "Unerwarteter Quellbaum: $actual_tree"
[[ "$branch_head" == "$SOURCE_COMMIT" ]] \
  || fail "Der PR-Branch wurde seit der Pruefung veraendert: $branch_head"
[[ "$upstream_head" == "$UPSTREAM_BASE_COMMIT" ]] \
  || fail "Upstream master ist weitergezogen: $upstream_head. PR #212 muss zuerst neu geprueft werden."
[[ "$(git -C "$SOURCE_DIR" rev-parse 'HEAD^')" == "$UPSTREAM_BASE_COMMIT" ]] \
  || fail "Der gepinnte Commit basiert nicht direkt auf dem geprueften master."
git -C "$SOURCE_DIR" merge-base --is-ancestor "$UPSTREAM_BASE_COMMIT" "$SOURCE_COMMIT" \
  || fail "Der gepinnte PR-Commit enthaelt den geprueften Upstream-Stand nicht."

manifest_version="$(
  python3 - "$SOURCE_DIR/custom_components/meteoswiss_radar/manifest.json" <<'PY'
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["version"])
PY
)"
[[ "$manifest_version" == "$EXPECTED_VERSION" ]] \
  || fail "Manifest-Version $manifest_version statt $EXPECTED_VERSION."

printf 'Quell-Commit: %s\n' "$SOURCE_COMMIT"
printf 'Quellbaum:   %s\n' "$SOURCE_TREE"
printf 'Branch:      %s (Head %s)\n' "$SOURCE_BRANCH" "$branch_head"
printf 'PR:          https://github.com/chriguschneider/hass-meteoswiss-radar/pull/%s\n' "$PR_NUMBER"
printf 'Basis:       upstream/master @ %s\n' "$UPSTREAM_BASE_COMMIT"

printf '\n[2/10] Nowcast-Code lokal validieren und Installationsarchiv bauen ...\n\n'
python3 -m compileall -q "$SOURCE_DIR/custom_components/meteoswiss_radar"
python3 "$SOURCE_DIR/tests/test_nowcast_core_local.py"
git -C "$SOURCE_DIR" diff --check "$UPSTREAM_BASE_COMMIT..$SOURCE_COMMIT"

python3 - "$SOURCE_DIR" "$UPSTREAM_BASE_COMMIT" "$SOURCE_COMMIT" <<'PY'
from __future__ import annotations

import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
changed = set(
    subprocess.check_output(
        ["git", "-C", str(root), "diff", "--name-only", sys.argv[2], sys.argv[3]],
        text=True,
    ).splitlines()
)
expected = {
    "custom_components/meteoswiss_radar/nowcast.py",
    "custom_components/meteoswiss_radar/nowcast_core.py",
    "LOCAL_NOWCAST.md",
    "docs/adr/0009-local-rain-nowcast-entities.md",
    "tests/test_nowcast.py",
    "tests/test_nowcast_core_local.py",
}
if changed != expected:
    missing = sorted(expected - changed)
    extra = sorted(changed - expected)
    raise SystemExit(
        f"Unerwarteter PR-Umfang; fehlend={missing}, zusaetzlich={extra}"
    )
PY

python3 - "$SOURCE_DIR/custom_components/meteoswiss_radar" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
required = {
    "__init__.py",
    "config_flow.py",
    "const.py",
    "nowcast.py",
    "nowcast_core.py",
    "sensor.py",
    "binary_sensor.py",
    "manifest.json",
    "strings.json",
    "translations/de.json",
    "translations/en.json",
    "translations/fr.json",
    "translations/it.json",
}
missing = sorted(name for name in required if not (root / name).is_file())
if missing:
    raise SystemExit("Fehlende Quelldateien: " + ", ".join(missing))

core_source = (root / "nowcast_core.py").read_text(encoding="utf-8")
for expected in (
    "DEFAULT_RAIN_THRESHOLD_MM_H = 1.0",
    "MAX_LEGEND_COLOR_DISTANCE = 15.0",
    "_legend_band_min_for_color",
    "frame_covers_grid_point",
):
    if expected not in core_source:
        raise SystemExit(f"Erwartete #195-Logik fehlt: {expected}")
if "NON_PRECIPITATION_COLORS" in core_source:
    raise SystemExit("Die alte Ausschlussliste ist unerwartet noch vorhanden.")

documents = {
    name: json.loads((root / name).read_text(encoding="utf-8"))
    for name in (
        "strings.json",
        "translations/de.json",
        "translations/en.json",
        "translations/fr.json",
        "translations/it.json",
    )
}
expected_sensor_keys = {
    "nowcast_status",
    "rain_in",
    "rain_start",
    "expected_dry_from",
}
for name, document in documents.items():
    entity = document.get("entity", {})
    sensor_keys = set(entity.get("sensor", {}))
    binary_keys = set(entity.get("binary_sensor", {}))
    option_data = (
        document.get("options", {})
        .get("step", {})
        .get("init", {})
        .get("data", {})
    )
    if "nowcast_enabled" not in option_data:
        raise SystemExit(f"Nowcast-Option fehlt in {name}")
    if not expected_sensor_keys <= sensor_keys or "rain_protection" not in binary_keys:
        raise SystemExit(f"Unvollstaendige Nowcast-Uebersetzungen in {name}")
PY

mkdir -p "$PAYLOAD_DIR"
cp -R "$SOURCE_DIR/custom_components/meteoswiss_radar" "$PAYLOAD_DIR/"
find "$PAYLOAD_DIR/meteoswiss_radar" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$PAYLOAD_DIR/meteoswiss_radar" -type f \( -name '*.pyc' -o -name '.DS_Store' \) -delete

python3 - "$PAYLOAD_DIR" "$CHECKSUMS_FILE" <<'PY'
from __future__ import annotations

import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
lines: list[str] = []
for path in sorted((root / "meteoswiss_radar").rglob("*")):
    if path.is_symlink():
        raise SystemExit(f"Symlinks sind im Installationsumfang nicht erlaubt: {path}")
    if not path.is_file():
        continue
    relative = path.relative_to(root).as_posix()
    lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}")
output.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

printf '%s\n' "$SOURCE_COMMIT" > "$PAYLOAD_DIR/SOURCE_COMMIT"
printf '%s\n' "$SOURCE_TREE" > "$PAYLOAD_DIR/SOURCE_TREE"
tar -czf "$LOCAL_ARCHIVE" -C "$PAYLOAD_DIR" \
  meteoswiss_radar SHA256SUMS SOURCE_COMMIT SOURCE_TREE
printf 'Lokale Codepruefung: OK\n'
printf 'Archiv-SHA-256:      %s\n' "$(sha256_file "$LOCAL_ARCHIVE")"

printf '\n[3/10] Geschuetzte SSH-Verbindung und Home Assistant pruefen ...\n\n'
ssh -M -S "$SSH_SOCKET" -fnNT -o ControlPersist=600 "$HA_TARGET"
ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  "test -d '$CURRENT_COMPONENT' && test -f '$CURRENT_COMPONENT/manifest.json'" \
  || fail "Keine bestehende MeteoSwiss-Radar-Installation gefunden."
ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  "test -f '$CURRENT_COMPONENT/nowcast.py' && test -f '$CURRENT_COMPONENT/nowcast_core.py' && test -f '$CURRENT_COMPONENT/sensor.py' && test -f '$CURRENT_COMPONENT/binary_sensor.py'" \
  || fail "Die bestehende lokale Nowcast-Erweiterung ist nicht vollstaendig."
ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  "test -f '$HA_CONFIG/.storage/core.entity_registry' && test -f '$HA_CONFIG/.storage/core.config_entries'" \
  || fail "Entity Registry oder Config Entries sind auf Home Assistant nicht lesbar."
ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  'command -v base64 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v grep >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 && command -v tail >/dev/null 2>&1 && command -v tar >/dev/null 2>&1' \
  || fail "Ein benoetigtes Werkzeug fehlt auf dem Home-Assistant-SSH-System."
ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  "ha backups new --help 2>&1 | grep -q -- '--password' && ha backups info --help >/dev/null 2>&1" \
  || fail "Die HA-CLI unterstuetzt den geschuetzten Backup-Ablauf nicht."
ssh -S "$SSH_SOCKET" "$HA_TARGET" 'ha core info >/dev/null && ha core check'

current_version="$(
  ssh -S "$SSH_SOCKET" "$HA_TARGET" "cat '$CURRENT_COMPONENT/manifest.json'" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'
)"
printf 'Installierte Manifest-Version: %s\n' "$current_version"
printf 'Home-Assistant-Konfiguration:  gueltig\n'

parse_entity_registry() {
  local registry_file=$1
  local map_file=$2
  python3 - "$registry_file" "$map_file" $STABLE_NOWCAST_KEYS <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

registry_path = pathlib.Path(sys.argv[1])
map_path = pathlib.Path(sys.argv[2])
keys = sys.argv[3:]
payload = json.loads(registry_path.read_text(encoding="utf-8"))
entities = payload.get("data", {}).get("entities", [])
rows: list[tuple[str, str, str]] = []

for key in keys:
    matches = []
    suffix = "_" + key
    for item in entities:
        if item.get("platform") != "meteoswiss_radar":
            continue
        unique_id = str(item.get("unique_id") or "")
        if unique_id.endswith(suffix):
            matches.append(item)
    if len(matches) != 1:
        raise SystemExit(
            f"Erwartete genau eine aktive Registry-Zuordnung fuer {key}, gefunden: {len(matches)}"
        )
    item = matches[0]
    if item.get("disabled_by") is not None:
        raise SystemExit(f"Nowcast-Entitaet ist deaktiviert: {item.get('entity_id')}")
    entity_id = str(item.get("entity_id") or "")
    unique_id = str(item.get("unique_id") or "")
    if not entity_id or not unique_id:
        raise SystemExit(f"Unvollstaendige Registry-Zuordnung fuer {key}")
    rows.append((key, entity_id, unique_id))

map_path.write_text(
    "".join(f"{key}\t{entity_id}\t{unique_id}\n" for key, entity_id, unique_id in rows),
    encoding="utf-8",
)
for key, entity_id, _unique_id in rows:
    print(f"  {key}: {entity_id}")
PY
}

fetch_entity_registry() {
  local destination=$1
  umask 077
  ssh -S "$SSH_SOCKET" "$HA_TARGET" \
    "cat '$HA_CONFIG/.storage/core.entity_registry'" > "$destination"
}

fetch_config_entries() {
  local destination=$1
  umask 077
  ssh -S "$SSH_SOCKET" "$HA_TARGET" \
    "cat '$HA_CONFIG/.storage/core.config_entries'" > "$destination"
}

read_nowcast_option() {
  local config_file=$1
  python3 - "$config_file" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
entries = [
    entry
    for entry in payload.get("data", {}).get("entries", [])
    if entry.get("domain") == "meteoswiss_radar"
]
if len(entries) != 1:
    raise SystemExit(
        f"Erwartete genau einen MeteoSwiss-Radar-Config-Entry, gefunden: {len(entries)}"
    )
entry = entries[0]
entry_id = str(entry.get("entry_id") or "")
if not entry_id:
    raise SystemExit("Der MeteoSwiss-Radar-Config-Entry hat keine ID.")
options = entry.get("options") if isinstance(entry.get("options"), dict) else {}
value = options.get("nowcast_enabled")
if value is False:
    raise SystemExit(
        "Die Nowcast-Option ist explizit deaktiviert; Live-Test wird nicht installiert."
    )
if value is True:
    label = "true (explizit aktiviert)"
else:
    label = "nicht gesetzt (Bestandsmigration ueber Entity Registry)"
print(f"{entry_id}\t{label}")
PY
}

find_entity_by_key() {
  local registry_file=$1
  local key=$2
  python3 - "$registry_file" "$key" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
suffix = "_" + sys.argv[2]
matches = [
    item
    for item in payload.get("data", {}).get("entities", [])
    if item.get("platform") == "meteoswiss_radar"
    and str(item.get("unique_id") or "").endswith(suffix)
    and item.get("disabled_by") is None
]
if len(matches) != 1:
    raise SystemExit(
        f"Erwartete genau eine aktive Registry-Zuordnung fuer {sys.argv[2]}, "
        f"gefunden: {len(matches)}"
    )
print(matches[0]["entity_id"])
PY
}

read_remote_state() {
  local entity_id=$1
  local response
  case "$entity_id" in
    *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  response="$(
    ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s -- "$entity_id" <<'REMOTE_STATE'
set -eu
entity_id=$1
test -n "${SUPERVISOR_TOKEN:-}"
curl -fsS \
  --max-time 20 \
  -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
  -H 'Content-Type: application/json' \
  "http://supervisor/core/api/states/${entity_id}"
REMOTE_STATE
  )" || return 1
  printf '%s' "$response" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'
}

fetch_remote_state_json() {
  local entity_id=$1
  local destination=$2
  case "$entity_id" in
    *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s -- "$entity_id" <<'REMOTE_STATE_JSON' > "$destination"
set -eu
entity_id=$1
test -n "${SUPERVISOR_TOKEN:-}"
curl -fsS \
  --max-time 20 \
  -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
  -H 'Content-Type: application/json' \
  "http://supervisor/core/api/states/${entity_id}"
REMOTE_STATE_JSON
  python3 - "$destination" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict) or not isinstance(payload.get("state"), str):
    raise SystemExit("Ungueltige Antwort der Home-Assistant-State-API")
PY
}

core_api_ready() {
  ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s <<'REMOTE_READY'
set -eu
test -n "${SUPERVISOR_TOKEN:-}"
curl -fsS \
  --max-time 10 \
  -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
  -H 'Content-Type: application/json' \
  http://supervisor/core/api/ >/dev/null
REMOTE_READY
}

printf '\n[4/10] Bestehende Nowcast-Entitaeten und Sicherheitsbezug erfassen ...\n\n'
mkdir -p "$LOCAL_RUN_DIR"
fetch_entity_registry "$BEFORE_REGISTRY"
fetch_config_entries "$BEFORE_CONFIG_ENTRIES"
parse_entity_registry "$BEFORE_REGISTRY" "$BEFORE_MAP"

option_record="$(read_nowcast_option "$BEFORE_CONFIG_ENTRIES")"
CONFIG_ENTRY_ID="${option_record%%$'\t'*}"
NOWCAST_OPTION_BEFORE="${option_record#*$'\t'}"
printf '  Config Entry: %s\n' "$CONFIG_ENTRY_ID"
printf '  nowcast_enabled: %s\n' "$NOWCAST_OPTION_BEFORE"

if BEFORE_DRY_ENTITY="$(find_entity_by_key "$BEFORE_REGISTRY" expected_dry_from 2>/dev/null)"; then
  printf '  Trockenzeit-Entitaet bereits migriert: %s\n' "$BEFORE_DRY_ENTITY"
elif BEFORE_DRY_ENTITY="$(find_entity_by_key "$BEFORE_REGISTRY" rain_end 2>/dev/null)"; then
  printf '  Zu migrierende Trockenzeit-Entitaet: %s\n' "$BEFORE_DRY_ENTITY"
else
  fail "Weder rain_end noch expected_dry_from ist als aktive Entitaet vorhanden."
fi

while IFS=$'\t' read -r key entity_id unique_id; do
  state="$(read_remote_state "$entity_id")" \
    || fail "Laufzeitstatus von $entity_id konnte nicht gelesen werden."
  [[ "$state" != "unavailable" ]] \
    || fail "Ausgangszustand ist nicht betriebsbereit: $entity_id=unavailable"
  printf '  %s = %s\n' "$entity_id" "$state"
done < "$BEFORE_MAP"

cp "$BEFORE_REGISTRY" "$LOCAL_RUN_DIR/entity-registry-before.json"
cp "$BEFORE_CONFIG_ENTRIES" "$LOCAL_RUN_DIR/config-entries-before.json"
cp "$BEFORE_MAP" "$LOCAL_RUN_DIR/nowcast-entities-before.tsv"
chmod 600 \
  "$LOCAL_RUN_DIR/entity-registry-before.json" \
  "$LOCAL_RUN_DIR/config-entries-before.json" \
  "$LOCAL_RUN_DIR/nowcast-entities-before.tsv"

ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s -- "$HA_CONFIG" <<'REMOTE_AUDIT' > "$AUTOMATION_AUDIT"
set -eu
ha_config=$1
pattern='rain_protection|regenschutz|nowcast_status|rain_in|rain_start|rain_end|expected_dry_from'

for file in "$ha_config/automations.yaml" "$ha_config/scripts.yaml"; do
  if [ -f "$file" ]; then
    printf '### %s\n' "$file"
    grep -niE "$pattern" "$file" || true
  fi
done

if [ -d "$ha_config/packages" ]; then
  printf '### %s\n' "$ha_config/packages"
  grep -RniE "$pattern" "$ha_config/packages" || true
fi

for file in "$ha_config"/.storage/lovelace*; do
  if [ -f "$file" ]; then
    printf '### %s\n' "$file"
    grep -niE "$pattern" "$file" || true
  fi
done
REMOTE_AUDIT
chmod 600 "$AUTOMATION_AUDIT"

audit_count="$(
  python3 - "$AUTOMATION_AUDIT" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
print(sum(bool(line.strip()) and not line.startswith("### ") for line in lines))
PY
)"
printf '  Gefundene Nowcast-Bezuege in Automationen/Dashboards: %s\n' "$audit_count"
printf '  Audit-Datei: %s\n' "$AUTOMATION_AUDIT"
if [[ "$audit_count" -eq 0 ]]; then
  printf '  Hinweis: Externe Automationssysteme wie Node-RED sind damit nicht erfasst.\n'
fi

printf '\n[5/10] Geplanten Live-Test von #195 / PR #212 bestaetigen ...\n\n'
cat <<EOF
Installiert wird exakt PR #212 (Issue #195) auf Basis des aktuellen master:
  - Niederschlag wird aus legend[] positiv klassifiziert,
  - Standard-Schwelle 1 mm/h und maximaler RGB-Abstand 15,
  - nicht klassifizierbare Farben und Punkte ausserhalb der Abdeckung werden unknown,
  - sicherer Vorrang: wet vor unknown vor dry,
  - #196: rain_end wird zu expected_dry_from und der Horizont betraegt zwei Stunden,
  - #209: die bestehenden Nowcast-Entitaeten bleiben fuer diesen Config Entry aktiv.

Unveraendert bleiben Home Assistant Core, Dashboards, Automationen, Standort und
die vier sicherheitsrelevanten Entity-IDs:
  nowcast_status, rain_in, rain_start und rain_protection.

Das Skript ersetzt ausschliesslich $CURRENT_COMPONENT, prueft danach Dateien,
Config Entry, Entity Registry, REST-Zustaende und Protokoll. Bei einem Fehler
wird der vorherige Komponentenstand automatisch zurueckgesichert.

WICHTIG: Waehrend des Neustarts koennen Sensoren kurz unavailable/unknown sein.
Eine Ausfahr-Automation darf deshalb nicht mit "nicht on" als Freigabe arbeiten.
EOF

printf '\nBitte jetzt alle Markisen einfahren und automatische Ausfahr-Automationen pausieren.\n'
printf 'Bestaetigung (exakt SICHER eingeben): '
read -r safety_confirmation
if [[ "$safety_confirmation" != "SICHER" ]]; then
  printf 'Abgebrochen; Home Assistant wurde nicht veraendert. Die Audit-Datei bleibt erhalten.\n'
  exit 0
fi

printf '\nFuer den vollstaendigen HA-Wiederherstellungspunkt wird ein neues\n'
printf 'Backup-Passwort benoetigt. Bitte vorher sicher im Passwortmanager speichern.\n'
while :; do
  read -r -s -p 'Backup-Passwort (mindestens 16 Zeichen): ' BACKUP_PASSWORD
  printf '\n'
  if [[ "${#BACKUP_PASSWORD}" -lt 16 ]]; then
    printf 'Das Passwort ist zu kurz.\n'
    continue
  fi
  read -r -s -p 'Backup-Passwort wiederholen: ' BACKUP_PASSWORD_CONFIRM
  printf '\n'
  if [[ "$BACKUP_PASSWORD" != "$BACKUP_PASSWORD_CONFIRM" ]]; then
    printf 'Die Eingaben stimmen nicht ueberein.\n'
    BACKUP_PASSWORD=""
    BACKUP_PASSWORD_CONFIRM=""
    continue
  fi
  BACKUP_PASSWORD_CONFIRM=""
  break
done

printf '\n[6/10] Zwei unabhaengige Rueckfallpfade erstellen ...\n\n'
mkdir -p "$LOCAL_RUN_DIR"
ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s -- \
  "$HA_CONFIG" "$CURRENT_COMPONENT" "$REMOTE_BACKUP_ROOT" \
  "$REMOTE_COMPONENT_BACKUP" "$SOURCE_COMMIT" <<'REMOTE_BACKUP'
set -eu
ha_config=$1
current=$2
backup_root=$3
component_backup=$4
target_commit=$5

mkdir -p "$backup_root"
tar -czf "$component_backup" -C "$ha_config/custom_components" meteoswiss_radar
cp "$ha_config/.storage/core.entity_registry" "$backup_root/core.entity_registry-before.json"
cp "$ha_config/.storage/core.config_entries" "$backup_root/core.config_entries-before.json"
chmod 600 \
  "$backup_root/core.entity_registry-before.json" \
  "$backup_root/core.config_entries-before.json"
{
  echo "Previous MeteoSwiss Radar component backup"
  echo "Target commit: $target_commit"
  echo "Created UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Restore component: stop Home Assistant, replace $current from component-before.tar.gz, then start Home Assistant"
} > "$backup_root/RESTORE.txt"
sha256sum "$component_backup" > "$backup_root/component-before.sha256"
REMOTE_BACKUP

scp -q -o ControlPath="$SSH_SOCKET" \
  "$HA_TARGET:$REMOTE_COMPONENT_BACKUP" "$LOCAL_COMPONENT_BACKUP"
chmod 600 "$LOCAL_COMPONENT_BACKUP"
local_component_sha="$(sha256_file "$LOCAL_COMPONENT_BACKUP")"
remote_component_record="$(
  ssh -S "$SSH_SOCKET" "$HA_TARGET" "cat '$REMOTE_BACKUP_ROOT/component-before.sha256'"
)"
remote_component_sha="${remote_component_record%% *}"
[[ "$local_component_sha" == "$remote_component_sha" ]] \
  || fail "Die externe Komponentensicherung stimmt nicht mit dem Original ueberein."

if [[ -f "$0" ]]; then
  cp "$0" "$SCRIPT_COPY"
  chmod 700 "$SCRIPT_COPY"
fi

backup_name_b64="$(printf '%s' "$BACKUP_NAME" | base64 | tr -d '\n')"
backup_password_b64="$(printf '%s' "$BACKUP_PASSWORD" | base64 | tr -d '\n')"
backup_json="$(
  ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s <<REMOTE_HA_BACKUP
set -eu
backup_name=\$(printf '%s' '$backup_name_b64' | base64 -d)
backup_password=\$(printf '%s' '$backup_password_b64' | base64 -d)
ha backups new \
  --name "\$backup_name" \
  --password "\$backup_password" \
  --no-progress \
  --raw-json
backup_password=
REMOTE_HA_BACKUP
)"
printf '%s\n' "$backup_json" > "$HA_BACKUP_CREATE_JSON"
chmod 600 "$HA_BACKUP_CREATE_JSON"
HA_BACKUP_SLUG="$(
  python3 - "$HA_BACKUP_CREATE_JSON" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys
from typing import Any

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if isinstance(payload, dict) and payload.get("result") not in (None, "ok"):
    raise SystemExit(f"HA-Backup fehlgeschlagen: {payload.get('message') or payload}")

def find_slug(value: Any) -> str | None:
    if isinstance(value, dict):
        slug = value.get("slug")
        if isinstance(slug, str) and slug:
            return slug
        for child in value.values():
            found = find_slug(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_slug(child)
            if found:
                return found
    return None

slug = find_slug(payload)
if not slug:
    raise SystemExit("HA-Backup-Antwort enthaelt keinen Slug.")
print(slug)
PY
)"
case "$HA_BACKUP_SLUG" in
  ""|*[!A-Za-z0-9_-]*) fail "Ungueltiger HA-Backup-Slug: $HA_BACKUP_SLUG" ;;
esac

ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  "ha backups info '$HA_BACKUP_SLUG' --no-progress --raw-json" \
  > "$HA_BACKUP_INFO_JSON"
chmod 600 "$HA_BACKUP_INFO_JSON"
python3 - "$HA_BACKUP_INFO_JSON" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys
from typing import Any

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))

def protected_values(value: Any) -> list[bool]:
    found: list[bool] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "protected" and isinstance(child, bool):
                found.append(child)
            found.extend(protected_values(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(protected_values(child))
    return found

values = protected_values(payload)
if True not in values:
    raise SystemExit("Der HA-Wiederherstellungspunkt ist nicht als geschuetzt bestaetigt.")
PY

BACKUP_PASSWORD=""
BACKUP_PASSWORD_CONFIRM=""
backup_password_b64=""
unset backup_password_b64

printf 'Externe Komponentensicherung: %s\n' "$LOCAL_COMPONENT_BACKUP"
printf 'Komponenten-SHA-256:           %s\n' "$local_component_sha"
printf 'Interne Komponentensicherung: %s\n' "$REMOTE_BACKUP_ROOT"
printf 'Geschuetztes vollstaendiges HA-Backup: %s\n' "$HA_BACKUP_SLUG"

printf '\n[7/10] Gepinnten Dateibestand installieren und Konfiguration pruefen ...\n\n'
scp -q -o ControlPath="$SSH_SOCKET" "$LOCAL_ARCHIVE" "$HA_TARGET:$REMOTE_ARCHIVE"
SWAP_STARTED=1

ssh -S "$SSH_SOCKET" "$HA_TARGET" /bin/sh -s -- \
  "$HA_CONFIG" "$CURRENT_COMPONENT" "$REMOTE_ARCHIVE" "$REMOTE_STAGE" \
  "$REMOTE_OLD" "$REMOTE_BACKUP_ROOT" "$SOURCE_COMMIT" "$SOURCE_TREE" <<'REMOTE_INSTALL'
set -eu
ha_config=$1
current=$2
archive=$3
stage=$4
old=$5
backup_root=$6
expected_commit=$7
expected_tree=$8

rm -rf "$stage" "$old"
mkdir -p "$stage"
tar -xzf "$archive" -C "$stage"

test "$(cat "$stage/SOURCE_COMMIT")" = "$expected_commit"
test "$(cat "$stage/SOURCE_TREE")" = "$expected_tree"
test -f "$stage/meteoswiss_radar/manifest.json"
test -f "$stage/meteoswiss_radar/nowcast.py"
test -f "$stage/meteoswiss_radar/nowcast_core.py"
(cd "$stage" && sha256sum -c SHA256SUMS >/dev/null)

cp "$stage/SHA256SUMS" "$backup_root/installed-pr212.sha256"
cp "$stage/SOURCE_COMMIT" "$backup_root/installed-source-commit.txt"
cp "$stage/SOURCE_TREE" "$backup_root/installed-source-tree.txt"

mv "$current" "$old"
mv "$stage/meteoswiss_radar" "$current"
rm -rf "$stage"
rm -f "$archive"

if ! (cd "$ha_config/custom_components" && \
      sha256sum -c "$backup_root/installed-pr212.sha256" >/dev/null); then
  echo "Installierter Dateibestand stimmt nicht mit der gepinnten Quelle ueberein." >&2
  rm -rf "$current"
  mv "$old" "$current"
  exit 1
fi

if ! ha core check; then
  echo "Konfigurationspruefung fehlgeschlagen; vorherige Dateien werden wiederhergestellt." >&2
  rm -rf "$current"
  mv "$old" "$current"
  exit 1
fi
REMOTE_INSTALL

printf 'Installierter Dateibestand: identisch mit %s\n' "$SOURCE_COMMIT"
printf 'Home-Assistant-Konfiguration mit PR-212: gueltig\n'

printf '\n[8/10] Home Assistant kontrolliert neu starten ...\n\n'
CORE_RESTARTED=1
ssh -S "$SSH_SOCKET" "$HA_TARGET" 'ha core restart'
sleep 5

core_running=0
attempt=1
while [[ "$attempt" -le 60 ]]; do
  if core_api_ready 2>/dev/null; then
    core_running=1
    break
  fi
  if [[ "$attempt" -eq 1 || $((attempt % 3)) -eq 0 ]]; then
    printf '  Home-Assistant-API noch nicht bereit; weiterer Versuch in 5 Sekunden (%ss) ...\n' \
      "$(((attempt - 1) * 5))"
  fi
  sleep 5
  attempt=$((attempt + 1))
done
[[ "$core_running" -eq 1 ]] \
  || fail "Die Home-Assistant-API ist nach fuenf Minuten noch nicht erreichbar."
printf 'Home-Assistant-API ist wieder erreichbar.\n'

printf '\n[9/10] #195, Migrationen und Nowcast-Laufzeit verifizieren ...\n\n'
ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  "cd '$HA_CONFIG/custom_components' && sha256sum -c '$REMOTE_BACKUP_ROOT/installed-pr212.sha256' >/dev/null"
ssh -S "$SSH_SOCKET" "$HA_TARGET" 'ha core check'

fetch_entity_registry "$AFTER_REGISTRY"
fetch_config_entries "$AFTER_CONFIG_ENTRIES"
parse_entity_registry "$AFTER_REGISTRY" "$AFTER_MAP"
cmp -s "$BEFORE_MAP" "$AFTER_MAP" \
  || fail "Mindestens eine der vier stabilen Nowcast-Entity-IDs hat sich geaendert."

option_record="$(read_nowcast_option "$AFTER_CONFIG_ENTRIES")"
after_config_entry_id="${option_record%%$'\t'*}"
NOWCAST_OPTION_AFTER="${option_record#*$'\t'}"
[[ "$after_config_entry_id" == "$CONFIG_ENTRY_ID" ]] \
  || fail "Der MeteoSwiss-Radar-Config-Entry hat sich geaendert."
printf '  Config Entry unveraendert: %s\n' "$after_config_entry_id"
printf '  nowcast_enabled nach Neustart: %s\n' "$NOWCAST_OPTION_AFTER"

EXPECTED_DRY_ENTITY="$(find_entity_by_key "$AFTER_REGISTRY" expected_dry_from)" \
  || fail "Die neue expected_dry_from-Entitaet wurde nicht aktiv registriert."

cp "$AFTER_REGISTRY" "$LOCAL_RUN_DIR/entity-registry-after.json"
cp "$AFTER_CONFIG_ENTRIES" "$LOCAL_RUN_DIR/config-entries-after.json"
cp "$AFTER_MAP" "$LOCAL_RUN_DIR/nowcast-entities-after.tsv"
chmod 600 \
  "$LOCAL_RUN_DIR/entity-registry-after.json" \
  "$LOCAL_RUN_DIR/config-entries-after.json" \
  "$LOCAL_RUN_DIR/nowcast-entities-after.tsv"

entities_ready=0
attempt=1
while [[ "$attempt" -le 60 ]]; do
  current_ready=1
  while IFS=$'\t' read -r key entity_id unique_id; do
    state="$(read_remote_state "$entity_id" 2>/dev/null || true)"
    if [[ -z "$state" || "$state" == "unavailable" ]]; then
      current_ready=0
      break
    fi
  done < "$AFTER_MAP"
  if [[ "$current_ready" -eq 1 ]]; then
    expected_dry_state="$(read_remote_state "$EXPECTED_DRY_ENTITY" 2>/dev/null || true)"
    if [[ -z "$expected_dry_state" || "$expected_dry_state" == "unavailable" ]]; then
      current_ready=0
    fi
  fi
  if [[ "$current_ready" -eq 1 ]]; then
    entities_ready=1
    break
  fi
  if [[ "$attempt" -eq 1 || $((attempt % 3)) -eq 0 ]]; then
    printf '  Nowcast-Entitaeten noch nicht vollstaendig bereit; weiterer Versuch in 5 Sekunden (%ss) ...\n' \
      "$(((attempt - 1) * 5))"
  fi
  sleep 5
  attempt=$((attempt + 1))
done
[[ "$entities_ready" -eq 1 ]] \
  || fail "Die Nowcast-Entitaeten wurden nach fuenf Minuten nicht verfuegbar."

while IFS=$'\t' read -r key entity_id unique_id; do
  state="$(read_remote_state "$entity_id")"
  case "$key:$state" in
    nowcast_status:dry|nowcast_status:approaching|nowcast_status:active|nowcast_status:unknown) ;;
    rain_protection:on|rain_protection:off|rain_protection:unknown) ;;
    rain_in:*|rain_start:*) ;;
    *) fail "Unerwarteter Zustand nach dem Upgrade: $entity_id=$state" ;;
  esac
  case "$key" in
    nowcast_status) STATUS_ENTITY=$entity_id ;;
    rain_protection) RAIN_PROTECTION_STATE=$state ;;
  esac
  printf '  %s = %s\n' "$entity_id" "$state"
done < "$AFTER_MAP"
printf '  %s = %s\n' "$EXPECTED_DRY_ENTITY" "$expected_dry_state"

[[ -n "$STATUS_ENTITY" && -n "$RAIN_PROTECTION_STATE" ]] \
  || fail "Status- oder Regenschutz-Entitaet konnte nicht bestimmt werden."
fetch_remote_state_json "$STATUS_ENTITY" "$STATUS_JSON"
chmod 600 "$STATUS_JSON"

status_validation="$(
  python3 - "$STATUS_JSON" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
state = payload.get("state")
if state not in {"dry", "approaching", "active", "unknown"}:
    raise SystemExit(f"Unerwarteter Nowcast-Status: {state!r}")
attributes = payload.get("attributes")
if not isinstance(attributes, dict):
    raise SystemExit("Nowcast-Status hat keine Attribute.")
failures = attributes.get("frame_failures")
if isinstance(failures, bool) or not isinstance(failures, int) or failures < 0:
    raise SystemExit(f"Ungueltiges frame_failures-Attribut: {failures!r}")
protection = attributes.get("protection_active")
if protection is True:
    expected_binary = "on"
elif protection is False:
    expected_binary = "off"
elif protection is None:
    expected_binary = "unknown"
else:
    raise SystemExit(f"Ungueltiges protection_active-Attribut: {protection!r}")
currently_wet = attributes.get("currently_wet")
if currently_wet not in (True, False, None):
    raise SystemExit(f"Ungueltiges currently_wet-Attribut: {currently_wet!r}")
print(f"{failures}\t{expected_binary}\t{currently_wet}")
PY
)"
frame_failures="${status_validation%%$'\t'*}"
status_tail="${status_validation#*$'\t'}"
expected_binary_state="${status_tail%%$'\t'*}"
currently_wet="${status_tail#*$'\t'}"
[[ "$RAIN_PROTECTION_STATE" == "$expected_binary_state" ]] \
  || fail "Regenschutz-Zustand widerspricht protection_active im Statussensor."
printf '  frame_failures = %s\n' "$frame_failures"
printf '  currently_wet = %s\n' "$currently_wet"
printf '  Regenschutz/Statussensor konsistent: %s\n' "$RAIN_PROTECTION_STATE"
if [[ "$frame_failures" -gt 0 ]]; then
  printf '  HINWEIS: Mindestens ein Frame war nicht klassifizierbar und wurde sicher als unknown behandelt.\n'
fi

ssh -S "$SSH_SOCKET" "$HA_TARGET" \
  'ha core logs 2>&1 | tail -n 500' > "$CORE_LOG" || true
chmod 600 "$CORE_LOG"
log_excerpt="$(grep -niE 'meteoswiss_radar|nowcast|traceback' "$CORE_LOG" | tail -n 80 || true)"
if [[ -n "$log_excerpt" ]]; then
  printf '\nRelevanter Auszug aus dem neuen Core-Protokoll:\n%s\n' "$log_excerpt"
else
  printf '  Keine MeteoSwiss-/Nowcast-/Traceback-Zeilen im neuen Core-Protokoll.\n'
fi
printf '  Vollstaendiger Protokollauszug: %s\n' "$CORE_LOG"

ssh -S "$SSH_SOCKET" "$HA_TARGET" "rm -rf '$REMOTE_OLD'"
INSTALL_COMMITTED=1

printf '\n[10/10] Live-Testinstallation erfolgreich abgeschlossen.\n\n'
printf 'Umfang:                     Issue #195 / PR #212\n'
printf 'Installierter Commit:       %s\n' "$SOURCE_COMMIT"
printf 'Installierter Quellbaum:    %s\n' "$SOURCE_TREE"
printf 'Upstream-Basis:             %s\n' "$UPSTREAM_BASE_COMMIT"
printf 'Dateibestand:               byteweise verifiziert\n'
printf 'Vier stabile Entity-IDs:    unveraendert\n'
printf 'Neue Trockenzeit-Entitaet:  %s\n' "$EXPECTED_DRY_ENTITY"
printf 'Nowcast-Option:             %s\n' "$NOWCAST_OPTION_AFTER"
printf 'Rain protection:            %s\n' "$RAIN_PROTECTION_STATE"
printf 'Nicht klassifizierte Frames: %s\n' "$frame_failures"
printf 'Home-Assistant-Pruefung:    gueltig\n'
printf 'Geschuetztes HA-Backup:     %s\n' "$HA_BACKUP_SLUG"
printf 'Externe Komponentensicherung: %s\n' "$LOCAL_COMPONENT_BACKUP"
printf 'Interne Komponentensicherung: %s\n' "$REMOTE_BACKUP_ROOT"
printf 'Pruefprotokolle und Snapshots: %s\n' "$LOCAL_RUN_DIR"
printf '\nDas Skript hat weder Automationen noch Dashboards veraendert.\n'
printf 'Lasse die automatische Markisen-Ausfahrt bitte pausiert, bis du die oben\n'
printf 'ausgegebenen Zustaende in Home Assistant kontrolliert hast. Danach kannst\n'
printf 'du sie bewusst wieder aktivieren. Sende mir anschliessend bitte die gesamte\n'
printf 'Terminal-Ausgabe; ich werte Live-Zustaende, frame_failures und Protokoll aus.\n'
printf '\nKein HACS-Update fuer diese Integration installieren, solange PR #212 noch\n'
printf 'nicht gemergt und in einer offiziellen Version veroeffentlicht ist.\n'
