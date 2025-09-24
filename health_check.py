#!/usr/bin/env python3
"""
Health Check Script for Rdio Scanner Monitor Container

This script performs comprehensive health checks for the containerized
Rdio Scanner Monitor application, including database connectivity,
API responsiveness, and system resource checks.

Exit codes:
    0 - All health checks passed
    1 - Critical health check failed
    2 - Warning level issues detected
"""

import sys
import os
import time
import json
import socket
import subprocess
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple
import logging

# Configure logging for health check script
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger('health_check')

class HealthChecker:
    """
    Comprehensive health checking system for the Rdio Scanner Monitor.
    
    This class performs various health checks including database connectivity,
    API responsiveness, system resources, and application-specific metrics.
    """
    
    def __init__(self):
        """Initialize the health checker with configuration."""
        self.start_time = time.time()
        self.checks_passed = 0
        self.checks_failed = 0
        self.checks_warning = 0
        self.results = []
        
        # Configuration from environment variables
        self.config = {
            'database_host': os.getenv('DATABASE_HOST', 'localhost'),
            'database_port': int(os.getenv('DATABASE_PORT', '5432')),
            'database_name': os.getenv('DATABASE_NAME', 'rdio_scanner'),
            'database_user': os.getenv('DATABASE_USER', 'scanner'),
            'database_password': os.getenv('DATABASE_PASSWORD', 'scanner_password'),
            'redis_host': os.getenv('REDIS_HOST', 'localhost'),
            'redis_port': int(os.getenv('REDIS_PORT', '6379')),
            'api_port': int(os.getenv('API_PORT', '8080')),
            'health_timeout': int(os.getenv('HEALTH_TIMEOUT', '10')),
        }
        
        logger.info("Health checker initialized")
    
    def add_result(self, check_name: str, status: str, message: str, 
                  details: Optional[Dict] = None, duration: Optional[float] = None):
        """
        Add a health check result to the results list.
        
        Args:
            check_name: Name of the health check
            status: Status (pass, fail, warning)
            message: Human-readable message
            details: Additional details about the check
            duration: Time taken for the check in seconds
        """
        result = {
            'check': check_name,
            'status': status,
            'message': message,
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'duration_seconds': duration,
            'details': details or {}
        }
        
        self.results.append(result)
        
        # Update counters
        if status == 'pass':
            self.checks_passed += 1
            logger.info(f"✓ {check_name}: {message}")
        elif status == 'fail':
            self.checks_failed += 1
            logger.error(f"✗ {check_name}: {message}")
        elif status == 'warning':
            self.checks_warning += 1
            logger.warning(f"⚠ {check_name}: {message}")
    
    def check_database_connectivity(self) -> bool:
        """
        Test database connectivity and basic operations.
        
        Returns:
            bool: True if database is healthy, False otherwise
        """
        start_time = time.time()
        
        try:
            import psycopg2
            from psycopg2 import sql
            
            # Create connection string
            connection_params = {
                'host': self.config['database_host'],
                'port': self.config['database_port'],
                'database': self.config['database_name'],
                'user': self.config['database_user'],
                'password': self.config['database_password'],
                'connect_timeout': self.config['health_timeout']
            }
            
            # Test connection
            with psycopg2.connect(**connection_params) as conn:
                with conn.cursor() as cursor:
                    # Test basic query
                    cursor.execute("SELECT version();")
                    version = cursor.fetchone()[0]
                    
                    # Test application tables exist
                    cursor.execute("""
                        SELECT count(*) FROM information_schema.tables 
                        WHERE table_name IN ('calls', 'audio_files', 'system_stats')
                    """)
                    table_count = cursor.fetchone()[0]
                    
                    # Test recent data activity
                    cursor.execute("""
                        SELECT COUNT(*) FROM calls 
                        WHERE created_at > NOW() - INTERVAL '1 hour'
                    """)
                    recent_calls = cursor.fetchone()[0]
                    
                    duration = time.time() - start_time
                    
                    self.add_result(
                        'database_connectivity',
                        'pass',
                        'Database connection and queries successful',
                        {
                            'postgres_version': version,
                            'application_tables': table_count,
                            'recent_calls_count': recent_calls,
                            'response_time_ms': round(duration * 1000, 2)
                        },
                        duration
                    )
                    return True
                    
        except ImportError:
            self.add_result(
                'database_connectivity',
                'fail',
                'psycopg2 module not available',
                {'error': 'Missing psycopg2 dependency'},
                time.time() - start_time
            )
            return False
            
        except Exception as e:
            duration = time.time() - start_time
            self.add_result(
                'database_connectivity',
                'fail',
                f'Database connection failed: {str(e)}',
                {'error_type': type(e).__name__, 'error_details': str(e)},
                duration
            )
            return False
    
    def check_redis_connectivity(self) -> bool:
        """
        Test Redis connectivity if Redis is configured.
        
        Returns:
            bool: True if Redis is healthy or not configured, False if configured but failing
        """
        redis_url = os.getenv('REDIS_URL')
        if not redis_url and self.config['redis_host'] == 'localhost':
            self.add_result(
                'redis_connectivity',
                'pass',
                'Redis not configured - skipping check',
                {'configured': False}
            )
            return True
        
        start_time = time.time()
        
        try:
            # Test TCP connection to Redis
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.config['health_timeout'])
            result = sock.connect_ex((self.config['redis_host'], self.config['redis_port']))
            sock.close()
            
            duration = time.time() - start_time
            
            if result == 0:
                self.add_result(
                    'redis_connectivity',
                    'pass',
                    'Redis connection successful',
                    {'response_time_ms': round(duration * 1000, 2)},
                    duration
                )
                return True
            else:
                self.add_result(
                    'redis_connectivity',
                    'fail',
                    'Redis connection failed',
                    {'error_code': result},
                    duration
                )
                return False
                
        except Exception as e:
            duration = time.time() - start_time
            self.add_result(
                'redis_connectivity',
                'fail',
                f'Redis connectivity check failed: {str(e)}',
                {'error_type': type(e).__name__},
                duration
            )
            return False
    
    def check_api_responsiveness(self) -> bool:
        """
        Test internal API responsiveness.
        
        Returns:
            bool: True if API is responding, False otherwise
        """
        start_time = time.time()
        
        try:
            import requests
            
            # Test API health endpoint
            url = f"http://localhost:{self.config['api_port']}/health"
            response = requests.get(
                url, 
                timeout=self.config['health_timeout'],
                headers={'User-Agent': 'HealthCheck/1.0'}
            )
            
            duration = time.time() - start_time
            
            if response.status_code == 200:
                try:
                    data = response.json()
                    self.add_result(
                        'api_responsiveness',
                        'pass',
                        'API health endpoint responding',
                        {
                            'status_code': response.status_code,
                            'response_time_ms': round(duration * 1000, 2),
                            'response_data': data
                        },
                        duration
                    )
                except json.JSONDecodeError:
                    self.add_result(
                        'api_responsiveness',
                        'warning',
                        'API responding but returned invalid JSON',
                        {
                            'status_code': response.status_code,
                            'response_text': response.text[:200]
                        },
                        duration
                    )
                return True
            else:
                self.add_result(
                    'api_responsiveness',
                    'fail',
                    f'API returned status code {response.status_code}',
                    {
                        'status_code': response.status_code,
                        'response_text': response.text[:200]
                    },
                    duration
                )
                return False
                
        except ImportError:
            self.add_result(
                'api_responsiveness',
                'warning',
                'requests module not available for API check',
                {'error': 'Missing requests dependency'}
            )
            return True  # Don't fail health check for missing optional dependency
            
        except requests.exceptions.ConnectioError:
            duration = time.time() - start_time
            self.add_result(
                'api_responsiveness',
                'fail',
                'Cannot connect to API endpoint',
                {'url': url, 'timeout': self.config['health_timeout']},
                duration
            )
            return False
            
        except Exception as e:
            duration = time.time() - start_time
            self.add_result(
                'api_responsiveness',
                'fail',
                f'API health check failed: {str(e)}',
                {'error_type': type(e).__name__},
                duration
            )
            return False
    
    def check_filesystem_health(self) -> bool:
        """
        Check filesystem health and available space.
        
        Returns:
            bool: True if filesystem is healthy, False otherwise
        """
        start_time = time.time()
        
        try:
            import shutil
            
            # Check critical directories
            critical_paths = ['/app', '/app/logs', '/app/audio', '/app/temp']
            path_stats = {}
            
            for path in critical_paths:
                if os.path.exists(path):
                    try:
                        total, used, free = shutil.disk_usage(path)
                        used_percent = (used / total) * 100
                        
                        path_stats[path] = {
                            'total_bytes': total,
                            'used_bytes': used,
                            'free_bytes': free,
                            'used_percent': round(used_percent, 2),
                            'exists': True
                        }
                    except Exception as e:
                        path_stats[path] = {
                            'exists': True,
                            'error': str(e)
                        }
                else:
                    path_stats[path] = {'exists': False}
            
            # Check if any path has critically low space
            critical_space = False
            warning_space = False
            
            for path, stats in path_stats.items():
                if 'used_percent' in stats:
                    if stats['used_percent'] > 95:
                        critical_space = True
                    elif stats['used_percent'] > 85:
                        warning_space = True
            
            duration = time.time() - start_time
            
            if critical_space:
                self.add_result(
                    'filesystem_health',
                    'fail',
                    'Critical: Filesystem space usage > 95%',
                    {'path_stats': path_stats},
                    duration
                )
                return False
            elif warning_space:
                self.add_result(
                    'filesystem_health',
                    'warning',
                    'Warning: Filesystem space usage > 85%',
                    {'path_stats': path_stats},
                    duration
                )
                return True
            else:
                self.add_result(
                    'filesystem_health',
                    'pass',
                    'Filesystem space usage is healthy',
                    {'path_stats': path_stats},
                    duration
                )
                return True
                
        except Exception as e:
            duration = time.time() - start_time
            self.add_result(
                'filesystem_health',
                'fail',
                f'Filesystem health check failed: {str(e)}',
                {'error_type': type(e).__name__},
                duration
            )
            return False
    
    def check_process_health(self) -> bool:
        """
        Check if critical processes are running.
        
        Returns:
            bool: True if processes are healthy, False otherwise
        """
        start_time = time.time()
        
        try:
            # Check if main Python process is running (current process)
            current_pid = os.getpid()
            
            # Check memory usage
            try:
                with open(f'/proc/{current_pid}/status', 'r') as f:
                    status_content = f.read()
                    
                # Parse memory information
                memory_info = {}
                for line in status_content.split('\n'):
                    if line.startswith('VmRSS:'):
                        memory_info['rss_kb'] = int(line.split()[1])
                    elif line.startswith('VmSize:'):
                        memory_info['size_kb'] = int(line.split()[1])
                
                duration = time.time() - start_time
                
                # Check for excessive memory usage (> 1GB)
                rss_mb = memory_info.get('rss_kb', 0) / 1024
                if rss_mb > 1024:
                    self.add_result(
                        'process_health',
                        'warning',
                        f'High memory usage: {rss_mb:.1f}MB',
                        {
                            'pid': current_pid,
                            'memory_info': memory_info
                        },
                        duration
                    )
                else:
                    self.add_result(
                        'process_health',
                        'pass',
                        f'Process healthy, memory usage: {rss_mb:.1f}MB',
                        {
                            'pid': current_pid,
                            'memory_info': memory_info
                        },
                        duration
                    )
                return True
                
            except FileNotFoundError:
                # /proc not available (non-Linux system)
                duration = time.time() - start_time
                self.add_result(
                    'process_health',
                    'pass',
                    'Process running (memory info not available)',
                    {'pid': current_pid, 'proc_available': False},
                    duration
                )
                return True
                
        except Exception as e:
            duration = time.time() - start_time
            self.add_result(
                'process_health',
                'fail',
                f'Process health check failed: {str(e)}',
                {'error_type': type(e).__name__},
                duration
            )
            return False
    
    def check_application_specific(self) -> bool:
        """
        Check application-specific health indicators.
        
        Returns:
            bool: True if application is healthy, False otherwise
        """
        start_time = time.time()
        
        try:
            # Check if configuration file exists
            config_file = os.getenv('CONFIG_FILE', '/app/config/config.ini')
            config_exists = os.path.exists(config_file)
            
            # Check if log directory is writable
            log_dir = '/app/logs'
            log_writable = os.access(log_dir, os.W_OK) if os.path.exists(log_dir) else False
            
            # Check if audio directory is writable
            audio_dir = '/app/audio'
            audio_writable = os.access(audio_dir, os.W_OK) if os.path.exists(audio_dir) else False
            
            # Check for recent log activity
            recent_logs = False
            if os.path.exists(log_dir):
                try:
                    log_files = [f for f in os.listdir(log_dir) if f.endswith('.log')]
                    for log_file in log_files:
                        log_path = os.path.join(log_dir, log_file)
                        if os.path.getmtime(log_path) > time.time() - 300:  # 5 minutes
                            recent_logs = True
                            break
                except Exception:
                    pass
            
            duration = time.time() - start_time
            
            # Determine overall application health
            issues = []
            if not config_exists:
                issues.append('Configuration file missing')
            if not log_writable:
                issues.append('Log directory not writable')
            if not audio_writable:
                issues.append('Audio directory not writable')
            
            details = {
                'config_file': config_file,
                'config_exists': config_exists,
                'log_directory_writable': log_writable,
                'audio_directory_writable': audio_writable,
                'recent_log_activity': recent_logs
            }
            
            if issues:
                self.add_result(
                    'application_health',
                    'fail',
                    f'Application issues detected: {", ".join(issues)}',
                    details,
                    duration
                )
                return False
            else:
                self.add_result(
                    'application_health',
                    'pass',
                    'Application configuration and directories are healthy',
                    details,
                    duration
                )
                return True
                
        except Exception as e:
            duration = time.time() - start_time
            self.add_result(
                'application_health',
                'fail',
                f'Application health check failed: {str(e)}',
                {'error_type': type(e).__name__},
                duration
            )
            return False
    
    def run_all_checks(self) -> Tuple[int, Dict]:
        """
        Run all health checks and return results.
        
        Returns:
            Tuple[int, Dict]: Exit code and results dictionary
        """
        logger.info("Starting comprehensive health check...")
        
        # Run all health checks
        checks = [
            self.check_database_connectivity,
            self.check_redis_connectivity,
            self.check_api_responsiveness,
            self.check_filesystem_health,
            self.check_process_health,
            self.check_application_specific
        ]
        
        for check in checks:
            try:
                check()
            except Exception as e:
                logger.error(f"Unexpected error in {check.__name__}: {e}")
                self.add_result(
                    check.__name__,
                    'fail',
                    f'Check failed with exception: {str(e)}',
                    {'error_type': type(e).__name__}
                )
        
        # Calculate total duration
        total_duration = time.time() - self.start_time
        
        # Prepare summary
        summary = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'total_duration_seconds': round(total_duration, 3),
            'checks': {
                'total': len(self.results),
                'passed': self.checks_passed,
                'failed': self.checks_failed,
                'warnings': self.checks_warning
            },
            'overall_status': 'healthy' if self.checks_failed == 0 else 'unhealthy',
            'results': self.results
        }
        
        # Determine exit code
        if self.checks_failed > 0:
            exit_code = 1  # Critical failures
        elif self.checks_warning > 0:
            exit_code = 2  # Warnings
        else:
            exit_code = 0  # All healthy
        
        logger.info(f"Health check completed: {self.checks_passed} passed, "
                   f"{self.checks_failed} failed, {self.checks_warning} warnings")
        
        return exit_code, summary


