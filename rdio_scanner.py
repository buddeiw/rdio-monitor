#!/usr/bin/env python3
"""
Rdio Scanner Monitor Application

This application monitors a specified Rdio Scanner domain for new calls,
logs call metadata to PostgreSQL database, and captures audio files.
Designed to run as a long-running service with proper error handling,
logging, and monitoring capabilities.

Author: System Administrator
Version: 1.0.0
License: MIT

Dependencies:
    - requests: HTTP client library for API calls
    - psycopg2-binary: PostgreSQL database adapter
    - pydub: Audio processing and manipulation
    - schedule: Task scheduling library
"""

import sys
import os
import time
import json
import logging
import configparser
import signal
import threading
from datetime import datetime, timezone, timedelta
from typing import Dict, List, Optional, Any
from pathlib import Path
from dataclasses import dataclass, asdict
from urllib.parse import urljoin, urlparse
import hashlib
import uuid

# Third-party imports
import requests
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry
import psycopg2
from psycopg2.extras import RealDictCursor, execute_values
from psycopg2.pool import ThreadedConnectionPool
import schedule
from pydub import AudioSegment
from pydub.utils import which

# Configure logging format and level
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(funcName)s:%(lineno)d - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


@dataclass
class CallRecord:
    """
    Data class representing a single call record from Rdio Scanner.
    
    This class encapsulates all metadata associated with a radio call,
    including timing information, frequency details, source identifiers,
    and audio processing status.
    """
    call_id: str                    # Unique identifier for the call
    timestamp: datetime             # When the call occurred
    frequency: float               # Radio frequency in Hz
    talkgroup: Optional[str]       # Talkgroup identifier
    source: Optional[str]          # Source radio identifier
    duration: float                # Call duration in seconds
    audio_url: Optional[str]       # URL to audio file
    audio_file_path: Optional[str] # Local path to downloaded audio
    system_name: Optional[str]     # Radio system name
    department: Optional[str]      # Department or agency
    call_type: Optional[str]       # Type of call (emergency, routine, etc.)
    units: Optional[List[str]]     # Units involved in the call
    metadata: Optional[Dict]       # Additional metadata from API
    processed: bool = False        # Whether audio has been processed
    created_at: Optional[datetime] = None  # When record was created locally
    
    def __post_init__(self):
        """Post-initialization processing for the CallRecord."""
        if self.created_at is None:
            self.created_at = datetime.now(timezone.utc)
        
        # Ensure timestamp has timezone info
        if self.timestamp and self.timestamp.tzinfo is None:
            self.timestamp = self.timestamp.replace(tzinfo=timezone.utc)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert CallRecord to dictionary for database storage."""
        data = asdict(self)
        # Convert datetime objects to ISO format strings
        for key, value in data.items():
            if isinstance(value, datetime):
                data[key] = value.isoformat()
        return data


class DatabaseManager:
    """
    Manages all database operations for the Rdio Scanner Monitor.
    
    This class handles connection pooling, schema management, and CRUD operations
    for call records. It includes proper error handling, connection recovery,
    and performance optimization features.
    """
    
    def __init__(self, config: configparser.ConfigParser):
        """
        Initialize database manager with configuration.
        
        Args:
            config: ConfigParser object containing database settings
        """
        self.config = config
        self.connection_pool = None
        self.lock = threading.Lock()
        
        # Database connection parameters
        self.db_params = {
            'host': config.get('database', 'host'),
            'port': config.getint('database', 'port'),
            'database': config.get('database', 'database'),
            'user': config.get('database', 'username'),
            'password': config.get('database', 'password'),
            'connect_timeout': config.getint('database', 'connect_timeout'),
        }
        
        # Add SSL configuration if enabled
        if config.getboolean('database', 'ssl_enabled'):
            self.db_params.update({
                'sslmode': 'require',
                'sslcert': config.get('database', 'ssl_cert_path'),
                'sslkey': config.get('database', 'ssl_key_path'),
            })
        
        self._initialize_connection_pool()
        self._initialize_schema()
    
    def _initialize_connection_pool(self):
        """Initialize the database connection pool."""
        try:
            pool_size = self.config.getint('database', 'pool_size')
            self.connection_pool = ThreadedConnectionPool(
                minconn=1,
                maxconn=pool_size,
                **self.db_params
            )
            logger.info(f"Database connection pool initialized with {pool_size} connections")
        except psycopg2.Error as e:
            logger.error(f"Failed to initialize database connection pool: {e}")
            raise
    
    def _initialize_schema(self):
        """Initialize database schema if it doesn't exist."""
        schema_sql = """
        -- Create extension for UUID generation if not exists
        CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
        
        -- Create calls table for storing call metadata
        CREATE TABLE IF NOT EXISTS calls (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            call_id VARCHAR(255) UNIQUE NOT NULL,
            timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
            frequency DOUBLE PRECISION,
            talkgroup VARCHAR(100),
            source VARCHAR(100),
            duration DOUBLE PRECISION,
            audio_url TEXT,
            audio_file_path TEXT,
            system_name VARCHAR(255),
            department VARCHAR(255),
            call_type VARCHAR(100),
            units TEXT[],
            metadata JSONB,
            processed BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
            updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        );
        
        -- Create indexes for performance optimization
        CREATE INDEX IF NOT EXISTS idx_calls_call_id ON calls(call_id);
        CREATE INDEX IF NOT EXISTS idx_calls_timestamp ON calls(timestamp);
        CREATE INDEX IF NOT EXISTS idx_calls_frequency ON calls(frequency);
        CREATE INDEX IF NOT EXISTS idx_calls_talkgroup ON calls(talkgroup);
        CREATE INDEX IF NOT EXISTS idx_calls_system_name ON calls(system_name);
        CREATE INDEX IF NOT EXISTS idx_calls_processed ON calls(processed);
        CREATE INDEX IF NOT EXISTS idx_calls_created_at ON calls(created_at);
        
        -- Create GIN index for JSONB metadata column
        CREATE INDEX IF NOT EXISTS idx_calls_metadata_gin ON calls USING GIN(metadata);
        
        -- Create audio_files table for tracking audio file storage
        CREATE TABLE IF NOT EXISTS audio_files (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            call_id VARCHAR(255) REFERENCES calls(call_id),
            original_url TEXT,
            local_path TEXT,
            file_size BIGINT,
            format VARCHAR(10),
            duration DOUBLE PRECISION,
            sample_rate INTEGER,
            channels INTEGER,
            bitrate INTEGER,
            checksum VARCHAR(64),
            processed BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        );
        
        -- Create indexes for audio_files table
        CREATE INDEX IF NOT EXISTS idx_audio_files_call_id ON audio_files(call_id);
        CREATE INDEX IF NOT EXISTS idx_audio_files_processed ON audio_files(processed);
        
        -- Create system_stats table for monitoring
        CREATE TABLE IF NOT EXISTS system_stats (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
            calls_processed INTEGER,
            audio_files_processed INTEGER,
            total_storage_bytes BIGINT,
            avg_processing_time DOUBLE PRECISION,
            error_count INTEGER,
            metadata JSONB
        );
        
        -- Create index for system_stats timestamp
        CREATE INDEX IF NOT EXISTS idx_system_stats_timestamp ON system_stats(timestamp);
        
        -- Create function to update updated_at timestamp
        CREATE OR REPLACE FUNCTION update_updated_at_column()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.updated_at = NOW();
            RETURN NEW;
        END;
        $$ language 'plpgsql';
        
        -- Create trigger for calls table
        DROP TRIGGER IF EXISTS update_calls_updated_at ON calls;
        CREATE TRIGGER update_calls_updated_at
            BEFORE UPDATE ON calls
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at_column();
        """
        
        try:
            with self.get_connection() as conn:
                with conn.cursor() as cursor:
                    cursor.execute(schema_sql)
                conn.commit()
            logger.info("Database schema initialized successfully")
        except psycopg2.Error as e:
            logger.error(f"Failed to initialize database schema: {e}")
            raise
    
    def get_connection(self):
        """Get a database connection from the pool."""
        try:
            return self.connection_pool.getconn()
        except psycopg2.Error as e:
            logger.error(f"Failed to get database connection: {e}")
            raise
    
    def return_connection(self, conn):
        """Return a database connection to the pool."""
        try:
            self.connection_pool.putconn(conn)
        except psycopg2.Error as e:
            logger.error(f"Failed to return database connection: {e}")
    
    def insert_call_record(self, call_record: CallRecord) -> bool:
        """
        Insert a call record into the database.
        
        Args:
            call_record: CallRecord object to insert
            
        Returns:
            bool: True if insert was successful, False otherwise
        """
        insert_sql = """
        INSERT INTO calls (
            call_id, timestamp, frequency, talkgroup, source, duration,
            audio_url, audio_file_path, system_name, department, call_type,
            units, metadata, processed
        ) VALUES (
            %(call_id)s, %(timestamp)s, %(frequency)s, %(talkgroup)s, %(source)s,
            %(duration)s, %(audio_url)s, %(audio_file_path)s, %(system_name)s,
            %(department)s, %(call_type)s, %(units)s, %(metadata)s, %(processed)s
        ) ON CONFLICT (call_id) DO UPDATE SET
            timestamp = EXCLUDED.timestamp,
            frequency = EXCLUDED.frequency,
            talkgroup = EXCLUDED.talkgroup,
            source = EXCLUDED.source,
            duration = EXCLUDED.duration,
            audio_url = EXCLUDED.audio_url,
            audio_file_path = EXCLUDED.audio_file_path,
            system_name = EXCLUDED.system_name,
            department = EXCLUDED.department,
            call_type = EXCLUDED.call_type,
            units = EXCLUDED.units,
            metadata = EXCLUDED.metadata,
            processed = EXCLUDED.processed,
            updated_at = NOW()
        """
        
        try:
            conn = self.get_connection()
            try:
                with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                    # Convert CallRecord to dictionary for database insertion
                    record_dict = call_record.to_dict()
                    # Convert metadata to JSON if it exists
                    if record_dict.get('metadata'):
                        record_dict['metadata'] = json.dumps(record_dict['metadata'])
                    
                    cursor.execute(insert_sql, record_dict)
                conn.commit()
                logger.debug(f"Successfully inserted call record: {call_record.call_id}")
                return True
            finally:
                self.return_connection(conn)
        except psycopg2.Error as e:
            logger.error(f"Failed to insert call record {call_record.call_id}: {e}")
            return False
    
    def insert_call_records_batch(self, call_records: List[CallRecord]) -> int:
        """
        Insert multiple call records in a batch operation.
        
        Args:
            call_records: List of CallRecord objects to insert
            
        Returns:
            int: Number of records successfully inserted
        """
        if not call_records:
            return 0
        
        insert_sql = """
        INSERT INTO calls (
            call_id, timestamp, frequency, talkgroup, source, duration,
            audio_url, audio_file_path, system_name, department, call_type,
            units, metadata, processed
        ) VALUES %s
        ON CONFLICT (call_id) DO UPDATE SET
            timestamp = EXCLUDED.timestamp,
            frequency = EXCLUDED.frequency,
            talkgroup = EXCLUDED.talkgroup,
            source = EXCLUDED.source,
            duration = EXCLUDED.duration,
            audio_url = EXCLUDED.audio_url,
            audio_file_path = EXCLUDED.audio_file_path,
            system_name = EXCLUDED.system_name,
            department = EXCLUDED.department,
            call_type = EXCLUDED.call_type,
            units = EXCLUDED.units,
            metadata = EXCLUDED.metadata,
            processed = EXCLUDED.processed,
            updated_at = NOW()
        """
        
        try:
            conn = self.get_connection()
            try:
                with conn.cursor() as cursor:
                    # Prepare data for batch insertion
                    records_data = []
                    for record in call_records:
                        record_dict = record.to_dict()
                        if record_dict.get('metadata'):
                            record_dict['metadata'] = json.dumps(record_dict['metadata'])
                        
                        records_data.append((
                            record_dict['call_id'],
                            record_dict['timestamp'],
                            record_dict['frequency'],
                            record_dict['talkgroup'],
                            record_dict['source'],
                            record_dict['duration'],
                            record_dict['audio_url'],
                            record_dict['audio_file_path'],
                            record_dict['system_name'],
                            record_dict['department'],
                            record_dict['call_type'],
                            record_dict['units'],
                            record_dict['metadata'],
                            record_dict['processed']
                        ))
                    
                    # Execute batch insert
                    execute_values(cursor, insert_sql, records_data)
                conn.commit()
                logger.info(f"Successfully inserted {len(call_records)} call records in batch")
                return len(call_records)
            finally:
                self.return_connection(conn)
        except psycopg2.Error as e:
            logger.error(f"Failed to insert call records batch: {e}")
            return 0
    
    def get_unprocessed_calls(self, limit: int = 100) -> List[Dict]:
        """
        Retrieve unprocessed call records from the database.
        
        Args:
            limit: Maximum number of records to retrieve
            
        Returns:
            List[Dict]: List of unprocessed call records
        """
        select_sql = """
        SELECT * FROM calls 
        WHERE processed = FALSE 
        ORDER BY timestamp ASC 
        LIMIT %s
        """
        
        try:
            conn = self.get_connection()
            try:
                with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                    cursor.execute(select_sql, (limit,))
                    records = cursor.fetchall()
                    logger.debug(f"Retrieved {len(records)} unprocessed call records")
                    return [dict(record) for record in records]
            finally:
                self.return_connection(conn)
        except psycopg2.Error as e:
            logger.error(f"Failed to retrieve unprocessed calls: {e}")
            return []
    
    def mark_call_processed(self, call_id: str) -> bool:
        """
        Mark a call record as processed.
        
        Args:
            call_id: Unique identifier of the call to mark as processed
            
        Returns:
            bool: True if update was successful, False otherwise
        """
        update_sql = "UPDATE calls SET processed = TRUE WHERE call_id = %s"
        
        try:
            conn = self.get_connection()
            try:
                with conn.cursor() as cursor:
                    cursor.execute(update_sql, (call_id,))
                    rows_updated = cursor.rowcount
                conn.commit()
                if rows_updated > 0:
                    logger.debug(f"Marked call {call_id} as processed")
                    return True
                else:
                    logger.warning(f"No call found with ID {call_id} to mark as processed")
                    return False
            finally:
                self.return_connection(conn)
        except psycopg2.Error as e:
            logger.error(f"Failed to mark call {call_id} as processed: {e}")
            return False
    
    def get_call_statistics(self) -> Dict[str, Any]:
        """
        Get statistics about stored call records.
        
        Returns:
            Dict[str, Any]: Statistics about call records
        """
        stats_sql = """
        SELECT 
            COUNT(*) as total_calls,
            COUNT(*) FILTER (WHERE processed = TRUE) as processed_calls,
            COUNT(*) FILTER (WHERE processed = FALSE) as unprocessed_calls,
            MIN(timestamp) as earliest_call,
            MAX(timestamp) as latest_call,
            AVG(duration) as avg_duration,
            COUNT(DISTINCT system_name) as unique_systems,
            COUNT(DISTINCT talkgroup) as unique_talkgroups
        FROM calls
        """
        
        try:
            conn = self.get_connection()
            try:
                with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                    cursor.execute(stats_sql)
                    stats = dict(cursor.fetchone())
                    logger.debug(f"Retrieved call statistics: {stats}")
                    return stats
            finally:
                self.return_connection(conn)
        except psycopg2.Error as e:
            logger.error(f"Failed to retrieve call statistics: {e}")
            return {}
    
    def cleanup_old_records(self, days: int = 30) -> int:
        """
        Remove old call records older than specified days.
        
        Args:
            days: Number of days to keep records
            
        Returns:
            int: Number of records deleted
        """
        cleanup_sql = """
        DELETE FROM calls 
        WHERE created_at < NOW() - INTERVAL '%s days'
        """
        
        try:
            conn = self.get_connection()
            try:
                with conn.cursor() as cursor:
                    cursor.execute(cleanup_sql, (days,))
                    deleted_count = cursor.rowcount
                conn.commit()
                logger.info(f"Cleaned up {deleted_count} old call records (older than {days} days)")
                return deleted_count
            finally:
                self.return_connection(conn)
        except psycopg2.Error as e:
            logger.error(f"Failed to cleanup old records: {e}")
            return 0
    
    def close(self):
        """Close all database connections and cleanup resources."""
        if self.connection_pool:
            self.connection_pool.closeall()
            logger.info("Database connection pool closed")


