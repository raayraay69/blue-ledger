# BlueLedger Feature Integration Guide

Last Updated: January 2026

## Overview

This document describes the new features implemented for BlueLedger Android app:

1. **Trust & Safety** - Community guidelines, flag/dispute system, verification badges
2. **Evidence Pipeline** - Unified evidence tracking with Room + Firebase
3. **ICE-specific UX** - Opt-in immigration enforcement monitoring
4. **Timeline & Analytics** - Officer/department timelines, enforcement dashboards
5. **Privacy & Legal Ops** - Metadata scrubbing, retention policies
6. **Polished Additions** - Evidence capsules, corroboration, witness mode, accountability

---

## File Locations

### Trust & Safety
| File | Purpose |
|------|---------|
| `data/model/CommunityGuidelines.kt` | Guidelines data model |
| `data/model/ReportFlag.kt` | Flag reasons, status, data class |
| `data/model/Dispute.kt` | Dispute model for challenging flags |
| `data/model/VerificationTag.kt` | Verification sources and badges |
| `data/repository/ModerationRepository.kt` | Flag/dispute operations |

### Evidence Pipeline
| File | Purpose |
|------|---------|
| `data/local/entity/Evidence.kt` | Room entity for evidence |
| `data/local/dao/EvidenceDao.kt` | Room DAO for evidence |
| `data/repository/EvidenceRepository.kt` | Unified evidence repository |

### ICE-specific UX
| File | Purpose |
|------|---------|
| `data/model/IceAlert.kt` | ICE alert model |
| `data/model/KnowYourRights.kt` | Rights info data |
| `data/preferences/IceAlertPreferences.kt` | Opt-in settings |

### Timeline & Analytics
| File | Purpose |
|------|---------|
| `data/model/Timeline.kt` | Timeline events model |
| `data/model/AnalyticsDashboard.kt` | Analytics data models |

### Privacy & Legal Ops
| File | Purpose |
|------|---------|
| `privacy/MetadataScrubber.kt` | EXIF/metadata removal |
| `privacy/RetentionPolicy.kt` | Retention policy models |
| `data/preferences/PrivacyPreferences.kt` | Privacy settings |

### Polished Additions
| File | Purpose |
|------|---------|
| `data/model/EvidenceCapsule.kt` | Evidence snippets |
| `data/model/AlertCorroboration.kt` | Corroboration tracking |
| `data/model/AccountabilityOutcome.kt` | Follow-up outcomes |

---

## Database Schema Changes

### New Entities

Add to `BlueLedgerDatabase.kt`:

```kotlin
@Database(
    entities = [
        Department::class,
        Officer::class,
        Incident::class,
        OfficerIncidentCrossRef::class,
        CommunityExperience::class,
        PoliceSighting::class,
        PendingUpload::class,
        Evidence::class  // NEW
    ],
    version = 6,  // INCREMENT
    exportSchema = true
)
```

### Type Converters

Add to `Converters.kt`:

```kotlin
@TypeConverter
fun fromMediaType(type: MediaType): String = type.name

@TypeConverter
fun toMediaType(value: String): MediaType = MediaType.valueOf(value)

@TypeConverter
fun fromUploadStatus(status: UploadStatus): String = status.name

@TypeConverter
fun toUploadStatus(value: String): UploadStatus = UploadStatus.valueOf(value)
```

### Migration

Add migration from v5 to v6:

```kotlin
val MIGRATION_5_6 = object : Migration(5, 6) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS evidence (
                id TEXT NOT NULL PRIMARY KEY,
                reportId TEXT NOT NULL,
                reportType TEXT NOT NULL,
                mediaType TEXT NOT NULL,
                localUri TEXT,
                remoteUrl TEXT,
                thumbnailUrl TEXT,
                uploadStatus TEXT NOT NULL DEFAULT 'PENDING',
                uploadProgress REAL NOT NULL DEFAULT 0,
                uploadAttempts INTEGER NOT NULL DEFAULT 0,
                lastUploadError TEXT,
                fileSizeBytes INTEGER NOT NULL,
                durationSeconds INTEGER,
                width INTEGER,
                height INTEGER,
                mimeType TEXT,
                transcriptText TEXT,
                transcriptConfidence REAL,
                metadataStripped INTEGER NOT NULL DEFAULT 0,
                encryptedLocally INTEGER NOT NULL DEFAULT 0,
                sourceDevice TEXT NOT NULL,
                capturedAt INTEGER NOT NULL,
                uploadedAt INTEGER,
                expiresAt INTEGER,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL
            )
        """)
        database.execSQL("CREATE INDEX IF NOT EXISTS index_evidence_reportId ON evidence(reportId)")
        database.execSQL("CREATE INDEX IF NOT EXISTS index_evidence_uploadStatus ON evidence(uploadStatus)")
    }
}
```