def main():
    """Main function to run health checks."""
    try:
        # Create health checker instance
        checker = HealthChecker()
        
        # Run all health checks
        exit_code, results = checker.run_all_checks()
        
        # Output results
        output_format = os.getenv('HEALTH_OUTPUT_FORMAT', 'json').lower()
        
        if output_format == 'json':
            print(json.dumps(results, indent=2))
        else:
            # Human-readable output
            print(f"Health Check Summary - Status: {results['overall_status'].upper()}")
            print(f"Duration: {results['total_duration_seconds']}s")
            print(f"Results: {results['checks']['passed']} passed, "
                  f"{results['checks']['failed']} failed, "
                  f"{results['checks']['warnings']} warnings")
            
            if results['checks']['failed'] > 0 or results['checks']['warnings'] > 0:
                print("\nIssues detected:")
                for result in results['results']:
                    if result['status'] in ['fail', 'warning']:
                        status_symbol = '✗' if result['status'] == 'fail' else '⚠'
                        print(f"  {status_symbol} {result['check']}: {result['message']}")
        
        sys.exit(exit_code)
        
    except KeyboardInterrupt:
        logger.info("Health check interrupted by user")
        sys.exit(130)
        
    except Exception as e:
        logger.error(f"Unexpected error during health check: {e}")
        print(json.dumps({
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'overall_status': 'error',
            'error': str(e),
            'error_type': type(e).__name__
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()