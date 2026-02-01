# iOS Offline Data Debugging

## Data Flow
1. User selects state in LocationPicker or via Profile.
2. `HomeFeedObservable.selectState` updates `activeState` in UserDefaults.
3. `loadFeedAsync` triggers `ensureOfflinePack` -> `downloadPackForStateIfNeeded(stateCode)`.
4. `OfflinePackManager` checks for existing pack & deduplicates logic prevents multiple downloads.
5. `OfflinePackStatusBanner` (if downloading) appears in `HomeFeedView` via `offlineStatus` observation.
6. `HomeFeedObservable` reloads feed from newly installed pack upon success.

## Log Prefixes
- 📦 `[OfflinePackManager]` - Download/Install status
- ⏳ `[OfflinePackManager]` - Deduplication/Locking
- 📱 `[HomeFeedObservable]` - Feed loading & source (Firebase vs Offline)
- ⚠️ `[HomeFeedObservable]` - Errors/Warnings
- 📡 `[HomeFeedObservable]` - Polling/Live Updates

## Verification
- **Console**: Check for "✅ [OfflinePackManager] Installed [STATE] pack"
- **UI**: Verify "Downloading..." banner appears on state change.
- **Data**: Verify incident count > 0 for states with data (e.g., IN, CA).
