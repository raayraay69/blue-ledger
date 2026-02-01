# Offline Incident Ingestion TODO

**Date:** January 20, 2026
**Status:** ✅ IMPLEMENTED (January 20, 2026)

## Overview

The Hugging Face state packs (`raayraay/blueledger-data/states/*.json`) now include incidents alongside officers and departments. The Android `OfflinePackManager` has been updated to ingest these incidents into Room.

## Implementation Summary (January 20, 2026)

### What Was Done

1. **IncidentDao** (`data/local/dao/IncidentDao.kt`)
   - Added `deleteByState(state: String)` - clears incidents before re-download
   - Added `countByState(state: String): Int` - checks if Room has data
   - `insertAll()` already existed for batch insert

2. **IncidentRepository** (`data/repository/IncidentRepository.kt`)
   - Added `insertAllIncidents(incidents: List<Incident>): List<Long>` - batch insert
   - Added `deleteByState(state: String)` - for clearing before re-import
   - Added `countByState(state: String): Int` - for Room-first strategy
   - Added `getIncidentCountByState(state: String): Int` - alias for docs

3. **OfflinePackManager** (`data/sync/OfflinePackManager.kt`)
   - Updated `DownloadStatus.Success` to include `incidentCount`
   - Updated `showCompletionNotification()` to show incident count
   - Added `incidentRepository.deleteByState(stateCode)` before insert
   - Changed from one-by-one insert to batch `insertAllIncidents()`
   - Logs incident counts in download progress

4. **HomeViewModel** (`ui/home/HomeViewModel.kt`)
   - Refactored `loadDataFromFirebase()` to use Room-first strategy
   - Added `loadDataFromFirebaseRemote()` as fallback
   - Checks `incidentRepository.getIncidentCountByState(state)` first
   - Uses Room data if available, falls back to Firebase only if empty

## Export Pipeline Status (Complete)

The Hugging Face export automation is fully operational:

| Component | Status | Notes |
|-----------|--------|-------|
| `export_hf_packs.sh` | ✅ Cron-ready | Retries, logging, exit codes, env toggles |
| `export_states_to_json.js` | ✅ Working | Exports Firestore → JSON |
| `generate_hf_index.py` | ✅ Working | Generates index_v1.json manifest |
| HF Dataset | ✅ Verified | 52 states, IN has 669 incidents |

**Cron Schedule:**
```bash
# Daily at 2 AM
0 2 * * * cd /path/to/BlueLedger/scripts && ./export_hf_packs.sh >> export_hf_packs.log 2>&1
```

## Firestore Usage Model

**Read Path (Offline Incidents):**
- Mobile apps should read from Hugging Face state packs (not Firestore)
- HF packs are refreshed daily via cron
- Reduces Firestore read costs and quota usage

**Write Path (Still Uses Firestore):**
- New incidents (user submissions, ETL ingestion) → Firestore
- Real-time features (sightings, confirmations) → Firestore
- The HF exporter reads from Firestore and publishes to HF

**Why This Architecture:**
- Firestore read quota is limited (50K/day free tier)
- HF hosting is free and unlimited
- Mobile apps get fast, offline-capable data
- Fresh data syncs daily from Firestore → HF

## Current State

- HF state packs contain: `{ officers: [], departments: [], incidents: [] }`
- IN pack has 669 incidents (IMPD Use of Force data)
- Other states have 0 incidents (pending connector integration)
- `index_v1.json` tracks per-state incident counts

## Required Changes

### 1. Room Entity for Incidents

Create `app/src/main/java/com/blueledger/app/data/local/entity/IncidentEntity.kt`:

```kotlin
@Entity(tableName = "incidents")
data class IncidentEntity(
    @PrimaryKey val id: String,
    val state: String,
    val city: String?,
    val type: String?,
    val date: String?,
    val description: String?,
    val summary: String?,
    val outcome: String?,
    val fatal: Boolean = false,
    val injury: Boolean = false,
    val department: String?,
    val address: String?,
    val latitude: Double?,
    val longitude: Double?,
    val imageUrl: String?,
    val sourceName: String?,
    val sourceUrl: String?,
    val verificationStatus: String?
)
```

### 2. DAO for Incidents

Create `app/src/main/java/com/blueledger/app/data/local/dao/IncidentDao.kt`:

```kotlin
@Dao
interface IncidentDao {
    @Query("SELECT * FROM incidents WHERE state = :state ORDER BY date DESC")
    fun getByState(state: String): Flow<List<IncidentEntity>>

    @Query("SELECT * FROM incidents WHERE city = :city ORDER BY date DESC")
    fun getByCity(city: String): Flow<List<IncidentEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(incidents: List<IncidentEntity>)

    @Query("DELETE FROM incidents WHERE state = :state")
    suspend fun deleteByState(state: String)

    @Query("SELECT COUNT(*) FROM incidents WHERE state = :state")
    suspend fun countByState(state: String): Int
}
```

