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
        "postgresql.conf"
        "grafana.ini"
        "nginx.conf"
        "supervisord.conf"
        "config.ini.template"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
            log_message "ERROR" "Required file missing: $file"
            exit 1
        fi
    done
    
    log_message "INFO" "All required files found"
}

# Create directory structure
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
    
    # Set permissions
    chmod 755 "$INSTALL_DIR" "$CONFIG_DIR"
    chmod 750 "$DATA_DIR" "$LOG_DIR"
    chmod 700 "$DATA_DIR/postgresql"
    
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
    
    # Enable RPM Fusion for multimedia packages
    dnf install -y --nogpgcheck \
        https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm \
        https://download1.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm
    
    # Install Podman and container tools
    dnf install -y podman podman-compose podman-docker
    
    # Verify podman installation and fix common issues
    if ! command -v podman &> /dev/null; then
        log_message "ERROR" "Podman installation failed"
        exit 1
    fi
    
    # Create symlink if podman-compose can't find podman
    if [[ ! -L /usr/bin/docker ]] && [[ ! -f /usr/bin/docker ]]; then
        ln -sf /usr/bin/podman /usr/bin/docker
    fi
    
    # Fix podman-compose PATH issues
    if command -v podman-compose &> /dev/null; then
        # Create wrapper script to ensure proper PATH
        cat > /usr/local/bin/podman-compose-wrapper << 'EOF'
#!/bin/bash
export PATH="/usr/bin:$PATH"
exec podman-compose "$@"
EOF
        chmod +x /usr/local/bin/podman-compose-wrapper
    else
        # Install podman-compose via pip if not available
        log_message "WARN" "podman-compose not available in repos, installing via pip"
        pip3 install podman-compose
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
    
    # Set up container registry configuration
    mkdir -p /etc/containers
    if [[ ! -f /etc/containers/registries.conf ]]; then
        cat > /etc/containers/registries.conf << 'EOF'
[registries.search]
registries = ['docker.io', 'registry.redhat.io', 'quay.io']

[registries.insecure]
registries = []

[registries.block]
registries = []
EOF
        log_message "INFO" "Created container registry configuration"
    fi
    
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
    cp "$SCRIPT_DIR/postgresql.conf" "$CONFIG_DIR/"
    cp "$SCRIPT_DIR/grafana.ini" "$CONFIG_DIR/"
    cp "$SCRIPT_DIR/nginx.conf" "$CONFIG_DIR/"
    cp "$SCRIPT_DIR/config.ini.template" "$CONFIG_DIR/"
    
    # Copy application files
    cp "$SCRIPT_DIR/rdio_scanner.py" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/health_check.py" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/entrypoint.sh" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/Dockerfile" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/supervisord.conf" "$INSTALL_DIR/"
    
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

