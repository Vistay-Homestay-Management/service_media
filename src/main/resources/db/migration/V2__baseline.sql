SET search_path TO app, extensions, public;

CREATE TABLE upload_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_by_account_type varchar(16) NOT NULL,
    requested_by_account_id uuid NOT NULL,
    owner_service varchar(64) NOT NULL,
    expected_file_count integer NOT NULL DEFAULT 1,
    uploaded_file_count integer NOT NULL DEFAULT 0,
    max_total_size_bytes bigint NOT NULL,
    uploaded_size_bytes bigint NOT NULL DEFAULT 0,
    status varchar(24) NOT NULL DEFAULT 'PENDING',
    expires_at timestamptz NOT NULL,
    completed_at timestamptz,
    cancelled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_upload_account_type CHECK (requested_by_account_type IN ('CUSTOMER', 'ADMIN', 'HOST', 'SYSTEM')),
    CONSTRAINT ck_upload_counts CHECK (expected_file_count > 0 AND uploaded_file_count >= 0 AND uploaded_file_count <= expected_file_count),
    CONSTRAINT ck_upload_sizes CHECK (max_total_size_bytes > 0 AND uploaded_size_bytes >= 0 AND uploaded_size_bytes <= max_total_size_bytes),
    CONSTRAINT ck_upload_status CHECK (status IN ('PENDING', 'UPLOADING', 'UPLOADED', 'COMPLETED', 'EXPIRED', 'CANCELLED')),
    CONSTRAINT ck_upload_expiry CHECK (expires_at > created_at)
);
CREATE INDEX ix_upload_session_expiry ON upload_sessions(status, expires_at) WHERE status IN ('PENDING', 'UPLOADING', 'UPLOADED');

CREATE TABLE media_assets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    upload_session_id uuid REFERENCES upload_sessions(id) ON DELETE SET NULL,
    original_filename varchar(260) NOT NULL,
    storage_bucket varchar(100) NOT NULL,
    storage_key varchar(1024) NOT NULL,
    mime_type varchar(120) NOT NULL,
    file_size_bytes bigint NOT NULL,
    checksum_sha256 char(64) NOT NULL,
    etag varchar(180),
    visibility varchar(16) NOT NULL DEFAULT 'PRIVATE',
    status varchar(24) NOT NULL DEFAULT 'PENDING_UPLOAD',
    scan_status varchar(24) NOT NULL DEFAULT 'PENDING',
    width_pixels integer,
    height_pixels integer,
    duration_milliseconds bigint,
    uploaded_by_account_type varchar(16) NOT NULL,
    uploaded_by_account_id uuid NOT NULL,
    captured_at timestamptz,
    uploaded_at timestamptz,
    available_at timestamptz,
    retention_until timestamptz,
    deleted_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    version bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_media_file_size CHECK (file_size_bytes > 0),
    CONSTRAINT ck_media_visibility CHECK (visibility IN ('PUBLIC', 'PRIVATE')),
    CONSTRAINT ck_media_status CHECK (status IN ('PENDING_UPLOAD', 'UPLOADED', 'PROCESSING', 'AVAILABLE', 'QUARANTINED', 'FAILED', 'DELETION_PENDING', 'DELETED')),
    CONSTRAINT ck_media_scan_status CHECK (scan_status IN ('PENDING', 'CLEAN', 'INFECTED', 'FAILED', 'SKIPPED')),
    CONSTRAINT ck_media_dimensions CHECK (
        (width_pixels IS NULL OR width_pixels > 0)
        AND (height_pixels IS NULL OR height_pixels > 0)
        AND (duration_milliseconds IS NULL OR duration_milliseconds >= 0)
    ),
    CONSTRAINT ck_media_uploader_type CHECK (uploaded_by_account_type IN ('CUSTOMER', 'ADMIN', 'HOST', 'SYSTEM')),
    CONSTRAINT ck_media_metadata CHECK (jsonb_typeof(metadata) = 'object'),
    CONSTRAINT ck_media_deletion CHECK ((status = 'DELETED' AND deleted_at IS NOT NULL) OR status <> 'DELETED'),
    UNIQUE (storage_bucket, storage_key)
);
CREATE INDEX ix_media_checksum ON media_assets(checksum_sha256, file_size_bytes);
CREATE INDEX ix_media_processing_queue ON media_assets(status, scan_status, created_at) WHERE status IN ('UPLOADED', 'PROCESSING', 'FAILED');

