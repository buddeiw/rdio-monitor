# Rdio Scanner Monitor

A comprehensive monitoring system for Rdio Scanner domains that captures call metadata and audio files using Podman containers on Rocky Linux 10.

## 🚀 Features

- **Automated Call Monitoring**: Polls Rdio Scanner APIs for new radio calls
- **Audio Capture & Processing**: Downloads, processes, and stores audio files with format conversion
- **Database Storage**: PostgreSQL backend for call metadata with optimized schema
- **Real-time Monitoring**: Grafana dashboards for system visualization and alerting
- **Containerized Deployment**: Podman-based architecture for reliability and isolation
- **Security Hardened**: Firewall configuration, SELinux integration, and security best practices
- **Scalable Architecture**: Designed for high-volume radio systems with resource management
- **Health Monitoring**: Comprehensive health checks and system monitoring

## 📋 System Requirements

### Operating System
- **Rocky Linux 10** (required)
- **Architecture**: x86_64
- **SELinux**: Enforcing (supported and configured)

### Hardware Requirements
- **Memory**: Minimum 4GB RAM (8GB+ recommended for high-volume systems)
- **Storage**: 20GB+ free space (additional space needed for audio storage)
- **CPU**: 2+ cores (4+ cores recommended)
- **Network**: Stable internet connection for API polling

### Software Dependencies
All dependencies are automatically installed by the installation script:
- Podman 4.0+ and Podman Compose
- Python 3.9+
- PostgreSQL client tools
- FFmpeg for audio processing
- Firewalld for security
- Standard development tools

## 🔧 Installation

### Quick Start

1. **Download all installation files**:
   ```bash
   # Create installation directory
   mkdir -p /opt/rdio-monitor-install
   cd /opt/rdio-monitor-install
   
   # Download or copy all 16 required files to this directory
   # Verify all files are present:
   ls -la
   ```

2. **Required Files Checklist**:
   ```
   ✓ install.sh                 # Main installation script
   ✓ config.ini                 # Main configuration file
   ✓ docker-compose.yml         # Container orchestration
   ✓ Dockerfile                 # Scanner application container
   ✓ requirements.txt           # Python dependencies
   ✓ rdio_scanner.py            # Main Python application
   ✓ health_check.py            # Container health check
   ✓ entrypoint.sh              # Container entrypoint
   ✓ schema.sql                 # PostgreSQL database schema
   ✓ rdio-monitor.service       # Systemd service file
   ✓ postgresql.conf            # PostgreSQL configuration
   ✓ grafana.ini                # Grafana configuration
   ✓ nginx.conf                 # Nginx reverse proxy config
   ✓ supervisord.conf           # Process management
   ✓ config.ini.template        # Environment variable template
   ✓ README.md                  # This documentation
   ```

3. **Run the installation**:
   ```bash
   # Make installer executable
   chmod +x install.sh
   
   # Run installation as root
   sudo ./install.sh
   ```

4. **Configure your Rdio Scanner domain**:
   ```bash
   # Edit the main configuration file
   sudo nano /etc/rdio-monitor/config.ini
   
   # REQUIRED: Set your Rdio Scanner domain
   # Change this line:
   domain = https://your-rdio-scanner-domain.com
   # To your actual domain:
   domain = https://your-actual-scanner-domain.com
   ```

5. **Start the system**:
   ```bash
   # Start all services
   sudo /opt/rdio-monitor/start.sh
   
   # Check system status
   sudo /opt/rdio-monitor/status.sh
   ```

6. **Access the monitoring dashboard**:
   ```
   Grafana: http://your-server:3000
   Default Login: admin/admin (change immediately!)
   Scanner API: http://your-server:8080/health
   ```

## ⚙️ Configuration

### Essential Configuration

The main configuration file is located at `/etc/rdio-monitor/config.ini`. Key settings to configure:

#### Rdio Scanner Settings (REQUIRED)
```ini
[rdio_scanner]
# REQUIRED: Replace with your actual Rdio Scanner domain
domain = https://your-rdio-scanner-domain.com
api_path = /api/calls
poll_interval = 30
max_calls_per_request = 100
auth_token =  # Add if your scanner requires authentication
```

#### Database Configuration
```ini
[database]
host = rdio-postgresql  # Container name (don't change)
port = 5432
database = rdio_scanner
username = scanner
password = scanner_password  # Change in production
```

