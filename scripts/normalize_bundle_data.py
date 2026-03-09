from __future__ import annotations

import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq


ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

LIVE_DATASETS = {
    "data/officers.parquet",
    "data/incidents.parquet",
}

ACTIVE_BUNDLE = {
    "entrypoint": "index.html",
    "script": "assets/index-BfLy6p76.js",
    "stylesheet": "assets/index-D5WdD-vB.css",
}

STATE_CODES = {
    "AL",
    "AK",
    "AZ",
    "AR",
    "CA",
    "CO",
    "CT",
    "DE",
    "DC",
    "FL",
    "GA",
    "HI",
    "IA",
    "ID",
    "IL",
    "IN",
    "KS",
    "KY",
    "LA",
    "MA",
    "MD",
    "ME",
    "MI",
    "MN",
    "MO",
    "MS",
    "MT",
    "NC",
    "ND",
    "NE",
    "NH",
    "NJ",
    "NM",
    "NV",
    "NY",
    "OH",
    "OK",
    "OR",
    "PA",
    "RI",
    "SC",
    "SD",
    "TN",
    "TX",
    "UT",
    "VA",
    "VT",
    "WA",
    "WI",
    "WV",
    "WY",
}

PLACEHOLDER_BADGES = {"", "00000", "UNKNOWN", "UNKNOWN BADGE"}

SOURCE_TAG_DESCRIPTIONS = {
    "ccrb": "New York City Civilian Complaint Review Board record family",
    "post_board": "POST or decertification board record family",
    "structured_agency_record": "Officer identifier embeds an agency-style record slug",
    "legacy_watchlist": "Legacy research/watchlist identifier without embedded provenance",
    "fatal_encounters": "Fatal Encounters incident import",
    "indy_open_data": "Indianapolis/IMPD incident import",
}

SPECIAL_DEPARTMENTS = {
    "CCRB": "New York City Police Department",
    "IN_IMPD": "Indianapolis Metropolitan Police Department",
    "WA_STATE_PATROL_WSP": "Washington State Patrol (WSP)",
    "MASSACHUSETTS_STATE_POLICE": "Massachusetts State Police",
}

DEPARTMENT_PATTERNS = (
    r"(.+?_POLICE_DEPARTMENT)",
    r"(.+?_STATE_POLICE)",
    r"(.+?_STATE_PATROL(?:__WSP__)?)",
    r"(.+?_SHERIFF_S_OFFICE)",
    r"(.+?_SHERIFF_OFFICE)",
    r"(.+?_SHERIFF_DEPARTMENT)",
    r"(.+?_DEPARTMENT_OF_PUBLIC_SAFETY)",
    r"(.+?_PUBLIC_SAFETY_DEPARTMENT)",
    r"(.+?_MARSHALS_SERVICE)",
    r"(.+?_UNIVERSITY_POLICE_DEPARTMENT)",
    r"(.+?_COLLEGE_POLICE_DEPARTMENT)",
)

TOKEN_REPLACEMENTS = {
    "PD": "PD",
    "WSP": "WSP",
    "MIT": "MIT",
    "IMPD": "IMPD",
    "CCRB": "CCRB",
    "WA": "WA",
    "U": "U",
    "S": "S",
}


def normalize_badge(value: object) -> object:
    if value is None or pd.isna(value):
        return pd.NA
    text = str(value).strip()
    if text.upper() in PLACEHOLDER_BADGES:
        return pd.NA
    return text


def is_missing_text(value: object) -> bool:
    return value is None or pd.isna(value) or not str(value).strip()


def infer_state_from_identifier(identifier: object, badge_number: object) -> tuple[object, bool]:
    candidates = []
    for value in (identifier, badge_number):
        if value is None or pd.isna(value):
            continue
        text = str(value).strip().upper()
        if not text:
            continue
        candidates.append(text)

    for text in candidates:
        if text.startswith("CCRB_"):
            return "NY", True

        match = re.match(r"^POST[_-]([A-Z]{2})[_-]", text)
        if match and match.group(1) in STATE_CODES:
            return match.group(1), True

        match = re.match(r"^([A-Z]{2})[_-]", text)
        if match and match.group(1) in STATE_CODES:
            return match.group(1), True

    return pd.NA, False


