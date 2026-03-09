# Bundle Data Inventory

Generated: 2026-03-09T03:32:30.447044+00:00

## Live Dashboard Files

### `data/officers.parquet`
- Rows: 6620
- Columns: 25
- Loaded by: `assets/index-BfLy6p76.js`
- Shipping status: `live_bundle`
- Source tags: `{"ccrb": 1000, "legacy_watchlist": 32, "post_board": 596, "structured_agency_record": 4992}`
- Note: Normalized placeholder badge numbers to null.
- Note: Replaced incorrect blanket officer state values with identifier-derived state codes when deterministic.
- Note: Filled department only when it was safely inferable from the shipped identifier.
- Note: Added provenance and bundle-role tags for auditability.

### `data/incidents.parquet`
- Rows: 22780
- Columns: 28
- Loaded by: `assets/index-BfLy6p76.js`
- Shipping status: `live_bundle`
- Source tags: `{"fatal_encounters": 22111, "indy_open_data": 669}`
- Note: Added source-family tags from stable record ID prefixes.
- Note: Marked non-live incident parquet variants as pipeline artifacts.

## Auxiliary Or Pipeline Files

### `data/incidents_enriched.parquet`
- Shipping status: `auxiliary_not_loaded`
- Size: n/a bytes
- Note: Added source-family tags from stable record ID prefixes.
- Note: Marked non-live incident parquet variants as pipeline artifacts.

### `data/incidents_linked.parquet`
- Shipping status: `auxiliary_not_loaded`
- Size: n/a bytes
- Note: Added source-family tags from stable record ID prefixes.
- Note: Marked non-live incident parquet variants as pipeline artifacts.

### `data/linking_report.json`
- Shipping status: `auxiliary_not_loaded`
- Size: 235 bytes
- Note: Pipeline artifact summarizing the current incident-to-officer linking run.
- Note: Not loaded by the live dashboard bundle.

### `alerts.json`
- Shipping status: `auxiliary_not_loaded`
- Size: 9938 bytes
- Records: 25

### `all_states.json`
- Shipping status: `auxiliary_not_loaded`
- Size: 9997 bytes
- Records: 510

### `states/`
- Shipping status: `auxiliary_not_loaded`
- Size: 387162 bytes
- Records: 51
- Note: State news feed shards used by research/news workflows.
- Note: Not referenced by the active dashboard bundle in index.html.
