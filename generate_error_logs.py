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
            
    def log_stack_trace_as_text_payload(self):
        """Log an error with stack trace using textPayload."""
        error_msg, stack_trace = self.generate_python_exception()
        
        # Prepend prefix to stack trace if provided
        if self.prefix:
            stack_trace = f"{self.prefix}\n{stack_trace}"
        
        # Log with textPayload (multi-line string with stack trace)
        self.logger.log_text(
            stack_trace,
            severity='ERROR'
        )
        print(f"Logged error with textPayload: {error_msg}")
        
    def log_stack_trace_as_json_payload(self):
        """Log an error with stack trace using jsonPayload."""
        error_msg, stack_trace = self.generate_python_exception()
        
        # Prepend prefix to message and stack trace if provided
        message = f'Error occurred: {error_msg}'
        if self.prefix:
            message = f'{self.prefix} {message}'
            stack_trace = f"{self.prefix}\n{stack_trace}"
        
        # Log with jsonPayload containing stack_trace field
        json_payload = {
            'message': message,
            'stack_trace': stack_trace,
            'serviceContext': {
                'service': 'error-reporting-demo',
                'version': '1.0.0'
            },
            'context': {
                'user': f'user_{random.randint(1000, 9999)}',
                'reportLocation': {
                    'filePath': 'generate_error_logs.py',
                    'lineNumber': random.randint(30, 50),
                    'functionName': 'generate_python_exception'
                }
            }
        }
        
        self.logger.log_struct(
            json_payload,
            severity='ERROR'
        )
        print(f"Logged error with jsonPayload (stack_trace field): {error_msg}")
        
    def log_text_message_error(self):
        """Log a text message error without stack trace."""
        error_messages = [
            "Database connection timeout after 30 seconds",
            "Failed to authenticate user: Invalid credentials",
            "Payment processing failed: Card declined",
            "API rate limit exceeded for endpoint /api/v1/users",
            "File upload failed: Maximum file size exceeded",
            "Cache miss for key: user_session_12345"
        ]
        
        error_msg = random.choice(error_messages)
        
        # Prepend prefix if provided
        if self.prefix:
            error_msg = f'{self.prefix} {error_msg}'
        
        # For text messages without stack trace, we need to use the special @type
        json_payload = {
            '@type': 'type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent',
            'message': error_msg,
            'serviceContext': {
                'service': 'error-reporting-demo',
                'version': '1.0.0'
            },
            'context': {
                'httpRequest': {
                    'method': random.choice(['GET', 'POST', 'PUT', 'DELETE']),
                    'url': f'https://example.com/api/v1/{random.choice(["users", "orders", "products"])}',
                    'responseStatusCode': random.choice([400, 401, 403, 404, 500, 502, 503])
                },
                'user': f'user_{random.randint(1000, 9999)}'
            }
        }
        
        self.logger.log_struct(
            json_payload,
            severity='ERROR'
        )
        print(f"Logged text message error: {error_msg}")
        
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
        
    def log_custom_json_with_embedded_stack_trace(self):
        """Log an error with stack trace embedded in a custom JSON field."""
        error_msg, stack_trace = self.generate_python_exception()
        
        # Prepend prefix if provided
        if self.prefix:
            error_msg = f'{self.prefix} {error_msg}'
            stack_trace = f"{self.prefix}\n{stack_trace}"
        
        # Create a complex JSON structure with stack trace in a nested field
        json_payload = {
            'timestamp': datetime.utcnow().isoformat(),
            'application': {
                'name': 'error-reporting-demo',
                'environment': random.choice(['production', 'staging', 'development']),
                'version': '2.1.0'
            },
            'error_details': {
                'error_type': type(Exception).__name__,
                'error_message': error_msg,
                'full_stack_trace': stack_trace,  # Error Reporting will find this
                'additional_context': {
                    'request_id': f'req_{random.randint(100000, 999999)}',
                    'session_id': f'sess_{random.randint(100000, 999999)}',
                    'feature_flags': {
                        'new_ui': random.choice([True, False]),
                        'beta_features': random.choice([True, False])
                    }
                }
            },
            'metrics': {
                'response_time_ms': random.randint(100, 5000),
                'memory_usage_mb': random.randint(50, 500)
            }
        }
        
        self.logger.log_struct(
            json_payload,
            severity='ERROR'
        )
        print(f"Logged custom JSON with embedded stack trace: {error_msg}")
        
    def generate_batch_errors(self, count=10):
        """Generate a batch of different error types."""
        print(f"\nGenerating {count} error log entries...")
        print("=" * 50)
        
        error_methods = [
            self.log_stack_trace_as_text_payload,
            self.log_stack_trace_as_json_payload,
            self.log_text_message_error,
            self.log_reported_error_event_format,
            self.log_custom_json_with_embedded_stack_trace
        ]
        
        for i in range(count):
            # Randomly select an error generation method
            error_method = random.choice(error_methods)
            try:
                error_method()
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
        '--type',
        choices=['text', 'json', 'message', 'reported', 'custom', 'all'],
        default='all',
        help='Type of error to generate (default: all)'
    )
    parser.add_argument(
        '--prefix',
        help='String to prepend to all error messages'
    )
    
    args = parser.parse_args()
    
    try:
        # Create error generator
        generator = ErrorGenerator(project_id=args.project_id, prefix=args.prefix)
        
        if args.type == 'all':
            # Generate a batch of mixed error types
            generator.generate_batch_errors(args.count)
        else:
            # Generate specific error type
            type_map = {
                'text': generator.log_stack_trace_as_text_payload,
                'json': generator.log_stack_trace_as_json_payload,
                'message': generator.log_text_message_error,
                'reported': generator.log_reported_error_event_format,
                'custom': generator.log_custom_json_with_embedded_stack_trace
            }
            
            print(f"\nGenerating {args.count} '{args.type}' error log entries...")
            for i in range(args.count):
                try:
                    type_map[args.type]()
                    print(f"  [{i+1}/{args.count}] ✓ Error logged successfully")
                except Exception as e:
                    print(f"  [{i+1}/{args.count}] ✗ Failed to log error: {e}")
                    
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
