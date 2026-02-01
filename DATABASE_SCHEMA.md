# BlueLedger Database Schema

Last Updated: January 9, 2026
Firebase Project: `blueledger-3af1a`

---

## CRITICAL: Field Naming Mismatch

**The database has MIXED naming conventions. This causes silent data failures on Android.**

| Layer | Convention | Example |
|-------|------------|---------|
| Firestore (seed data) | snake_case | `incident_type`, `created_at`, `badge_number` |
| Firestore (some fields) | camelCase | `incidentType`, `incidentCount`, `liabilityRisk` |
| Firestore Indexes | Mixed | See `firestore.indexes.json` |
| Android DTOs | camelCase | `incidentType`, `createdAt`, `badgeNumber` |
| iOS Models | camelCase | `incidentType`, `incidentDate` |

**Solution for Android**: Use `@PropertyName` annotations to map Firestore fields to Kotlin properties.

---

## Data Management (CRITICAL)

**NEVER delete data. Always use additive migrations.**

### Scripts (in `scripts/`)
| Script | Purpose | When to Use |
|--------|---------|-------------|
| `backup-firestore.js` | Creates timestamped backup | BEFORE any data operation |
| `seed-firestore.js` | Additive seeding (150+ incidents, all states) | Initial setup |
| `seed-sightings.js` | Seeds sighting data | Initial setup |
| `seed_federal.js` | Seeds verified 2026 federal incidents (ICE/CBP) | Federal incident tracking |
| `seed_top_offenders.js` | Seeds repeat offenders (3+ incidents) | Top offenders from POST boards |
| `add-incident-images.js` | Adds image URLs to incidents | After seeding |
| `migrate-add-geopoint.js` | Adds `location` GeoPoint field | Schema updates |
| `refresh_daily.js` | Daily ETL refresh (cron job) | Production sync |
| `restore-firestore.js` | Recovers from backup | After data loss |

### Usage
```bash
cd scripts
npm install

# Step 1: ALWAYS backup first
node backup-firestore.js
# Creates: scripts/backups/backup-2026-01-09T.../

# Step 2: Run migration or seed
node seed-firestore.js

# Step 3: If something goes wrong
node restore-firestore.js ./backups/backup-2026-...
```

### Golden Rule
```javascript
// ❌ NEVER DO THIS - destroys user data
const deleteOps = snapshot.docs.map(doc => doc.ref.delete());
await Promise.all(deleteOps);

// ✅ ALWAYS DO THIS - preserves existing data
await doc.ref.set(newData, { merge: true });
```

---

## Collection: `incidents`

**Seed script field names** (from `seed-firestore.js`):

| Field | Type | Example | Notes |
|-------|------|---------|-------|
| `id` | string | `"CA_losangeles_20250910"` | Custom document ID |
| `state` | string | `"CA"` | 2-letter ISO code |
| `city` | string | `"Los Angeles"` | Human readable |
| `latitude` | number | `34.0522` | Decimal degrees |
| `longitude` | number | `-118.2437` | Decimal degrees |
| `location` | GeoPoint | `{lat, lng}` | Added by migration |
| `geohash` | string | `"9q5c"` | For geo-queries |
| `incident_type` | string | `"FATAL_SHOOTING"` | snake_case in DB |
| `incident_date` | string | `"2025-09-10"` | ISO date string |
| `description` | string | `"..."` | Incident details |
| `department` | string | `"LAPD"` | Agency name |
| `outcome` | string | `"UNDER_INVESTIGATION"` | Status |
| `fatal` | boolean | `true` | Fatality flag |
| `injury` | boolean | `false` | Injury flag |
| `victim_name` | string | `"John Doe"` | Optional |
| `officer_name` | string | `"Ofc. Smith"` | Optional |
| `settlement_amount` | number | `295000` | If settled |
| `source_name` | string | `"KTVU FOX 2"` | Attribution |
| `source_url` | string | `"https://..."` | Optional |
| `image_url` | string | `"https://picsum..."` | Card thumbnail |
| `created_at` | timestamp | Server timestamp | Auto-set |

**Index field names** (from `firestore.indexes.json`):
- `state` (snake_case) ✓
- `created_at` (snake_case) ✓
- `incidentType` (camelCase!) - **MISMATCH with seed data**
- `geohash` (lowercase) ✓
- `city` (lowercase) ✓
- `verificationStatus` (camelCase)