def titleize_department_slug(slug: str) -> str:
    normalized = slug.replace("__", "_").strip("_")
    if normalized in SPECIAL_DEPARTMENTS:
        return SPECIAL_DEPARTMENTS[normalized]

    tokens = [token for token in normalized.split("_") if token]
    words: list[str] = []
    for token in tokens:
        replacement = TOKEN_REPLACEMENTS.get(token)
        words.append(replacement if replacement else token.capitalize())

    text = " ".join(words)
    text = text.replace("Sheriff S Office", "Sheriff's Office")
    text = text.replace(" Of ", " of ")
    text = text.replace(" And ", " and ")
    text = text.replace(" Department Of ", " Department of ")
    text = text.replace(" State Patrol WSP", " State Patrol (WSP)")
    return text


def infer_department_from_identifier(identifier: object) -> tuple[object, bool]:
    if identifier is None or pd.isna(identifier):
        return pd.NA, False

    raw = str(identifier).strip().upper()
    if not raw:
        return pd.NA, False

    if raw.startswith("CCRB_"):
        return SPECIAL_DEPARTMENTS["CCRB"], True
    if raw.startswith("IN_IMPD_"):
        return SPECIAL_DEPARTMENTS["IN_IMPD"], True

    without_state = re.sub(r"^[A-Z]{2}_", "", raw)
    without_post = re.sub(r"^POST_[A-Z]{2}_", "", without_state)

    for pattern in DEPARTMENT_PATTERNS:
        match = re.search(pattern, without_post)
        if match:
            return titleize_department_slug(match.group(1)), True

    return pd.NA, False


def infer_officer_source_tag(identifier: object, badge_number: object) -> str:
    identifier_text = "" if identifier is None or pd.isna(identifier) else str(identifier).strip().upper()
    badge_text = "" if badge_number is None or pd.isna(badge_number) else str(badge_number).strip().upper()

    if identifier_text.startswith("CCRB_"):
        return "ccrb"
    if identifier_text.startswith("POST_") or badge_text.startswith("POST-"):
        return "post_board"
    if re.match(r"^[A-Z]{2}_", identifier_text):
        return "structured_agency_record"
    return "legacy_watchlist"


def normalize_officers(path: Path) -> dict[str, object]:
    df = pq.read_table(path).to_pandas()

    cleaned_badge = df["badge_number"].map(normalize_badge)
    state_values: list[object] = []
    state_inferred_flags: list[bool] = []
    department_values: list[object] = []
    department_inferred_flags: list[bool] = []
    source_tags: list[str] = []

    for _, row in df.iterrows():
        inferred_state, state_inferred = infer_state_from_identifier(row["id"], cleaned_badge.get(row.name))
        state_value = inferred_state if state_inferred else pd.NA
        if state_value is None or pd.isna(state_value) or str(state_value).strip().upper() not in STATE_CODES:
            state_value = pd.NA

        inferred_department, department_inferred = infer_department_from_identifier(row["id"])
        existing_department = row["department"] if "department" in df.columns else pd.NA
        department_value = existing_department
        if is_missing_text(department_value):
            department_value = inferred_department
        if is_missing_text(department_value):
            department_value = pd.NA

        state_values.append(state_value)
        state_inferred_flags.append(bool(state_inferred))
        department_values.append(department_value)
        department_inferred_flags.append(bool(department_inferred and is_missing_text(existing_department)))
        source_tags.append(infer_officer_source_tag(row["id"], cleaned_badge.get(row.name)))

    df["badge_number"] = cleaned_badge.astype("string")
    df["state"] = pd.Series(state_values, dtype="string")
    df["department"] = pd.Series(department_values, dtype="string")
    df["record_source_tag"] = pd.Series(source_tags, dtype="string")
    df["record_source_label"] = df["record_source_tag"].map(SOURCE_TAG_DESCRIPTIONS).astype("string")
    df["provenance_status"] = df["record_source_tag"].map(
        {
            "ccrb": "named_source_family",
            "post_board": "named_source_family",
            "structured_agency_record": "identifier_inferred",
            "legacy_watchlist": "unverified_bundle_record",
        }
    ).astype("string")
    df["bundle_role_tag"] = "live_dashboard"
    df["state_inferred_from_id"] = state_inferred_flags
    df["department_inferred_from_id"] = department_inferred_flags
    df["badge_number_present"] = df["badge_number"].notna()

    pq.write_table(pa.Table.from_pandas(df, preserve_index=False), path)

    return {
        "path": path.relative_to(ROOT).as_posix(),
        "shippingStatus": "live_bundle",
        "loadedBy": ACTIVE_BUNDLE["script"],
        "rowCount": int(len(df)),
        "columnCount": int(len(df.columns)),
        "sourceTagCounts": dict(sorted(Counter(df["record_source_tag"].dropna()).items())),
        "stateCounts": dict(sorted(Counter(df["state"].dropna()).items())),
        "departmentFilledCount": int(df["department"].notna().sum()),
        "badgeMissingCount": int(df["badge_number"].isna().sum()),
        "notes": [
            "Normalized placeholder badge numbers to null.",
            "Replaced incorrect blanket officer state values with identifier-derived state codes when deterministic.",
            "Filled department only when it was safely inferable from the shipped identifier.",
            "Added provenance and bundle-role tags for auditability.",
        ],
    }


