# Google Cloud City Data Download Setup Guide

**Last Updated:** January 13, 2026
**Purpose:** Enable users to download city-specific data packages instead of calling Firebase API repeatedly

---

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Google Cloud Services Required](#google-cloud-services-required)
3. [Service Account Setup](#service-account-setup)
4. [Cloud Storage Structure](#cloud-storage-structure)
5. [Cloud Functions Configuration](#cloud-functions-configuration)
6. [API Gateway Setup](#api-gateway-setup)
7. [City-Level Data Schema](#city-level-data-schema)
8. [Caching Strategy](#caching-strategy)
9. [Local Development Setup](#local-development-setup)
10. [One-Shot Configuration](#one-shot-configuration)

---

## Architecture Overview

### Current Architecture (Firebase API)
```
Mobile App → Firebase API → Firestore Database
  └─ Every query hits Firestore
  └─ High read costs for frequent queries
  └─ Requires active internet connection
```

### Proposed Architecture (City Data Downloads)
```
Mobile App → Cloud Storage → Pre-generated City Data Packages (JSON/Parquet)
  ├─ One-time download per city
  ├─ Offline-first capability
  ├─ Reduced Firebase read costs
  └─ Cloud Function regenerates packages daily
```

### Data Flow
```
Daily ETL Pipeline (6 AM ET)
  ↓
Firestore Database (source of truth)
  ↓
Cloud Function: generate-city-packages
  ↓
Cloud Storage Buckets (by state/city)
  ↓
API Gateway (public CDN endpoint)
  ↓
Mobile Apps (download + cache locally)
```

---

## Google Cloud Services Required

### 1. **Cloud Storage** (gs://blueledger-city-data)
- **Purpose:** Store pre-generated city data packages
- **Cost:** ~$0.026/GB/month (Standard Storage)
- **Estimated Size:** 50 states × 50 cities × 2MB = ~5GB
- **Monthly Cost:** ~$0.13

### 2. **Cloud Functions (2nd Gen)**
- **Purpose:** Generate city data packages from Firestore
- **Runtime:** Python 3.12
- **Triggers:**
  - Scheduled (daily at 7 AM ET)
  - HTTP (manual trigger for specific cities)
- **Cost:** $0.40 per million invocations
- **Estimated Cost:** ~$0.02/month (30 scheduled + manual triggers)

### 3. **Cloud Scheduler**
- **Purpose:** Trigger daily data package generation
- **Cost:** $0.10 per job/month
- **Jobs:** 1 job (daily city package generation)
- **Monthly Cost:** $0.10

### 4. **Cloud CDN** (optional but recommended)
- **Purpose:** Cache city packages at edge locations globally
- **Cost:** $0.08 per GB served (first 10TB)
- **Estimated Cost:** ~$0.50/month (assuming 500 downloads/month)

### 5. **Firestore** (existing)
- **Current:** Already in use
- **No additional cost** for exports (read operations only)

### **Total Estimated Monthly Cost:** ~$0.75 - $1.00

---

## Service Account Setup

### Step 1: Create Service Account

```bash
# Set project ID
export PROJECT_ID="blueledger-3af1a"
gcloud config set project $PROJECT_ID

# Create service account for city data exports
gcloud iam service-accounts create blueledger-city-data \
  --display-name="BlueLedger City Data Exporter" \
  --description="Service account for exporting city data packages"

# Get service account email
export SA_EMAIL="blueledger-city-data@${PROJECT_ID}.iam.gserviceaccount.com"
```

### Step 2: Grant Required Permissions

```bash
# 1. Firestore read access (to query data)
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/datastore.viewer"

# 2. Cloud Storage write access (to upload packages)
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# 3. Cloud Functions invoker (for manual triggers)
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudfunctions.invoker"

# 4. Cloud Scheduler admin (for cron job management)
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudscheduler.admin"
```

### Step 3: Generate Service Account Key

```bash
# Generate JSON key file
gcloud iam service-accounts keys create \
  ~/blueledger-city-data-sa-key.json \
  --iam-account=$SA_EMAIL

# Move to project scripts directory
mv ~/blueledger-city-data-sa-key.json scripts/cityDataServiceAccountKey.json

# IMPORTANT: Add to .gitignore
echo "scripts/cityDataServiceAccountKey.json" >> .gitignore
```

### Step 4: Verify Permissions

```bash
# Test Firestore access
gcloud auth activate-service-account --key-file=scripts/cityDataServiceAccountKey.json

# List Firestore collections (should succeed)
gcloud firestore collections list --project=$PROJECT_ID
```

---

## Cloud Storage Structure

### Bucket Configuration

```bash
# Create main bucket for city data packages
gsutil mb -p $PROJECT_ID -c STANDARD -l us-central1 gs://blueledger-city-data

# Enable versioning (rollback capability)
gsutil versioning set on gs://blueledger-city-data

# Set lifecycle policy (delete old versions after 30 days)
cat > lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {
          "numNewerVersions": 3,
          "age": 30
        }
      }
    ]
  }
}
EOF

gsutil lifecycle set lifecycle.json gs://blueledger-city-data
```

### Directory Structure

```
gs://blueledger-city-data/
├── states/
│   ├── IN/
│   │   ├── state_summary.json          # State-level aggregates
│   │   ├── cities/
│   │   │   ├── Indianapolis.json       # City data package
│   │   │   ├── Fort_Wayne.json
│   │   │   ├── Evansville.json
│   │   │   └── ...
│   │   ├── departments/
│   │   │   ├── Indianapolis_PD.json
│   │   │   ├── IMPD.json
│   │   │   └── ...
│   │   └── metadata.json               # State metadata (last_updated, record_counts)
│   ├── NY/
│   │   ├── state_summary.json
│   │   ├── cities/
│   │   │   ├── New_York.json           # Large city (25MB+)
│   │   │   ├── Buffalo.json
│   │   │   └── ...
│   │   ├── departments/
│   │   │   ├── NYPD.json
│   │   │   └── ...
│   │   └── metadata.json
│   └── ... (all 50 states + DC)
│
├── national/
│   ├── top_officers_watchlist.json     # National top 100 officers
│   ├── federal_agencies.json           # ICE, CBP, FBI, etc.
│   └── metadata.json
│
├── manifests/
│   ├── full_manifest.json              # Complete state/city index
│   ├── last_updated.json               # Global last update timestamp
│   └── data_version.json               # Schema version (v1, v2, etc.)
│
└── compressed/                         # Gzipped versions for bandwidth savings
    ├── states/
    │   ├── IN/
    │   │   └── cities/
    │   │       ├── Indianapolis.json.gz
    │   │       └── ...
    │   └── ...
    └── national/
        └── top_officers_watchlist.json.gz
```

### Public Access Configuration

```bash
# Make bucket publicly readable (CDN-friendly)
gsutil iam ch allUsers:objectViewer gs://blueledger-city-data

# Set CORS policy for web access
cat > cors.json <<EOF
[
  {
    "origin": ["*"],
    "method": ["GET", "HEAD"],
    "responseHeader": ["Content-Type", "Content-Length"],
    "maxAgeSeconds": 3600
  }
]
EOF

gsutil cors set cors.json gs://blueledger-city-data
```

---

## Cloud Functions Configuration

### Function 1: `generate-city-packages` (Python 3.12)

**Purpose:** Generate JSON packages for all cities from Firestore data

**File:** `functions/city_data_exporter/main.py`

```python
"""
Cloud Function: Generate City Data Packages
Queries Firestore and generates JSON packages per city/state.
"""

import json
import gzip
from datetime import datetime
from typing import Dict, List, Any

from firebase_admin import initialize_app, firestore
from google.cloud import storage
from firebase_functions import scheduler_fn, https_fn, options

# Initialize Firebase
initialize_app()

# Cloud Storage client
storage_client = storage.Client()
BUCKET_NAME = "blueledger-city-data"

# State code mappings (2-letter ISO codes)
STATE_CODES = {
    "Indiana": "IN", "New York": "NY", "California": "CA",
    # ... all 50 states + DC
}


@scheduler_fn.on_schedule(
    schedule="0 7 * * *",  # Daily at 7 AM ET (after Firestore ETL at 6 AM)
    timezone=scheduler_fn.Timezone("America/New_York"),
    memory=options.MemoryOption.GB_4,
    timeout_sec=540,
)
def daily_city_package_generation(event: scheduler_fn.ScheduledEvent) -> None:
    """
    Daily scheduled generation of all city data packages.
    Runs AFTER the main Firestore ETL (6 AM) to ensure fresh data.
    """
    print(f"Starting daily city package generation at {datetime.utcnow()}")

    db = firestore.client()
    bucket = storage_client.bucket(BUCKET_NAME)

    # Get all unique state/city combinations from Firestore
    incidents_ref = db.collection("incidents")
    cities = set()

    # Query all distinct state/city pairs
    for doc in incidents_ref.stream():
        data = doc.to_dict()
        state = data.get("state")
        city = data.get("city")
        if state and city:
            cities.add((state, city))

    print(f"Found {len(cities)} unique cities across all states")

    # Generate package for each city
    results = []
    for state, city in sorted(cities):
        try:
            result = generate_city_package(db, bucket, state, city)
            results.append(result)
            print(f"✓ Generated package for {city}, {state}: {result['size_bytes']} bytes")
        except Exception as e:
            print(f"✗ Error generating package for {city}, {state}: {e}")
            results.append({
                "state": state,
                "city": city,
                "status": "error",
                "error": str(e)
            })

    # Generate state summaries
    for state_code in set(s for s, c in cities):
        generate_state_summary(db, bucket, state_code)

    # Generate national watchlist
    generate_national_watchlist(db, bucket)

    # Update manifest
    update_manifest(bucket, results)

    print(f"Daily generation complete: {len(results)} packages")


@https_fn.on_request(
    memory=options.MemoryOption.GB_2,
    timeout_sec=300,
)
def manual_city_package_trigger(req: https_fn.Request) -> https_fn.Response:
    """
    HTTP endpoint to manually regenerate a specific city package.

    Query params:
      - state: 2-letter state code (required)
      - city: City name (required)
      - compress: true/false (default: true)

    Example:
      POST https://us-central1-blueledger-3af1a.cloudfunctions.net/manual_city_package_trigger?state=IN&city=Indianapolis
    """
    if req.method != "POST":
        return https_fn.Response("Method not allowed", status=405)

    state = req.args.get("state")
    city = req.args.get("city")
    compress = req.args.get("compress", "true").lower() == "true"

    if not state or not city:
        return https_fn.Response(
            json.dumps({"error": "Missing required params: state, city"}),
            status=400,
            mimetype="application/json"
        )

    try:
        db = firestore.client()
        bucket = storage_client.bucket(BUCKET_NAME)

        result = generate_city_package(db, bucket, state, city, compress=compress)

        return https_fn.Response(
            json.dumps({"status": "success", "result": result}),
            status=200,
            mimetype="application/json"
        )

    except Exception as e:
        return https_fn.Response(
            json.dumps({"status": "error", "message": str(e)}),
            status=500,
            mimetype="application/json"
        )


def generate_city_package(
    db: firestore.Client,
    bucket: storage.Bucket,
    state: str,
    city: str,
    compress: bool = True
) -> Dict[str, Any]:
    """
    Generate a complete data package for a specific city.

    Returns dict with:
      - state, city, size_bytes, record_counts, upload_path, cdn_url
    """
    # 1. Query all incidents for this city
    incidents_ref = db.collection("incidents")
    incidents_query = incidents_ref.where("state", "==", state).where("city", "==", city)

    incidents = []
    for doc in incidents_query.stream():
        data = doc.to_dict()
        # Remove server-side fields
        data.pop("created_at", None)
        data.pop("updated_at", None)
        incidents.append(data)

    # 2. Query all officers in this city
    officers_ref = db.collection("officers")
    officers_query = officers_ref.where("state", "==", state)

    officers = []
    for doc in officers_query.stream():
        data = doc.to_dict()
        data.pop("created_at", None)
        data.pop("updated_at", None)
        officers.append(data)

    # 3. Query departments
    depts_ref = db.collection("departments")
    depts_query = depts_ref.where("state", "==", state).where("city", "==", city)

    departments = []
    for doc in depts_query.stream():
        data = doc.to_dict()
        data.pop("created_at", None)
        data.pop("updated_at", None)
        departments.append(data)

    # 4. Build city package
    package = {
        "metadata": {
            "state": state,
            "city": city,
            "generated_at": datetime.utcnow().isoformat(),
            "schema_version": "v1",
            "record_counts": {
                "incidents": len(incidents),
                "officers": len(officers),
                "departments": len(departments)
            }
        },
        "incidents": incidents,
        "officers": officers,
        "departments": departments
    }

    # 5. Serialize to JSON
    json_bytes = json.dumps(package, indent=2).encode("utf-8")

    # 6. Optionally compress
    if compress:
        json_bytes = gzip.compress(json_bytes)
        extension = ".json.gz"
    else:
        extension = ".json"

    # 7. Upload to Cloud Storage
    city_slug = city.replace(" ", "_").replace("/", "_")
    blob_path = f"states/{state}/cities/{city_slug}{extension}"

    blob = bucket.blob(blob_path)
    blob.upload_from_string(
        json_bytes,
        content_type="application/json" if not compress else "application/gzip"
    )

    # 8. Return result
    cdn_url = f"https://storage.googleapis.com/{BUCKET_NAME}/{blob_path}"

    return {
        "state": state,
        "city": city,
        "status": "success",
        "size_bytes": len(json_bytes),
        "upload_path": blob_path,
        "cdn_url": cdn_url,
        "record_counts": package["metadata"]["record_counts"]
    }


def generate_state_summary(
    db: firestore.Client,
    bucket: storage.Bucket,
    state: str
) -> Dict[str, Any]:
    """Generate state-level summary statistics."""
    incidents_ref = db.collection("incidents")
    incidents_query = incidents_ref.where("state", "==", state)

    officers_ref = db.collection("officers")
    officers_query = officers_ref.where("state", "==", state)

    incident_count = len(list(incidents_query.stream()))
    officer_count = len(list(officers_query.stream()))

    summary = {
        "state": state,
        "generated_at": datetime.utcnow().isoformat(),
        "totals": {
            "incidents": incident_count,
            "officers": officer_count
        }
    }

    blob_path = f"states/{state}/state_summary.json"
    blob = bucket.blob(blob_path)
    blob.upload_from_string(json.dumps(summary, indent=2), content_type="application/json")

    return summary


def generate_national_watchlist(
    db: firestore.Client,
    bucket: storage.Bucket
) -> Dict[str, Any]:
    """Generate national top 100 officers watchlist."""
    officers_ref = db.collection("officers")

    # Query top 100 by incident count
    top_officers_query = officers_ref.order_by("incidentCount", direction=firestore.Query.DESCENDING).limit(100)

    top_officers = []
    for doc in top_officers_query.stream():
        data = doc.to_dict()
        data.pop("created_at", None)
        data.pop("updated_at", None)
        top_officers.append(data)

    watchlist = {
        "generated_at": datetime.utcnow().isoformat(),
        "total_officers": len(top_officers),
        "officers": top_officers
    }

    blob_path = "national/top_officers_watchlist.json"
    blob = bucket.blob(blob_path)
    blob.upload_from_string(json.dumps(watchlist, indent=2), content_type="application/json")

    # Also upload compressed version
    compressed = gzip.compress(json.dumps(watchlist).encode("utf-8"))
    blob_gz = bucket.blob(f"{blob_path}.gz")
    blob_gz.upload_from_string(compressed, content_type="application/gzip")

    return watchlist


def update_manifest(bucket: storage.Bucket, results: List[Dict[str, Any]]) -> None:
    """Update the global manifest with all available city packages."""
    manifest = {
        "last_updated": datetime.utcnow().isoformat(),
        "total_packages": len(results),
        "packages": results
    }

    blob = bucket.blob("manifests/full_manifest.json")
    blob.upload_from_string(json.dumps(manifest, indent=2), content_type="application/json")
```

### Function 2: `get-city-package-url` (Lightweight API)

**Purpose:** Return CDN URL for a city package (with caching header)

**File:** `functions/city_data_api/main.py`

```python
"""
Cloud Function: City Package URL API
Returns CDN URLs for city data packages.
"""

import json
from firebase_functions import https_fn

BUCKET_NAME = "blueledger-city-data"
CDN_BASE_URL = f"https://storage.googleapis.com/{BUCKET_NAME}"


@https_fn.on_request()
def get_city_package_url(req: https_fn.Request) -> https_fn.Response:
    """
    Return CDN URL for a city data package.

    Query params:
      - state: 2-letter state code (required)
      - city: City name (required)
      - format: json | json.gz (default: json.gz)

    Returns:
      {
        "cdn_url": "https://storage.googleapis.com/blueledger-city-data/states/IN/cities/Indianapolis.json.gz",
        "state": "IN",
        "city": "Indianapolis",
        "format": "json.gz",
        "cache_ttl": 86400
      }
    """
    state = req.args.get("state")
    city = req.args.get("city")
    format_type = req.args.get("format", "json.gz")

    if not state or not city:
        return https_fn.Response(
            json.dumps({"error": "Missing required params: state, city"}),
            status=400,
            mimetype="application/json"
        )

    city_slug = city.replace(" ", "_").replace("/", "_")
    blob_path = f"states/{state}/cities/{city_slug}.{format_type}"
    cdn_url = f"{CDN_BASE_URL}/{blob_path}"

    response_data = {
        "cdn_url": cdn_url,
        "state": state,
        "city": city,
        "format": format_type,
        "cache_ttl": 86400  # 24 hours
    }

    return https_fn.Response(
        json.dumps(response_data),
        status=200,
        mimetype="application/json",
        headers={
            "Cache-Control": "public, max-age=86400",  # Cache for 24 hours
            "Access-Control-Allow-Origin": "*"
        }
    )
```

### Deploy Functions

```bash
cd functions

# Deploy city package generator
firebase deploy --only functions:daily_city_package_generation,functions:manual_city_package_trigger

# Deploy API endpoint
firebase deploy --only functions:get_city_package_url
```

---

## API Gateway Setup

### Optional: Use Cloud Load Balancer with Cloud CDN

```bash
# 1. Create backend bucket
gcloud compute backend-buckets create blueledger-city-data-backend \
  --gcs-bucket-name=blueledger-city-data \
  --enable-cdn

# 2. Create URL map
gcloud compute url-maps create blueledger-city-data-url-map \
  --default-backend-bucket=blueledger-city-data-backend

# 3. Create target HTTP proxy
gcloud compute target-http-proxies create blueledger-city-data-proxy \
  --url-map=blueledger-city-data-url-map

# 4. Create global forwarding rule
gcloud compute forwarding-rules create blueledger-city-data-forwarding-rule \
  --global \
  --target-http-proxy=blueledger-city-data-proxy \
  --ports=80

# 5. Get external IP
gcloud compute forwarding-rules describe blueledger-city-data-forwarding-rule --global
```

### Access URLs

| Endpoint | URL | Purpose |
|----------|-----|---------|
| Direct Cloud Storage | `https://storage.googleapis.com/blueledger-city-data/states/IN/cities/Indianapolis.json.gz` | Direct download (no CDN) |
| Cloud CDN | `http://[EXTERNAL_IP]/states/IN/cities/Indianapolis.json.gz` | Cached at edge locations |
| API Gateway | `https://us-central1-blueledger-3af1a.cloudfunctions.net/get_city_package_url?state=IN&city=Indianapolis` | URL resolver |

---

## City-Level Data Schema

### City Package Structure (JSON)

```json
{
  "metadata": {
    "state": "IN",
    "city": "Indianapolis",
    "generated_at": "2026-01-13T12:00:00Z",
    "schema_version": "v1",
    "record_counts": {
      "incidents": 152,
      "officers": 8,
      "departments": 3
    }
  },
  "incidents": [
    {
      "id": "IN_indianapolis_20250910",
      "state": "IN",
      "city": "Indianapolis",
      "latitude": 39.7684,
      "longitude": -86.1581,
      "geohash": "dp3w",
      "incident_type": "FATAL_SHOOTING",
      "incident_date": "2025-09-10",
      "description": "Fatal officer-involved shooting",
      "outcome": "UNDER_INVESTIGATION",
      "victim_name": "John Doe",
      "officer_name": "Jane Smith",
      "department": "Indianapolis Metropolitan Police Department",
      "settlement_amount": 0,
      "source_name": "IMPD Public Records",
      "source_url": "https://www.indy.gov/...",
      "fatal": true,
      "injury": false
    }
  ],
  "officers": [
    {
      "state": "IN",
      "full_name": "Jane Smith",
      "first_name": "Jane",
      "last_name": "Smith",
      "badge_number": "12345",
      "department": "Indianapolis Metropolitan Police Department",
      "rank": "Officer",
      "photoUrl": "https://ui-avatars.com/api/?name=Jane+Smith&background=1976D2&color=fff",
      "incidentCount": 2,
      "complaintsCount": 5,
      "settlementTotal": 150000,
      "liabilityRisk": "HIGH",
      "isRepeatOffender": true,
      "search_terms": ["jane", "smith", "js", "12345"]
    }
  ],
  "departments": [
    {
      "id": "impd",
      "name": "Indianapolis Metropolitan Police Department",
      "city": "Indianapolis",
      "state": "IN",
      "officer_count": 1700,
      "agency_type": "MUNICIPAL",
      "incident_count": 152,
      "is_verified": true
    }
  ]
}
```

### State Summary Structure

```json
{
  "state": "IN",
  "generated_at": "2026-01-13T12:00:00Z",
  "totals": {
    "incidents": 1523,
    "officers": 85,
    "departments": 54,
    "cities": 42
  },
  "top_cities": [
    {"city": "Indianapolis", "incident_count": 152},
    {"city": "Fort Wayne", "incident_count": 48},
    {"city": "Evansville", "incident_count": 32}
  ]
}
```

### Manifest Structure

```json
{
  "last_updated": "2026-01-13T12:00:00Z",
  "schema_version": "v1",
  "total_packages": 2547,
  "packages": [
    {
      "state": "IN",
      "city": "Indianapolis",
      "cdn_url": "https://storage.googleapis.com/blueledger-city-data/states/IN/cities/Indianapolis.json.gz",
      "size_bytes": 245678,
      "record_counts": {
        "incidents": 152,
        "officers": 8,
        "departments": 3
      }
    }
  ]
}
```

---

## Caching Strategy

### Client-Side (Mobile App)

```kotlin
// Android Example
class CityDataCache(private val context: Context) {
    private val cacheDir = File(context.cacheDir, "city_data")
    private val maxAge = 24 * 60 * 60 * 1000L // 24 hours

    fun getCityData(state: String, city: String): CityPackage? {
        val cacheFile = File(cacheDir, "${state}_${city}.json")

        if (cacheFile.exists() && isCacheValid(cacheFile)) {
            return Json.decodeFromString(cacheFile.readText())
        }

        return null // Cache miss - trigger download
    }

    fun downloadAndCache(state: String, city: String) {
        val url = "https://storage.googleapis.com/blueledger-city-data/states/$state/cities/${city}.json.gz"

        // Download + decompress + save
        val response = httpClient.get(url)
        val decompressed = GZIPInputStream(response.bodyAsStream()).readBytes()

        val cacheFile = File(cacheDir, "${state}_${city}.json")
        cacheFile.writeBytes(decompressed)
    }

    private fun isCacheValid(file: File): Boolean {
        val age = System.currentTimeMillis() - file.lastModified()
        return age < maxAge
    }
}
```

### Server-Side (Cloud Storage)

```bash
# Set Cache-Control headers on all objects
gsutil -m setmeta -h "Cache-Control:public, max-age=86400" \
  "gs://blueledger-city-data/states/**"

# Set metadata for manifest (shorter TTL)
gsutil setmeta -h "Cache-Control:public, max-age=3600" \
  "gs://blueledger-city-data/manifests/full_manifest.json"
```

---

## Local Development Setup

### Prerequisites

```bash
# 1. Install Google Cloud SDK
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
gcloud init

# 2. Install Firebase CLI
npm install -g firebase-tools
firebase login

# 3. Install Python dependencies
cd functions/city_data_exporter
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# 4. Set environment variables
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/../../scripts/cityDataServiceAccountKey.json"
export PROJECT_ID="blueledger-3af1a"
```

### Local Testing

```bash
# 1. Test Firestore connection
python3 << EOF
from firebase_admin import initialize_app, firestore, credentials

cred = credentials.Certificate("scripts/cityDataServiceAccountKey.json")
initialize_app(cred)

db = firestore.client()
incidents = db.collection("incidents").limit(5).stream()

for doc in incidents:
    print(f"{doc.id}: {doc.to_dict()}")
EOF

# 2. Test Cloud Storage upload
python3 << EOF
from google.cloud import storage

client = storage.Client()
bucket = client.bucket("blueledger-city-data")

blob = bucket.blob("test/hello.txt")
blob.upload_from_string("Hello from local dev!")

print(f"Uploaded to: https://storage.googleapis.com/{bucket.name}/{blob.name}")
EOF

# 3. Run cloud function locally
cd functions/city_data_exporter
functions-framework --target=manual_city_package_trigger --debug

# Test HTTP endpoint
curl -X POST "http://localhost:8080?state=IN&city=Indianapolis"
```

### Generate Single City Package (Manual)

```bash
# Script: scripts/generate_city_package_local.py
python3 << 'EOF'
import json
import gzip
from firebase_admin import initialize_app, firestore, credentials
from google.cloud import storage

# Initialize
cred = credentials.Certificate("scripts/cityDataServiceAccountKey.json")
initialize_app(cred)

db = firestore.client()
storage_client = storage.Client()
bucket = storage_client.bucket("blueledger-city-data")

# Parameters
STATE = "IN"
CITY = "Indianapolis"

# Query data
incidents = []
for doc in db.collection("incidents").where("state", "==", STATE).where("city", "==", CITY).stream():
    data = doc.to_dict()
    data.pop("created_at", None)
    data.pop("updated_at", None)
    incidents.append(data)

officers = []
for doc in db.collection("officers").where("state", "==", STATE).stream():
    data = doc.to_dict()
    data.pop("created_at", None)
    data.pop("updated_at", None)
    officers.append(data)

# Build package
package = {
    "metadata": {
        "state": STATE,
        "city": CITY,
        "record_counts": {
            "incidents": len(incidents),
            "officers": len(officers)
        }
    },
    "incidents": incidents,
    "officers": officers
}

# Save locally
with open(f"{STATE}_{CITY}_package.json", "w") as f:
    json.dump(package, f, indent=2)

# Upload to Cloud Storage
blob = bucket.blob(f"states/{STATE}/cities/{CITY}.json.gz")
blob.upload_from_string(gzip.compress(json.dumps(package).encode("utf-8")))

print(f"✓ Generated package: {len(incidents)} incidents, {len(officers)} officers")
print(f"✓ Uploaded to: gs://blueledger-city-data/states/{STATE}/cities/{CITY}.json.gz")
EOF
```

---

## One-Shot Configuration

### Complete Setup Script

**File:** `scripts/setup_gcloud_city_data.sh`

```bash
#!/bin/bash
set -e

echo "=================================================="
echo "BlueLedger - Google Cloud City Data Setup"
echo "=================================================="
echo ""

# Configuration
PROJECT_ID="blueledger-3af1a"
BUCKET_NAME="blueledger-city-data"
SA_NAME="blueledger-city-data"
REGION="us-central1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

step() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Step 1: Set project
step "Setting GCloud project to $PROJECT_ID..."
gcloud config set project $PROJECT_ID || error "Failed to set project"

# Step 2: Enable required APIs
step "Enabling required Google Cloud APIs..."
gcloud services enable \
  cloudfunctions.googleapis.com \
  cloudscheduler.googleapis.com \
  storage.googleapis.com \
  firestore.googleapis.com \
  run.googleapis.com || error "Failed to enable APIs"

# Step 3: Create service account
step "Creating service account: $SA_NAME..."
if gcloud iam service-accounts describe ${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com &>/dev/null; then
    warn "Service account already exists, skipping creation"
else
    gcloud iam service-accounts create $SA_NAME \
      --display-name="BlueLedger City Data Exporter" \
      --description="Service account for exporting city data packages"
fi

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Step 4: Grant permissions
step "Granting IAM permissions..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/datastore.viewer" \
  --condition=None

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" \
  --condition=None

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudfunctions.invoker" \
  --condition=None

# Step 5: Generate service account key
step "Generating service account key..."
KEY_FILE="scripts/cityDataServiceAccountKey.json"
if [ -f "$KEY_FILE" ]; then
    warn "Service account key already exists at $KEY_FILE"
    read -p "Overwrite? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Skipping key generation"
    else
        gcloud iam service-accounts keys create $KEY_FILE \
          --iam-account=$SA_EMAIL
    fi
else
    gcloud iam service-accounts keys create $KEY_FILE \
      --iam-account=$SA_EMAIL
fi

# Step 6: Create Cloud Storage bucket
step "Creating Cloud Storage bucket: $BUCKET_NAME..."
if gsutil ls -b gs://$BUCKET_NAME &>/dev/null; then
    warn "Bucket already exists, skipping creation"
else
    gsutil mb -p $PROJECT_ID -c STANDARD -l $REGION gs://$BUCKET_NAME
fi

# Step 7: Enable versioning
step "Enabling versioning on bucket..."
gsutil versioning set on gs://$BUCKET_NAME

# Step 8: Set lifecycle policy
step "Setting lifecycle policy..."
cat > /tmp/lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {
          "numNewerVersions": 3,
          "age": 30
        }
      }
    ]
  }
}
EOF
gsutil lifecycle set /tmp/lifecycle.json gs://$BUCKET_NAME

# Step 9: Set public access
step "Configuring public access..."
gsutil iam ch allUsers:objectViewer gs://$BUCKET_NAME

# Step 10: Set CORS policy
step "Setting CORS policy..."
cat > /tmp/cors.json <<EOF
[
  {
    "origin": ["*"],
    "method": ["GET", "HEAD"],
    "responseHeader": ["Content-Type", "Content-Length"],
    "maxAgeSeconds": 3600
  }
]
EOF
gsutil cors set /tmp/cors.json gs://$BUCKET_NAME

# Step 11: Create directory structure
step "Creating bucket directory structure..."
echo '{"initialized": true}' | gsutil cp - gs://$BUCKET_NAME/manifests/last_updated.json

# Step 12: Add to .gitignore
step "Adding service account key to .gitignore..."
if ! grep -q "cityDataServiceAccountKey.json" .gitignore 2>/dev/null; then
    echo "scripts/cityDataServiceAccountKey.json" >> .gitignore
fi

# Step 13: Test connection
step "Testing Firestore connection..."
export GOOGLE_APPLICATION_CREDENTIALS="$KEY_FILE"
python3 << 'PYEOF'
try:
    from firebase_admin import initialize_app, firestore, credentials
    cred = credentials.Certificate("scripts/cityDataServiceAccountKey.json")
    app = initialize_app(cred)
    db = firestore.client()
    count = len(list(db.collection("incidents").limit(1).stream()))
    print(f"✓ Firestore connection successful (found {count} incident)")
except Exception as e:
    print(f"✗ Firestore connection failed: {e}")
    exit(1)
PYEOF

# Step 14: Test Cloud Storage
step "Testing Cloud Storage access..."
echo "test" | gsutil cp - gs://$BUCKET_NAME/test/connection_test.txt
gsutil rm gs://$BUCKET_NAME/test/connection_test.txt

echo ""
echo "=================================================="
echo -e "${GREEN}Setup Complete!${NC}"
echo "=================================================="
echo ""
echo "Summary:"
echo "  - Project ID: $PROJECT_ID"
echo "  - Service Account: $SA_EMAIL"
echo "  - Storage Bucket: gs://$BUCKET_NAME"
echo "  - Key File: $KEY_FILE"
echo ""
echo "Next Steps:"
echo "  1. Deploy Cloud Functions:"
echo "     cd functions"
echo "     firebase deploy --only functions"
echo ""
echo "  2. Generate initial city packages:"
echo "     python3 scripts/generate_all_city_packages.py"
echo ""
echo "  3. Test API endpoint:"
echo "     curl 'https://us-central1-$PROJECT_ID.cloudfunctions.net/get_city_package_url?state=IN&city=Indianapolis'"
echo ""
```

### Run Setup

```bash
chmod +x scripts/setup_gcloud_city_data.sh
./scripts/setup_gcloud_city_data.sh
```

---

## Testing & Verification

### Test Checklist

```bash
# 1. Verify service account permissions
gcloud projects get-iam-policy blueledger-3af1a \
  --flatten="bindings[].members" \
  --filter="bindings.members:blueledger-city-data@*"

# 2. Verify bucket exists and is public
gsutil ls gs://blueledger-city-data
curl -I https://storage.googleapis.com/blueledger-city-data/manifests/last_updated.json

# 3. Test manual package generation
curl -X POST "https://us-central1-blueledger-3af1a.cloudfunctions.net/manual_city_package_trigger?state=IN&city=Indianapolis"

# 4. Verify package was created
gsutil ls gs://blueledger-city-data/states/IN/cities/

# 5. Download and verify package structure
curl -o /tmp/test_package.json.gz \
  https://storage.googleapis.com/blueledger-city-data/states/IN/cities/Indianapolis.json.gz

gunzip /tmp/test_package.json.gz
jq '.metadata' /tmp/test_package.json

# 6. Test API endpoint
curl "https://us-central1-blueledger-3af1a.cloudfunctions.net/get_city_package_url?state=IN&city=Indianapolis" | jq

# 7. Verify Cloud Scheduler job
gcloud scheduler jobs list

# 8. Check function logs
gcloud functions logs read daily_city_package_generation --limit=50
```

---

## Cost Estimation

### Monthly Costs (Estimated)

| Service | Usage | Unit Cost | Monthly Cost |
|---------|-------|-----------|--------------|
| Cloud Storage (Standard) | 5 GB stored | $0.026/GB/month | $0.13 |
| Cloud Storage (Egress) | 10 GB/month | $0.12/GB | $1.20 |
| Cloud Functions (2nd Gen) | 30 daily + 10 manual | $0.40/M invocations | $0.02 |
| Cloud Scheduler | 1 job | $0.10/job/month | $0.10 |
| Cloud CDN (optional) | 10 GB cache hits | $0.08/GB | $0.80 |
| **Total** | | | **$2.25/month** |

### Cost Comparison

| Approach | Reads/Month | Cost |
|----------|-------------|------|
| **Firestore Direct** (Current) | 1M reads | $0.36/100K = $3.60 |
| **City Data Packages** (Proposed) | 5K reads (just manifests) | ~$2.25 total |

**Savings:** ~$1.35/month at 1M reads, scales better at higher volume

---

## Mobile App Integration

### Android Implementation

```kotlin
// CityDataDownloader.kt
class CityDataDownloader(
    private val context: Context,
    private val httpClient: HttpClient
) {
    private val cacheDir = File(context.cacheDir, "city_data")
    private val maxCacheAgeMs = 24 * 60 * 60 * 1000L // 24 hours

    init {
        cacheDir.mkdirs()
    }

    suspend fun getCityData(state: String, city: String): CityPackage {
        // Check cache first
        val cached = loadFromCache(state, city)
        if (cached != null && isCacheValid(cached)) {
            return cached.data
        }

        // Download from Cloud Storage
        return downloadAndCache(state, city)
    }

    private fun loadFromCache(state: String, city: String): CachedPackage? {
        val file = getCacheFile(state, city)
        if (!file.exists()) return null

        return try {
            val json = file.readText()
            CachedPackage(
                data = Json.decodeFromString(json),
                timestamp = file.lastModified()
            )
        } catch (e: Exception) {
            null
        }
    }

    private suspend fun downloadAndCache(state: String, city: String): CityPackage {
        val citySlug = city.replace(" ", "_")
        val url = "https://storage.googleapis.com/blueledger-city-data/states/$state/cities/$citySlug.json.gz"

        val response: HttpResponse = httpClient.get(url)
        val compressed = response.readBytes()
        val decompressed = GZIPInputStream(compressed.inputStream()).readBytes()

        // Save to cache
        val cacheFile = getCacheFile(state, city)
        cacheFile.writeBytes(decompressed)

        return Json.decodeFromString(decompressed.decodeToString())
    }

    private fun getCacheFile(state: String, city: String): File {
        return File(cacheDir, "${state}_${city}.json")
    }

    private fun isCacheValid(cached: CachedPackage): Boolean {
        val age = System.currentTimeMillis() - cached.timestamp
        return age < maxCacheAgeMs
    }
}

@Serializable
data class CityPackage(
    val metadata: PackageMetadata,
    val incidents: List<RemoteIncident>,
    val officers: List<RemoteOfficer>,
    val departments: List<RemoteDepartment>
)

@Serializable
data class PackageMetadata(
    val state: String,
    val city: String,
    val generated_at: String,
    val schema_version: String,
    val record_counts: RecordCounts
)

data class CachedPackage(
    val data: CityPackage,
    val timestamp: Long
)
```

### iOS Implementation

```swift
// CityDataDownloader.swift
class CityDataDownloader {
    private let cacheDirectory: URL
    private let maxCacheAge: TimeInterval = 24 * 60 * 60 // 24 hours

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("city_data", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func getCityData(state: String, city: String) async throws -> CityPackage {
        // Check cache
        if let cached = try? loadFromCache(state: state, city: city),
           isCacheValid(cached) {
            return cached.data
        }

        // Download
        return try await downloadAndCache(state: state, city: city)
    }

    private func loadFromCache(state: String, city: String) throws -> CachedPackage? {
        let file = cacheFile(state: state, city: city)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        let data = try Data(contentsOf: file)
        let package = try JSONDecoder().decode(CityPackage.self, from: data)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let timestamp = (attributes[.modificationDate] as? Date) ?? Date()

        return CachedPackage(data: package, timestamp: timestamp)
    }

    private func downloadAndCache(state: String, city: String) async throws -> CityPackage {
        let citySlug = city.replacingOccurrences(of: " ", with: "_")
        let urlString = "https://storage.googleapis.com/blueledger-city-data/states/\(state)/cities/\(citySlug).json.gz"

        let url = URL(string: urlString)!
        let (data, _) = try await URLSession.shared.data(from: url)

        // Decompress gzip
        let decompressed = try (data as NSData).decompressed(using: .zlib) as Data

        // Save to cache
        let file = cacheFile(state: state, city: city)
        try decompressed.write(to: file)

        // Decode
        return try JSONDecoder().decode(CityPackage.self, from: decompressed)
    }

    private func cacheFile(state: String, city: String) -> URL {
        return cacheDirectory.appendingPathComponent("\(state)_\(city).json")
    }

    private func isCacheValid(_ cached: CachedPackage) -> Bool {
        let age = Date().timeIntervalSince(cached.timestamp)
        return age < maxCacheAge
    }
}

struct CityPackage: Codable {
    let metadata: PackageMetadata
    let incidents: [Incident]
    let officers: [Officer]
    let departments: [Department]
}

struct CachedPackage {
    let data: CityPackage
    let timestamp: Date
}
```

---

## Monitoring & Maintenance

### Cloud Function Logging

```bash
# View function logs
gcloud functions logs read daily_city_package_generation --limit=100

# Tail logs in real-time
gcloud functions logs read daily_city_package_generation --limit=10 --follow

# Filter errors
gcloud functions logs read daily_city_package_generation --filter="severity=ERROR" --limit=50
```

### Storage Monitoring

```bash
# Check bucket size
gsutil du -sh gs://blueledger-city-data

# List largest objects
gsutil du -h gs://blueledger-city-data/states/** | sort -rh | head -20

# Check object count
gsutil ls -r gs://blueledger-city-data/** | wc -l
```

### Scheduled Jobs

```bash
# List all scheduled jobs
gcloud scheduler jobs list

# Pause daily generation
gcloud scheduler jobs pause daily_city_package_generation

# Resume
gcloud scheduler jobs resume daily_city_package_generation

# Manually trigger
gcloud scheduler jobs run daily_city_package_generation
```

---

## Troubleshooting

### Issue: Cloud Function Timeout

**Symptom:** Function times out after 540 seconds

**Solution:**
```bash
# Increase timeout to max (60 minutes for 2nd gen)
gcloud functions deploy daily_city_package_generation \
  --gen2 \
  --timeout=3600s \
  --memory=4GB
```

### Issue: Permission Denied on Storage

**Symptom:** `403 Forbidden` when uploading to bucket

**Solution:**
```bash
# Re-grant storage permissions
gcloud projects add-iam-policy-binding blueledger-3af1a \
  --member="serviceAccount:blueledger-city-data@blueledger-3af1a.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

### Issue: Stale Cache in Mobile App

**Symptom:** App shows old data despite new packages

**Solution:**
- Check `generated_at` timestamp in package metadata
- Clear app cache manually
- Reduce `maxCacheAge` to 12 hours

---

## Security Considerations

### Public Bucket Access

**Risk:** All data is publicly readable

**Mitigation:**
- De-identify sensitive data (no SSNs, DOBs, addresses)
- Only include verified public records
- Set up Cloud Armor for DDoS protection if needed

### Service Account Key

**Risk:** Key file grants full access if leaked

**Mitigation:**
```bash
# Add to .gitignore (already done)
echo "scripts/cityDataServiceAccountKey.json" >> .gitignore

# Rotate keys every 90 days
gcloud iam service-accounts keys list \
  --iam-account=blueledger-city-data@blueledger-3af1a.iam.gserviceaccount.com

# Delete old keys
gcloud iam service-accounts keys delete KEY_ID \
  --iam-account=blueledger-city-data@blueledger-3af1a.iam.gserviceaccount.com
```

---

## Performance Optimization

### Compression Comparison

| Format | Size (IN/Indianapolis) | Bandwidth Savings |
|--------|------------------------|-------------------|
| JSON (uncompressed) | 2.5 MB | 0% |
| JSON.gz (gzip) | 456 KB | 82% |
| Parquet (columnar) | 389 KB | 84% |

**Recommendation:** Use gzip for simplicity, or Parquet for analytics

### Parallel Package Generation

```python
# Generate packages in parallel using ThreadPoolExecutor
from concurrent.futures import ThreadPoolExecutor, as_completed

def generate_all_cities_parallel(db, bucket, cities, max_workers=10):
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {
            executor.submit(generate_city_package, db, bucket, state, city): (state, city)
            for state, city in cities
        }

        results = []
        for future in as_completed(futures):
            state, city = futures[future]
            try:
                result = future.result()
                results.append(result)
                print(f"✓ {city}, {state}")
            except Exception as e:
                print(f"✗ {city}, {state}: {e}")

        return results
```

---

## Future Enhancements

### 1. Delta Updates
Instead of downloading full packages, send only changed records

### 2. GraphQL API
Allow clients to request specific fields only

### 3. Real-time Sync
Use Firebase Realtime Database for live updates + city packages for bulk data

### 4. Multi-region CDN
Deploy to Cloud CDN in multiple regions for lower latency

### 5. Parquet Format
For analytics teams, provide Parquet exports in addition to JSON

---

## Summary

This setup enables:

✅ **Offline-first mobile apps** (download once, use offline)
✅ **Reduced Firebase costs** (from $3.60/month to $2.25/month at 1M reads)
✅ **Faster app performance** (local cache vs remote API)
✅ **Scalable architecture** (CDN caching + pre-generated packages)
✅ **Simple maintenance** (daily scheduled refresh, no manual intervention)

**Total setup time:** ~30 minutes using the one-shot script

**Next Steps:**
1. Run `./scripts/setup_gcloud_city_data.sh`
2. Deploy Cloud Functions
3. Trigger initial package generation
4. Update mobile apps to use city package downloader
5. Monitor costs and performance

---

## Reference Links

- [Google Cloud Storage Pricing](https://cloud.google.com/storage/pricing)
- [Cloud Functions Pricing](https://cloud.google.com/functions/pricing)
- [Firebase Admin SDK for Python](https://firebase.google.com/docs/admin/setup)
- [Cloud CDN Documentation](https://cloud.google.com/cdn/docs)
- [Firestore Best Practices](https://cloud.google.com/firestore/docs/best-practices)

---

**Document Version:** 1.0
**Last Updated:** January 13, 2026
**Maintained By:** BlueLedger Team
