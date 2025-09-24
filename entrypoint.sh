#!/bin/bash
# Container entrypoint script for Rdio Scanner Monitor
# This script handles container initialization, configuration setup,
# and graceful service management within the container environment

set -e  # Exit immediately if a command exits with a non-zero status

# Color codes for output formatting
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging function with timestamp and color support
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC}  ${timestamp} - ${message}" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC}  ${timestamp} - ${message}" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} ${timestamp} - ${message}" ;;
        *)       echo "${timestamp} - ${message}" ;;
    esac
}

# Function to wait for database to be ready
wait_for_database() {
    log_message "INFO" "Waiting for database to be ready..."
    
    local host="${DATABASE_HOST:-localhost}"
    local port="${DATABASE_PORT:-5432}"
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if timeout 5 bash -c "</dev/tcp/${host}/${port}"; then
            log_message "INFO" "Database is ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_message "DEBUG" "Database not ready, attempt ${attempt}/${max_attempts}"
        sleep 2
    done
    
    log_message "ERROR" "Database failed to become ready after ${max_attempts} attempts"
    return 1
}

# Function to wait for Redis to be ready (if configured)
wait_for_redis() {
    local redis_host="${REDIS_HOST:-localhost}"
    local redis_port="${REDIS_PORT:-6379}"
    
    if [ -n "$REDIS_URL" ] || [ "$redis_host" != "localhost" ]; then
        log_message "INFO" "Waiting for Redis to be ready..."
        
        local max_attempts=15
        local attempt=0
        
        while [ $attempt -lt $max_attempts ]; do
            if timeout 5 bash -c "</dev/tcp/${redis_host}/${redis_port}"; then
                log_message "INFO" "Redis is ready!"
                return 0
            fi
            
            attempt=$((attempt + 1))
            log_message "DEBUG" "Redis not ready, attempt ${attempt}/${max_attempts}"
            sleep 2
        done
        
        log_message "WARN" "Redis failed to become ready, continuing without Redis"
    fi
}

# Function to setup configuration files
setup_configuration() {
    log_message "INFO" "Setting up configuration..."
    
    local config_file="${CONFIG_FILE:-/app/config/config.ini}"
    local config_template="/app/config/config.ini.template"
    
    # Create config directory if it doesn't exist
    mkdir -p "$(dirname "$config_file")"
    
    # Copy template if config doesn't exist
    if [ ! -f "$config_file" ] && [ -f "$config_template" ]; then
        log_message "INFO" "Creating configuration from template"
        cp "$config_template" "$config_file"
    fi
    
    # Set up environment variable substitution for common settings
    if [ -f "$config_file" ]; then
        # Replace environment variables in configuration file
        envsubst < "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
        log_message "INFO" "Configuration file ready at: $config_file"
    else
        log_message "ERROR" "Configuration file not found: $config_file"
        exit 1
    fi
}

# Function to setup logging directories
setup_logging() {
    log_message "INFO" "Setting up logging directories..."
    
    # Create log directories with proper permissions
    mkdir -p /app/logs
    chmod 755 /app/logs
    
    # Create audio processing directory
    mkdir -p /app/audio
    chmod 755 /app/audio
    
    # Create temporary processing directory
    mkdir -p /app/temp
    chmod 755 /app/temp
    
    log_message "INFO" "Logging directories ready"
}

# Function to run database migrations or schema setup
run_database_setup() {
    log_message "INFO" "Checking database schema..."
    
    # This would typically run database migrations
    # For now, we'll just log that the database is ready
    python3 -c "
import psycopg2
import os
import sys

try:
    # Parse DATABASE_URL or use individual components
    if 'DATABASE_URL' in os.environ:
        conn = psycopg2.connect(os.environ['DATABASE_URL'])
    else:
        conn = psycopg2.connect(
            host=os.environ.get('DATABASE_HOST', 'localhost'),
            port=int(os.environ.get('DATABASE_PORT', '5432')),
            database=os.environ.get('DATABASE_NAME', 'rdio_scanner'),
            user=os.environ.get('DATABASE_USER', 'scanner'),
            password=os.environ.get('DATABASE_PASSWORD', 'scanner_password')
        )
    
    cursor = conn.cursor()
    cursor.execute('SELECT version();')
    version = cursor.fetchone()[0]
    print(f'Database connection successful: {version}')
    cursor.close()
    conn.close()
    
except Exception as e:
    print(f'Database connection failed: {e}')
    sys.exit(1)
" && log_message "INFO" "Database schema check completed"
}