def infer_incident_source_tag(identifier: object) -> str:
    if identifier is None or pd.isna(identifier):
        return "unknown_incident_source"
    text = str(identifier).strip().upper()
    if text.startswith("FE_"):
        return "fatal_encounters"
    if text.startswith("IN_IMPD_"):
        return "indy_open_data"
    return "other_bundle_incident"


def normalize_incidents(path: Path) -> dict[str, object]:
    df = pq.read_table(path).to_pandas()
    df["record_source_tag"] = df["id"].map(infer_incident_source_tag).astype("string")
    df["record_source_label"] = df["record_source_tag"].map(SOURCE_TAG_DESCRIPTIONS).fillna(
        "Other bundled incident import"
    ).astype("string")
    df["provenance_status"] = df["record_source_tag"].map(
        {
            "fatal_encounters": "named_source_family",
            "indy_open_data": "named_source_family",
        }
    ).fillna("bundle_import").astype("string")
    df["bundle_role_tag"] = "live_dashboard" if path.name == "incidents.parquet" else "pipeline_artifact"

    pq.write_table(pa.Table.from_pandas(df, preserve_index=False), path)

    return {
        "path": path.relative_to(ROOT).as_posix(),
        "shippingStatus": "live_bundle" if path.name == "incidents.parquet" else "auxiliary_not_loaded",
        "loadedBy": ACTIVE_BUNDLE["script"] if path.name == "incidents.parquet" else None,
        "rowCount": int(len(df)),
        "columnCount": int(len(df.columns)),
        "sourceTagCounts": dict(sorted(Counter(df["record_source_tag"].dropna()).items())),
        "notes": [
            "Added source-family tags from stable record ID prefixes.",
            "Marked non-live incident parquet variants as pipeline artifacts.",
        ],
    }


def summarize_json(path: Path, shipping_status: str) -> dict[str, object]:
    payload = json.loads(path.read_text())
    entry = {
        "path": path.relative_to(ROOT).as_posix(),
        "shippingStatus": shipping_status,
        "loadedBy": None,
        "topLevelKeys": sorted(payload.keys()) if isinstance(payload, dict) else None,
        "sizeBytes": path.stat().st_size,
    }
    if path.name == "alerts.json":
        entry["recordCount"] = len(payload.get("alerts", []))
    elif path.name == "all_states.json":
        entry["recordCount"] = int(payload.get("totalArticles", 0))
        entry["stateCount"] = int(payload.get("totalStates", 0))
    return entry


def write_inventory(manifest: dict[str, object]) -> None:
    live_entries = [entry for entry in manifest["datasets"] if entry["shippingStatus"] == "live_bundle"]
    aux_entries = [entry for entry in manifest["datasets"] if entry["shippingStatus"] != "live_bundle"]

    lines = [
        "# Bundle Data Inventory",
        "",
        f"Generated: {manifest['generatedAt']}",
        "",
        "## Live Dashboard Files",
        "",
    ]

    for entry in live_entries:
        lines.extend(
            [
                f"### `{entry['path']}`",
                f"- Rows: {entry.get('rowCount', 'n/a')}",
                f"- Columns: {entry.get('columnCount', 'n/a')}",
                f"- Loaded by: `{entry.get('loadedBy')}`",
                f"- Shipping status: `{entry['shippingStatus']}`",
            ]
        )
        if entry.get("sourceTagCounts"):
            lines.append(f"- Source tags: `{json.dumps(entry['sourceTagCounts'], sort_keys=True)}`")
        for note in entry.get("notes", []):
            lines.append(f"- Note: {note}")
        lines.append("")

    lines.extend(["## Auxiliary Or Pipeline Files", ""])
    for entry in aux_entries:
        lines.extend(
            [
                f"### `{entry['path']}`",
                f"- Shipping status: `{entry['shippingStatus']}`",
                f"- Size: {entry.get('sizeBytes', 'n/a')} bytes",
            ]
        )
        if entry.get("recordCount") is not None:
            lines.append(f"- Records: {entry['recordCount']}")
        for note in entry.get("notes", []):
            lines.append(f"- Note: {note}")
        lines.append("")

    (ROOT / "DATA_INVENTORY.md").write_text("\n".join(lines).rstrip() + "\n")


