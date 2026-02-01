# iOS Offline Parity Test Checklist

## 1. Auto-Download
- [ ] Fresh install (delete app from Simulator/Device)
- [ ] Launch app (Default: Indiana)
- [ ] Verify banner: "Downloading data..." immediately appears
- [ ] Verify success: Banner disappears, feed populates with >0 incidents
- [ ] Verify console log: "✅ Installed IN pack"

## 2. State Switching
- [ ] Tap Location Header -> Select "California"
- [ ] Verify banner "Downloading..." appears immediately
- [ ] Verify feed refreshes with CA data (Incidents > 0)
- [ ] Tap Location Header -> Select "Indiana" (Already installed)
- [ ] Verify NO download banner (instant switch)
- [ ] Verify feed refreshes with IN data

## 3. Offline Mode
- [ ] Enable Airplane Mode
- [ ] Kill and Relaunch App within an installed state
- [ ] Verify feed loads from cache
- [ ] Verify no "0 incidents" empty state if data exists

## 4. Error Handling
- [ ] Enable Airplane Mode
- [ ] Select new uninstalled state (e.g., "Texas")
- [ ] Verify error banner "Unable to download..." on "Retry"
- [ ] Enable Internet -> Tap "Retry" on banner
- [ ] Verify download starts and succeeds
