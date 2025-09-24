-- PostgreSQL Database Schema for Rdio Scanner Monitor
-- This script creates all necessary tables, indexes, functions, and triggers
-- for the Rdio Scanner monitoring system

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "btree_gin";

-- Create schema for organization (optional, but recommended)
CREATE SCHEMA IF NOT EXISTS rdio_monitor;
SET search_path TO rdio_monitor, public;

-- Create enum types for better data consistency
CREATE TYPE call_priority AS ENUM ('low', 'normal', 'high', 'emergency');
CREATE TYPE call_status AS ENUM ('active', 'completed', 'archived', 'error');
CREATE TYPE audio_format AS ENUM ('mp3', 'wav', 'flac', 'aac');
CREATE TYPE processing_status AS ENUM ('pending', 'processing', 'completed', 'failed');

-- Main calls table for storing radio call metadata
CREATE TABLE calls (
    -- Primary key and unique identifiers
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id VARCHAR(255) UNIQUE NOT NULL,
    
    -- Temporal information
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Radio system information
    frequency DOUBLE PRECISION,
    talkgroup VARCHAR(100),
    source VARCHAR(100),
    system_name VARCHAR(255),
    
    -- Call characteristics
    duration DOUBLE PRECISION DEFAULT 0.0,
    call_type VARCHAR(100),
    priority call_priority DEFAULT 'normal',
    status call_status DEFAULT 'active',
    
    -- Organizational information
    department VARCHAR(255),
    agency VARCHAR(255),
    district VARCHAR(100),
    units TEXT[],
    
    -- Audio information
    audio_url TEXT,
    audio_file_path TEXT,
    audio_format audio_format,
    audio_duration DOUBLE PRECISION,
    audio_size BIGINT,
    audio_checksum VARCHAR(64),
    
    -- Processing status
    processed BOOLEAN DEFAULT FALSE,
    processing_status processing_status DEFAULT 'pending',
    processing_error TEXT,
    processing_attempts INTEGER DEFAULT 0,
    last_processing_attempt TIMESTAMP WITH TIME ZONE,
    
    -- Additional metadata stored as JSON
    metadata JSONB,
    tags TEXT[],
    
    -- Quality metrics
    signal_strength DOUBLE PRECISION,
    noise_level DOUBLE PRECISION,
    
    -- Geographic information (if available)
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    location_name VARCHAR(255),
    
    -- Archival and retention
    archived BOOLEAN DEFAULT FALSE,
    archive_date TIMESTAMP WITH TIME ZONE,
    retention_date TIMESTAMP WITH TIME ZONE,
    
    -- Record versioning
    version INTEGER DEFAULT 1
);

-- Create comprehensive indexes for performance optimization
CREATE INDEX idx_calls_call_id ON calls(call_id);
CREATE INDEX idx_calls_timestamp ON calls(timestamp DESC);
CREATE INDEX idx_calls_timestamp_range ON calls(timestamp) WHERE timestamp > NOW() - INTERVAL '30 days';
CREATE INDEX idx_calls_frequency ON calls(frequency) WHERE frequency IS NOT NULL;
CREATE INDEX idx_calls_talkgroup ON calls(talkgroup) WHERE talkgroup IS NOT NULL;
CREATE INDEX idx_calls_source ON calls(source) WHERE source IS NOT NULL;
CREATE INDEX idx_calls_system_name ON calls(system_name) WHERE system_name IS NOT NULL;
CREATE INDEX idx_calls_department ON calls(department) WHERE department IS NOT NULL;
CREATE INDEX idx_calls_call_type ON calls(call_type) WHERE call_type IS NOT NULL;
CREATE INDEX idx_calls_priority ON calls(priority);
CREATE INDEX idx_calls_status ON calls(status);
CREATE INDEX idx_calls_processed ON calls(processed);
CREATE INDEX idx_calls_processing_status ON calls(processing_status);
CREATE INDEX idx_calls_created_at ON calls(created_at DESC);
CREATE INDEX idx_calls_duration ON calls(duration) WHERE duration > 0;
CREATE INDEX idx_calls_archived ON calls(archived);
CREATE INDEX idx_calls_retention_date ON calls(retention_date) WHERE retention_date IS NOT NULL;

-- GIN indexes for array and JSONB columns
CREATE INDEX idx_calls_metadata_gin ON calls USING GIN(metadata);
CREATE INDEX idx_calls_units_gin ON calls USING GIN(units);
CREATE INDEX idx_calls_tags_gin ON calls USING GIN(tags);

-- Partial indexes for common queries
CREATE INDEX idx_calls_unprocessed ON calls(timestamp) WHERE processed = FALSE;
CREATE INDEX idx_calls_recent_errors ON calls(timestamp) WHERE processing_status = 'failed' AND timestamp > NOW() - INTERVAL '24 hours';
CREATE INDEX idx_calls_emergency ON calls(timestamp) WHERE priority = 'emergency';