---

## Dependency Injection

### Using Manual DI (Current Pattern)

Add to `BlueLedgerApplication.kt`:

```kotlin
companion object {
    // Existing...

    lateinit var evidenceDao: EvidenceDao
    lateinit var metadataScrubber: MetadataScrubber
    lateinit var privacyPreferences: PrivacyPreferences
    lateinit var iceAlertPreferences: IceAlertPreferences
    lateinit var evidenceRepository: EvidenceRepository
    lateinit var moderationRepository: ModerationRepository
}

override fun onCreate() {
    super.onCreate()

    // Existing initialization...

    // New features
    evidenceDao = database.evidenceDao()
    metadataScrubber = MetadataScrubber(this)
    privacyPreferences = PrivacyPreferences(this)
    iceAlertPreferences = IceAlertPreferences(this)
    evidenceRepository = EvidenceRepository(
        this, evidenceDao, firebaseEvidenceRepository,
        metadataScrubber, privacyPreferences
    )
    moderationRepository = ModerationRepository()
}
```

### Using Hilt (If Migrating)

Create `NewFeaturesModule.kt`:

```kotlin
@Module
@InstallIn(SingletonComponent::class)
object NewFeaturesModule {

    @Provides
    @Singleton
    fun provideEvidenceDao(database: BlueLedgerDatabase): EvidenceDao {
        return database.evidenceDao()
    }

    @Provides
    @Singleton
    fun provideMetadataScrubber(@ApplicationContext context: Context): MetadataScrubber {
        return MetadataScrubber(context)
    }

    @Provides
    @Singleton
    fun providePrivacyPreferences(@ApplicationContext context: Context): PrivacyPreferences {
        return PrivacyPreferences(context)
    }

    @Provides
    @Singleton
    fun provideIceAlertPreferences(@ApplicationContext context: Context): IceAlertPreferences {
        return IceAlertPreferences(context)
    }

    @Provides
    @Singleton
    fun provideModerationRepository(): ModerationRepository {
        return ModerationRepository()
    }
}
```

---

## Navigation Routes

Add to `BlueLedgerNavHost.kt`:

```kotlin
// Privacy Settings
composable("privacy_settings") {
    PrivacySettingsScreen(
        onNavigateBack = { navController.popBackStack() }
    )
}

// ICE Alert Settings
composable("ice_alert_settings") {
    IceAlertSettingsScreen(
        onNavigateBack = { navController.popBackStack() }
    )
}

// Community Guidelines
composable("community_guidelines") {
    CommunityGuidelinesScreen(
        onBackClick = { navController.popBackStack() }
    )
}

// Officer Timeline
composable(
    route = "officer_timeline/{officerId}",
    arguments = listOf(navArgument("officerId") { type = NavType.LongType })
) { backStackEntry ->
    val officerId = backStackEntry.arguments?.getLong("officerId") ?: 0L
    OfficerTimelineScreen(
        officerId = officerId,
        onBackClick = { navController.popBackStack() }
    )
}

// Analytics Dashboard
composable("analytics_dashboard") {
    AnalyticsDashboardScreen()
}

// Witness Mode
composable("witness_mode") {
    WitnessModeScreen(
        onBackClick = { navController.popBackStack() }
    )
}
```

---

## Cross-Feature Dependencies

### Evidence → Privacy
- `EvidenceRepository` uses `MetadataScrubber` for automatic EXIF removal
- `EvidenceRepository` uses `PrivacyPreferences` for retention settings