### Incident Type Values
```
FATAL_SHOOTING, SHOOTING, USE_OF_FORCE, IN_CUSTODY_DEATH,
MISCONDUCT, DOMESTIC_VIOLENCE, WRONGFUL_ARREST
```

### Outcome Values
```
UNDER_INVESTIGATION, CHARGES_FILED, SETTLEMENT, TERMINATED, CLOSED
```

---

## Collection: `officers`

**These fields are used in Firestore indexes** (from `firestore.indexes.json`):

| Field | Type | Convention | Used In Index |
|-------|------|------------|---------------|
| `state` | string | lowercase | ✓ |
| `last_name` | string | snake_case | ✓ |
| `badge_number` | string | snake_case | ✓ |
| `search_terms` | array | snake_case | ✓ (ARRAY_CONTAINS) |
| `incidentCount` | number | camelCase | ✓ |
| `liabilityRisk` | string | camelCase | ✓ |
| `isRepeatOffender` | boolean | camelCase | ✓ |

**All officer fields** (based on ETL sync and indexes):

| Field | Type | Example | Notes |
|-------|------|---------|-------|
| `state` | string | `"NY"` | 2-letter code |
| `full_name` | string | `"Carlos Baker"` | Display name |
| `first_name` | string | `"Carlos"` | For search |
| `last_name` | string | `"Baker"` | For search/index |
| `badge_number` | string | `"CPD-4928"` | Primary lookup |
| `department` | string | `"Chicago PD"` | Agency name |
| `rank` | string | `"Officer"` | Optional |
| `photoUrl` | string | `"https://..."` | camelCase in DB |
| `incidentCount` | number | `12` | camelCase in DB |
| `complaintsCount` | number | `15` | camelCase in DB |
| `settlementTotal` | number | `0` | camelCase in DB |
| `liabilityRisk` | string | `"CRITICAL"` | camelCase in DB |
| `isRepeatOffender` | boolean | `true` | camelCase in DB |
| `source` | string | `"NYC CCRB"` | Data attribution |
| `search_terms` | array | `["carlos", "baker"]` | snake_case |
| `created_at` | timestamp | Server timestamp | snake_case |
| `updated_at` | timestamp | Server timestamp | snake_case |

### Liability Risk Values
- `CRITICAL` - incidentCount > 3 OR settlementTotal > $500K (red badge)
- `HIGH` - incidentCount > 1 OR complaintsCount > 5 (orange badge)
- `LOW` - default (blue badge)

---

## Collection: `departments`

**Seed script field names**:

| Field | Type | Example | Notes |
|-------|------|---------|-------|
| `name` | string | `"New York Police Department"` | Full name |
| `city` | string | `"New York"` | City location |
| `state` | string | `"NY"` | 2-letter code |
| `officer_count` | number | `36000` | snake_case |
| `agency_type` | string | `"MUNICIPAL"` | snake_case |
| `incident_count` | number | `37` | snake_case (optional) |
| `avg_rating` | number | `3.0` | snake_case (optional) |
| `is_verified` | boolean | `true` | snake_case |
| `search_terms` | array | `["nypd", "new york"]` | For search |
| `created_at` | timestamp | Server timestamp | |
| `updated_at` | timestamp | Server timestamp | |

### Agency Type Values
```
STATE, MUNICIPAL, COUNTY, FEDERAL
```

---

## Collection: `sightings` (Real-time Reports)

**NOTE:** This is for the Waze-like real-time police sighting feature, NOT accountability data.

| Field | Type | Notes |
|-------|------|-------|
| `state` | string | 2-letter code |
| `city` | string | Location city |
| `latitude` | number | Decimal degrees |
| `longitude` | number | Decimal degrees |
| `geohash` | string | For geo-queries |
| `sighting_type` | string | snake_case |
| `is_active` | boolean | snake_case |
| `reported_at` | timestamp | snake_case |
| `confirm_count` | number | snake_case |
| `not_there_count` | number | snake_case |

### Sighting Type Values
```
PATROL_CAR, TRAFFIC_STOP, SPEED_TRAP, CHECKPOINT, ACCIDENT,
PARKED, MOTORCYCLE_COP, UNMARKED_CAR, FOOT_PATROL, MULTIPLE_UNITS
```