# Create management scripts
create_scripts() {
    log_message "INFO" "Creating management scripts..."
    
    # Start script
    cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
set -e

echo "Starting Rdio Scanner Monitor..."
cd /etc/rdio-monitor

# Use full path and ensure podman is in PATH
export PATH="/usr/bin:$PATH"

# Try podman-compose, fall back to alternatives
if command -v podman-compose &> /dev/null; then
    podman-compose up -d
elif command -v /usr/local/bin/podman-compose-wrapper &> /dev/null; then
    /usr/local/bin/podman-compose-wrapper up -d
else
    # Manual container startup if podman-compose fails
    echo "Starting containers manually..."
    
    # Create network
    podman network create rdio_network --subnet 172.20.0.0/24 || true
    
    # Start PostgreSQL
    podman run -d \
        --name rdio-postgresql \
        --network rdio_network \
        --ip 172.20.0.10 \
        -p 5432:5432 \
        -v /var/lib/rdio-monitor/postgresql:/var/lib/postgresql/data \
        -v /var/lib/rdio-monitor/schema.sql:/docker-entrypoint-initdb.d/01-schema.sql:ro \
        -e POSTGRES_PASSWORD=postgres_admin_password \
        -e POSTGRES_DB=rdio_scanner \
        -e POSTGRES_USER=postgres \
        --restart unless-stopped \
        postgres:15-alpine
    
    # Wait for PostgreSQL
    echo "Waiting for PostgreSQL to start..."
    sleep 30
    
    # Start Redis
    podman run -d \
        --name rdio-redis \
        --network rdio_network \
        --ip 172.20.0.30 \
        -p 6379:6379 \
        -v /var/lib/rdio-monitor/redis:/data \
        --restart unless-stopped \
        redis:7-alpine
    
    # Start Grafana
    podman run -d \
        --name rdio-grafana \
        --network rdio_network \
        --ip 172.20.0.20 \
        -p 3000:3000 \
        -v /var/lib/rdio-monitor/grafana:/var/lib/grafana \
        -v /etc/rdio-monitor/grafana.ini:/etc/grafana/grafana.ini:ro \
        -e GF_SECURITY_ADMIN_USER=admin \
        -e GF_SECURITY_ADMIN_PASSWORD=admin \
        --restart unless-stopped \
        grafana/grafana:latest
    
    # Build and start scanner app
    cd /opt/rdio-monitor
    podman build -t rdio-scanner:latest .
    
    podman run -d \
        --name rdio-scanner-app \
        --network rdio_network \
        --ip 172.20.0.50 \
        -p 8080:8080 \
        -v /etc/rdio-monitor/config.ini:/app/config/config.ini:ro \
        -v /var/lib/rdio-monitor/audio:/app/audio \
        -v /var/log/rdio-monitor:/app/logs \
        -e CONFIG_FILE=/app/config/config.ini \
        -e DATABASE_HOST=rdio-postgresql \
        -e DATABASE_PORT=5432 \
        -e REDIS_HOST=172.20.0.30 \
        --restart unless-stopped \
        rdio-scanner:latest
    
    echo "Containers started manually"
fi

echo "Waiting for services to start..."
sleep 30

# Initialize database if needed
if [[ -f /var/lib/rdio-monitor/schema.sql ]]; then
    if podman exec rdio-postgresql pg_isready -U postgres; then
        # Check if database needs initialization
        if ! podman exec rdio-postgresql psql -U postgres -d rdio_scanner -c "SELECT 1 FROM calls LIMIT 1;" 2>/dev/null; then
            echo "Initializing database schema..."
            podman exec -i rdio-postgresql psql -U postgres -d rdio_scanner < /var/lib/rdio-monitor/schema.sql
        fi
    else
        echo "Database not ready"
        exit 1
    fi
fi

echo "Starting system service..."
systemctl enable --now rdio-monitor.service

echo "Rdio Scanner Monitor started successfully!"
echo "Access Grafana at: http://localhost:3000 (admin/admin)"
echo "Check status with: $0/../status.sh"
EOF

    # Stop script
    cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
set -e

echo "Stopping Rdio Scanner Monitor..."

systemctl stop rdio-monitor.service || echo "Service already stopped"

cd /etc/rdio-monitor

# Try podman-compose first, fall back to manual
if command -v podman-compose &> /dev/null; then
    podman-compose down
elif command -v /usr/local/bin/podman-compose-wrapper &> /dev/null; then
    /usr/local/bin/podman-compose-wrapper down
else
    # Manual container stop
    echo "Stopping containers manually..."
    podman stop rdio-scanner-app rdio-grafana rdio-redis rdio-postgresql || true
    podman rm rdio-scanner-app rdio-grafana rdio-redis rdio-postgresql || true
    podman network rm rdio_network || true
fi

echo "Rdio Scanner Monitor stopped"
EOF

    # Status script
    cat > "$INSTALL_DIR/status.sh" << 'EOF'
#!/bin/bash

echo "=== Rdio Scanner Monitor System Status ==="
echo

echo "Service Status:"
systemctl status rdio-monitor.service --no-pager -l || echo "Service not running"
echo

echo "Container Status:"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || echo "No containers running"
echo

echo "Network Status:"
podman network ls | grep rdio_network || echo "Network not found"
echo

echo "Disk Usage:"
df -h /opt/rdio-monitor /var/lib/rdio-monitor /var/log/rdio-monitor 2>/dev/null || echo "Directories not found"
echo

echo "Recent Logs (last 20 lines):"
tail -20 /var/log/rdio-monitor/scanner.log 2>/dev/null || echo "No logs found"
echo

echo "Container Health:"
for container in rdio-postgresql rdio-redis rdio-grafana rdio-scanner-app; do
    if podman ps --filter "name=$container" --format "{{.Names}}" | grep -q "$container"; then
        echo "✓ $container: Running"
        # Try to get health status
        health=$(podman inspect "$container" --format "{{.State.Health.Status}}" 2>/dev/null || echo "unknown")
        if [[ "$health" != "unknown" ]]; then
            echo "  Health: $health"
        fi
    else
        echo "✗ $container: Not running"
    fi
done
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
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

${DATA_DIR}/audio/*.log {
    weekly
    missingok
    rotate 12
    compress
    delaycompress
    notifempty
    create 644 podman podman
}
EOF
    
    log_message "INFO" "Log rotation configured"
}

# Set ownership and permissions
set_permissions() {
    log_message "INFO" "Setting ownership and permissions..."
    
    # Set ownership
    chown -R podman:podman "$DATA_DIR"
    chown -R podman:podman "$LOG_DIR"
    chown root:root "$CONFIG_DIR"/*.conf "$CONFIG_DIR"/*.ini "$CONFIG_DIR"/*.yml
    
    # Set permissions
    chmod 640 "$CONFIG_DIR/config.ini"
    chmod 644 "$CONFIG_DIR"/*.conf "$CONFIG_DIR"/*.yml "$CONFIG_DIR"/*.ini
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
    create_scripts
    setup_logging
    set_permissions
    
    log_message "INFO" "Installation completed successfully!"
    
    echo
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  Rdio Scanner Monitor Installation Complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo
    echo "Next steps:"
    echo "  1. Edit configuration: $CONFIG_DIR/config.ini"
    echo "  2. Configure your Rdio Scanner domain in the config file"
    echo "  3. Start services: $INSTALL_DIR/start.sh"
    echo "  4. Check status: $INSTALL_DIR/status.sh"
    echo "  5. Access Grafana: http://localhost:3000 (admin/admin)"
    echo
    echo "Important directories:"
    echo "  - Installation: $INSTALL_DIR"
    echo "  - Configuration: $CONFIG_DIR"
    echo "  - Data: $DATA_DIR"
    echo "  - Logs: $LOG_DIR"
    echo
    echo "Management commands:"
    echo "  - Start:  $INSTALL_DIR/start.sh"
    echo "  - Stop:   $INSTALL_DIR/stop.sh"
    echo "  - Status: $INSTALL_DIR/status.sh"
    echo
}

# Execute main function
main "$@"