-- Geographic index if PostGIS is available (optional)
-- CREATE INDEX idx_calls_location ON calls USING GIST(ST_Point(longitude, latitude)) WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- Audio files table for tracking audio file storage and processing
CREATE TABLE audio_files (
    -- Primary identifiers
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id VARCHAR(255) NOT NULL,
    
    -- File information
    original_url TEXT,
    local_path TEXT NOT NULL,
    filename VARCHAR(255),
    file_size BIGINT DEFAULT 0,
    format audio_format NOT NULL,
    
    -- Audio properties
    duration DOUBLE PRECISION DEFAULT 0.0,
    sample_rate INTEGER,
    channels INTEGER DEFAULT 1,
    bitrate INTEGER,
    codec VARCHAR(50),
    
    -- File integrity and verification
    checksum VARCHAR(64),
    checksum_algorithm VARCHAR(20) DEFAULT 'sha256',
    
    -- Processing information
    processed BOOLEAN DEFAULT FALSE,
    processing_status processing_status DEFAULT 'pending',
    processing_error TEXT,
    processing_start_time TIMESTAMP WITH TIME ZONE,
    processing_end_time TIMESTAMP WITH TIME ZONE,
    processing_duration DOUBLE PRECISION,
    
    -- Quality metrics
    audio_quality_score DOUBLE PRECISION,
    noise_reduction_applied BOOLEAN DEFAULT FALSE,
    normalization_applied BOOLEAN DEFAULT FALSE,
    compression_ratio DOUBLE PRECISION,
    
    -- Storage information
    storage_tier VARCHAR(50) DEFAULT 'standard',
    compressed BOOLEAN DEFAULT FALSE,
    encrypted BOOLEAN DEFAULT FALSE,
    
    -- Temporal tracking
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    accessed_at TIMESTAMP WITH TIME ZONE,
    access_count INTEGER DEFAULT 0,
    
    -- Archival and cleanup
    archived BOOLEAN DEFAULT FALSE,
    archive_location TEXT,
    delete_after TIMESTAMP WITH TIME ZONE,
    
    -- Foreign key constraint
    FOREIGN KEY (call_id) REFERENCES calls(call_id) ON DELETE CASCADE
);

-- Indexes for audio_files table
CREATE INDEX idx_audio_files_call_id ON audio_files(call_id);
CREATE INDEX idx_audio_files_local_path ON audio_files(local_path);
CREATE INDEX idx_audio_files_processed ON audio_files(processed);
CREATE INDEX idx_audio_files_processing_status ON audio_files(processing_status);
CREATE INDEX idx_audio_files_format ON audio_files(format);
CREATE INDEX idx_audio_files_created_at ON audio_files(created_at DESC);
CREATE INDEX idx_audio_files_file_size ON audio_files(file_size) WHERE file_size > 0;
CREATE INDEX idx_audio_files_checksum ON audio_files(checksum) WHERE checksum IS NOT NULL;
CREATE INDEX idx_audio_files_delete_after ON audio_files(delete_after) WHERE delete_after IS NOT NULL;

-- System statistics table for monitoring and analytics
CREATE TABLE system_stats (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Temporal information
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    period_start TIMESTAMP WITH TIME ZONE,
    period_end TIMESTAMP WITH TIME ZONE,
    collection_interval INTEGER DEFAULT 300, -- seconds
    
    -- Call processing statistics
    calls_processed INTEGER DEFAULT 0,
    calls_failed INTEGER DEFAULT 0,
    calls_per_second DOUBLE PRECISION DEFAULT 0.0,
    
    -- Audio processing statistics
    audio_files_processed INTEGER DEFAULT 0,
    audio_files_failed INTEGER DEFAULT 0,
    audio_processing_time_avg DOUBLE PRECISION DEFAULT 0.0,
    audio_processing_time_max DOUBLE PRECISION DEFAULT 0.0,
    
    -- Storage statistics
    total_storage_bytes BIGINT DEFAULT 0,
    audio_storage_bytes BIGINT DEFAULT 0,
    database_size_bytes BIGINT DEFAULT 0,
    storage_growth_rate DOUBLE PRECISION DEFAULT 0.0,
    
    -- Performance metrics
    avg_processing_time DOUBLE PRECISION DEFAULT 0.0,
    max_processing_time DOUBLE PRECISION DEFAULT 0.0,
    memory_usage_bytes BIGINT DEFAULT 0,
    cpu_usage_percent DOUBLE PRECISION DEFAULT 0.0,
    disk_io_read_bytes BIGINT DEFAULT 0,
    disk_io_write_bytes BIGINT DEFAULT 0,
    
    -- Error tracking
    error_count INTEGER DEFAULT 0,
    error_rate DOUBLE PRECISION DEFAULT 0.0,
    critical_errors INTEGER DEFAULT 0,
    
    -- API statistics
    api_requests INTEGER DEFAULT 0,
    api_errors INTEGER DEFAULT 0,
    api_response_time_avg DOUBLE PRECISION DEFAULT 0.0,
    api_rate_limit_hits INTEGER DEFAULT 0,
    
    -- Database statistics
    db_connections_active INTEGER DEFAULT 0,
    db_connections_max INTEGER DEFAULT 0,
    db_query_time_avg DOUBLE PRECISION DEFAULT 0.0,
    db_deadlocks INTEGER DEFAULT 0,
    
    -- System health indicators
    health_score DOUBLE PRECISION DEFAULT 100.0,
    uptime_seconds BIGINT DEFAULT 0,
    restart_count INTEGER DEFAULT 0,
    
    -- Additional metrics as JSON
    custom_metrics JSONB,
    
    -- Alert information
    alerts_triggered INTEGER DEFAULT 0,
    alert_details JSONB
);

-- Indexes for system_stats table
CREATE INDEX idx_system_stats_timestamp ON system_stats(timestamp DESC);
CREATE INDEX idx_system_stats_period ON system_stats(period_start, period_end);
CREATE INDEX idx_system_stats_collection_interval ON system_stats(collection_interval);
CREATE INDEX idx_system_stats_error_rate ON system_stats(error_rate) WHERE error_rate > 0;
CREATE INDEX idx_system_stats_health_score ON system_stats(health_score) WHERE health_score < 90;
CREATE INDEX idx_system_stats_custom_metrics_gin ON system_stats USING GIN(custom_metrics);

