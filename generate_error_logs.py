#!/usr/bin/env python3
"""
Generate error log entries for Google Cloud Error Reporting.

This script creates various types of error log entries that follow the
Error Reporting format and will show up in GCP Error Reporting.
"""

import json
import random
import traceback
import warnings
from datetime import datetime

# Suppress urllib3 warnings about OpenSSL version
warnings.filterwarnings('ignore', message='urllib3 v2 only supports OpenSSL')

from google.cloud import logging
from google.cloud.logging import DESCENDING


class ErrorGenerator:
    """Generate different types of errors for testing Error Reporting."""
    
    def __init__(self, project_id=None, prefix=None):
        """Initialize the error generator with a Cloud Logging client."""
        import os
        
        # Try to get project ID from various sources
        if not project_id:
            # Try environment variable
            project_id = os.environ.get('GOOGLE_CLOUD_PROJECT') or os.environ.get('GCP_PROJECT')
            
        if not project_id:
            # Try to get from gcloud config
            try:
                import subprocess
                result = subprocess.run(['gcloud', 'config', 'get-value', 'project'], 
                                      capture_output=True, text=True)
                if result.returncode == 0 and result.stdout.strip():
                    project_id = result.stdout.strip()
            except:
                pass
                
        if not project_id:
            raise ValueError(
                "Project ID not found. Please provide it using one of these methods:\n"
                "1. Pass --project-id flag: python generate_error_logs.py --project-id YOUR_PROJECT_ID\n"
                "2. Set environment variable: export GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID\n"
                "3. Set gcloud default project: gcloud config set project YOUR_PROJECT_ID"
            )
            
        print(f"Using project ID: {project_id}")
        self.project_id = project_id
        self.client = logging.Client(project=project_id)
        self.logger = self.client.logger('error-reporting-demo')
        self.prefix = prefix
        
        print("Logger initialized successfully")
        if self.prefix:
            print(f"Error message prefix: '{self.prefix}'")
        
    def generate_python_exception(self):
        """Generate a Python exception with stack trace."""
        try:
            # Intentionally cause different types of errors
            error_type = random.choice(['division', 'index', 'key', 'value', 'type'])
            
            if error_type == 'division':
                result = 10 / 0
            elif error_type == 'index':
                lst = [1, 2, 3]
                item = lst[10]
            elif error_type == 'key':
                d = {'a': 1}
                value = d['nonexistent_key']
            elif error_type == 'value':
                int('not_a_number')
            else:
                # Type error
                result = "string" + 123
                
        except Exception as e:
            # Get the stack trace
            stack_trace = traceback.format_exc()
            return str(e), stack_trace
            
    def log_reported_error_event_format(self):
        """Log an error using the ReportedErrorEvent format."""
        # Simulate different types of application errors
        error_scenarios = [
            {
                'message': 'NullPointerException: Cannot read property "id" of null\n'
                          'at UserService.getUser (UserService.java:45)\n'
                          'at UserController.handleRequest (UserController.java:123)\n'
                          'at RequestHandler.process (RequestHandler.java:67)',
                'service': 'user-service',
                'http_path': '/api/users/12345'
            },
            {
                'message': 'SQLException: Connection pool exhausted\n'
                          'at DatabasePool.getConnection (DatabasePool.java:89)\n'
                          'at OrderRepository.findById (OrderRepository.java:156)\n'
                          'at OrderService.processOrder (OrderService.java:234)',
                'service': 'order-service',
                'http_path': '/api/orders/process'
            },
            {
                'message': 'TimeoutException: Request timed out after 5000ms\n'
                          'at HttpClient.sendRequest (HttpClient.java:78)\n'
                          'at PaymentGateway.charge (PaymentGateway.java:45)\n'
                          'at PaymentService.processPayment (PaymentService.java:123)',
                'service': 'payment-service',
                'http_path': '/api/payments/charge'
            }
        ]
        
        scenario = random.choice(error_scenarios)
        
        # Prepend prefix to message if provided
        message = scenario['message']
        if self.prefix:
            message = f"{self.prefix}\n{message}"
        
        # Format as ReportedErrorEvent
        reported_error = {
            'eventTime': datetime.utcnow().isoformat() + 'Z',
            'serviceContext': {
                'service': scenario['service'],
                'version': f'v{random.randint(1, 3)}.{random.randint(0, 9)}.{random.randint(0, 99)}'
            },
            'message': message,
            'context': {
                'httpRequest': {
                    'method': random.choice(['GET', 'POST', 'PUT']),
                    'url': f'https://api.example.com{scenario["http_path"]}',
                    'userAgent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
                    'referrer': 'https://app.example.com',
                    'responseStatusCode': 500,
                    'remoteIp': f'192.168.{random.randint(1, 255)}.{random.randint(1, 255)}'
                },
                'user': f'user_{random.randint(10000, 99999)}',
                'reportLocation': {
                    'filePath': f'{scenario["service"]}/Main.java',
                    'lineNumber': random.randint(100, 500),
                    'functionName': 'handleRequest'
                }
            }
        }
        
        self.logger.log_struct(
            reported_error,
            severity='ERROR'
        )
        print(f"Logged ReportedErrorEvent format error for {scenario['service']}")
        
    def generate_batch_errors(self, count=10):
        """Generate a batch of different error types."""
        print(f"\nGenerating {count} error log entries...")
        print("=" * 50)
        
        for i in range(count):
            try:
                self.log_reported_error_event_format()
                print(f"  [{i+1}/{count}] ✓ Error logged successfully")
            except Exception as e:
                print(f"  [{i+1}/{count}] ✗ Failed to log error: {e}")
                
        print("=" * 50)
        print(f"Finished generating {count} error log entries.")
        print("\nCheck Google Cloud Console:")
        print("  - Logging: https://console.cloud.google.com/logs")
        print("  - Error Reporting: https://console.cloud.google.com/errors")
        print("\nNote: Logs will be routed to buckets based on your log sink configurations.")


def main():
    """Main function to run the error generator."""
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Generate error logs for Google Cloud Error Reporting'
    )
    parser.add_argument(
        '--project-id',
        help='Google Cloud Project ID (optional, uses default if not specified)'
    )
    parser.add_argument(
        '--count',
        type=int,
        default=10,
        help='Number of error log entries to generate (default: 10)'
    )
    parser.add_argument(
        '--prefix',
        help='String to prepend to all error messages'
    )
    
    args = parser.parse_args()
    
    try:
        # Create error generator
        generator = ErrorGenerator(project_id=args.project_id, prefix=args.prefix)
        
        # Generate a batch of error logs
        generator.generate_batch_errors(args.count)
                    
    except ValueError as e:
        print(f"\nError: {e}")
        return 1
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        return 1
        
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main())