---

## Collection: `experiences` (User Encounters)

User-submitted stories about interactions with officers.

| Field | Type | Notes |
|-------|------|-------|
| `state` | string | 2-letter code |
| `officerBadgeNumber` | string | camelCase |
| `createdAt` | timestamp | camelCase (different from other collections!) |
| `content` | string | Story text |
| `rating` | number | 1-5 |

---

## State Codes

**CRITICAL: Always use 2-letter ISO codes, NOT full state names.**

```
AL, AK, AZ, AR, CA, CO, CT, DE, FL, GA, HI, ID, IL, IN, IA, KS, KY,
LA, ME, MD, MA, MI, MN, MS, MO, MT, NE, NV, NH, NJ, NM, NY, NC, ND,
OH, OK, OR, PA, RI, SC, SD, TN, TX, UT, VT, VA, WA, WV, WI, WY, DC
```

**Common mistake:**
```kotlin
// ❌ WRONG - returns 0 results
.whereEqualTo("state", "Indiana")

// ✅ CORRECT
.whereEqualTo("state", "IN")
```

---

## Android DTO Mapping

The Android app uses camelCase in Kotlin data classes. Use `@PropertyName` to map:

```kotlin
import com.google.firebase.firestore.PropertyName

data class RemoteIncident(
    val id: String? = null,

    @PropertyName("incident_type")
    val incidentType: String = "unknown",

    @PropertyName("incident_date")
    val incidentDate: String? = null,

    @PropertyName("created_at")
    val createdAt: String? = null,

    // These are already camelCase in Firestore
    val verificationStatus: String = "unverified",

    // ... rest of fields
)

data class RemoteOfficer(
    @PropertyName("badge_number")
    val badgeNumber: String,

    @PropertyName("first_name")
    val firstName: String? = null,

    @PropertyName("last_name")
    val lastName: String? = null,

    // These are already camelCase in Firestore
    val incidentCount: Int = 0,
    val liabilityRisk: String = "LOW",
    val isRepeatOffender: Boolean = false,

    // ... rest of fields
)
```

---

## iOS Model Mapping

iOS uses Firestore REST API. The `FirebaseService.swift` parses JSON manually:

```swift
// In parseIncidentDocument()
let incidentTypeStr = fields["incidentType"]?.stringValue
    ?? fields["incident_type"]?.stringValue  // Fallback for snake_case
    ?? "OTHER"
```

---

## Firestore Indexes

See `firestore.indexes.json` for complete index definitions.

### Key Composite Indexes

**incidents:**
1. `state` ASC, `created_at` DESC - Home feed by state
2. `geohash` ASC, `created_at` DESC - Map view
3. `incidentType` ASC, `created_at` DESC - Filter by type
4. `verificationStatus` ASC, `created_at` DESC - Moderation queue

**officers:**
1. `state` ASC, `incidentCount` DESC - State watchlist
2. `state` ASC, `last_name` ASC - Alphabetical browse
3. `badge_number` ASC, `state` ASC - Badge lookup
4. `liabilityRisk` ASC, `incidentCount` DESC - Risk filtering
5. `isRepeatOffender` ASC, `incidentCount` DESC - Repeat offenders

**sightings:**
1. `is_active` ASC, `reported_at` DESC - Active sightings
2. `geohash` ASC, `reported_at` DESC - Map view

---

## Live Data Status (Jan 20, 2026)

| Collection | Source | Records | States Covered |
|------------|--------|---------|----------------|
| `officers` | POST Boards + CCRB + WSCJTC | **6,620** | **52 states/territories** |
| `incidents` | Seed data + Federal + IMPD UOF | **800+** | All 50 states + DC + Federal |
| `departments` | Seed data + Connectors | **461** | All 50 states + DC |

### Top States by Officer Coverage
| State | Officers | Departments | Source |
|-------|----------|-------------|--------|
| **MA** | 3,344 | 337 | MA POST Commission |
| **WA** | 1,503 | 1 | WSCJTC Socrata API |
| **NY** | 1,003 | 3 | NYC CCRB |
| **CA** | 537 | 6 | CA POST + CPRA |
| **IN** | 38 | 16 | NPI + Local sources |

