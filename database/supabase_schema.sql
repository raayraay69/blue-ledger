-- ============================================================================
-- BLUELEDGER: ZERO-KNOWLEDGE INCIDENT REPORTING SYSTEM
-- Supabase PostgreSQL Schema with PostGIS + Row Level Security
-- ============================================================================
--
-- PHILOSOPHY: "We don't want to know WHO the user is, only WHERE the incident is."
--
-- This schema implements:
-- 1. PostGIS for fast geospatial radius queries (25-mile tactical radius)
-- 2. "Black Box" model - anonymous incident reporting
-- 3. Row Level Security for privacy-preserving data access
-- 4. Community-vetted officer database
-- ============================================================================

-- Enable PostGIS extension for geospatial queries
CREATE EXTENSION IF NOT EXISTS postgis;

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- INCIDENTS TABLE (The "Black Box")
-- ============================================================================
-- Anonymous incident reports - no user tracking, only location + facts

CREATE TABLE IF NOT EXISTS incidents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Geospatial Location (PostGIS Geography Point for fast radius queries)
    location GEOGRAPHY(POINT, 4326) NOT NULL,

    -- Human-readable location info (derived from reverse geocoding on device)
    city TEXT,
    state TEXT,
    zip_code TEXT,
    address TEXT,
    location_type TEXT, -- 'street', 'traffic_stop', 'home', 'business', etc.

    -- Officer Information (Community Vetted)
    badge_number TEXT, -- Indexed for fast lookup
    officer_name TEXT,
    department TEXT,

    -- Incident Classification
    incident_type TEXT NOT NULL DEFAULT 'unknown',
    -- Tags Array: ["taser", "search", "verbal", "physical", "weapon_drawn"]
    tags TEXT[] DEFAULT '{}',

    -- AI Confidence Score (0.0 - 1.0)
    -- How confident the edge AI was in extracting this data
    ai_confidence REAL DEFAULT 0.0 CHECK (ai_confidence >= 0.0 AND ai_confidence <= 1.0),

    -- Narrative (anonymized transcript from edge AI)
    description TEXT,
    summary TEXT,

    -- Outcome Classification
    outcome TEXT, -- 'resolved', 'citation', 'arrest', 'force_used', 'injury', 'unknown'

    -- Witness Mode Markers
    non_consent_declared BOOLEAN DEFAULT false,
    non_consent_timestamp TIMESTAMPTZ,

    -- Verification (Community + AI)
    verification_status TEXT DEFAULT 'unverified', -- 'verified', 'disputed', 'retracted'
    confirm_count INTEGER DEFAULT 0,
    dispute_count INTEGER DEFAULT 0,

    -- Media References (hashes only - actual media stored separately if at all)
    has_audio BOOLEAN DEFAULT false,
    has_video BOOLEAN DEFAULT false,
    has_photos BOOLEAN DEFAULT false,

    -- Device fingerprint for rate limiting (NOT for tracking users)
    -- This is a salted hash that changes daily
    device_token_hash TEXT,

    -- Timestamps
    incident_date TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Performance indices for incidents
CREATE INDEX IF NOT EXISTS idx_incidents_location
    ON incidents USING GIST (location);

