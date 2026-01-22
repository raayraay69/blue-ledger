# Google Cloud City Data - Files Checklist

This document lists all files created for the Google Cloud city data download feature.

## Documentation

- [x] `docs/GCLOUD_CITY_DATA_SETUP.md` - Comprehensive 400+ line setup guide
- [x] `docs/GCLOUD_QUICKSTART.md` - Quick start guide (30 min setup)
- [x] `docs/GCLOUD_FILES_CHECKLIST.md` - This checklist

## Setup Scripts

- [x] `scripts/setup_gcloud_city_data.sh` - One-shot automated setup script
  - Creates service account
  - Sets up Cloud Storage bucket
  - Configures permissions
  - Tests connections

## Local Development Scripts

- [x] `scripts/generate_city_package_local.py` - Generate packages locally
  - Test before deploying Cloud Functions
  - Generate all cities or specific city
  - Save locally or upload to Cloud Storage

## Cloud Functions

- [x] `functions/city_data_exporter.py` - Main Cloud Function
  - `daily_city_package_generation` - Scheduled (7 AM ET daily)
  - `manual_city_package_trigger` - HTTP endpoint for manual triggers
  - `get_city_package_url` - API to get package URLs

## Configuration Files (Needed)

These need to be added to the functions directory:

- [ ] `functions/requirements.txt` - Update with new dependencies:
  ```
  firebase-functions>=0.4.0
  firebase-admin>=6.0.0
  google-cloud-storage>=2.10.0
  requests>=2.28.0
  ```

- [ ] `firebase.json` - Update with new functions:
  ```json
  {
    "functions": [
      {
        "source": "functions",
        "codebase": "default",
        "runtime": "python312",
        "ignore": ["venv", ".git", "*.local"]
      }
    ]
  }
  ```

## Mobile App Integration (Reference Code)

The documentation includes complete implementation examples:

### Android (Kotlin)
- `CityDataDownloader.kt` - Download and cache city packages
- `CityPackage.kt` - Data models
- Integration with existing `FirebaseRepository.kt`

### iOS (Swift)
- `CityDataDownloader.swift` - Download and cache city packages
- `CityPackage.swift` - Data models
- Integration with existing `FirebaseService.swift`

(See docs/GCLOUD_CITY_DATA_SETUP.md for full code)

## Generated Files (After Running Setup)

After running `./scripts/setup_gcloud_city_data.sh`:

- [x] `scripts/cityDataServiceAccountKey.json` - Service account credentials (gitignored)
- [x] Cloud Storage bucket: `gs://blueledger-city-data`
- [x] Service account: `blueledger-city-data@blueledger-3af1a.iam.gserviceaccount.com`

After running `python3 scripts/generate_city_package_local.py --all`:

- [x] `scripts/data/city_packages/*/cities/*.json.gz` - City data packages
- [x] `scripts/data/city_packages/manifest.json` - Package manifest

## Cloud Resources Created

- [x] Service Account: `blueledger-city-data`
- [x] Storage Bucket: `gs://blueledger-city-data`
- [x] Cloud Functions:
  - `daily_city_package_generation`
  - `manual_city_package_trigger`
  - `get_city_package_url`
- [x] Cloud Scheduler Job: `daily_city_package_generation` (7 AM ET daily)

## Next Steps

1. Run setup script: `./scripts/setup_gcloud_city_data.sh`
2. Update `functions/requirements.txt` with dependencies above
3. Deploy functions: `firebase deploy --only functions`
4. Generate initial packages: `python3 scripts/generate_city_package_local.py --all`
5. Test API: `curl "https://us-central1-blueledger-3af1a.cloudfunctions.net/get_city_package_url?state=IN&city=Indianapolis"`
6. Integrate mobile apps using reference code from documentation

---

**Status:** Ready for deployment
**Estimated Setup Time:** 30 minutes
**Monthly Cost:** ~$2.25
