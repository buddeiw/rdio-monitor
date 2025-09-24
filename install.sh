#!/bin/bash
# Rdio Scanner Monitor Installation Script for Rocky Linux 10
# Complete installation with error checking and proper package management
# Usage: sudo ./install.sh

set -euo pipefail

# Configuration variables
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="/opt/rdio-monitor"
readonly CONFIG_DIR="/etc/rdio-monitor"
readonly DATA_DIR="/var/lib/rdio-monitor"
readonly LOG_DIR="/var/log/rdio-monitor"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC}  ${timestamp} - ${message}" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC}  ${timestamp} - ${message}" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" ;;
        *)       echo "${timestamp} - ${message}" ;;
    esac
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check Rocky Linux version and system requirements
check_system() {
    log_message "INFO" "Checking system requirements..."
    
    if [[ ! -f /etc/rocky-release ]]; then
        log_message "ERROR" "This script is designed for Rocky Linux"
        exit 1
    fi
    
    # Check available disk space (require at least 10GB free)
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space=$((10 * 1024 * 1024)) # 10GB in KB
    
    if [[ "$available_space" -lt "$required_space" ]]; then
        log_message "ERROR" "Insufficient disk space. Required: 10GB, Available: $((available_space / 1024 / 1024))GB"
        exit 1
    fi
    
    log_message "INFO" "System requirements check passed"
}

