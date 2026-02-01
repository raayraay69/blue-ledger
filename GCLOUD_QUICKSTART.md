# Google Cloud City Data - Quick Start Guide

**Time to complete:** ~30 minutes
**Cost:** ~$2.25/month

---

## Prerequisites

```bash
# 1. Install gcloud CLI
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# 2. Login to Google Cloud
gcloud auth login

# 3. Verify project access
gcloud config set project blueledger-3af1a
gcloud projects describe blueledger-3af1a
```

---

## One-Shot Setup

```bash
cd /home/user/BlueLedgerr

# Run the automated setup script
./scripts/setup_gcloud_city_data.sh
```

**This script will:**
1. ✅ Enable required Google Cloud APIs
2. ✅ Create service account with proper permissions
3. ✅ Generate service account key → `scripts/cityDataServiceAccountKey.json`
4. ✅ Create Cloud Storage bucket `gs://blueledger-city-data`
5. ✅ Configure bucket (versioning, lifecycle, CORS, public access)
6. ✅ Test Firestore and Storage connections

---

## Deploy Cloud Functions

```bash
cd functions

# Deploy the city data exporter function
firebase deploy --only functions:city_data_exporter

# This deploys:
# - daily_city_package_generation (scheduled, 7 AM ET daily)
# - manual_city_package_trigger (HTTP endpoint)
# - get_city_package_url (HTTP API)
```

---

## Generate Initial Data Packages

### Option 1: Generate All Cities

```bash
python3 scripts/generate_city_package_local.py --all
```

### Option 2: Generate Specific City

```bash
python3 scripts/generate_city_package_local.py --state IN --city Indianapolis
```

### Option 3: Trigger Cloud Function Manually

```bash
curl -X POST \
  "https://us-central1-blueledger-3af1a.cloudfunctions.net/manual_city_package_trigger?state=IN&city=Indianapolis"
```

---

## Verify Setup

```bash
# 1. Check bucket contents
gsutil ls -r gs://blueledger-city-data/states/IN/cities/

# 2. Download a package
curl -o /tmp/test.json.gz \
  https://storage.googleapis.com/blueledger-city-data/states/IN/cities/Indianapolis.json.gz

# 3. Decompress and inspect
gunzip /tmp/test.json.gz
cat /tmp/test.json | jq '.metadata'

# 4. Test API endpoint
curl "https://us-central1-blueledger-3af1a.cloudfunctions.net/get_city_package_url?state=IN&city=Indianapolis" | jq
```

---

## Directory Structure Created

```
gs://blueledger-city-data/
├── states/
│   ├── IN/
│   │   ├── cities/
│   │   │   └── Indianapolis.json.gz
│   │   └── state_summary.json
│   ├── NY/
│   └── ... (50 states + DC)
│
├── national/
│   └── top_officers_watchlist.json.gz
│
└── manifests/
    └── full_manifest.json
```

---

## Mobile App Integration

### Android (Kotlin)

```kotlin
// 1. Add dependency to app/build.gradle.kts
dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}

// 2. Use CityDataDownloader (from docs/GCLOUD_CITY_DATA_SETUP.md)
val downloader = CityDataDownloader(context, httpClient)
val cityData = downloader.getCityData("IN", "Indianapolis")

// cityData is cached locally for 24 hours
```

### iOS (Swift)

```swift
// Use CityDataDownloader (from docs/GCLOUD_CITY_DATA_SETUP.md)
let downloader = CityDataDownloader()
let cityData = try await downloader.getCityData(state: "IN", city: "Indianapolis")

// cityData is cached locally for 24 hours
```

---

## Daily Automated Refresh

The Cloud Function `daily_city_package_generation` runs automatically every day at 7 AM ET (after the main Firestore ETL at 6 AM).

**To check the schedule:**

```bash
gcloud scheduler jobs list
gcloud scheduler jobs describe daily_city_package_generation
```

**To manually trigger:**