### Hugging Face Datasets (Offline Packs)
| Dataset | Contents | URL |
|---------|----------|-----|
| `raayraay/blueledger-data` | State packs (officers, depts, incidents) | [Link](https://huggingface.co/datasets/raayraay/blueledger-data/tree/main/states) |
| `raayraay/blueledger-news` | 510 articles, 51 states | [Link](https://huggingface.co/datasets/raayraay/blueledger-news) |

**State Pack Incident Coverage (Jan 2026):**
| State | Incidents | Source |
|-------|-----------|--------|
| IN | 669 | IMPD Use of Force Dashboard (ArcGIS) |
| Other states | 0 | Pending connector integration |

The `index_v1.json` manifest tracks per-state incident counts. Mobile apps can check this to determine offline data availability.

### Hugging Face Export Automation

**State packs are refreshed via the Hugging Face exporter, NOT Firebase Cloud Functions.**

| Script | Location | Purpose |
|--------|----------|---------|
| `export_hf_packs.sh` | `scripts/` | Exports Firestore → JSON → Hugging Face |
| `export_states_to_json.js` | `scripts/` | Firestore to JSON export |
| `generate_hf_index.py` | `scripts/` | Generates `index_v1.json` manifest |

**Cron Setup (Daily at 2 AM):**
```bash
# Add to crontab (crontab -e)
0 2 * * * cd /path/to/BlueLedger/scripts && ./export_hf_packs.sh >> export_hf_packs.log 2>&1
```

**Environment Variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `SKIP_FIRESTORE` | `0` | Set to `1` to use cached exports (no Firestore reads) |
| `DRY_RUN` | `0` | Set to `1` to skip Hugging Face upload |
| `HF_CLI` | `/path/to/huggingface-cli` | Path to huggingface-cli binary |
| `MAX_RETRIES` | `5` | Retry count for Firestore export |
| `SLEEP_SECONDS` | `300` | Delay between retries (5 min) |

**Exit Codes:**
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Firestore export failed |
| 2 | Index generation failed |
| 3 | Hugging Face upload failed |

**Manual Run Examples:**
```bash
# Full export (Firestore → HF)
./export_hf_packs.sh

# Use cached exports, skip Firestore (when quota exhausted)
SKIP_FIRESTORE=1 ./export_hf_packs.sh

# Generate locally, don't upload to HF
DRY_RUN=1 ./export_hf_packs.sh

# Both (testing)
SKIP_FIRESTORE=1 DRY_RUN=1 ./export_hf_packs.sh
```

**Note:** The mobile apps now read from Hugging Face datasets rather than Firestore directly. Firestore is used for writes (new incidents, user submissions) and real-time features only.

---

## Data Sources & Connectors

### 50-State Connector Architecture (in `scripts/connectors/`)
The `scripts/connectors/` directory houses specialized scripts for each state's transparency portal.

| Connector | Jurisdiction | Type | Records | Status |
|-----------|--------------|------|---------|--------|
| `fetch_wa_cjtc.js` | Washington (WSCJTC) | Socrata API | 1,905 | ✅ Active |
| `fetch_ma_post.js` | Massachusetts POST | CSV Download | 3,340 | ✅ Active |
| `fetch_or_dpsst.js` | Oregon DPSST | Excel Local | TBD | ✅ Active (needs file) |
| `fetch_indiana_npi.js` | Indiana NPI | Puppeteer | TBD | ✅ Active |
| `fetch_in_impd_use_of_force.js` | Indiana (IMPD) | ArcGIS REST API | 669 incidents | ✅ Active |
| `ingest_manual_csv.js` | Generic CSV | Manual | Varies | ✅ Active |

### Dropbox POST Data Pipeline (in `scripts/temp_repo/db/`)
26 states with pre-cleaned POST board data from national-post-db Dropbox:
```
CA, AZ, FL, GA, ID, IL, IN, KS, KY, MD, MN, MS, NC, NM, OH, OR, SC, TN, TX, UT, VT, WA, WV, WY
+ Florida-Discipline, Georgia-Discipline
```

Pipeline: `db/download` → `db/preprocess` → `db/upload` (to Firestore `db_launch` collection)

### IMPD Use of Force Incidents (in `scripts/connectors/`)
- Source: [IMPD Use of Force Dashboard](https://data.indy.gov/datasets/impd-use-of-force-incidents/about)
- REST endpoint: `https://gis.indy.gov/server/rest/services/OpenData/OpenData_NonSpatial/MapServer/7`
- Script: `fetch_in_impd_use_of_force.js` (geocodes each address via ArcGIS World Geocoding API and upserts lethal-force incidents into Firestore `incidents`)
- Coverage: 2014-present firearm discharges (669 subject-level incidents after de-duping by incident + subject)

### Connector Logic
All connectors MUST normalize data to this schema before writing to Firestore:
1. **Officer ID:** `STATE_DEPT_NAME` (e.g., `IN_IMPD_JOHN_DOE`)
2. **Naming:** `snake_case` for fields (`full_name`, `badge_number`)
3. **Metrics:** `camelCase` for counts (`incidentCount`, `liabilityRisk`)
4. **Source:** Explicit attribution string

**Federal Incidents:**
- Minneapolis ICE shooting (Jan 7, 2026): Renee Nicole Good
- Portland CBP shooting (Jan 8, 2026): Hospital parking lot incident

**Officer Data:**
- NY: 100 real NYPD officers from NYC CCRB
- Top Offenders (6 states): CA, FL, MA, MN, OR, TX
  - Threshold: 3+ documented incidents (repeat offender pattern)
  - Source: State POST board decertifications
- Remaining 43 states: Need National Decertification Index integration

### Verification Queries (Firebase Console)

Test data exists:
```
incidents where state == "IN"   → Indiana incidents (8+)
incidents where state == "CA"   → California incidents
incidents where agency_type == "FEDERAL" → Federal ICE/CBP incidents (2)
officers where state == "NY"    → 100 real NYPD officers
officers where state == "CA"    → Christopher Schurr (6 incidents, $750K settlement)
officers where state == "MN"    → Derek Chauvin (18 incidents, $27M settlement)
officers where source == "NYC CCRB" → Real officers with complaints
officers where isRepeatOffender == true → Flagged officers
officers where liabilityRisk == "CRITICAL" → Highest risk
system_metadata/threat_level → Federal threat level (HIGH if >= 2 shootings)
```

---

## Watchlist Data Sources

### Working Sources (have officer names)
| Source | State | Dataset | Officers | Auth |
|--------|-------|---------|----------|------|
| NYC CCRB | NY | `data.cityofnewyork.us/2fir-qns4` | 36K+ | Tyler Token |
| MA POST | MA | `mapostcommission.gov` CSV | Decertified | None |
| OR DPSST | OR | `oregon.gov/dpsst` Excel | Professional Standards | None |

### De-Identified Sources (Statistics Only)
| Source | Dataset | Officer Names |
|--------|---------|---------------|
| Chicago COPA | `vnz2-rmie` | "Unknown" |
| Chicago BIA | `kf8c-t4u8` | "Unknown" |
| San Francisco DPA | `b4we-97wx` | Salesforce IDs |
| SF Use of Force | `hrt5-562g` | "Officer_UID" |
| Austin APD | `gt7y-jdu4` | Aggregated |
| Seattle OPA | `hyay-5x7b` | De-identified |

### API Tokens (in `functions/.env`)
```
NYC_OPENDATA_APP_TOKEN=j6B29V3A6NH3bfUCNjBGLXrx2
SEATTLE_OPENDATA_APP_TOKEN=VR5dJE1Csc7PYptNaG9Kbqe34
SOCRATA_APP_TOKEN=j6B29V3A6NH3bfUCNjBGLXrx2
```

---

## Socrata Portals (Potential - NOT Connected)

**Cities:**
| City | Portal |
|------|--------|
| Chicago | `data.cityofchicago.org` |
| Los Angeles | `data.lacity.org` |
| San Francisco | `datasf.org` |
| Philadelphia | `opendataphilly.org` |
| Austin | `data.austintexas.gov` |
| Denver | `denvergov.org/opendata` |
| Baltimore | `data.baltimorecity.gov` |
| Boston | `data.boston.gov` |
| Seattle | `data.seattle.gov` |

**States:**
| State | Portal |
|-------|--------|
| CA | `data.ca.gov` |
| TX | `data.texas.gov` |
| NY | `data.ny.gov` |
| IL | `data.illinois.gov` |
| CT | `data.ct.gov` |
| MD | `data.maryland.gov` |
