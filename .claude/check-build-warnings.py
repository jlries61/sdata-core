#!/usr/bin/env python3
"""PostToolUse hook: surface GNAT warnings from alr build / make build runs."""
import sys
import json
import re

data = json.load(sys.stdin)
cmd = data.get('tool_input', {}).get('command', '')

# Only process build commands
if not re.search(r'(alr|make)\s+build', cmd):
    sys.exit(0)

# Extract text output from whatever structure tool_response uses
resp = data.get('tool_response', '')
if isinstance(resp, str):
    output = resp
elif isinstance(resp, dict):
    output = resp.get('output', '') or resp.get('stdout', '') or ''
    if not output and isinstance(resp.get('content'), list):
        output = '\n'.join(
            item.get('text', '')
            for item in resp['content']
            if isinstance(item, dict) and item.get('type') == 'text'
        )
else:
    output = str(resp)

warnings = [line for line in output.splitlines() if 'warning:' in line]

if not warnings:
    sys.exit(0)

count = len(warnings)
label = 'warning' if count == 1 else 'warnings'
warn_text = '\n'.join(warnings)

print(json.dumps({
    'systemMessage': f'Build completed with {count} GNAT {label}:\n{warn_text}',
    'hookSpecificOutput': {
        'hookEventName': 'PostToolUse',
        'additionalContext': (
            f'The build produced {count} GNAT {label}. '
            f'List each one to the user and ask whether it should be fixed or suppressed:\n'
            f'{warn_text}'
        )
    }
}))