#### Audio Processing
```ini
[audio]
enable_recording = true
storage_path = /var/lib/rdio-monitor/audio
audio_format = mp3  # mp3, wav, flac
audio_quality = 192  # bitrate for mp3
retention_days = 30  # 0 = keep forever
```

#### Monitoring and Alerts
```ini
[monitoring]
collect_metrics = true
email_notifications = false
smtp_server = smtp.gmail.com
email_recipients = admin@your-domain.com
disk_space_threshold = 85
```

### Security Configuration

The system is configured with security best practices:
- Firewall rules for required ports only
- Non-root container execution
- SELinux integration and labeling
- Resource limits and quotas
- Rate limiting and access controls

#### Firewall Ports
The installer automatically configures these ports:
- **5432/tcp**: PostgreSQL database
- **3000/tcp**: Grafana dashboard
- **8080/tcp**: Scanner API and health checks
- **80/tcp**: HTTP (Nginx reverse proxy)
- **443/tcp**: HTTPS (if SSL configured)
- **6379/tcp**: Redis cache

## 🐳 Container Architecture

The system uses Podman with these containers:

### Core Containers
- **rdio-postgresql**: PostgreSQL 15 database with optimized configuration
- **rdio-scanner-app**: Custom Python application for call monitoring
- **rdio-grafana**: Grafana for dashboards and visualization
- **rdio-redis**: Redis for caching and session management
- **rdio-nginx**: Nginx reverse proxy for load balancing

### Container Network
- **Network**: `rdio_network` (172.20.0.0/24)
- **Isolation**: All containers communicate via internal network
- **Health Checks**: Comprehensive health monitoring for all services
- **Resource Limits**: CPU and memory limits to prevent resource exhaustion

## 📊 Monitoring & Dashboards

### Grafana Dashboards
Access Grafana at `http://your-server:3000`

**Default Login**: admin/admin (⚠️ **Change immediately!**)

#### Key Dashboards Include:
- **System Overview**: Call processing rates, system health
- **Call Analytics**: Frequency analysis, department breakdowns
- **Performance Metrics**: Database performance, API response times
- **Storage Monitoring**: Disk usage, audio file statistics
- **Error Tracking**: Failed calls, system errors, alerts

### System Health Monitoring
- **Health Endpoint**: `http://your-server:8080/health`
- **Metrics Endpoint**: `http://your-server:8080/stats`
- **Nginx Status**: `http://your-server/nginx_status` (localhost only)

### Key Metrics Tracked
- Call processing rate (calls per minute/hour)
- Audio processing success/failure rates
- Database query performance and connection health
- System resource utilization (CPU, memory, disk)
- Storage growth rates and cleanup statistics
- API response times and error rates

## 🔧 Management Commands

The system provides easy-to-use management scripts:

### Start/Stop Services
```bash
# Start all services
sudo /opt/rdio-monitor/start.sh

# Stop all services  
sudo /opt/rdio-monitor/stop.sh

# Check system status
sudo /opt/rdio-monitor/status.sh
```

### Service Management
```bash
# Using systemd service
sudo systemctl status rdio-monitor.service
sudo systemctl start rdio-monitor.service
sudo systemctl stop rdio-monitor.service
sudo systemctl restart rdio-monitor.service

# Enable/disable automatic startup
sudo systemctl enable rdio-monitor.service
sudo systemctl disable rdio-monitor.service
```

### Container Management
```bash
# Check container status
cd /etc/rdio-monitor
sudo podman-compose ps

# View container logs
sudo podman-compose logs rdio-scanner-app
sudo podman-compose logs rdio-postgresql
sudo podman-compose logs rdio-grafana

# Restart specific container
sudo podman-compose restart rdio-scanner-app
```

### Log Management
```bash
# Application logs
sudo tail -f /var/log/rdio-monitor/scanner.log

# System service logs
sudo journalctl -u rdio-monitor.service -f

# Container logs
sudo podman logs rdio-scanner-app --follow
```

## 🗄️ Database Schema

The PostgreSQL database includes optimized tables:

### Main Tables
- **`calls`**: Radio call metadata with full indexing
- **`audio_files`**: Audio file tracking and processing status  
- **`system_stats`**: Performance metrics and monitoring data