class AudioProcessor:
    """
    Handles audio file downloading, processing, and storage.
    
    This class manages the complete audio processing pipeline including
    downloading audio files from URLs, format conversion, compression,
    normalization, and storage management.
    """
    
    def __init__(self, config: configparser.ConfigParser):
        """
        Initialize audio processor with configuration.
        
        Args:
            config: ConfigParser object containing audio settings
        """
        self.config = config
        self.storage_path = Path(config.get('audio', 'storage_path'))
        self.audio_format = config.get('audio', 'audio_format').lower()
        self.audio_quality = config.getint('audio', 'audio_quality')
        self.max_file_size = config.getint('audio', 'max_file_size') * 1024 * 1024  # Convert MB to bytes
        self.enable_compression = config.getboolean('audio', 'enable_compression')
        self.compression_level = config.getint('audio', 'compression_level')
        self.auto_gain_control = config.getboolean('audio', 'auto_gain_control')
        self.normalize_audio = config.getboolean('audio', 'normalize_audio')
        self.retention_days = config.getint('audio', 'retention_days')
        
        # Create storage directory if it doesn't exist
        self.storage_path.mkdir(parents=True, exist_ok=True)
        
        # Setup HTTP session for audio downloads
        self.session = requests.Session()
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)
        
        # Check if ffmpeg is available for audio processing
        if not which("ffmpeg"):
            logger.warning("ffmpeg not found. Audio processing capabilities will be limited.")
        
        logger.info(f"Audio processor initialized - Storage: {self.storage_path}, Format: {self.audio_format}")
    
    def download_audio(self, audio_url: str, call_id: str) -> Optional[Path]:
        """
        Download audio file from URL and save to local storage.
        
        Args:
            audio_url: URL of the audio file to download
            call_id: Unique identifier for the call (used in filename)
            
        Returns:
            Optional[Path]: Path to downloaded file, None if download failed
        """
        if not audio_url:
            logger.warning(f"No audio URL provided for call {call_id}")
            return None
        
        try:
            # Generate filename based on call ID and current timestamp
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"{call_id}_{timestamp}.{self.audio_format}"
            file_path = self.storage_path / filename
            
            # Download audio file with streaming to handle large files
            logger.debug(f"Downloading audio from {audio_url} for call {call_id}")
            response = self.session.get(audio_url, stream=True, timeout=30)
            response.raise_for_status()
            
            # Check file size before downloading completely
            content_length = response.headers.get('content-length')
            if content_length and int(content_length) > self.max_file_size:
                logger.warning(f"Audio file too large ({content_length} bytes) for call {call_id}")
                return None
            
            # Write file to disk
            with open(file_path, 'wb') as f:
                downloaded_bytes = 0
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:  # Filter out keep-alive chunks
                        f.write(chunk)
                        downloaded_bytes += len(chunk)
                        
                        # Check size limit during download
                        if self.max_file_size > 0 and downloaded_bytes > self.max_file_size:
                            logger.warning(f"Audio file exceeded size limit during download for call {call_id}")
                            file_path.unlink()  # Delete partially downloaded file
                            return None
            
            logger.info(f"Successfully downloaded audio file: {file_path} ({downloaded_bytes} bytes)")
            return file_path
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to download audio for call {call_id}: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error downloading audio for call {call_id}: {e}")
            return None
    
    def process_audio(self, file_path: Path) -> Optional[Path]:
        """
        Process audio file (convert format, normalize, compress).
        
        Args:
            file_path: Path to the audio file to process
            
        Returns:
            Optional[Path]: Path to processed file, None if processing failed
        """
        if not file_path.exists():
            logger.error(f"Audio file does not exist: {file_path}")
            return None
        
        try:
            # Load audio file using pydub
            logger.debug(f"Processing audio file: {file_path}")
            audio = AudioSegment.from_file(str(file_path))
            
            # Apply audio processing based on configuration
            if self.normalize_audio:
                # Normalize audio to standard volume level
                audio = self._normalize_audio(audio)
                logger.debug(f"Applied normalization to {file_path}")
            
            if self.auto_gain_control:
                # Apply automatic gain control
                audio = self._apply_agc(audio)
                logger.debug(f"Applied AGC to {file_path}")
            
            # Convert to target format if needed
            processed_path = file_path
            if self.audio_format != file_path.suffix.lower().lstrip('.'):
                processed_path = file_path.with_suffix(f'.{self.audio_format}')
                
                # Export with appropriate settings based on format
                export_params = self._get_export_params()
                audio.export(str(processed_path), format=self.audio_format, **export_params)
                logger.debug(f"Converted audio format to {self.audio_format}: {processed_path}")
                
                # Remove original file if conversion successful
                if processed_path != file_path and processed_path.exists():
                    file_path.unlink()
            else:
                # Re-export with processing applied
                export_params = self._get_export_params()
                audio.export(str(processed_path), format=self.audio_format, **export_params)
            
            logger.info(f"Successfully processed audio file: {processed_path}")
            return processed_path
            
        except Exception as e:
            logger.error(f"Failed to process audio file {file_path}: {e}")
            return None
    
    def _normalize_audio(self, audio: AudioSegment) -> AudioSegment:
        """
        Normalize audio to standard volume level.
        
        Args:
            audio: AudioSegment to normalize
            
        Returns:
            AudioSegment: Normalized audio
        """
        # Calculate the current peak amplitude
        peak_amplitude = audio.max
        if peak_amplitude == 0:
            return audio  # Avoid division by zero
        
        # Normalize to -3dB to prevent clipping while maximizing volume
        target_amplitude = audio.max_possible_amplitude * 0.7  # -3dB
        gain = target_amplitude / peak_amplitude
        
        # Apply gain adjustment
        normalized_audio = audio + (20 * float(gain).bit_length())  # Convert to dB
        return normalized_audio
    
    def _apply_agc(self, audio: AudioSegment) -> AudioSegment:
        """
        Apply automatic gain control to audio.
        
        Args:
            audio: AudioSegment to apply AGC to
            
        Returns:
            AudioSegment: Audio with AGC applied
        """
        # Simple AGC implementation - compress dynamic range
        # This is a basic implementation; more sophisticated AGC could be added
        compressed = audio.compress_dynamic_range(threshold=-20.0, ratio=4.0, attack=5.0, release=50.0)
        return compressed
    
    def _get_export_params(self) -> Dict[str, Any]:
        """
        Get export parameters based on audio format and quality settings.
        
        Returns:
            Dict[str, Any]: Export parameters for pydub
        """
        params = {}
        
        if self.audio_format == 'mp3':
            params['bitrate'] = f"{self.audio_quality}k"
            if self.enable_compression:
                params['parameters'] = ["-q:a", str(9 - self.compression_level)]
        elif self.audio_format == 'wav':
            # WAV format doesn't have bitrate, use sample rate and bit depth
            params['parameters'] = ["-ar", "22050", "-ac", "1"]  # Mono, 22kHz
        elif self.audio_format == 'flac':
            params['parameters'] = ["-compression_level", str(self.compression_level)]
        
        return params
    
    def calculate_checksum(self, file_path: Path) -> str:
        """
        Calculate SHA-256 checksum of audio file.
        
        Args:
            file_path: Path to the audio file
            
        Returns:
            str: SHA-256 checksum in hexadecimal format
        """
        if not file_path.exists():
            return ""
        
        hash_sha256 = hashlib.sha256()
        try:
            with open(file_path, "rb") as f:
                for chunk in iter(lambda: f.read(4096), b""):
                    hash_sha256.update(chunk)
            return hash_sha256.hexdigest()
        except Exception as e:
            logger.error(f"Failed to calculate checksum for {file_path}: {e}")
            return ""
    
    def cleanup_old_files(self) -> int:
        """
        Remove old audio files based on retention policy.
        
        Returns:
            int: Number of files deleted
        """
        if self.retention_days <= 0:
            return 0  # Keep files forever
        
        cutoff_date = datetime.now() - timedelta(days=self.retention_days)
        deleted_count = 0
        
        try:
            for file_path in self.storage_path.glob("*"):
                if file_path.is_file():
                    # Get file modification time
                    file_mtime = datetime.fromtimestamp(file_path.stat().st_mtime)
                    
                    if file_mtime < cutoff_date:
                        file_path.unlink()
                        deleted_count += 1
                        logger.debug(f"Deleted old audio file: {file_path}")
            
            logger.info(f"Cleaned up {deleted_count} old audio files (older than {self.retention_days} days)")
            return deleted_count
            
        except Exception as e:
            logger.error(f"Error during audio file cleanup: {e}")
            return deleted_count
    
    def get_storage_stats(self) -> Dict[str, Any]:
        """
        Get statistics about audio file storage.
        
        Returns:
            Dict[str, Any]: Storage statistics
        """
        stats = {
            'total_files': 0,
            'total_size_bytes': 0,
            'total_size_mb': 0,
            'oldest_file': None,
            'newest_file': None,
            'formats': {}
        }
        
        try:
            oldest_time = None
            newest_time = None
            
            for file_path in self.storage_path.glob("*"):
                if file_path.is_file():
                    stats['total_files'] += 1
                    file_size = file_path.stat().st_size
                    stats['total_size_bytes'] += file_size
                    
                    # Track file format distribution
                    file_ext = file_path.suffix.lower().lstrip('.')
                    if file_ext in stats['formats']:
                        stats['formats'][file_ext] += 1
                    else:
                        stats['formats'][file_ext] = 1
                    
                    # Track oldest and newest files
                    file_mtime = datetime.fromtimestamp(file_path.stat().st_mtime)
                    if oldest_time is None or file_mtime < oldest_time:
                        oldest_time = file_mtime
                        stats['oldest_file'] = str(file_path)
                    if newest_time is None or file_mtime > newest_time:
                        newest_time = file_mtime
                        stats['newest_file'] = str(file_path)
            
            stats['total_size_mb'] = round(stats['total_size_bytes'] / (1024 * 1024), 2)
            
        except Exception as e:
            logger.error(f"Error getting storage stats: {e}")
        
        return stats