-- Alert rules table for configurable monitoring alerts
CREATE TABLE alert_rules (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Rule identification
    name VARCHAR(255) NOT NULL UNIQUE,
    description TEXT,
    category VARCHAR(100),
    
    -- Rule configuration
    enabled BOOLEAN DEFAULT TRUE,
    metric_name VARCHAR(255) NOT NULL,
    threshold_operator VARCHAR(10) NOT NULL, -- >, <, >=, <=, =, !=
    threshold_value DOUBLE PRECISION NOT NULL,
    evaluation_window INTEGER DEFAULT 300, -- seconds
    minimum_data_points INTEGER DEFAULT 1,
    
    -- Alert severity and actions
    severity VARCHAR(20) DEFAULT 'warning', -- info, warning, critical, emergency
    notification_channels TEXT[], -- email, slack, webhook, etc.
    escalation_rules JSONB,
    
    -- Temporal settings
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_triggered TIMESTAMP WITH TIME ZONE,
    trigger_count INTEGER DEFAULT 0,
    
    -- Suppression settings
    suppress_until TIMESTAMP WITH TIME ZONE,
    max_alerts_per_hour INTEGER DEFAULT 10,
    
    -- Additional configuration
    metadata JSONB
);

-- Indexes for alert_rules table
CREATE INDEX idx_alert_rules_enabled ON alert_rules(enabled) WHERE enabled = TRUE;
CREATE INDEX idx_alert_rules_metric_name ON alert_rules(metric_name);
CREATE INDEX idx_alert_rules_severity ON alert_rules(severity);
CREATE INDEX idx_alert_rules_last_triggered ON alert_rules(last_triggered);

-- Triggered alerts table for alert history
CREATE TABLE triggered_alerts (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Alert rule reference
    rule_id UUID NOT NULL,
    rule_name VARCHAR(255) NOT NULL,
    
    -- Alert details
    triggered_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE,
    severity VARCHAR(20) NOT NULL,
    status VARCHAR(20) DEFAULT 'active', -- active, acknowledged, resolved, suppressed
    
    -- Metric information
    metric_name VARCHAR(255) NOT NULL,
    metric_value DOUBLE PRECISION NOT NULL,
    threshold_value DOUBLE PRECISION NOT NULL,
    threshold_operator VARCHAR(10) NOT NULL,
    
    -- Context and details
    message TEXT,
    context JSONB,
    affected_components TEXT[],
    
    -- Response tracking
    acknowledged_by VARCHAR(255),
    acknowledged_at TIMESTAMP WITH TIME ZONE,
    resolved_by VARCHAR(255),
    resolution_notes TEXT,
    
    -- Notification tracking
    notifications_sent JSONB,
    escalation_level INTEGER DEFAULT 0,
    
    -- Foreign key constraint
    FOREIGN KEY (rule_id) REFERENCES alert_rules(id) ON DELETE CASCADE
);

-- Indexes for triggered_alerts table
CREATE INDEX idx_triggered_alerts_rule_id ON triggered_alerts(rule_id);
CREATE INDEX idx_triggered_alerts_triggered_at ON triggered_alerts(triggered_at DESC);
CREATE INDEX idx_triggered_alerts_severity ON triggered_alerts(severity);
CREATE INDEX idx_triggered_alerts_status ON triggered_alerts(status);
CREATE INDEX idx_triggered_alerts_metric_name ON triggered_alerts(metric_name);
CREATE INDEX idx_triggered_alerts_resolved_at ON triggered_alerts(resolved_at);

-- Configuration table for system settings
CREATE TABLE system_config (
    -- Configuration key-value pairs
    key VARCHAR(255) PRIMARY KEY,
    value TEXT NOT NULL,
    data_type VARCHAR(50) DEFAULT 'string', -- string, integer, float, boolean, json
    category VARCHAR(100),
    description TEXT,
    
    -- Validation and constraints
    min_value DOUBLE PRECISION,
    max_value DOUBLE PRECISION,
    allowed_values TEXT[],
    validation_regex VARCHAR(500),
    
    -- Temporal tracking
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_by VARCHAR(255),
    
    -- Configuration metadata
    sensitive BOOLEAN DEFAULT FALSE, -- For password/secret fields
    requires_restart BOOLEAN DEFAULT FALSE,
    environment VARCHAR(50) DEFAULT 'production'
);

-- Indexes for system_config table
CREATE INDEX idx_system_config_category ON system_config(category);
CREATE INDEX idx_system_config_data_type ON system_config(data_type);
CREATE INDEX idx_system_config_updated_at ON system_config(updated_at DESC);

-- System log table for application-level logging
CREATE TABLE system_logs (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Log entry details
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    level VARCHAR(20) NOT NULL, -- DEBUG, INFO, WARNING, ERROR, CRITICAL
    logger VARCHAR(255),
    message TEXT NOT NULL,
    
    -- Context information
    module VARCHAR(255),
    function VARCHAR(255),
    line_number INTEGER,
    call_id VARCHAR(255), -- Link to specific call if applicable
    
    -- Error details
    exception_type VARCHAR(255),
    exception_message TEXT,
    stack_trace TEXT,
    
    -- Additional context
    user_id VARCHAR(255),
    session_id VARCHAR(255),
    request_id VARCHAR(255),
    correlation_id VARCHAR(255),
    
    -- Structured data
    extra_data JSONB,
    tags TEXT[],
    
    -- Performance metrics
    execution_time DOUBLE PRECISION,
    memory_usage BIGINT,
    
    -- Geographic and network context
    ip_address INET,
    user_agent TEXT,
    hostname VARCHAR(255)
);