### Key Features
- **UUID primary keys** for distributed systems
- **JSONB metadata columns** for flexible data storage
- **Comprehensive indexing** for high-performance queries
- **Automatic cleanup functions** for data retention
- **Performance optimization** for time-series workloads

### Database Maintenance
```sql
-- Get system statistics
SELECT * FROM get_system_metrics();

-- Clean up old records (30 days)
SELECT cleanup_old_records(30);

-- Check recent calls
SELECT * FROM recent_calls LIMIT 10;

-- System health summary
SELECT * FROM system_health_summary;
```

## 🔊 Audio Processing Pipeline

The audio processing system provides:

### Audio Capture Features
1. **Download**: Fetches audio files from Rdio Scanner URLs
2. **Format Conversion**: Supports MP3, WAV, FLAC formats
3. **Quality Control**: Configurable bitrates and compression
4. **Processing**: Audio normalization and gain control
5. **Storage**: Organized directory structure with metadata
6. **Cleanup**: Automatic removal based on retention policies

### Supported Audio Formats
- **MP3**: Configurable bitrate (128, 192, 256, 320 kbps)
- **WAV**: Uncompressed PCM audio
- **FLAC**: Lossless compression

### Storage Management
```bash
# Check audio storage usage
df -h /var/lib/rdio-monitor/audio

# Manual cleanup (remove files older than 30 days)
find /var/lib/rdio-monitor/audio -type f -mtime +30 -delete

# Check audio processing statistics
curl -s http://localhost:8080/stats | jq '.audio_stats'
```

## 🚨 Alerting & Notifications

### Built-in Alert Rules
- **High Error Rates**: >5% processing failures
- **Low Disk Space**: >85% storage utilization
- **High Memory Usage**: >90% memory utilization
- **Database Issues**: Connection failures or slow queries
- **API Problems**: Response time >5 seconds or failures
- **Processing Delays**: Backup in call processing queue

### Notification Channels
Configure in `/etc/rdio-monitor/config.ini`:
```ini
[monitoring]
email_notifications = true
smtp_server = smtp.gmail.com
smtp_port = 587
smtp_username = your-email@gmail.com
smtp_password = your-app-password
email_recipients = admin@your-domain.com,ops@your-domain.com
```

### Custom Alerts
Grafana supports custom alerting rules with:
- **Email notifications**
- **Slack integration**
- **Webhook endpoints**
- **PagerDuty integration**

## 🔐 Security Features

### Network Security
- **Firewall Integration**: Automatic firewall rule configuration
- **Container Isolation**: Network-isolated container environment
- **Rate Limiting**: Protection against DoS attacks
- **SSL/TLS Support**: HTTPS configuration ready

### Application Security
- **Non-root Execution**: All containers run as non-privileged users
- **Resource Limits**: CPU and memory quotas prevent resource exhaustion
- **Input Validation**: Sanitized API inputs and SQL injection protection
- **Audit Logging**: Comprehensive logging for security monitoring

### Data Security
- **Database Encryption**: Support for encrypted connections
- **File Integrity**: SHA-256 checksums for audio files
- **Access Controls**: Role-based database permissions
- **Secure Configuration**: Secrets management and secure defaults

## 📈 Performance Optimization

### Database Tuning
The system includes PostgreSQL optimizations:
```sql
-- Key performance settings in postgresql.conf
shared_buffers = 256MB           -- Optimized for container
work_mem = 16MB                  -- Query processing memory
maintenance_work_mem = 128MB     -- Maintenance operations
effective_cache_size = 1GB       -- Available system cache
checkpoint_timeout = 15min       -- Checkpoint frequency
autovacuum = on                  -- Automatic maintenance
```

### Application Performance
- **Connection Pooling**: Database connection reuse
- **Async Processing**: Non-blocking I/O operations
- **Caching**: Redis-backed caching layer
- **Batch Processing**: Efficient bulk operations
- **Resource Monitoring**: Automatic performance tracking

### System Optimization
```bash
# Check system performance
sudo /opt/rdio-monitor/status.sh

# Monitor resource usage
htop
iostat -x 1
df -h

# Database performance
sudo podman exec rdio-postgresql psql -U postgres -d rdio_scanner -c "
SELECT 
    schemaname,
    tablename,
    attname,
    n_distinct,
    correlation 
FROM pg_stats 
WHERE tablename = 'calls'
ORDER BY n_distinct DESC;"
```