class RdioScannerClient:
    """
    Client for communicating with Rdio Scanner API.
    
    This class handles all HTTP communication with the Rdio Scanner instance,
    including authentication, rate limiting, error handling, and data parsing.
    """
    
    def __init__(self, config: configparser.ConfigParser):
        """
        Initialize Rdio Scanner client with configuration.
        
        Args:
            config: ConfigParser object containing scanner settings
        """
        self.config = config
        self.domain = config.get('rdio_scanner', 'domain').rstrip('/')
        self.api_path = config.get('rdio_scanner', 'api_path').lstrip('/')
        self.auth_token = config.get('rdio_scanner', 'auth_token', fallback='')
        self.user_agent = config.get('rdio_scanner', 'user_agent')
        self.request_timeout = config.getint('rdio_scanner', 'request_timeout')
        self.retry_attempts = config.getint('rdio_scanner', 'retry_attempts')
        self.retry_delay = config.getint('rdio_scanner', 'retry_delay')
        self.max_calls_per_request = config.getint('rdio_scanner', 'max_calls_per_request')
        
        # Build API endpoint URL
        self.api_url = urljoin(self.domain + '/', self.api_path)
        
        # Setup HTTP session with retry strategy and custom headers
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': self.user_agent,
            'Accept': 'application/json',
            'Content-Type': 'application/json'
        })
        
        # Add authentication header if token is provided
        if self.auth_token:
            self.session.headers.update({
                'Authorization': f'Bearer {self.auth_token}'
            })
        
        # Configure retry strategy
        retry_strategy = Retry(
            total=self.retry_attempts,
            backoff_factor=self.retry_delay,
            status_forcelist=[429, 500, 502, 503, 504],
            method_whitelist=["HEAD", "GET", "OPTIONS"]
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)
        
        logger.info(f"Rdio Scanner client initialized - API URL: {self.api_url}")
    
    def fetch_calls(self, since: Optional[datetime] = None, limit: Optional[int] = None) -> List[Dict]:
        """
        Fetch call records from Rdio Scanner API.
        
        Args:
            since: Only fetch calls newer than this timestamp
            limit: Maximum number of calls to fetch
            
        Returns:
            List[Dict]: List of call records from the API
        """
        try:
            # Build request parameters
            params = {}
            
            if limit is None:
                limit = self.max_calls_per_request
            params['limit'] = limit
            
            if since:
                # Convert datetime to Unix timestamp for API
                params['since'] = int(since.timestamp())
            
            # Make API request
            logger.debug(f"Fetching calls from API with params: {params}")
            response = self.session.get(
                self.api_url,
                params=params,
                timeout=self.request_timeout
            )
            response.raise_for_status()
            
            # Parse JSON response
            data = response.json()
            
            # Handle different API response formats
            if isinstance(data, list):
                calls = data
            elif isinstance(data, dict) and 'calls' in data:
                calls = data['calls']
            elif isinstance(data, dict) and 'data' in data:
                calls = data['data']
            else:
                logger.warning(f"Unexpected API response format: {type(data)}")
                calls = []
            
            logger.info(f"Successfully fetched {len(calls)} calls from API")
            return calls
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to fetch calls from API: {e}")
            return []
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse API response as JSON: {e}")
            return []
        except Exception as e:
            logger.error(f"Unexpected error fetching calls: {e}")
            return []
    
    def parse_call_record(self, api_call: Dict) -> Optional[CallRecord]:
        """
        Parse API call data into CallRecord object.
        
        Args:
            api_call: Raw call data from API
            
        Returns:
            Optional[CallRecord]: Parsed CallRecord, None if parsing failed
        """
        try:
            # Extract required fields with fallbacks
            call_id = api_call.get('id') or api_call.get('call_id') or str(uuid.uuid4())
            
            # Parse timestamp - try multiple formats
            timestamp_raw = api_call.get('timestamp') or api_call.get('time') or api_call.get('datetime')
            if isinstance(timestamp_raw, (int, float)):
                timestamp = datetime.fromtimestamp(timestamp_raw, tz=timezone.utc)
            elif isinstance(timestamp_raw, str):
                # Try to parse ISO format timestamp
                try:
                    timestamp = datetime.fromisoformat(timestamp_raw.replace('Z', '+00:00'))
                except ValueError:
                    # Fallback to current time if parsing fails
                    timestamp = datetime.now(timezone.utc)
                    logger.warning(f"Failed to parse timestamp '{timestamp_raw}' for call {call_id}")
            else:
                timestamp = datetime.now(timezone.utc)
            
            # Extract other fields with appropriate type conversion
            frequency = float(api_call.get('frequency', 0)) if api_call.get('frequency') else 0.0
            duration = float(api_call.get('duration', 0)) if api_call.get('duration') else 0.0
            
            # Handle talkgroup - can be string or integer
            talkgroup = api_call.get('talkgroup') or api_call.get('tg')
            if talkgroup is not None:
                talkgroup = str(talkgroup)
            
            # Handle source - can be string or integer
            source = api_call.get('source') or api_call.get('src')
            if source is not None:
                source = str(source)
            
            # Extract audio URL
            audio_url = (api_call.get('audio_url') or 
                        api_call.get('audioUrl') or 
                        api_call.get('audio') or 
                        api_call.get('file'))
            
            # Handle units list
            units = api_call.get('units', [])
            if isinstance(units, str):
                units = [units]  # Convert single unit to list
            elif not isinstance(units, list):
                units = []
            
            # Create CallRecord object
            call_record = CallRecord(
                call_id=call_id,
                timestamp=timestamp,
                frequency=frequency,
                talkgroup=talkgroup,
                source=source,
                duration=duration,
                audio_url=audio_url,
                audio_file_path=None,  # Will be set when audio is downloaded
                system_name=api_call.get('system') or api_call.get('system_name'),
                department=api_call.get('department') or api_call.get('agency'),
                call_type=api_call.get('type') or api_call.get('call_type'),
                units=units,
                metadata=api_call,  # Store full API response as metadata
                processed=False
            )
            
            logger.debug(f"Successfully parsed call record: {call_id}")
            return call_record
            
        except Exception as e:
            logger.error(f"Failed to parse call record: {e}")
            logger.debug(f"Raw API call data: {api_call}")
            return None
    
    def test_connection(self) -> bool:
        """
        Test connection to Rdio Scanner API.
        
        Returns:
            bool: True if connection successful, False otherwise
        """
        try:
            # Make a simple request with minimal parameters
            response = self.session.get(
                self.api_url,
                params={'limit': 1},
                timeout=self.request_timeout
            )
            response.raise_for_status()
            
            logger.info("Successfully connected to Rdio Scanner API")
            return True
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to connect to Rdio Scanner API: {e}")
            return False