CREATE TABLE media_variants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    media_asset_id uuid NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
    variant_type varchar(32) NOT NULL,
    storage_bucket varchar(100) NOT NULL,
    storage_key varchar(1024) NOT NULL,
    mime_type varchar(120) NOT NULL,
    file_size_bytes bigint NOT NULL,
    checksum_sha256 char(64) NOT NULL,
    width_pixels integer,
    height_pixels integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_media_variant_type CHECK (variant_type IN ('THUMBNAIL_SMALL', 'THUMBNAIL_MEDIUM', 'WEB_OPTIMIZED', 'PREVIEW')),
    CONSTRAINT ck_media_variant_size CHECK (file_size_bytes > 0),
    CONSTRAINT ck_media_variant_dimensions CHECK ((width_pixels IS NULL OR width_pixels > 0) AND (height_pixels IS NULL OR height_pixels > 0)),
    UNIQUE (media_asset_id, variant_type),
    UNIQUE (storage_bucket, storage_key)
);

CREATE TABLE media_processing_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    media_asset_id uuid NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
    job_type varchar(32) NOT NULL,
    status varchar(24) NOT NULL DEFAULT 'PENDING',
    attempt_count integer NOT NULL DEFAULT 0,
    maximum_attempts integer NOT NULL DEFAULT 5,
    next_retry_at timestamptz,
    started_at timestamptz,
    completed_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_media_job_type CHECK (job_type IN ('VERIFY_UPLOAD', 'MALWARE_SCAN', 'EXTRACT_METADATA', 'CREATE_THUMBNAILS', 'STRIP_METADATA', 'DELETE_OBJECTS')),
    CONSTRAINT ck_media_job_status CHECK (status IN ('PENDING', 'RUNNING', 'RETRY_WAIT', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    CONSTRAINT ck_media_job_attempts CHECK (attempt_count >= 0 AND maximum_attempts > 0 AND attempt_count <= maximum_attempts)
);
CREATE INDEX ix_media_job_queue ON media_processing_jobs(status, next_retry_at, created_at) WHERE status IN ('PENDING', 'RETRY_WAIT');

CREATE TABLE media_deletion_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    media_asset_id uuid NOT NULL REFERENCES media_assets(id),
    requested_by_account_type varchar(16) NOT NULL,
    requested_by_account_id uuid NOT NULL,
    reason varchar(1000) NOT NULL,
    status varchar(24) NOT NULL DEFAULT 'REQUESTED',
    not_before timestamptz NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT now(),
    approved_at timestamptz,
    completed_at timestamptz,
    rejection_reason varchar(1000),
    CONSTRAINT ck_media_delete_actor CHECK (requested_by_account_type IN ('ADMIN', 'SYSTEM')),
    CONSTRAINT ck_media_delete_status CHECK (status IN ('REQUESTED', 'REFERENCE_CHECK', 'APPROVED', 'REJECTED', 'COMPLETED', 'CANCELLED')),
    CONSTRAINT ck_media_delete_schedule CHECK (not_before >= requested_at)
);
CREATE INDEX ix_media_deletion_queue ON media_deletion_requests(status, not_before) WHERE status IN ('REQUESTED', 'REFERENCE_CHECK', 'APPROVED');

CREATE TABLE media_access_audit (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    media_asset_id uuid NOT NULL REFERENCES media_assets(id),
    actor_account_type varchar(16),
    actor_account_id uuid,
    action varchar(24) NOT NULL,
    purpose varchar(500),
    ip_address inet,
    correlation_id varchar(100),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_media_access_actor_type CHECK (actor_account_type IS NULL OR actor_account_type IN ('CUSTOMER', 'ADMIN', 'HOST', 'SYSTEM')),
    CONSTRAINT ck_media_access_actor_pair CHECK ((actor_account_type IS NULL) = (actor_account_id IS NULL)),
    CONSTRAINT ck_media_access_action CHECK (action IN ('UPLOAD', 'VIEW', 'DOWNLOAD', 'PRESIGN', 'DELETE_REQUEST', 'DELETE', 'RESTORE'))
);
CREATE INDEX ix_media_access_timeline ON media_access_audit(media_asset_id, occurred_at DESC);

CREATE TABLE processed_events (
    event_id uuid NOT NULL,
    consumer_name varchar(120) NOT NULL,
    processed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, consumer_name)
);

CREATE TABLE outbox_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type varchar(100) NOT NULL,
    aggregate_id uuid NOT NULL,
    aggregate_version bigint NOT NULL CHECK (aggregate_version >= 0),
    event_type varchar(160) NOT NULL,
    event_version integer NOT NULL DEFAULT 1 CHECK (event_version > 0),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    available_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    publish_attempts integer NOT NULL DEFAULT 0 CHECK (publish_attempts >= 0),
    last_error text,
    correlation_id varchar(100),
    causation_id varchar(100)
);
CREATE INDEX ix_media_outbox_pending ON outbox_events(available_at, occurred_at) WHERE published_at IS NULL;