# Function to handle graceful shutdown
graceful_shutdown() {
    log_message "INFO" "Received shutdown signal, stopping services..."
    
    # Send SIGTERM to child processes
    if [ -n "$MAIN_PID" ]; then
        log_message "INFO" "Stopping main application process (PID: $MAIN_PID)"
        kill -TERM "$MAIN_PID" 2>/dev/null || true
        
        # Wait for graceful shutdown
        local timeout=30
        while [ $timeout -gt 0 ] && kill -0 "$MAIN_PID" 2>/dev/null; do
            sleep 1
            timeout=$((timeout - 1))
        done
        
        # Force kill if still running
        if kill -0 "$MAIN_PID" 2>/dev/null; then
            log_message "WARN" "Force killing main application process"
            kill -KILL "$MAIN_PID" 2>/dev/null || true
        fi
    fi
    
    log_message "INFO" "Shutdown complete"
    exit 0
}

# Function to check system requirements
check_requirements() {
    log_message "INFO" "Checking system requirements..."
    
    # Check Python version
    python3 --version || {
        log_message "ERROR" "Python 3 is not available"
        exit 1
    }
    
    # Check required Python packages
    python3 -c "
import requests
import psycopg2
import schedule
print('Required Python packages are available')
" || {
        log_message "ERROR" "Required Python packages are missing"
        exit 1
    }
    
    # Check ffmpeg availability for audio processing
    if ! command -v ffmpeg >/dev/null 2>&1; then
        log_message "WARN" "ffmpeg not found - audio processing may be limited"
    else
        log_message "INFO" "ffmpeg is available for audio processing"
    fi
    
    log_message "INFO" "System requirements check passed"
}

# Function to start the main application
start_application() {
    local config_file="${CONFIG_FILE:-/app/config/config.ini}"
    
    log_message "INFO" "Starting Rdio Scanner Monitor application..."
    log_message "INFO" "Configuration file: $config_file"
    log_message "INFO" "Working directory: $(pwd)"
    log_message "INFO" "User: $(whoami)"
    
    # Execute the main application
    exec python3 /app/rdio_scanner.py "$config_file" &
    MAIN_PID=$!
    
    log_message "INFO" "Application started with PID: $MAIN_PID"
    
    # Wait for the process to finish
    wait $MAIN_PID
}

# Set up signal handlers for graceful shutdown
trap graceful_shutdown SIGTERM SIGINT SIGQUIT

# Main execution flow
main() {
    log_message "INFO" "Starting Rdio Scanner Monitor container..."
    log_message "INFO" "Container user: $(whoami)"
    log_message "INFO" "Container working directory: $(pwd)"
    log_message "INFO" "Environment: ${ENVIRONMENT:-production}"
    
    # Perform initialization steps
    check_requirements
    setup_logging
    setup_configuration
    
    # Wait for dependent services
    wait_for_database
    wait_for_redis
    
    # Set up database if needed
    run_database_setup
    
    # Handle different run modes
    case "${1:-start}" in
        "start"|"run")
            start_application
            ;;
        "shell"|"bash")
            log_message "INFO" "Starting interactive shell..."
            exec /bin/bash
            ;;
        "test")
            log_message "INFO" "Running tests..."
            python3 -m pytest /app/tests/ -v
            ;;
        "health-check")
            log_message "INFO" "Running health check..."
            python3 /app/health_check.py
            ;;
        "migrate")
            log_message "INFO" "Running database migrations..."
            run_database_setup
            ;;
        "help"|"--help")
            echo "Usage: $0 [COMMAND]"
            echo ""
            echo "Commands:"
            echo "  start, run          Start the main application (default)"
            echo "  shell, bash         Start interactive shell"
            echo "  test                Run test suite"
            echo "  health-check        Run health check"
            echo "  migrate             Run database migrations"
            echo "  help, --help        Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  CONFIG_FILE         Path to configuration file"
            echo "  DATABASE_URL        Database connection string"
            echo "  REDIS_URL           Redis connection string"
            echo "  LOG_LEVEL           Logging level (DEBUG, INFO, WARNING, ERROR)"
            echo "  ENVIRONMENT         Environment (development, production)"
            ;;
        *)
            log_message "ERROR" "Unknown command: $1"
            log_message "INFO" "Use 'help' to see available commands"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"