### 3. Update BlueLedgerDatabase

Add incident entity and DAO to `BlueLedgerDatabase.kt`:

```kotlin
@Database(
    entities = [DepartmentEntity::class, OfficerEntity::class, IncidentEntity::class],
    version = 3  // Bump version
)
abstract class BlueLedgerDatabase : RoomDatabase() {
    abstract fun departmentDao(): DepartmentDao
    abstract fun officerDao(): OfficerDao
    abstract fun incidentDao(): IncidentDao
}
```

### 4. Update OfflinePackManager

Modify `OfflinePackManager.kt` to parse and insert incidents:

```kotlin
// In StatePackData DTO
data class StatePackData(
    val officers: List<OfficerDto>? = null,
    val departments: List<DepartmentDto>? = null,
    val incidents: List<IncidentDto>? = null  // NEW
)

// In the download/parse logic
suspend fun downloadStatePack(stateCode: String) {
    // ... existing download logic ...

    packData.incidents?.let { incidents ->
        val entities = incidents.map { it.toEntity() }
        incidentDao.deleteByState(stateCode)
        incidentDao.insertAll(entities)
        Log.d(TAG, "Inserted ${entities.size} incidents for $stateCode")
    }
}
```

### 5. IncidentDto for Gson Parsing

Create DTO that matches the HF JSON schema:

```kotlin
data class IncidentDto(
    val id: String? = null,
    val city: String? = null,
    val state: String? = null,
    val type: String? = null,
    val incident_type: String? = null,
    val date: String? = null,
    val incident_date: String? = null,
    val description: String? = null,
    val summary: String? = null,
    val outcome: String? = null,
    val fatal: Boolean? = null,
    val injury: Boolean? = null,
    val department: String? = null,
    val address: String? = null,
    val verification_status: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val location: LocationDto? = null,
    val image_url: String? = null,
    val source_name: String? = null,
    val source_url: String? = null
) {
    fun toEntity(): IncidentEntity = IncidentEntity(
        id = id ?: UUID.randomUUID().toString(),
        state = state ?: "UNKNOWN",
        city = city,
        type = type ?: incident_type,
        date = date ?: incident_date,
        description = description,
        summary = summary,
        outcome = outcome,
        fatal = fatal ?: false,
        injury = injury ?: false,
        department = department,
        address = address,
        latitude = latitude ?: location?.lat,
        longitude = longitude ?: location?.lng,
        imageUrl = image_url,
        sourceName = source_name,
        sourceUrl = source_url,
        verificationStatus = verification_status
    )
}

data class LocationDto(val lat: Double?, val lng: Double?)
```

### 6. Disable Redundant Firestore Reads

Once offline incidents work, modify HomeViewModel to:

1. Check if incidents exist in Room for the selected state
2. If yes, use Room data (fast, offline)
3. If no, fall back to Firestore (for states without HF data)
4. Optionally: Use Firestore only for "confirmations" (latest updates)

```kotlin
// In HomeViewModel
fun loadIncidents(stateCode: String) {
    viewModelScope.launch {
        // Try Room first
        val localCount = incidentDao.countByState(stateCode)
        if (localCount > 0) {
            incidentDao.getByState(stateCode).collect { incidents ->
                _uiState.update { it.copy(incidents = incidents.map { it.toUiModel() }) }
            }
        } else {
            // Fall back to Firestore
            loadIncidentsFromFirestore(stateCode)
        }
    }
}
```

## Testing Checklist

- [x] IncidentDao methods compile (deleteByState, countByState)
- [x] IncidentRepository methods compile (insertAllIncidents, deleteByState, countByState)
- [x] OfflinePackManager compiles with batch incident insert
- [x] HomeViewModel compiles with Room-first strategy
- [ ] Download IN pack and verify 669 incidents inserted
- [ ] Query incidents by state returns correct data
- [ ] UI displays incidents from Room
- [ ] Fallback to Firestore works for states without HF data
- [ ] Add DAO instrumentation test (optional)

## Dependencies

- Room version: 2.6.x (check `build.gradle.kts`)
- Gson: Already in use for offline packs
- HF dataset URL: `https://huggingface.co/datasets/raayraay/blueledger-data/resolve/main/states/{STATE}_v1.json`

## Notes

- All fields in DTOs MUST be nullable with defaults (Gson sets non-nullable to null)
- Use `OnConflictStrategy.REPLACE` to handle re-downloads
- Consider adding a `lastUpdated` timestamp to track freshness