-- Indexes for system_logs table
CREATE INDEX idx_system_logs_timestamp ON system_logs(timestamp DESC);
CREATE INDEX idx_system_logs_level ON system_logs(level);
CREATE INDEX idx_system_logs_logger ON system_logs(logger);
CREATE INDEX idx_system_logs_call_id ON system_logs(call_id) WHERE call_id IS NOT NULL;
CREATE INDEX idx_system_logs_module_function ON system_logs(module, function);
CREATE INDEX idx_system_logs_correlation_id ON system_logs(correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_system_logs_tags_gin ON system_logs USING GIN(tags);
CREATE INDEX idx_system_logs_extra_data_gin ON system_logs USING GIN(extra_data);

-- Partial indexes for performance on large log tables
CREATE INDEX idx_system_logs_recent_errors ON system_logs(timestamp) 
    WHERE level IN ('ERROR', 'CRITICAL') AND timestamp > NOW() - INTERVAL '7 days';
CREATE INDEX idx_system_logs_recent_warnings ON system_logs(timestamp) 
    WHERE level = 'WARNING' AND timestamp > NOW() - INTERVAL '1 day';

-- Functions and triggers for automatic timestamp updates

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Triggers for updated_at columns
CREATE TRIGGER update_calls_updated_at
    BEFORE UPDATE ON calls
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_audio_files_updated_at
    BEFORE UPDATE ON audio_files
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_alert_rules_updated_at
    BEFORE UPDATE ON alert_rules
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_system_config_updated_at
    BEFORE UPDATE ON system_config
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function to calculate retention dates based on configuration
CREATE OR REPLACE FUNCTION calculate_retention_date(call_timestamp TIMESTAMP WITH TIME ZONE)
RETURNS TIMESTAMP WITH TIME ZONE AS $$
DECLARE
    retention_days INTEGER;
BEGIN
    -- Get retention days from system_config table
    SELECT COALESCE(value::INTEGER, 30) INTO retention_days
    FROM system_config
    WHERE key = 'data_retention_days';
    
    RETURN call_timestamp + (retention_days || ' days')::INTERVAL;
END;
$$ language 'plpgsql';

-- Trigger to automatically set retention date for new calls
CREATE OR REPLACE FUNCTION set_call_retention_date()
RETURNS TRIGGER AS $$
BEGIN
    NEW.retention_date = calculate_retention_date(NEW.timestamp);
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER set_calls_retention_date
    BEFORE INSERT OR UPDATE ON calls
    FOR EACH ROW
    EXECUTE FUNCTION set_call_retention_date();

-- Function for automatic data archival and cleanup
CREATE OR REPLACE FUNCTION cleanup_expired_records()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER := 0;
    archived_count INTEGER := 0;
BEGIN
    -- Archive old records before deletion
    UPDATE calls 
    SET archived = TRUE, archive_date = NOW()
    WHERE retention_date < NOW() 
      AND archived = FALSE;
    
    GET DIAGNOSTICS archived_count = ROW_COUNT;
    
    -- Delete very old archived records (older than 2x retention period)
    DELETE FROM calls 
    WHERE archive_date < NOW() - INTERVAL '60 days'
      AND archived = TRUE;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    -- Log cleanup activity
    INSERT INTO system_logs (level, logger, message, extra_data)
    VALUES (
        'INFO',
        'cleanup_function',
        'Automatic data cleanup completed',
        jsonb_build_object(
            'archived_records', archived_count,
            'deleted_records', deleted_count,
            'cleanup_timestamp', NOW()
        )
    );
    
    RETURN deleted_count + archived_count;
END;
$$ language 'plpgsql';

-- Views for common queries and reporting

-- View for recent call activity
CREATE VIEW recent_calls AS
SELECT 
    call_id,
    timestamp,
    frequency,
    talkgroup,
    source,
    duration,
    system_name,
    department,
    call_type,
    priority,
    processed,
    processing_status,
    audio_file_path IS NOT NULL as has_audio
FROM calls
WHERE timestamp > NOW() - INTERVAL '24 hours'
ORDER BY timestamp DESC;

-- View for system health summary
CREATE VIEW system_health_summary AS
SELECT 
    DATE_TRUNC('hour', timestamp) as hour,
    AVG(health_score) as avg_health_score,
    MAX(error_count) as max_errors,
    AVG(cpu_usage_percent) as avg_cpu_usage,
    AVG(memory_usage_bytes) / (1024*1024*1024) as avg_memory_gb,
    COUNT(*) as measurement_count
FROM system_stats
WHERE timestamp > NOW() - INTERVAL '24 hours'
GROUP BY DATE_TRUNC('hour', timestamp)
ORDER BY hour DESC;

-- View for call processing performance
CREATE VIEW processing_performance AS
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    COUNT(*) as total_calls,
    COUNT(*) FILTER (WHERE processed = TRUE) as processed_calls,
    COUNT(*) FILTER (WHERE processing_status = 'failed') as failed_calls,
    AVG(duration) as avg_call_duration,
    COUNT(DISTINCT system_name) as unique_systems,
    COUNT(DISTINCT talkgroup) as unique_talkgroups
FROM calls
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY DATE_TRUNC('hour', created_at)
ORDER BY hour DESC;

-- View for active alerts
CREATE VIEW active_alerts AS
SELECT 
    ta.id,
    ta.rule_name,
    ta.triggered_at,
    ta.severity,
    ta.status,
    ta.metric_name,
    ta.metric_value,
    ta.threshold_value,
    ta.threshold_operator,
    ta.message,
    ar.description as rule_description,
    ar.notification_channels
FROM triggered_alerts ta
JOIN alert_rules ar ON ta.rule_id = ar.id
WHERE ta.status IN ('active', 'acknowledged')
ORDER BY ta.triggered_at DESC;

-- Insert default configuration values
INSERT INTO system_config (key, value, data_type, category, description) VALUES
    ('data_retention_days', '30', 'integer', 'data_management', 'Number of days to retain call records'),
    ('max_audio_file_size_mb', '50', 'integer', 'audio', 'Maximum audio file size in MB'),
    ('audio_processing_enabled', 'true', 'boolean', 'audio', 'Enable audio processing and storage'),
    ('health_check_interval', '300', 'integer', 'monitoring', 'Health check interval in seconds'),
    ('log_retention_days', '7', 'integer', 'logging', 'Number of days to retain system logs'),
    ('api_rate_limit_per_minute', '1000', 'integer', 'api', 'API rate limit per minute'),
    ('backup_enabled', 'false', 'boolean', 'backup', 'Enable automatic database backups'),
    ('alert_notification_enabled', 'false', 'boolean', 'alerts', 'Enable alert notifications'),
    ('metrics_collection_interval', '60', 'integer', 'monitoring', 'Metrics collection interval in seconds')
ON CONFLICT (key) DO NOTHING;

-- Insert default alert rules
INSERT INTO alert_rules (name, description, metric_name, threshold_operator, threshold_value, severity, enabled) VALUES
    ('High Error Rate', 'Alert when error rate exceeds 5%', 'error_rate', '>', 0.05, 'warning', true),
    ('Low Disk Space', 'Alert when disk usage exceeds 85%', 'disk_usage_percent', '>', 85.0, 'warning', true),
    ('High Memory Usage', 'Alert when memory usage exceeds 90%', 'memory_usage_percent', '>', 90.0, 'critical', true),
    ('High CPU Usage', 'Alert when CPU usage exceeds 80%', 'cpu_usage_percent', '>', 80.0, 'warning', true),
    ('Processing Failures', 'Alert when processing failure rate is high', 'processing_failure_rate', '>', 0.1, 'critical', true),
    ('API Response Time', 'Alert when API response time is too high', 'api_response_time_avg', '>', 5.0, 'warning', true),
    ('Database Connection Issues', 'Alert when database connections are problematic', 'db_connection_errors', '>', 0, 'critical', true),
    ('Storage Growth Rate', 'Alert when storage is growing too quickly', 'storage_growth_rate_mb_per_hour', '>', 1000, 'warning', true),
    ('System Health Score', 'Alert when overall system health is degraded', 'health_score', '<', 70.0, 'critical', true)
ON CONFLICT (name) DO NOTHING;

-- Create partition tables for large data sets (optional optimization)
-- Partition system_stats by month for better performance on time-series data
-- Note: This requires PostgreSQL 10+ for native partitioning

-- Create partitioned table for system_stats (commented out for compatibility)
/*
CREATE TABLE system_stats_partitioned (
    LIKE system_stats INCLUDING ALL
) PARTITION BY RANGE (timestamp);

-- Create monthly partitions for the current and next few months
-- These would typically be created by a maintenance script
CREATE TABLE system_stats_2024_01 PARTITION OF system_stats_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
    
CREATE TABLE system_stats_2024_02 PARTITION OF system_stats_partitioned
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
*/

-- Create materialized views for performance on large datasets
CREATE MATERIALIZED VIEW daily_call_summary AS
SELECT 
    DATE_TRUNC('day', timestamp) as day,
    COUNT(*) as total_calls,
    COUNT(*) FILTER (WHERE processed = TRUE) as processed_calls,
    COUNT(*) FILTER (WHERE processing_status = 'failed') as failed_calls,
    COUNT(*) FILTER (WHERE priority = 'emergency') as emergency_calls,
    COUNT(DISTINCT system_name) as unique_systems,
    COUNT(DISTINCT talkgroup) as unique_talkgroups,
    COUNT(DISTINCT department) as unique_departments,
    AVG(duration) as avg_duration,
    SUM(duration) as total_duration,
    MIN(timestamp) as first_call_time,
    MAX(timestamp) as last_call_time,
    COUNT(*) FILTER (WHERE audio_file_path IS NOT NULL) as calls_with_audio,
    SUM(audio_size) FILTER (WHERE audio_size IS NOT NULL) as total_audio_bytes
FROM calls
GROUP BY DATE_TRUNC('day', timestamp);

-- Create index on the materialized view
CREATE UNIQUE INDEX idx_daily_call_summary_day ON daily_call_summary(day);

-- Create materialized view for talkgroup statistics
CREATE MATERIALIZED VIEW talkgroup_statistics AS
SELECT 
    talkgroup,
    system_name,
    department,
    COUNT(*) as total_calls,
    COUNT(*) FILTER (WHERE timestamp > NOW() - INTERVAL '24 hours') as calls_last_24h,
    COUNT(*) FILTER (WHERE timestamp > NOW() - INTERVAL '7 days') as calls_last_7d,
    COUNT(*) FILTER (WHERE priority = 'emergency') as emergency_calls,
    AVG(duration) as avg_duration,
    MAX(timestamp) as last_activity,
    COUNT(DISTINCT source) as unique_sources,
    array_agg(DISTINCT call_type) FILTER (WHERE call_type IS NOT NULL) as call_types
FROM calls
WHERE talkgroup IS NOT NULL
GROUP BY talkgroup, system_name, department;

-- Create indexes on talkgroup statistics
CREATE INDEX idx_talkgroup_stats_talkgroup ON talkgroup_statistics(talkgroup);
CREATE INDEX idx_talkgroup_stats_system ON talkgroup_statistics(system_name);
CREATE INDEX idx_talkgroup_stats_last_activity ON talkgroup_statistics(last_activity DESC);

-- Stored procedures for common operations

-- Procedure to refresh materialized views
CREATE OR REPLACE FUNCTION refresh_summary_views()
RETURNS VOID AS $
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY daily_call_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY talkgroup_statistics;
    
    INSERT INTO system_logs (level, logger, message)
    VALUES ('INFO', 'maintenance', 'Summary views refreshed successfully');
    
EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO system_logs (level, logger, message, exception_message)
        VALUES ('ERROR', 'maintenance', 'Failed to refresh summary views', SQLERRM);
        RAISE;
END;
$ LANGUAGE plpgsql;

-- Procedure to get system statistics for monitoring
CREATE OR REPLACE FUNCTION get_system_metrics()
RETURNS TABLE (
    metric_name VARCHAR(255),
    metric_value DOUBLE PRECISION,
    metric_unit VARCHAR(50),
    timestamp TIMESTAMP WITH TIME ZONE
) AS $
BEGIN
    RETURN QUERY
    SELECT 
        'total_calls'::VARCHAR(255),
        COUNT(*)::DOUBLE PRECISION,
        'count'::VARCHAR(50),
        NOW()
    FROM calls
    UNION ALL
    SELECT 
        'calls_last_hour'::VARCHAR(255),
        COUNT(*)::DOUBLE PRECISION,
        'count'::VARCHAR(50),
        NOW()
    FROM calls
    WHERE timestamp > NOW() - INTERVAL '1 hour'
    UNION ALL
    SELECT 
        'processing_failure_rate'::VARCHAR(255),
        (COUNT(*) FILTER (WHERE processing_status = 'failed')::DOUBLE PRECISION / 
         NULLIF(COUNT(*), 0))::DOUBLE PRECISION,
        'ratio'::VARCHAR(50),
        NOW()
    FROM calls
    WHERE timestamp > NOW() - INTERVAL '1 hour'
    UNION ALL
    SELECT 
        'database_size_mb'::VARCHAR(255),
        (pg_database_size(current_database())::DOUBLE PRECISION / (1024*1024))::DOUBLE PRECISION,
        'megabytes'::VARCHAR(50),
        NOW()
    UNION ALL
    SELECT 
        'table_sizes_mb'::VARCHAR(255),
        (pg_total_relation_size('calls')::DOUBLE PRECISION / (1024*1024))::DOUBLE PRECISION,
        'megabytes'::VARCHAR(50),
        NOW();
END;
$ LANGUAGE plpgsql;

-- Procedure to archive old data
CREATE OR REPLACE FUNCTION archive_old_data(retention_days INTEGER DEFAULT 30)
RETURNS TABLE (
    operation VARCHAR(50),
    records_affected INTEGER,
    execution_time INTERVAL
) AS $
DECLARE
    start_time TIMESTAMP;
    calls_archived INTEGER := 0;
    logs_deleted INTEGER := 0;
    stats_deleted INTEGER := 0;
    alerts_deleted INTEGER := 0;
BEGIN
    start_time := clock_timestamp();
    
    -- Archive old calls
    UPDATE calls 
    SET archived = TRUE, archive_date = NOW()
    WHERE timestamp < NOW() - (retention_days || ' days')::INTERVAL
      AND archived = FALSE;
    
    GET DIAGNOSTICS calls_archived = ROW_COUNT;
    
    RETURN QUERY SELECT 
        'calls_archived'::VARCHAR(50), 
        calls_archived, 
        clock_timestamp() - start_time;
    
    -- Delete old system logs (keep logs for half the retention period)
    DELETE FROM system_logs
    WHERE timestamp < NOW() - ((retention_days / 2) || ' days')::INTERVAL;
    
    GET DIAGNOSTICS logs_deleted = ROW_COUNT;
    
    RETURN QUERY SELECT 
        'logs_deleted'::VARCHAR(50), 
        logs_deleted, 
        clock_timestamp() - start_time;
    
    -- Delete old system stats (keep stats for double the retention period)
    DELETE FROM system_stats
    WHERE timestamp < NOW() - ((retention_days * 2) || ' days')::INTERVAL;
    
    GET DIAGNOSTICS stats_deleted = ROW_COUNT;
    
    RETURN QUERY SELECT 
        'stats_deleted'::VARCHAR(50), 
        stats_deleted, 
        clock_timestamp() - start_time;
    
    -- Clean up resolved alerts older than retention period
    DELETE FROM triggered_alerts
    WHERE resolved_at < NOW() - (retention_days || ' days')::INTERVAL
      AND status = 'resolved';
    
    GET DIAGNOSTICS alerts_deleted = ROW_COUNT;
    
    RETURN QUERY SELECT 
        'alerts_cleaned'::VARCHAR(50), 
        alerts_deleted, 
        clock_timestamp() - start_time;
    
    -- Log the archival operation
    INSERT INTO system_logs (level, logger, message, extra_data)
    VALUES (
        'INFO',
        'archival',
        'Data archival completed',
        jsonb_build_object(
            'retention_days', retention_days,
            'calls_archived', calls_archived,
            'logs_deleted', logs_deleted,
            'stats_deleted', stats_deleted,
            'alerts_cleaned', alerts_deleted,
            'execution_time_seconds', EXTRACT(EPOCH FROM (clock_timestamp() - start_time))
        )
    );
    
    -- Vacuum and analyze tables after cleanup
    VACUUM ANALYZE calls, system_logs, system_stats, triggered_alerts;
    
    RETURN QUERY SELECT 
        'vacuum_completed'::VARCHAR(50), 
        0, 
        clock_timestamp() - start_time;
END;
$ LANGUAGE plpgsql;

-- Procedure for database maintenance and optimization
CREATE OR REPLACE FUNCTION perform_maintenance()
RETURNS TABLE (
    task VARCHAR(100),
    status VARCHAR(50),
    details TEXT,
    execution_time INTERVAL
) AS $
DECLARE
    start_time TIMESTAMP;
    task_start TIMESTAMP;
BEGIN
    start_time := clock_timestamp();
    
    -- Refresh materialized views
    task_start := clock_timestamp();
    BEGIN
        PERFORM refresh_summary_views();
        RETURN QUERY SELECT 
            'refresh_views'::VARCHAR(100),
            'completed'::VARCHAR(50),
            'All materialized views refreshed'::TEXT,
            clock_timestamp() - task_start;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT 
                'refresh_views'::VARCHAR(100),
                'failed'::VARCHAR(50),
                SQLERRM::TEXT,
                clock_timestamp() - task_start;
    END;
    
    -- Update table statistics
    task_start := clock_timestamp();
    BEGIN
        ANALYZE calls, audio_files, system_stats, system_logs;
        RETURN QUERY SELECT 
            'analyze_tables'::VARCHAR(100),
            'completed'::VARCHAR(50),
            'Table statistics updated'::TEXT,
            clock_timestamp() - task_start;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT 
                'analyze_tables'::VARCHAR(100),
                'failed'::VARCHAR(50),
                SQLERRM::TEXT,
                clock_timestamp() - task_start;
    END;
    
    -- Clean up expired records
    task_start := clock_timestamp();
    BEGIN
        PERFORM cleanup_expired_records();
        RETURN QUERY SELECT 
            'cleanup_expired'::VARCHAR(100),
            'completed'::VARCHAR(50),
            'Expired records cleaned up'::TEXT,
            clock_timestamp() - task_start;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT 
                'cleanup_expired'::VARCHAR(100),
                'failed'::VARCHAR(50),
                SQLERRM::TEXT,
                clock_timestamp() - task_start;
    END;
    
    -- Reindex critical tables if needed
    task_start := clock_timestamp();
    BEGIN
        -- Only reindex if fragmentation is significant
        -- This is a simplified check - production systems might need more sophisticated logic
        REINDEX INDEX idx_calls_timestamp, idx_calls_call_id;
        RETURN QUERY SELECT 
            'reindex_critical'::VARCHAR(100),
            'completed'::VARCHAR(50),
            'Critical indexes rebuilt'::TEXT,
            clock_timestamp() - task_start;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT 
                'reindex_critical'::VARCHAR(100),
                'failed'::VARCHAR(50),
                SQLERRM::TEXT,
                clock_timestamp() - task_start;
    END;
    
    -- Log maintenance completion
    INSERT INTO system_logs (level, logger, message, extra_data)
    VALUES (
        'INFO',
        'maintenance',
        'Database maintenance completed',
        jsonb_build_object(
            'total_execution_time_seconds', EXTRACT(EPOCH FROM (clock_timestamp() - start_time))
        )
    );
    
END;
$ LANGUAGE plpgsql;

-- Security: Create roles and permissions

-- Create read-only role for monitoring and reporting
CREATE ROLE rdio_monitor_readonly;
GRANT CONNECT ON DATABASE rdio_scanner TO rdio_monitor_readonly;
GRANT USAGE ON SCHEMA rdio_monitor TO rdio_monitor_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA rdio_monitor TO rdio_monitor_readonly;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA rdio_monitor TO rdio_monitor_readonly;

-- Create application role with limited permissions
CREATE ROLE rdio_monitor_app;
GRANT CONNECT ON DATABASE rdio_scanner TO rdio_monitor_app;
GRANT USAGE ON SCHEMA rdio_monitor TO rdio_monitor_app;
GRANT SELECT, INSERT, UPDATE ON calls, audio_files, system_stats, system_logs TO rdio_monitor_app;
GRANT SELECT, INSERT, UPDATE ON triggered_alerts TO rdio_monitor_app;
GRANT SELECT ON alert_rules, system_config TO rdio_monitor_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA rdio_monitor TO rdio_monitor_app;

-- Create admin role with full permissions
CREATE ROLE rdio_monitor_admin;
GRANT CONNECT ON DATABASE rdio_scanner TO rdio_monitor_admin;
GRANT ALL ON SCHEMA rdio_monitor TO rdio_monitor_admin;
GRANT ALL ON ALL TABLES IN SCHEMA rdio_monitor TO rdio_monitor_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA rdio_monitor TO rdio_monitor_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA rdio_monitor TO rdio_monitor_admin;

-- Row Level Security (RLS) policies (optional, for multi-tenant scenarios)
-- Uncomment and modify as needed for specific security requirements

/*
-- Enable RLS on sensitive tables
ALTER TABLE calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE audio_files ENABLE ROW LEVEL SECURITY;

-- Create policy for department-based access
CREATE POLICY calls_department_policy ON calls
    FOR ALL TO rdio_monitor_app
    USING (department = current_setting('app.current_department', true));

CREATE POLICY audio_files_department_policy ON audio_files
    FOR ALL TO rdio_monitor_app
    USING (
        call_id IN (
            SELECT call_id FROM calls 
            WHERE department = current_setting('app.current_department', true)
        )
    );
*/

-- Create helpful utility functions for application use

-- Function to get call statistics for a specific time range
CREATE OR REPLACE FUNCTION get_call_stats(
    start_time TIMESTAMP WITH TIME ZONE,
    end_time TIMESTAMP WITH TIME ZONE DEFAULT NOW()
)
RETURNS TABLE (
    total_calls BIGINT,
    processed_calls BIGINT,
    failed_calls BIGINT,
    avg_duration DOUBLE PRECISION,
    total_duration DOUBLE PRECISION,
    unique_talkgroups BIGINT,
    unique_sources BIGINT,
    emergency_calls BIGINT,
    calls_with_audio BIGINT
) AS $
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*),
        COUNT(*) FILTER (WHERE processed = TRUE),
        COUNT(*) FILTER (WHERE processing_status = 'failed'),
        AVG(calls.duration),
        SUM(calls.duration),
        COUNT(DISTINCT calls.talkgroup),
        COUNT(DISTINCT calls.source),
        COUNT(*) FILTER (WHERE priority = 'emergency'),
        COUNT(*) FILTER (WHERE audio_file_path IS NOT NULL)
    FROM calls
    WHERE timestamp BETWEEN start_time AND end_time;