## 🔄 Backup & Recovery

### Automatic Backups
Configure in `/etc/rdio-monitor/config.ini`:
```ini
[backup]
enable_backups = true
backup_interval = 24        # Hours between backups
backup_retention = 7        # Days to keep backups
backup_path = /var/lib/rdio-monitor/backups
backup_audio = false        # Include audio files (large!)
compress_backups = true     # Compress backup files
```

### Manual Backup Procedures
```bash
# Database backup
sudo podman exec rdio-postgresql pg_dump -U postgres rdio_scanner > \
    /var/lib/rdio-monitor/backups/manual_backup_$(date +%Y%m%d).sql

# Audio files backup (use rsync for efficiency)
sudo rsync -av /var/lib/rdio-monitor/audio/ /backup/rdio-monitor/audio/

# Configuration backup
sudo tar -czf /var/lib/rdio-monitor/backups/config_$(date +%Y%m%d).tar.gz \
    /etc/rdio-monitor/

# Container images backup
sudo podman save -o /var/lib/rdio-monitor/backups/images_$(date +%Y%m%d).tar \
    rdio-scanner:latest postgres:15-alpine grafana/grafana:latest
```

### Recovery Procedures
```bash
# Stop services
sudo /opt/rdio-monitor/stop.sh

# Restore database
sudo podman exec -i rdio-postgresql psql -U postgres rdio_scanner < \
    /var/lib/rdio-monitor/backups/backup_20240101.sql

# Restore audio files
sudo rsync -av /backup/rdio-monitor/audio/ /var/lib/rdio-monitor/audio/

# Restore configuration
sudo tar -xzf /var/lib/rdio-monitor/backups/config_20240101.tar.gz -C /

# Start services
sudo /opt/rdio-monitor/start.sh
```

## 🐛 Troubleshooting

### Common Issues

#### Installation Problems
```bash
# Check system requirements
cat /etc/rocky-release
df -h /
free -m

# Verify all files present
ls -la /opt/rdio-monitor-install/
# Should show all 16 required files

# Check installation logs
tail -f /var/log/rdio-monitor/install.log
```

#### Container Issues
```bash
# Check container status
cd /etc/rdio-monitor
sudo podman-compose ps

# Container logs
sudo podman-compose logs rdio-scanner-app
sudo podman-compose logs rdio-postgresql

# Restart problematic container
sudo podman-compose restart rdio-scanner-app

# Rebuild containers
sudo podman-compose build --no-cache
sudo podman-compose up -d
```

#### Database Connection Problems
```bash
# Test database connectivity
sudo podman exec rdio-postgresql pg_isready -U postgres

# Check database logs
sudo podman logs rdio-postgresql

# Manual database connection
sudo podman exec -it rdio-postgresql psql -U postgres -d rdio_scanner

# Check database statistics
sudo podman exec rdio-postgresql psql -U postgres -d rdio_scanner -c "
SELECT * FROM get_system_metrics();"
```

#### Audio Processing Issues
```bash
# Check audio storage space
df -h /var/lib/rdio-monitor/audio

# Verify FFmpeg availability
sudo podman exec rdio-scanner-app ffmpeg -version

# Check audio processing logs
grep -i audio /var/log/rdio-monitor/scanner.log

# Test audio download manually
curl -I "https://your-scanner-domain.com/audio/test.mp3"
```

#### API Connection Failures
```bash
# Test API connectivity
curl -I https://your-rdio-scanner-domain.com/api/calls

# Check DNS resolution
nslookup your-rdio-scanner-domain.com

# Verify firewall rules
sudo firewall-cmd --list-all

# Check network connectivity from container
sudo podman exec rdio-scanner-app curl -I https://your-rdio-scanner-domain.com
```

### Performance Issues
```bash
# Check system resources
htop
iotop
nethogs

# Database performance
sudo podman exec rdio-postgresql psql -U postgres -d rdio_scanner -c "
SELECT query, calls, total_time, mean_time 
FROM pg_stat_statements 
ORDER BY total_time DESC 
LIMIT 10;"

# Container resource usage
sudo podman stats

# Application performance
curl -s http://localhost:8080/health | jq
```