# Verify required files exist
check_files() {
    log_message "INFO" "Checking required installation files..."
    
    local required_files=(
        "config.ini"
        "docker-compose.yml"
        "Dockerfile"
        "requirements.txt"
        "rdio_scanner.py"
        "health_check.py"
        "entrypoint.sh"
        "schema.sql"
        "rdio-monitor.service"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
            log_message "ERROR" "Required file missing: $file"
            exit 1
        fi
    done
    
    log_message "INFO" "All required files found"
}

# Create directory structure with proper permissions
create_directories() {
    log_message "INFO" "Creating directory structure..."
    
    local directories=(
        "$INSTALL_DIR"
        "$CONFIG_DIR"
        "$DATA_DIR"
        "$DATA_DIR/postgresql"
        "$DATA_DIR/grafana"
        "$DATA_DIR/audio"
        "$DATA_DIR/redis"
        "$DATA_DIR/backups"
        "$LOG_DIR"
        "$LOG_DIR/nginx"
        "/tmp/rdio-monitor"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
        log_message "INFO" "Created directory: $dir"
    done

    # In the create_directories() function, add:
# Create container user directories with proper ownership
mkdir -p /var/lib/rdio-monitor/audio /var/log/rdio-monitor
chown -R 1000:1000 /var/lib/rdio-monitor/audio
chown -R 1000:1000 /var/log/rdio-monitor
chmod -R 755 /var/lib/rdio-monitor/audio /var/log/rdio-monitor
    
    # Set base permissions
    chmod 755 "$INSTALL_DIR" "$CONFIG_DIR"
    chmod 750 "$DATA_DIR" "$LOG_DIR"
    chmod 700 "$DATA_DIR/postgresql"
    
    # CRITICAL FIX: Set proper ownership for container users
    # Grafana runs as user 472:472
    chown -R 472:472 "$DATA_DIR/grafana" || {
        # If user 472 doesn't exist, create it or use fallback
        useradd -r -u 472 -g 472 grafana 2>/dev/null || true
        chown -R 472:472 "$DATA_DIR/grafana" || chmod 777 "$DATA_DIR/grafana"
    }
    
    # Redis runs as user 999:999 typically
    chown -R 999:999 "$DATA_DIR/redis" 2>/dev/null || chmod 777 "$DATA_DIR/redis"
    
    # PostgreSQL runs as user 70:70 in Alpine images
    chown -R 70:70 "$DATA_DIR/postgresql" 2>/dev/null || chmod 700 "$DATA_DIR/postgresql"
    
    # Set SELinux contexts if enabled
    if command -v semanage &> /dev/null && getenforce | grep -q "Enforcing"; then
        log_message "INFO" "Configuring SELinux contexts..."
        setsebool -P container_manage_cgroup on
        semanage fcontext -a -t container_file_t "$DATA_DIR(/.*)?" 2>/dev/null || true
        restorecon -Rv "$DATA_DIR" 2>/dev/null || true
    fi
}

# Install packages for Rocky Linux
install_packages() {
    log_message "INFO" "Installing required packages..."
    
    # Update system packages
    dnf update -y
    
    # Enable EPEL and CodeReady Builder repositories
    dnf install -y epel-release
    dnf config-manager --set-enabled crb
    
    # Install Podman without the problematic wrapper scripts
    dnf install -y podman podman-docker
    
    # Verify podman installation
    if ! command -v podman &> /dev/null; then
        log_message "ERROR" "Podman installation failed"
        exit 1
    fi
    
    # Install system utilities
    dnf install -y \
        curl \
        wget \
        jq \
        git \
        htop \
        rsync \
        logrotate \
        crontabs \
        firewalld \
        vim \
        nano
    
    # Install Python and development tools
    dnf install -y \
        python3 \
        python3-pip \
        python3-devel \
        gcc \
        gcc-c++ \
        make
    
    # Install audio processing libraries
    dnf install -y \
        ffmpeg \
        ffmpeg-devel
    
    # Install PostgreSQL client
    dnf install -y postgresql postgresql-contrib
    
    # Install Python packages
    pip3 install --upgrade pip setuptools wheel
    
    log_message "INFO" "Package installation completed"
}

# Configure firewall
configure_firewall() {
    log_message "INFO" "Configuring firewall..."
    
    # Enable and start firewalld
    systemctl enable --now firewalld
    
    # Open required ports
    local ports=(
        "5432/tcp"   # PostgreSQL
        "3000/tcp"   # Grafana
        "8080/tcp"   # Scanner API
        "80/tcp"     # HTTP
        "443/tcp"    # HTTPS
        "6379/tcp"   # Redis
    )
    
    for port in "${ports[@]}"; do
        firewall-cmd --permanent --add-port="$port"
        log_message "INFO" "Opened firewall port: $port"
    done
    
    firewall-cmd --reload
    log_message "INFO" "Firewall configuration completed"
}

# Setup Podman
setup_podman() {
    log_message "INFO" "Configuring Podman..."
    
    # Create podman user if it doesn't exist
    if ! id -u podman &>/dev/null; then
        useradd -r -s /bin/false -d "$DATA_DIR" -c "Podman service account" podman
        log_message "INFO" "Created podman system user"
    fi
    
    # Configure subuid and subgid
    if ! grep -q "^podman:" /etc/subuid; then
        echo "podman:100000:65536" >> /etc/subuid
        echo "podman:100000:65536" >> /etc/subgid
        log_message "INFO" "Configured subuid/subgid for podman user"
    fi
    
    # Set up container registry configuration (simplified)
    mkdir -p /etc/containers
    cat > /etc/containers/registries.conf << 'EOF'
[registries.search]
registries = ['docker.io']

[registries.insecure]
registries = []

[registries.block]
registries = []
EOF
    
    # Enable podman socket for systemd integration
    systemctl enable --now podman.socket
    
    log_message "INFO" "Podman configuration completed"
}

# Copy configuration files
copy_files() {
    log_message "INFO" "Copying configuration files..."
    
    # Copy configuration files
    cp "$SCRIPT_DIR/config.ini" "$CONFIG_DIR/"
    cp "$SCRIPT_DIR/docker-compose.yml" "$CONFIG_DIR/"
    
    # Copy application files to build context FIRST
    cp "$SCRIPT_DIR/rdio_scanner.py" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/health_check.py" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/entrypoint.sh" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/Dockerfile" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
    
    # Copy database schema
    cp "$SCRIPT_DIR/schema.sql" "$DATA_DIR/"
    
    # Copy systemd service file
    cp "$SCRIPT_DIR/rdio-monitor.service" /etc/systemd/system/
    systemctl daemon-reload
    
    # Make scripts executable
    chmod +x "$INSTALL_DIR/entrypoint.sh"
    chmod +x "$INSTALL_DIR/health_check.py"
    chmod +x "$INSTALL_DIR/rdio_scanner.py"
    
    log_message "INFO" "Files copied successfully"
}

# Create database initialization script
create_db_init() {
    log_message "INFO" "Creating database initialization script..."
    
    cat > "$DATA_DIR/init-scanner-user.sql" << 'EOF'
-- Create scanner user and grant permissions
DO $$
BEGIN
    -- Create scanner user if it doesn't exist
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'scanner') THEN
        CREATE USER scanner WITH PASSWORD 'scanner_password';
    END IF;
    
    -- Grant necessary permissions
    GRANT CONNECT ON DATABASE rdio_scanner TO scanner;
    GRANT CREATE ON DATABASE rdio_scanner TO scanner;
    GRANT USAGE ON SCHEMA public TO scanner;
    GRANT CREATE ON SCHEMA public TO scanner;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO scanner;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO scanner;
    
    -- Ensure scanner can access future tables/sequences
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO scanner;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO scanner;
END
$$;
EOF

    log_message "INFO" "Database initialization script created"
}

# Create management scripts with fixes
create_scripts() {
    log_message "INFO" "Creating management scripts..."
    
    # Create minimal requirements.txt
    cat > "$INSTALL_DIR/requirements.txt" << 'EOF'
# Minimal Python requirements for Rdio Scanner Monitor
requests==2.31.0
psycopg2-binary==2.9.9
pydub==0.25.1
schedule==1.2.0
python-dateutil==2.8.2
psutil==5.9.6
flask==3.0.0
gunicorn==21.2.0
EOF

    # Create simplified entrypoint.sh
    cat > "$INSTALL_DIR/entrypoint.sh" << 'EOF'
#!/bin/bash
set -e

# Add this in the start.sh generation, before "podman run -d --name rdio-scanner-app":
echo "Setting up container permissions..."
chown -R 1000:1000 /var/lib/rdio-monitor/audio /var/log/rdio-monitor 2>/dev/null || true
chmod -R 755 /var/lib/rdio-monitor/audio /var/log/rdio-monitor 2>/dev/null || true

echo "Starting Rdio Scanner Monitor..."
echo "Config file: ${CONFIG_FILE:-/app/config/config.ini}"

# Start the application directly without complex health checks
exec python3 /app/rdio_scanner.py "${CONFIG_FILE:-/app/config/config.ini}"
EOF
    chmod +x "$INSTALL_DIR/entrypoint.sh"
    
    # Start script with manual container management only
    cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
set -e

echo "Starting Rdio Scanner Monitor..."

# Create network
podman network create rdio_network --subnet 172.20.0.0/24 2>/dev/null || {
    echo "Network already exists, continuing..."
}

# Start PostgreSQL
# Start PostgreSQL with fixed permissions
echo "Starting PostgreSQL..."
sudo chown -R 999:999 /var/lib/rdio-monitor/postgresql 2>/dev/null || true
podman run -d \
    --name rdio-postgresql \
    --network rdio_network \
    -p 5432:5432 \
    -v /var/lib/rdio-monitor/postgresql:/var/lib/postgresql/data \
    -e POSTGRES_PASSWORD=postgres_admin_password \
    -e POSTGRES_DB=rdio_scanner \
    -e POSTGRES_USER=postgres \
    --restart unless-stopped \
    postgres:15-alpine 2>/dev/null || {
    echo "PostgreSQL container might already exist, trying to start..."
    podman start rdio-postgresql 2>/dev/null || true
}

# Wait for PostgreSQL
echo "Waiting for PostgreSQL to initialize..."
for i in {1..60}; do
    if podman exec rdio-postgresql pg_isready -U postgres &>/dev/null; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting for PostgreSQL... ($i/60)"
    sleep 2
done

# Start Redis
echo "Starting Redis..."
podman run -d \
    --name rdio-redis \
    --network rdio_network \
    -p 6379:6379 \
    -v /var/lib/rdio-monitor/redis:/data:Z \
    --restart unless-stopped \
    redis:7-alpine \
    redis-server --appendonly yes --appendfsync everysec --maxmemory 256mb --maxmemory-policy allkeys-lru 2>/dev/null || {
    echo "Redis container might already exist, trying to start..."
    podman start rdio-redis 2>/dev/null || true
}

# Start Grafana with proper permissions
echo "Starting Grafana..."
podman run -d \
    --name rdio-grafana \
    --network rdio_network \
    -p 3000:3000 \
    --user 472:472 \
    -v /var/lib/rdio-monitor/grafana:/var/lib/grafana:Z \
    -e GF_SECURITY_ADMIN_USER=admin \
    -e GF_SECURITY_ADMIN_PASSWORD=admin \
    --restart unless-stopped \
    grafana/grafana:latest 2>/dev/null || {
    echo "Grafana container might already exist, trying to start..."
    podman start rdio-grafana 2>/dev/null || true
}

# Wait for Grafana
echo "Waiting for Grafana to start..."
sleep 15
for i in {1..30}; do
    if curl -s http://localhost:3000/api/health &>/dev/null; then
        echo "Grafana is ready!"
        break
    fi
    echo "Waiting for Grafana... ($i/30)"
    sleep 2
done

# Build and start scanner app
echo "Building scanner application..."
cd /opt/rdio-monitor
if ! podman build -t rdio-scanner:latest . 2>/dev/null; then
    echo "Build failed, checking if image exists..."
    if ! podman image exists rdio-scanner:latest; then
        echo "ERROR: Scanner image build failed and no existing image found"
        exit 1
    fi
fi

echo "Starting scanner application..."
podman run -d \
    --name rdio-scanner-app \
    --network rdio_network \
    -p 8080:8080 \
    -v /etc/rdio-monitor/config.ini:/app/config/config.ini:Z,ro \
    -v /var/lib/rdio-monitor/audio:/app/audio:Z \
    -v /var/log/rdio-monitor:/app/logs:Z \
    -v /tmp/rdio-monitor:/app/temp:Z \
    -e CONFIG_FILE=/app/config/config.ini \
    -e DATABASE_HOST=rdio-postgresql \
    -e DATABASE_PORT=5432 \
    -e REDIS_HOST=rdio-redis \
    -e LOG_LEVEL=INFO \
    --restart unless-stopped \
    rdio-scanner:latest 2>/dev/null || {
    echo "Scanner app container might already exist, trying to start..."
    podman start rdio-scanner-app 2>/dev/null || true
}

# Wait for scanner app
echo "Waiting for scanner application to be ready..."
for i in {1..60}; do
    if curl -s http://localhost:8080/health &>/dev/null; then
        echo "Scanner application is ready!"
        break
    fi
    echo "Waiting for scanner app... ($i/60)"
    sleep 2
done

echo ""
echo "=== Rdio Scanner Monitor Started ==="
echo "Grafana: http://localhost:3000 (admin/admin)"
echo "Scanner API: http://localhost:8080/health"
echo "Check status: /opt/rdio-monitor/status.sh"
echo ""

# Show final status
echo "Final container status:"
podman ps --filter "name=rdio-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF

    # Stop script
    cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
set -e

echo "Stopping Rdio Scanner Monitor..."

# Manual container stop
echo "Stopping containers..."
podman stop rdio-scanner-app rdio-grafana rdio-redis rdio-postgresql || true
podman rm rdio-scanner-app rdio-grafana rdio-redis rdio-postgresql || true
podman network rm rdio_network || true

echo "Rdio Scanner Monitor stopped"
EOF

    # Status script
    cat > "$INSTALL_DIR/status.sh" << 'EOF'
#!/bin/bash

echo "=== Rdio Scanner Monitor System Status ==="
echo

echo "Container Status:"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep rdio- || echo "No rdio containers running"
echo

echo "Network Status:"
podman network ls | grep rdio_network || echo "Network not found"
echo

echo "Disk Usage:"
df -h /opt/rdio-monitor /var/lib/rdio-monitor /var/log/rdio-monitor 2>/dev/null || echo "Directories not found"
echo

echo "Container Health:"
for container in rdio-postgresql rdio-redis rdio-grafana rdio-scanner-app; do
    if podman ps --filter "name=$container" --format "{{.Names}}" | grep -q "$container"; then
        echo "✓ $container: Running"
    else
        echo "✗ $container: Not running"
    fi
done

echo ""
echo "Directory Permissions:"
ls -la /var/lib/rdio-monitor/ | head -5
EOF

    # Make scripts executable
    chmod +x "$INSTALL_DIR"/*.sh
    
    log_message "INFO" "Management scripts created"
}

# Setup log rotation
setup_logging() {
    log_message "INFO" "Setting up log rotation..."
    
    cat > /etc/logrotate.d/rdio-monitor << EOF
${LOG_DIR}/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF
    
    log_message "INFO" "Log rotation configured"
}

# Set ownership and permissions
set_permissions() {
    log_message "INFO" "Setting ownership and permissions..."
    
    # Set ownership for data directories
    chown -R podman:podman "$DATA_DIR/audio" "$LOG_DIR" || true
    chown root:root "$CONFIG_DIR"/*.ini "$CONFIG_DIR"/*.yml || true
    
    # Ensure container user permissions are correct
    chown -R 472:472 "$DATA_DIR/grafana" || chmod 755 "$DATA_DIR/grafana"
    
    # Set permissions
    chmod 640 "$CONFIG_DIR/config.ini" || true
    chmod 644 "$CONFIG_DIR"/*.yml || true
    chmod 755 "$INSTALL_DIR"/*.sh
    
    log_message "INFO" "Permissions set correctly"
}

# Main installation function
main() {
    log_message "INFO" "Starting Rdio Scanner Monitor installation..."
    
    check_root
    check_system
    check_files
    create_directories
    install_packages
    configure_firewall
    setup_podman
    copy_files
    create_db_init
    create_scripts
    setup_logging
    set_permissions
    
    log_message "INFO" "Installation completed successfully!"
    
    echo
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  Rdio Scanner Monitor Installation Complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo
    echo "IMPORTANT: Before starting, edit your configuration:"
    echo "  1. Edit: $CONFIG_DIR/config.ini"
    echo "  2. Set your actual Rdio Scanner domain URL"
    echo "  3. Configure any other settings as needed"
    echo
    echo "Then start the services:"
    echo "  $INSTALL_DIR/start.sh"
    echo
    echo "Management commands:"
    echo "  - Start:  $INSTALL_DIR/start.sh"
    echo "  - Stop:   $INSTALL_DIR/stop.sh"
    echo "  - Status: $INSTALL_DIR/status.sh"
    echo
    echo "Access points after starting:"
    echo "  - Grafana: http://localhost:3000 (admin/admin)"
    echo "  - Scanner Health: http://localhost:8080/health"
    echo
    echo "KEY FIXES APPLIED:"
    echo "  ✓ Removed problematic podman-compose wrapper"
    echo "  ✓ Fixed container directory permissions"
    echo "  ✓ Simplified requirements.txt (minimal dependencies)"
    echo "  ✓ Fixed container networking with hostnames"
    echo "  ✓ Added database user initialization"
    echo "  ✓ Simplified entrypoint script"
    echo
}

# Execute main function
main "$@"