CREATE INDEX IF NOT EXISTS idx_incidents_badge_number
    ON incidents (badge_number)
    WHERE badge_number IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_incidents_created_at
    ON incidents (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_incidents_city_state
    ON incidents (city, state);

CREATE INDEX IF NOT EXISTS idx_incidents_incident_type
    ON incidents (incident_type);

CREATE INDEX IF NOT EXISTS idx_incidents_tags
    ON incidents USING GIN (tags);

-- ============================================================================
-- OFFICERS TABLE (Community Vetted)
-- ============================================================================
-- Aggregated officer profiles from community reports

CREATE TABLE IF NOT EXISTS officers (
    badge_number TEXT PRIMARY KEY,

    -- Officer Info
    first_name TEXT,
    last_name TEXT,

    -- Department
    department TEXT NOT NULL,
    department_city TEXT,
    department_state TEXT,

    -- Rank/Unit (if known)
    rank TEXT,
    unit TEXT,

    -- Aggregated Statistics
    reports_count INTEGER DEFAULT 0,
    positive_encounters INTEGER DEFAULT 0,
    negative_encounters INTEGER DEFAULT 0,

    -- Community Rating (1-5 scale, computed average)
    avg_rating REAL CHECK (avg_rating IS NULL OR (avg_rating >= 1.0 AND avg_rating <= 5.0)),

    -- Tag frequency (JSON object with counts)
    -- e.g., {"respectful": 5, "aggressive": 2, "professional": 8}
    tag_frequency JSONB DEFAULT '{}',

    -- Verification
    is_verified BOOLEAN DEFAULT false, -- Verified by official source

    -- Timestamps
    first_reported_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for officer lookup
CREATE INDEX IF NOT EXISTS idx_officers_department
    ON officers (department);

CREATE INDEX IF NOT EXISTS idx_officers_name
    ON officers (last_name, first_name);

-- ============================================================================
-- POLICE SIGHTINGS TABLE (Real-time Waze-style alerts)
-- ============================================================================
-- Ephemeral sightings - auto-expire after 30 minutes

CREATE TABLE IF NOT EXISTS police_sightings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Location (PostGIS)
    location GEOGRAPHY(POINT, 4326) NOT NULL,

    -- Human-readable
    address TEXT,
    cross_street TEXT,
    city TEXT,
    state TEXT,

    -- Sighting details
    sighting_type TEXT NOT NULL, -- 'patrol_car', 'traffic_stop', 'speed_trap', 'checkpoint', 'unmarked'
    direction TEXT, -- 'northbound', 'southbound', 'eastbound', 'westbound', 'stationary'
    vehicle_count INTEGER DEFAULT 1,
    description TEXT,

    -- Community validation
    confirm_count INTEGER DEFAULT 0,
    not_there_count INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT true,

    -- Timing
    reported_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '30 minutes'),
    last_confirmed_at TIMESTAMPTZ DEFAULT NOW(),

    -- Rate limiting token
    device_token_hash TEXT,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Geospatial index for sightings
CREATE INDEX IF NOT EXISTS idx_sightings_location
    ON police_sightings USING GIST (location);

CREATE INDEX IF NOT EXISTS idx_sightings_expires_at
    ON police_sightings (expires_at)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_sightings_city_state
    ON police_sightings (city, state);

-- ============================================================================
-- COMMUNITY EXPERIENCES TABLE
-- ============================================================================
-- Detailed encounter reports from community members

CREATE TABLE IF NOT EXISTS community_experiences (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Officer reference
    officer_badge_number TEXT REFERENCES officers(badge_number),
    officer_name TEXT,
    officer_description TEXT,
    department TEXT,

    -- Location
    location GEOGRAPHY(POINT, 4326),
    city TEXT,
    state TEXT,

    -- Encounter details
    encounter_type TEXT NOT NULL, -- 'traffic_stop', 'pedestrian_stop', 'checkpoint', etc.
    encounter_date DATE,
    encounter_time TIME,

    -- Experience narrative
    title TEXT,
    description TEXT,
    stated_reason TEXT,

    -- Rating
    rating INTEGER CHECK (rating IS NULL OR (rating >= 1 AND rating <= 5)),

    -- Tags (array)
    tags TEXT[] DEFAULT '{}',

    -- Outcome
    outcome TEXT,
    ticket_amount DECIMAL(10, 2),

    -- Community validation
    helpful_count INTEGER DEFAULT 0,
    not_helpful_count INTEGER DEFAULT 0,

    -- Verification
    is_verified BOOLEAN DEFAULT false,

    -- Anonymous posting
    reporter_alias TEXT,
    is_anonymous BOOLEAN DEFAULT true,

    -- Rate limiting
    device_token_hash TEXT,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indices for experiences
CREATE INDEX IF NOT EXISTS idx_experiences_officer
    ON community_experiences (officer_badge_number);

CREATE INDEX IF NOT EXISTS idx_experiences_location
    ON community_experiences USING GIST (location);

CREATE INDEX IF NOT EXISTS idx_experiences_department
    ON community_experiences (department);

-- ============================================================================
-- DEPARTMENTS TABLE
-- ============================================================================
-- Police department directory

CREATE TABLE IF NOT EXISTS departments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Department info
    name TEXT NOT NULL,
    short_name TEXT,

    -- Location
    city TEXT NOT NULL,
    state TEXT NOT NULL,
    county TEXT,

    -- Contact
    address TEXT,
    phone TEXT,
    website TEXT,

    -- Statistics (aggregated)
    total_officers INTEGER DEFAULT 0,
    total_reports INTEGER DEFAULT 0,
    avg_rating REAL,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_departments_city_state
    ON departments (city, state);

CREATE INDEX IF NOT EXISTS idx_departments_name
    ON departments (name);

-- ============================================================================
-- ROW LEVEL SECURITY POLICIES (Zero-Knowledge by Default)
-- ============================================================================

-- Enable RLS on all tables
ALTER TABLE incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE officers ENABLE ROW LEVEL SECURITY;
ALTER TABLE police_sightings ENABLE ROW LEVEL SECURITY;
ALTER TABLE community_experiences ENABLE ROW LEVEL SECURITY;
ALTER TABLE departments ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- INCIDENTS POLICIES
-- ============================================================================

-- Anyone can read incidents (public accountability data)
CREATE POLICY "Incidents are publicly readable"
    ON incidents FOR SELECT
    USING (true);

-- Anyone can insert incidents (anonymous reporting)
-- Rate limiting handled by device_token_hash at application level
CREATE POLICY "Anyone can report incidents"
    ON incidents FOR INSERT
    WITH CHECK (true);

-- No one can update incidents (immutable once submitted)
-- Disputes handled via separate mechanism
CREATE POLICY "Incidents are immutable"
    ON incidents FOR UPDATE
    USING (false);

-- No one can delete incidents (permanent record)
CREATE POLICY "Incidents cannot be deleted"
    ON incidents FOR DELETE
    USING (false);

-- ============================================================================
-- OFFICERS POLICIES
-- ============================================================================

-- Public read access
CREATE POLICY "Officers are publicly readable"
    ON officers FOR SELECT
    USING (true);

-- Insert via service role only (aggregated from incidents)
CREATE POLICY "Officers created via service role"
    ON officers FOR INSERT
    WITH CHECK (false); -- Service role bypasses RLS

-- Update via service role only
CREATE POLICY "Officers updated via service role"
    ON officers FOR UPDATE
    USING (false);

-- ============================================================================
-- POLICE SIGHTINGS POLICIES
-- ============================================================================

-- Public read for active sightings only
CREATE POLICY "Active sightings are readable"
    ON police_sightings FOR SELECT
    USING (is_active = true AND expires_at > NOW());

-- Anyone can report sightings
CREATE POLICY "Anyone can report sightings"
    ON police_sightings FOR INSERT
    WITH CHECK (true);

-- Allow confirm/not-there updates
CREATE POLICY "Community can validate sightings"
    ON police_sightings FOR UPDATE
    USING (is_active = true)
    WITH CHECK (is_active = true);

-- ============================================================================
-- COMMUNITY EXPERIENCES POLICIES
-- ============================================================================

-- Public read
CREATE POLICY "Experiences are publicly readable"
    ON community_experiences FOR SELECT
    USING (true);

-- Anyone can share experiences
CREATE POLICY "Anyone can share experiences"
    ON community_experiences FOR INSERT
    WITH CHECK (true);

-- No updates to experiences
CREATE POLICY "Experiences are immutable"
    ON community_experiences FOR UPDATE
    USING (false);

-- ============================================================================
-- DEPARTMENTS POLICIES
-- ============================================================================

-- Public read
CREATE POLICY "Departments are publicly readable"
    ON departments FOR SELECT
    USING (true);

-- Service role manages departments
CREATE POLICY "Departments managed by service"
    ON departments FOR INSERT
    WITH CHECK (false);

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Function to query incidents within a radius (miles)
CREATE OR REPLACE FUNCTION get_incidents_in_radius(
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION,
    radius_miles DOUBLE PRECISION DEFAULT 25
)
RETURNS SETOF incidents
LANGUAGE sql
STABLE
AS $$
    SELECT *
    FROM incidents
    WHERE ST_DWithin(
        location,
        ST_MakePoint(lng, lat)::geography,
        radius_miles * 1609.34  -- Convert miles to meters
    )
    ORDER BY created_at DESC;
$$;

-- Function to query sightings within a radius
CREATE OR REPLACE FUNCTION get_sightings_in_radius(
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION,
    radius_miles DOUBLE PRECISION DEFAULT 10
)
RETURNS SETOF police_sightings
LANGUAGE sql
STABLE
AS $$
    SELECT *
    FROM police_sightings
    WHERE is_active = true
      AND expires_at > NOW()
      AND ST_DWithin(
          location,
          ST_MakePoint(lng, lat)::geography,
          radius_miles * 1609.34
      )
    ORDER BY reported_at DESC;
$$;

-- Function to upsert officer from incident
CREATE OR REPLACE FUNCTION upsert_officer_from_incident()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF NEW.badge_number IS NOT NULL AND NEW.department IS NOT NULL THEN
        INSERT INTO officers (badge_number, department, reports_count, last_seen_at)
        VALUES (NEW.badge_number, NEW.department, 1, NOW())
        ON CONFLICT (badge_number)
        DO UPDATE SET
            reports_count = officers.reports_count + 1,
            last_seen_at = NOW(),
            updated_at = NOW();
    END IF;
    RETURN NEW;
END;
$$;

-- Trigger to auto-update officers table when incident reported
CREATE TRIGGER trigger_upsert_officer
    AFTER INSERT ON incidents
    FOR EACH ROW
    EXECUTE FUNCTION upsert_officer_from_incident();

-- Function to confirm a sighting (atomic increment + timestamp update)
CREATE OR REPLACE FUNCTION confirm_sighting(sighting_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE police_sightings
    SET confirm_count = confirm_count + 1,
        last_confirmed_at = NOW()
    WHERE id = sighting_id AND is_active = true;
END;
$$;

-- Function to mark a sighting as "not there" (atomic increment)
CREATE OR REPLACE FUNCTION mark_sighting_not_there(sighting_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE police_sightings
    SET not_there_count = not_there_count + 1
    WHERE id = sighting_id AND is_active = true;

    -- Auto-deactivate if too many "not there" votes
    UPDATE police_sightings
    SET is_active = false
    WHERE id = sighting_id
      AND not_there_count >= 3
      AND not_there_count > confirm_count;
END;
$$;

-- Function to clean up expired sightings
CREATE OR REPLACE FUNCTION cleanup_expired_sightings()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE police_sightings
    SET is_active = false
    WHERE expires_at < NOW() AND is_active = true;
END;
$$;

-- ============================================================================
-- CRON JOB FOR SIGHTING CLEANUP (Supabase pg_cron)
-- ============================================================================
-- Run every 5 minutes to mark expired sightings as inactive
-- Uncomment when pg_cron extension is available:
--
-- SELECT cron.schedule(
--     'cleanup-expired-sightings',
--     '*/5 * * * *',
--     'SELECT cleanup_expired_sightings()'
-- );

-- ============================================================================
-- PRIVACY-PRESERVING LOCATION TILES
-- ============================================================================
-- For "Home & Roam" feature - users subscribe to ~25mi tiles, not exact locations

CREATE OR REPLACE FUNCTION get_location_tile(
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION,
    tile_size_degrees DOUBLE PRECISION DEFAULT 0.5  -- ~35 miles at equator
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        FLOOR(lat / tile_size_degrees)::TEXT || ':' ||
        FLOOR(lng / tile_size_degrees)::TEXT;
$$;

-- ============================================================================
-- INITIAL SEED DATA
-- ============================================================================
-- Comment out for production

-- INSERT INTO departments (name, short_name, city, state, county)
-- VALUES
--     ('Los Angeles Police Department', 'LAPD', 'Los Angeles', 'CA', 'Los Angeles'),
--     ('New York Police Department', 'NYPD', 'New York', 'NY', 'New York'),
--     ('Chicago Police Department', 'CPD', 'Chicago', 'IL', 'Cook'),
--     ('Houston Police Department', 'HPD', 'Houston', 'TX', 'Harris');

-- ============================================================================
-- VERIFICATION QUERIES (Run to verify schema)
-- ============================================================================

-- Check PostGIS is working:
-- SELECT PostGIS_Version();

-- Check radius query works:
-- SELECT * FROM get_incidents_in_radius(34.0522, -118.2437, 25);

-- Check tile function:
-- SELECT get_location_tile(34.0522, -118.2437);

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