### ICE Alerts → Corroboration
- ICE alerts use `AlertCorroboration` to require ≥2 reports before display
- Reduces harassment risk by requiring community verification

### Timeline → Accountability
- `TimelineEvent` can be followed up with `AccountabilityOutcome`
- Enables tracking of lawsuit outcomes, settlements, etc.

### Trust & Safety → All Reports
- `VerificationTag` applies to incidents, experiences, and sightings
- `ReportFlag` can flag any report type

---

## Testing Checklist

- [ ] Build project successfully
- [ ] Evidence entity migrations work
- [ ] Metadata scrubbing removes GPS data
- [ ] Privacy preferences persist
- [ ] ICE alert preferences default to opt-out
- [ ] Moderation repository flag/dispute flow works
- [ ] Navigation routes load correctly

---

## Security Considerations

1. **Anonymous Reporting**: Device hashes instead of user IDs
2. **Metadata Stripping**: GPS/device info removed before upload
3. **ICE Alerts Opt-In**: All immigration monitoring is opt-in only
4. **Corroboration Threshold**: Alerts require ≥2 reports to display
5. **Auto-Expiration**: Evidence auto-deletes based on retention policy
6. **Local Encryption**: Support for encrypting local evidence files

---

---

## Glass UI Design System (January 2026)

### Overview
The app uses a consistent "Liquid Glass" design language across all screens. Glass components provide transparency with blur effects using the Haze library.

### Core Components

| Component | File | Purpose |
|-----------|------|---------|
| `GlassScaffold` | `ui/components/glass/GlassScaffold.kt` | Root scaffold with blur source |
| `GlassContainer` | `ui/glass/GlassContainer.kt` | Blurred card with border |
| `GlassMeshBackground` | `ui/components/GlassMeshBackground.kt` | Animated mesh gradient background |
| `GlassHeader` | `ui/components/GlassHeader.kt` | Blurred top app bar |
| `LiquidGlassBottomBar` | `ui/components/glass/LiquidGlassBottomBar.kt` | Floating navigation bar |

### Updated Screens (Jan 2026)
- **OfficerDetailScreen** - Full glass treatment with GlassContainer for profile, stats, risk banners
- **SearchScreen** - Already uses GlassScaffold and glass cards
- **QuickLookupScreen** - Uses GlassScaffold with GlassContainer
- **HomeScreen** - Uses GlassScaffold with glass stats bars

### Usage Pattern

```kotlin
val hazeState = remember { HazeState() }

GlassScaffold(
    hazeState = hazeState,
    topBar = { GlassHeader(title = "SCREEN", hazeState = hazeState) }
) { padding ->
    Box(Modifier.fillMaxSize().padding(padding)) {
        GlassMeshBackground()

        LazyColumn {
            item {
                GlassContainer(
                    hazeState = hazeState,
                    shape = RoundedCornerShape(20.dp),
                    tint = Color.White.copy(alpha = 0.03f),
                    borderColor = Color.White.copy(alpha = 0.15f)
                ) {
                    // Content here
                }
            }
        }
    }
}
```

### Card Components with Glass Support

All card components accept `glassmorphismEnabled: Boolean` and `hazeState: HazeState?`:
- `OfficerCardCompact`
- `IncidentCardCompact`
- `DepartmentCardCompact`

---

## City Complaint Portal (January 2026)

### Overview
The Complaint Portal feature enables users to file formal complaints against police officers and departments through official city channels. Supports multiple submission methods: email, web portal, phone, and physical mail.

### Architecture
```
User → ComplaintWizardScreen → ComplaintViewModel → ComplaintRepository → Room
                                    ↓                      ↓
                            ComplaintEmailService    ComplaintSubmission
                            ComplaintPortalService   (persisted for history)
                            ComplaintPdfGenerator
```

### File Locations