```bash
gcloud scheduler jobs run daily_city_package_generation
```

---

## Cost Breakdown

| Service | Monthly Cost |
|---------|--------------|
| Cloud Storage (5 GB) | $0.13 |
| Cloud Storage Egress (10 GB) | $1.20 |
| Cloud Functions (40 invocations) | $0.02 |
| Cloud Scheduler (1 job) | $0.10 |
| Cloud CDN (optional) | $0.80 |
| **Total** | **$2.25/month** |

**Cost Savings vs Direct Firestore:**
- Current approach: 1M reads/month = $3.60
- City packages: ~$2.25/month total
- **Savings: $1.35/month** (38% reduction)

---

## Troubleshooting

### Service Account Key Not Found

```bash
# Regenerate key
gcloud iam service-accounts keys create scripts/cityDataServiceAccountKey.json \
  --iam-account=blueledger-city-data@blueledger-3af1a.iam.gserviceaccount.com
```

### Bucket Already Exists (Different Project)

```bash
# Use a different bucket name
export BUCKET_NAME="blueledger-city-data-$(date +%s)"
gsutil mb -p blueledger-3af1a gs://$BUCKET_NAME
```

### Permission Denied on Firestore

```bash
# Re-grant permissions
gcloud projects add-iam-policy-binding blueledger-3af1a \
  --member="serviceAccount:blueledger-city-data@blueledger-3af1a.iam.gserviceaccount.com" \
  --role="roles/datastore.viewer"
```

### Cloud Function Deployment Fails

```bash
# Check logs
gcloud functions logs read daily_city_package_generation --limit=50

# Redeploy with verbose output
firebase deploy --only functions --debug
```

---

## Access URLs

| Resource | URL |
|----------|-----|
| **City Package (Indianapolis)** | https://storage.googleapis.com/blueledger-city-data/states/IN/cities/Indianapolis.json.gz |
| **State Summary (Indiana)** | https://storage.googleapis.com/blueledger-city-data/states/IN/state_summary.json |
| **National Watchlist** | https://storage.googleapis.com/blueledger-city-data/national/top_officers_watchlist.json.gz |
| **Manifest** | https://storage.googleapis.com/blueledger-city-data/manifests/full_manifest.json |
| **API Endpoint** | https://us-central1-blueledger-3af1a.cloudfunctions.net/get_city_package_url |
| **Manual Trigger** | https://us-central1-blueledger-3af1a.cloudfunctions.net/manual_city_package_trigger |

---

## Monitoring

```bash
# View function logs
gcloud functions logs read daily_city_package_generation --limit=100

# Check bucket size
gsutil du -sh gs://blueledger-city-data

# List recent packages
gsutil ls -l gs://blueledger-city-data/states/*/cities/ | head -20

# Check costs
gcloud billing accounts list
gcloud alpha billing budgets list
```

---

## Next Steps

1. ✅ **Setup Complete** → Run `./scripts/setup_gcloud_city_data.sh`
2. ✅ **Deploy Functions** → `firebase deploy --only functions`
3. ✅ **Generate Packages** → `python3 scripts/generate_city_package_local.py --all`
4. ⏳ **Integrate Mobile Apps** → Use CityDataDownloader classes
5. ⏳ **Monitor Costs** → Check Google Cloud Console after 7 days

---

## Support

For detailed documentation, see:
- **Full Setup Guide:** `docs/GCLOUD_CITY_DATA_SETUP.md` (comprehensive 400+ line guide)
- **Database Schema:** `docs/DATABASE_SCHEMA.md`
- **Project Reference:** `CLAUDE.md`

For issues:
- Check Cloud Function logs: `gcloud functions logs read <function_name>`
- Check bucket access: `gsutil ls gs://blueledger-city-data`
- Verify service account: `gcloud iam service-accounts describe blueledger-city-data@blueledger-3af1a.iam.gserviceaccount.com`

---

**Last Updated:** January 13, 2026
**Estimated Time to Production:** 30 minutes