def validate_incident_linkage() -> dict[str, object]:
    """Report linkage quality between officers and incidents (Finding 3)."""
    officers = pq.read_table(DATA_DIR / "officers.parquet").to_pandas()
    incidents = pq.read_table(DATA_DIR / "incidents.parquet").to_pandas()

    total_incidents = len(incidents)
    has_officer_id = incidents["officer_id"].notna().sum() if "officer_id" in incidents.columns else 0
    linkage_rate = has_officer_id / total_incidents * 100 if total_incidents else 0

    # Officers claiming incidents but with no linked rows
    phantom_count = 0
    if "incident_count" in officers.columns and "officer_id" in incidents.columns:
        linked_officer_ids = set(incidents["officer_id"].dropna().unique())
        has_count = officers[officers["incident_count"].fillna(0) > 0]
        phantom_count = int((~has_count["id"].isin(linked_officer_ids)).sum())

    # Cross-state mismatches
    cross_state = 0
    if "officer_id" in incidents.columns and "state" in incidents.columns:
        linked = incidents[incidents["officer_id"].notna()].copy()
        if not linked.empty and "state" in officers.columns:
            merged = linked.merge(officers[["id", "state"]], left_on="officer_id", right_on="id",
                                  suffixes=("_incident", "_officer"), how="left")
            both_have_state = merged["state_incident"].notna() & merged["state_officer"].notna()
            cross_state = int((merged.loc[both_have_state, "state_incident"] !=
                               merged.loc[both_have_state, "state_officer"]).sum())

    stats = {
        "total_incidents": total_incidents,
        "incidents_with_officer_id": int(has_officer_id),
        "linkage_rate_pct": round(linkage_rate, 2),
        "officers_with_count_but_no_links": phantom_count,
        "cross_state_mismatches": cross_state,
    }
    print("\n=== Incident Linkage Quality Report ===")
    for k, v in stats.items():
        print(f"  {k}: {v}")
    if linkage_rate < 5:
        print("  ⚠  WARNING: Linkage rate is very low — timeline per-officer history will be sparse.")
    print()
    return stats


def main() -> None:
    generated_at = datetime.now(timezone.utc).isoformat()

    dataset_entries: list[dict[str, object]] = []
    dataset_entries.append(normalize_officers(DATA_DIR / "officers.parquet"))
    dataset_entries.append(normalize_incidents(DATA_DIR / "incidents.parquet"))
    dataset_entries.append(normalize_incidents(DATA_DIR / "incidents_enriched.parquet"))
    dataset_entries.append(normalize_incidents(DATA_DIR / "incidents_linked.parquet"))

    # Finding 3: Report linkage quality
    linkage_stats = validate_incident_linkage()

    dataset_entries.append(
        {
            "path": "data/linking_report.json",
            "shippingStatus": "auxiliary_not_loaded",
            "loadedBy": None,
            "sizeBytes": (DATA_DIR / "linking_report.json").stat().st_size,
            "notes": [
                "Pipeline artifact summarizing the current incident-to-officer linking run.",
                "Not loaded by the live dashboard bundle.",
            ],
        }
    )
    dataset_entries.append(summarize_json(ROOT / "alerts.json", "auxiliary_not_loaded"))
    dataset_entries.append(summarize_json(ROOT / "all_states.json", "auxiliary_not_loaded"))
    dataset_entries.append(
        {
            "path": "states/",
            "shippingStatus": "auxiliary_not_loaded",
            "loadedBy": None,
            "sizeBytes": sum(path.stat().st_size for path in (ROOT / "states").glob("*.json")),
            "recordCount": len(list((ROOT / "states").glob("*.json"))),
            "notes": [
                "State news feed shards used by research/news workflows.",
                "Not referenced by the active dashboard bundle in index.html.",
            ],
        }
    )

    manifest = {
        "generatedAt": generated_at,
        "app": ACTIVE_BUNDLE,
        "datasets": dataset_entries,
        "notes": [
            "The active dashboard bundle loads only data/officers.parquet and data/incidents.parquet.",
            "Auxiliary JSON/news files remain in-repo but are explicitly tagged as not loaded by the live dashboard.",
            "Officer provenance is only upgraded when the shipped identifier makes the source family deterministic.",
        ],
    }

    manifest_path = DATA_DIR / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n")
    write_inventory(manifest)


if __name__ == "__main__":
    main()