### Log Analysis
```bash
# Real-time application logs
sudo tail -f /var/log/rdio-monitor/scanner.log

# Search for errors
sudo grep -i error /var/log/rdio-monitor/*.log

# System service logs
sudo journalctl -u rdio-monitor.service --since "1 hour ago"

# Container logs with timestamps
sudo podman-compose logs --timestamps rdio-scanner-app
```

## 📚 API Reference

### Health Check Endpoints
```http
GET /health
# Returns system health status and database connectivity

GET /stats  
# Returns call processing statistics

GET /metrics
# Returns Prometheus-compatible metrics
```

### Example API Responses
```json
{
  "status": "healthy",
  "timestamp": "2024-01-01T12:00:00Z",
  "database_stats": {
    "total_calls": 1250,
    "processed_calls": 1240,
    "unprocessed_calls": 10,
    "calls_last_24h": 150,
    "unique_systems": 5,
    "avg_duration": 23.5
  }
}
```

## 🔧 Development & Customization

### Local Development Setup
```bash
# Create development environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run in development mode
export CONFIG_FILE=config/dev.ini
export DEBUG_MODE=true
python3 rdio_scanner.py
```

### Custom Configuration
```bash
# Override specific settings with environment variables
export RDIO_SCANNER_DOMAIN="https://your-custom-domain.com"
export AUDIO_RETENTION_DAYS=60
export LOG_LEVEL=DEBUG

# Use custom config template
cp config.ini.template config/custom.ini
# Edit custom.ini with your settings
export CONFIG_FILE=config/custom.ini
```

### Adding Custom Monitoring
```python
# Add custom metrics to rdio_scanner.py
from prometheus_client import Counter, Histogram

custom_counter = Counter('custom_metric_total', 'Custom metric description')
custom_histogram = Histogram('custom_duration_seconds', 'Custom duration metric')

# Use in your code
custom_counter.inc()
with custom_histogram.time():
    # Your custom operation
    pass
```

## 📄 File Locations

### Important Directories
```
/opt/rdio-monitor/           # Application files
├── rdio_scanner.py          # Main application
├── health_check.py          # Health check script
├── start.sh                 # Start script
├── stop.sh                  # Stop script
└── status.sh                # Status script

/etc/rdio-monitor/           # Configuration files
├── config.ini               # Main configuration
├── docker-compose.yml       # Container orchestration
├── postgresql.conf          # Database configuration
├── grafana.ini              # Grafana configuration
└── nginx.conf               # Nginx configuration

/var/lib/rdio-monitor/       # Data directory
├── postgresql/              # Database data
├── grafana/                 # Dashboard data
├── audio/                   # Audio file storage
├── redis/                   # Cache data
└── backups/                 # Backup files

/var/log/rdio-monitor/       # Log directory
├── scanner.log              # Application logs
├── install.log              # Installation logs
└── nginx/                   # Nginx logs
```

## 🆘 Support & Maintenance

### Regular Maintenance Tasks
```bash
# Weekly maintenance (run as cron job)
#!/bin/bash
# Clean up old logs
find /var/log/rdio-monitor -name "*.log.*" -mtime +30 -delete

# Update container images
cd /etc/rdio-monitor
sudo podman-compose pull
sudo podman-compose up -d

# Database maintenance
sudo podman exec rdio-postgresql psql -U postgres -d rdio_scanner -c "VACUUM ANALYZE;"

# Check system health
sudo /opt/rdio-monitor/status.sh
```

### System Updates
```bash
# Update Rocky Linux packages
sudo dnf update -y

# Update container images
cd /etc/rdio-monitor
sudo podman-compose pull
sudo podman-compose up -d

# Update Python dependencies (if needed)
cd /opt/rdio-monitor
pip install --upgrade -r requirements.txt
```

### Getting Help
- **System Logs**: Check `/var/log/rdio-monitor/` for detailed logs
- **Health Status**: Use `/opt/rdio-monitor/status.sh` for system overview
- **Container Logs**: Use `podman-compose logs [service]` for container-specific issues
- **Database Issues**: Connect directly with `podman exec -it rdio-postgresql psql`

---

**Version**: 1.0.0  
**Last Updated**: January 2024  
**Compatibility**: Rocky Linux 10, Podman 4.0+

This system provides a robust, production-ready solution for monitoring Rdio Scanner systems with comprehensive logging, monitoring, and alerting capabilities.