| File | Purpose |
|------|---------|
| `data/local/entity/ComplaintSubmission.kt` | Room entity for complaint submissions |
| `data/local/dao/ComplaintSubmissionDao.kt` | Room DAO for complaint operations |
| `data/repository/ComplaintRepository.kt` | Repository for complaint persistence |
| `service/ComplaintEmailService.kt` | Email generation and sharesheet launch |
| `service/ComplaintPortalService.kt` | Portal opening and clipboard copy |
| `service/ComplaintPdfGenerator.kt` | PDF generation for formal complaints |
| `ui/complaint/ComplaintWizardScreen.kt` | 4-step complaint wizard UI |
| `ui/complaint/ComplaintViewModel.kt` | ViewModel orchestrating submission |

### Database Schema

**ComplaintSubmission Table** (added in MIGRATION_6_7):
```sql
CREATE TABLE complaint_submissions (
    id TEXT NOT NULL PRIMARY KEY,
    departmentId INTEGER,
    departmentName TEXT NOT NULL,
    officerId INTEGER,
    officerName TEXT,
    officerBadgeNumber TEXT,
    incidentDate TEXT NOT NULL,
    incidentLocation TEXT NOT NULL,
    incidentDescription TEXT NOT NULL,
    complaintType TEXT NOT NULL,
    desiredOutcome TEXT,
    witnessInfo TEXT,
    isAnonymous INTEGER NOT NULL DEFAULT 0,
    submitterName TEXT,
    submitterEmail TEXT,
    submitterPhone TEXT,
    submissionMethod TEXT NOT NULL,
    submissionStatus TEXT NOT NULL,
    submittedAt INTEGER NOT NULL,
    lastUpdatedAt INTEGER NOT NULL,
    trackingNumber TEXT,
    responseReceived TEXT,
    attachedEvidenceIds TEXT
)
```

**Department Table Additions** (added in MIGRATION_6_7):
- `complaintEmail TEXT` - Department complaint email address
- `complaintPortalUrl TEXT` - Web portal URL for filing complaints
- `complaintPhone TEXT` - Phone number for complaints
- `complaintAddress TEXT` - Physical mailing address
- `complaintFormUrl TEXT` - Downloadable complaint form URL
- `internalAffairsEmail TEXT` - Internal Affairs email
- `civilianOversightBoard TEXT` - Oversight board contact info
- `acceptsAnonymous INTEGER DEFAULT 1` - Whether anonymous complaints accepted

### Navigation Routes

Add to `Screen.kt`:
```kotlin
data object ComplaintWizard : Screen(
    route = "complaint?departmentId={departmentId}&officerId={officerId}&officerName={officerName}&officerBadge={officerBadge}&incidentId={incidentId}",
    title = "File Complaint"
) {
    fun createRoute(
        departmentId: Long? = null,
        officerId: Long? = null,
        officerName: String? = null,
        officerBadgeNumber: String? = null,
        incidentId: Long? = null
    ): String { ... }
}

data object ComplaintHistory : Screen(
    route = "complaint_history",
    title = "My Complaints"
)
```

### Submission Methods

| Method | Service | Flow |
|--------|---------|------|
| **Email** | `ComplaintEmailService` | Generate body → Launch sharesheet → User sends via email client |
| **Portal** | `ComplaintPortalService` | Copy to clipboard → Open Chrome Custom Tabs → User pastes |
| **Phone** | N/A | Display phone number with click-to-call |
| **Mail** | `ComplaintPdfGenerator` | Generate PDF → Share via sharesheet |

### Wizard Steps

1. **Channel Selection** - User picks submission method based on department's available channels
2. **Incident Details** - Date, location, description, complaint type, desired outcome
3. **Evidence Attachment** - Attach photos/videos (optional), uses MetadataScrubber for privacy
4. **Review & Submit** - Preview, toggle anonymous, submit via selected channel

### OfflinePackManager Integration

`DepartmentDto` now includes complaint channel fields:
- `complaintEmail` / `complaint_email`
- `complaintPortalUrl` / `complaint_portal_url`
- `complaintPhone` / `complaint_phone`
- `complaintAddress` / `complaint_address`
- `complaintFormUrl` / `complaint_form_url`
- `internalAffairsEmail` / `internal_affairs_email`
- `civilianOversightBoard` / `civilian_oversight_board`
- `acceptsAnonymous` / `accepts_anonymous`