END;
$ LANGUAGE plpgsql;

-- Function to search calls with full-text search capabilities
CREATE OR REPLACE FUNCTION search_calls(
    search_term TEXT,
    limit_count INTEGER DEFAULT 100,
    offset_count INTEGER DEFAULT 0
)
RETURNS TABLE (
    call_id VARCHAR(255),
    timestamp TIMESTAMP WITH TIME ZONE,
    talkgroup VARCHAR(100),
    source VARCHAR(100),
    system_name VARCHAR(255),
    department VARCHAR(255),
    call_type VARCHAR(100),
    duration DOUBLE PRECISION,
    relevance_score DOUBLE PRECISION
) AS $
BEGIN
    RETURN QUERY
    SELECT 
        c.call_id,
        c.timestamp,
        c.talkgroup,
        c.source,
        c.system_name,
        c.department,
        c.call_type,
        c.duration,
        -- Simple relevance scoring based on field matches
        (
            CASE WHEN c.talkgroup ILIKE '%' || search_term || '%' THEN 1.0 ELSE 0.0 END +
            CASE WHEN c.source ILIKE '%' || search_term || '%' THEN 0.8 ELSE 0.0 END +
            CASE WHEN c.system_name ILIKE '%' || search_term || '%' THEN 0.6 ELSE 0.0 END +
            CASE WHEN c.department ILIKE '%' || search_term || '%' THEN 0.6 ELSE 0.0 END +
            CASE WHEN c.call_type ILIKE '%' || search_term || '%' THEN 0.4 ELSE 0.0 END +
            CASE WHEN c.metadata::TEXT ILIKE '%' || search_term || '%' THEN 0.2 ELSE 0.0 END
        ) as relevance_score
    FROM calls c
    WHERE 
        c.talkgroup ILIKE '%' || search_term || '%' OR
        c.source ILIKE '%' || search_term || '%' OR
        c.system_name ILIKE '%' || search_term || '%' OR
        c.department ILIKE '%' || search_term || '%' OR
        c.call_type ILIKE '%' || search_term || '%' OR
        c.metadata::TEXT ILIKE '%' || search_term || '%'
    ORDER BY relevance_score DESC, timestamp DESC
    LIMIT limit_count
    OFFSET offset_count;