class SystemMonitor:
    """
    System monitoring and health check functionality.
    
    This class provides system monitoring capabilities including health checks,
    performance metrics collection, and alerting functionality.
    """
    
    def __init__(self, config: configparser.ConfigParser):
        """
        Initialize system monitor with configuration.
        
        Args:
            config: ConfigParser object containing monitoring settings
        """
        self.config = config
        self.health_check_interval = config.getint('monitoring', 'health_check_interval')
        self.collect_metrics = config.getboolean('monitoring', 'collect_metrics')
        self.metrics_interval = config.getint('monitoring', 'metrics_interval')
        self.disk_space_threshold = config.getint('monitoring', 'disk_space_threshold')
        
        # Performance tracking
        self.start_time = datetime.now(timezone.utc)
        self.call_count = 0
        self.error_count = 0
        self.processing_times = []
        
        # Monitoring lock for thread safety
        self.lock = threading.Lock()
        
        logger.info("System monitor initialized")
    
    def record_call_processed(self, processing_time: float):
        """
        Record that a call was processed and track processing time.
        
        Args:
            processing_time: Time taken to process the call in seconds
        """
        with self.lock:
            self.call_count += 1
            self.processing_times.append(processing_time)
            
            # Keep only recent processing times (last 1000)
            if len(self.processing_times) > 1000:
                self.processing_times = self.processing_times[-1000:]
    
    def record_error(self):
        """Record that an error occurred."""
        with self.lock:
            self.error_count += 1
    
    def get_system_stats(self) -> Dict[str, Any]:
        """
        Get current system statistics.
        
        Returns:
            Dict[str, Any]: System statistics
        """
        with self.lock:
            uptime = datetime.now(timezone.utc) - self.start_time
            avg_processing_time = (
                sum(self.processing_times) / len(self.processing_times)
                if self.processing_times else 0.0
            )
            
            stats = {
                'uptime_seconds': uptime.total_seconds(),
                'uptime_formatted': str(uptime),
                'calls_processed': self.call_count,
                'error_count': self.error_count,
                'avg_processing_time': avg_processing_time,
                'calls_per_hour': self.call_count / (uptime.total_seconds() / 3600) if uptime.total_seconds() > 0 else 0,
                'error_rate': self.error_count / max(self.call_count, 1),
                'timestamp': datetime.now(timezone.utc).isoformat()
            }
        
        return stats
    
    def check_disk_space(self, path: str) -> Dict[str, Any]:
        """
        Check disk space for given path.
        
        Args:
            path: Path to check disk space for
            
        Returns:
            Dict[str, Any]: Disk space information
        """
        try:
            import shutil
            total, used, free = shutil.disk_usage(path)
            
            used_percent = (used / total) * 100
            
            return {
                'path': path,
                'total_bytes': total,
                'used_bytes': used,
                'free_bytes': free,
                'used_percent': used_percent,
                'alert': used_percent > self.disk_space_threshold
            }
        except Exception as e:
            logger.error(f"Failed to check disk space for {path}: {e}")
            return {'path': path, 'error': str(e)}
    
    def get_memory_usage(self) -> Dict[str, Any]:
        """
        Get current memory usage information.
        
        Returns:
            Dict[str, Any]: Memory usage information
        """
        try:
            import psutil
            memory = psutil.virtual_memory()
            
            return {
                'total_bytes': memory.total,
                'available_bytes': memory.available,
                'used_bytes': memory.used,
                'used_percent': memory.percent,
                'alert': memory.percent > 85
            }
        except ImportError:
            logger.warning("psutil not available for memory monitoring")
            return {'error': 'psutil not available'}
        except Exception as e:
            logger.error(f"Failed to get memory usage: {e}")
            return {'error': str(e)}
    
    def perform_health_check(self, db_manager: DatabaseManager, 
                           scanner_client: RdioScannerClient) -> Dict[str, Any]:
        """
        Perform comprehensive health check of all system components.
        
        Args:
            db_manager: Database manager instance
            scanner_client: Scanner client instance
            
        Returns:
            Dict[str, Any]: Health check results
        """
        health_status = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'overall_status': 'healthy',
            'components': {}
        }
        
        # Database health check
        try:
            conn = db_manager.get_connection()
            with conn.cursor() as cursor:
                cursor.execute("SELECT 1")
                result = cursor.fetchone()
            db_manager.return_connection(conn)
            
            health_status['components']['database'] = {
                'status': 'healthy' if result else 'unhealthy',
                'message': 'Database connection successful' if result else 'Database query failed'
            }
        except Exception as e:
            health_status['components']['database'] = {
                'status': 'unhealthy',
                'message': f'Database connection failed: {e}'
            }
            health_status['overall_status'] = 'unhealthy'
        
        # API connection health check
        api_healthy = scanner_client.test_connection()
        health_status['components']['api'] = {
            'status': 'healthy' if api_healthy else 'unhealthy',
            'message': 'API connection successful' if api_healthy else 'API connection failed'
        }
        if not api_healthy:
            health_status['overall_status'] = 'unhealthy'
        
        # Disk space check
        disk_info = self.check_disk_space('/var/lib/rdio-monitor')
        health_status['components']['disk_space'] = disk_info
        if disk_info.get('alert', False):
            health_status['overall_status'] = 'warning'
        
        # Memory usage check
        memory_info = self.get_memory_usage()
        health_status['components']['memory'] = memory_info
        if memory_info.get('alert', False):
            health_status['overall_status'] = 'warning'
        
        # System statistics
        health_status['system_stats'] = self.get_system_stats()
        
        return health_status