Both camelCase and snake_case are supported for cross-platform compatibility.

### Entry Points

Users can launch the complaint wizard from:
1. **Officer Detail Screen** → "File Complaint" button (pre-fills officer info)
2. **Department Detail Screen** → "File Complaint" button (pre-fills department)
3. **Incident Detail Screen** → "File Complaint" button (pre-fills incident context)
4. **Profile Screen** → "My Complaints" to view submission history

### Privacy Considerations

1. **Anonymous Submissions** - User can toggle anonymity; name/email omitted from submission
2. **Metadata Scrubbing** - Evidence goes through `MetadataScrubber` to remove GPS/device info
3. **Local Storage** - Complaint drafts and history stored locally in Room, not sent to server
4. **No Tracking** - BlueLedger does not track or store complaint contents on any server

### Testing Checklist

- [ ] Wizard navigates through all 4 steps
- [ ] Channel selection shows only available channels for department
- [ ] Email sharesheet opens with pre-filled subject and body
- [ ] Portal opens in Chrome Custom Tabs with clipboard toast
- [ ] PDF generates with correct layout
- [ ] Complaint history shows submitted complaints
- [ ] Anonymous toggle omits personal info
- [ ] Evidence attachments display correctly

---

## Known Issues

### Officer Complaint Count Mismatch (Jan 2026) - ✅ FIXED

**Symptom**: Officer cards show complaint count (e.g., "5 complaints"), but detail screen shows different value.

**Root Cause**: Data source inconsistency
- Search results use `data.model.Officer` from offline packs (Hugging Face)
- Detail screen was using `data.local.entity.Officer` from Room database
- When clicking an officer, the String ID was converted to Long for Room lookup
- If officer doesn't exist in Room or ID conversion fails, wrong data was shown

**Fix Applied (January 20, 2026)**:
1. Updated navigation to use `createRouteWithDocId(officer.id)` instead of converting to Long
2. Updated `OfficerDetailViewModel` to support document ID lookups via `loadOfficerFromFirebase()`
3. Navigation route now uses `NavType.StringType` to support both Long IDs and "doc_xxx" format
4. Factory updated to accept `FirebaseRepository` for remote lookups
5. `OfficerDetailUiState` now includes `departmentName` field for Firebase officers

**Files Modified**:
- `ui/detail/OfficerDetailViewModel.kt` - Added document ID support
- `ui/navigation/BlueLedgerNavHost.kt` - Updated navigation and route handling
- `ui/navigation/Screen.kt` - Already had `createRouteWithDocId()` method

---

## Data Architecture (Jan 2026)

### Offline Pack System (Primary)
- Pre-packaged JSON data hosted on **Hugging Face**
- Downloaded per city/state via `OfflinePackManager`
- Parsed and stored in Room database
- Works offline after initial download
- iOS Home feed now mirrors Android: packs download automatically when a state is selected, progress is surfaced inline, and the feed waits for data before rendering.
- Home/Search share the same pack-backed data via `StateCodeMapper` + `OfflinePackManager`.

### Data Flow
```
Hugging Face → OfflinePackManager → Room Database → UI
```

### Key Files
| File | Purpose |
|------|---------|
| `OfflinePackManager.kt` | Downloads, decompresses, parses, inserts |
| `SearchViewModel.kt` | Loads data from Room |
| `DepartmentRepository.kt` | Room queries |
| `iosApp/iosApp/ViewModels/HomeFeedObservable.swift` | Auto-downloads state packs, feeds Home tab |
| `iosApp/iosApp/Screens/HomeFeedView.swift` | Displays state/pack status & filter chips |
| `iosApp/iosApp/Services/OfflinePackManager.swift` | Shared download manager (Android parity) |

---

## Future Enhancements

1. **FFmpeg Integration**: Full video metadata removal
2. **Audio Transcription**: Whisper/Speech-to-Text integration
3. **Unified Data Layer**: Single data source for search and detail screens
4. **Push Notifications**: Alert users to nearby ICE activity
5. **Partner API**: Integration with ACLU/legal aid organizations