END;
$ LANGUAGE plpgsql;

-- Final optimizations and comments

-- Create partial indexes for common filtered queries
CREATE INDEX idx_calls_emergency_recent ON calls(timestamp DESC) 
    WHERE priority = 'emergency' AND timestamp > NOW() - INTERVAL '30 days';

CREATE INDEX idx_calls_unprocessed_recent ON calls(timestamp ASC) 
    WHERE processed = FALSE AND timestamp > NOW() - INTERVAL '7 days';

-- Optimize PostgreSQL configuration for time-series workload
-- These are suggestions that should be added to postgresql.conf:
/*
-- Increase shared buffers for better caching
shared_buffers = 256MB

-- Optimize for write-heavy workload
wal_buffers = 16MB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.7

-- Improve query performance for time-series data
effective_cache_size = 1GB
random_page_cost = 1.1

-- Enable auto-vacuum tuning for large tables
autovacuum = on
autovacuum_max_workers = 4
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05

-- Log slow queries for monitoring
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
*/

-- Add comments to important tables for documentation
COMMENT ON TABLE calls IS 'Main table storing radio call metadata and processing information';
COMMENT ON TABLE audio_files IS 'Tracking table for audio file storage and processing status';
COMMENT ON TABLE system_stats IS 'Time-series data for system performance monitoring';
COMMENT ON TABLE alert_rules IS 'Configuration for automated monitoring alerts';
COMMENT ON TABLE triggered_alerts IS 'History of triggered alerts and their resolution';
COMMENT ON TABLE system_config IS 'Application configuration stored in database';
COMMENT ON TABLE system_logs IS 'Application-level logging for debugging and auditing';

-- Add column comments for key fields
COMMENT ON COLUMN calls.call_id IS 'Unique identifier from the source Rdio Scanner system';
COMMENT ON COLUMN calls.timestamp IS 'When the radio call occurred (source timestamp)';
COMMENT ON COLUMN calls.metadata IS 'Complete JSON data from the source API for forensic purposes';
COMMENT ON COLUMN calls.retention_date IS 'Calculated date when this record should be archived or deleted';
COMMENT ON COLUMN calls.processing_status IS 'Current status of audio processing pipeline';

-- Log schema initialization
INSERT INTO system_logs (level, logger, message, extra_data)
VALUES (
    'INFO',
    'schema_init',
    'Database schema initialized successfully',
    jsonb_build_object(
        'version', '1.0.0',
        'initialized_at', NOW(),
        'features', jsonb_build_array(
            'call_tracking',
            'audio_processing',
            'system_monitoring',
            'alerting',
            'configuration_management',
            'automated_maintenance'
        )
    )
);

-- Success message
SELECT 'Rdio Scanner Monitor database schema initialization completed successfully!' as status;