class RdioScannerMonitor:
    """
    Main application class that orchestrates the monitoring system.
    
    This is the primary class that coordinates all components including
    database management, audio processing, API communication, and monitoring.
    """
    
    def __init__(self, config_file: str):
        """
        Initialize the Rdio Scanner Monitor application.
        
        Args:
            config_file: Path to the configuration file
        """
        self.config_file = config_file
        self.config = self._load_config()
        self.running = False
        self.shutdown_event = threading.Event()
        
        # Initialize components
        self.db_manager = DatabaseManager(self.config)
        self.audio_processor = AudioProcessor(self.config)
        self.scanner_client = RdioScannerClient(self.config)
        self.system_monitor = SystemMonitor(self.config)
        
        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
        
        # Configuration parameters
        self.poll_interval = self.config.getint('rdio_scanner', 'poll_interval')
        
        # Last poll timestamp tracking
        self.last_poll_time = None
        
        logger.info("Rdio Scanner Monitor initialized successfully")
    
    def _load_config(self) -> configparser.ConfigParser:
        """
        Load and validate configuration file.
        
        Returns:
            configparser.ConfigParser: Loaded configuration
        """
        config = configparser.ConfigParser()
        
        if not os.path.exists(self.config_file):
            logger.error(f"Configuration file not found: {self.config_file}")
            sys.exit(1)
        
        try:
            config.read(self.config_file)
            logger.info(f"Configuration loaded from: {self.config_file}")
            
            # Validate required sections and options
            required_sections = ['rdio_scanner', 'database', 'audio', 'logging']
            for section in required_sections:
                if not config.has_section(section):
                    logger.error(f"Required configuration section missing: {section}")
                    sys.exit(1)
            
            return config
            
        except Exception as e:
            logger.error(f"Failed to load configuration: {e}")
            sys.exit(1)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully."""
        logger.info(f"Received signal {signum}, initiating graceful shutdown...")
        self.shutdown_event.set()
    
    def _setup_logging(self):
        """Setup logging configuration based on config file."""
        log_level = self.config.get('logging', 'log_level')
        log_file = self.config.get('logging', 'log_file')
        max_log_size = self.config.getint('logging', 'max_log_size') * 1024 * 1024
        log_backup_count = self.config.getint('logging', 'log_backup_count')
        console_logging = self.config.getboolean('logging', 'console_logging')
        
        # Create log directory if it doesn't exist
        log_dir = os.path.dirname(log_file)
        os.makedirs(log_dir, exist_ok=True)
        
        # Setup root logger
        root_logger = logging.getLogger()
        root_logger.setLevel(getattr(logging, log_level.upper()))
        
        # Clear existing handlers
        root_logger.handlers.clear()
        
        # File handler with rotation
        from logging.handlers import RotatingFileHandler
        file_handler = RotatingFileHandler(
            log_file,
            maxBytes=max_log_size,
            backupCount=log_backup_count
        )
        file_formatter = logging.Formatter(
            self.config.get('logging', 'log_format'),
            datefmt=self.config.get('logging', 'date_format')
        )
        file_handler.setFormatter(file_formatter)
        root_logger.addHandler(file_handler)
        
        # Console handler if enabled
        if console_logging:
            console_handler = logging.StreamHandler()
            console_handler.setFormatter(file_formatter)
            root_logger.addHandler(console_handler)
        
        logger.info("Logging configuration applied")
    
    def poll_and_process_calls(self):
        """Poll for new calls and process them."""
        try:
            start_time = time.time()
            
            # Fetch calls from API
            calls_data = self.scanner_client.fetch_calls(
                since=self.last_poll_time,
                limit=self.config.getint('rdio_scanner', 'max_calls_per_request')
            )
            
            if not calls_data:
                logger.debug("No new calls retrieved from API")
                return
            
            # Process each call
            call_records = []
            for call_data in calls_data:
                call_record = self.scanner_client.parse_call_record(call_data)
                if call_record:
                    call_records.append(call_record)
            
            if not call_records:
                logger.warning("No valid call records parsed from API response")
                return
            
            # Batch insert call records to database
            inserted_count = self.db_manager.insert_call_records_batch(call_records)
            logger.info(f"Inserted {inserted_count} call records into database")
            
            # Process audio for each call
            for call_record in call_records:
                if call_record.audio_url:
                    self._process_call_audio(call_record)
            
            # Update last poll time
            self.last_poll_time = datetime.now(timezone.utc)
            
            # Record processing metrics
            processing_time = time.time() - start_time
            self.system_monitor.record_call_processed(processing_time)
            
            logger.info(f"Processed {len(call_records)} calls in {processing_time:.2f} seconds")
            
        except Exception as e:
            logger.error(f"Error during call polling and processing: {e}")
            self.system_monitor.record_error()
    
    def _process_call_audio(self, call_record: CallRecord):
        """
        Process audio for a single call record.
        
        Args:
            call_record: CallRecord to process audio for
        """
        try:
            # Download audio file
            audio_path = self.audio_processor.download_audio(
                call_record.audio_url,
                call_record.call_id
            )
            
            if not audio_path:
                logger.warning(f"Failed to download audio for call {call_record.call_id}")
                return
            
            # Process audio file
            processed_path = self.audio_processor.process_audio(audio_path)
            
            if processed_path:
                # Update call record with processed audio path
                call_record.audio_file_path = str(processed_path)
                call_record.processed = True
                
                # Update database record
                self.db_manager.mark_call_processed(call_record.call_id)
                
                logger.debug(f"Successfully processed audio for call {call_record.call_id}")
            else:
                logger.warning(f"Failed to process audio for call {call_record.call_id}")
                
        except Exception as e:
            logger.error(f"Error processing audio for call {call_record.call_id}: {e}")
    
    def run_maintenance_tasks(self):
        """Run periodic maintenance tasks."""
        try:
            logger.info("Running maintenance tasks...")
            
            # Cleanup old call records if retention is configured
            retention_days = self.config.getint('audio', 'retention_days')
            if retention_days > 0:
                # Cleanup database records
                deleted_records = self.db_manager.cleanup_old_records(retention_days)
                logger.info(f"Cleaned up {deleted_records} old database records")
                
                # Cleanup audio files
                deleted_files = self.audio_processor.cleanup_old_files()
                logger.info(f"Cleaned up {deleted_files} old audio files")
            
            # Get and log system statistics
            stats = self.system_monitor.get_system_stats()
            db_stats = self.db_manager.get_call_statistics()
            audio_stats = self.audio_processor.get_storage_stats()
            
            logger.info(f"System stats: {stats}")
            logger.info(f"Database stats: {db_stats}")
            logger.info(f"Audio storage stats: {audio_stats}")
            
        except Exception as e:
            logger.error(f"Error during maintenance tasks: {e}")
    
    def run(self):
        """Main application loop."""
        logger.info("Starting Rdio Scanner Monitor...")
        
        # Setup logging
        self._setup_logging()
        
        # Test initial connections
        if not self.scanner_client.test_connection():
            logger.error("Failed to connect to Rdio Scanner API. Exiting.")
            return False
        
        # Schedule maintenance tasks
        schedule.every(1).hours.do(self.run_maintenance_tasks)
        schedule.every(self.system_monitor.health_check_interval).seconds.do(
            lambda: self.system_monitor.perform_health_check(
                self.db_manager, 
                self.scanner_client
            )
        )
        
        self.running = True
        logger.info("Rdio Scanner Monitor started successfully")
        
        try:
            while self.running and not self.shutdown_event.is_set():
                # Poll for new calls
                self.poll_and_process_calls()
                
                # Run scheduled tasks
                schedule.run_pending()
                
                # Wait for next poll interval or shutdown signal
                if self.shutdown_event.wait(timeout=self.poll_interval):
                    break  # Shutdown signal received
                    
        except KeyboardInterrupt:
            logger.info("Received keyboard interrupt")
        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}")
        finally:
            self._shutdown()
        
        return True
    
    def _shutdown(self):
        """Cleanup and shutdown all components."""
        logger.info("Shutting down Rdio Scanner Monitor...")
        
        self.running = False
        
        # Close database connections
        if hasattr(self, 'db_manager'):
            self.db_manager.close()
        
        logger.info("Rdio Scanner Monitor shutdown complete")


def main():
    """Main entry point for the application."""
    # Default configuration file path
    config_file = os.environ.get('CONFIG_FILE', '/etc/rdio-monitor/config.ini')
    
    # Parse command line arguments if needed
    if len(sys.argv) > 1:
        config_file = sys.argv[1]
    
    try:
        # Create and run the monitor
        monitor = RdioScannerMonitor(config_file)
        success = monitor.run()
        sys.exit(0 if success else 1)
        
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()