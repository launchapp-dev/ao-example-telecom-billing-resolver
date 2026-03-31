#!/usr/bin/env bash
# aggregate-weekly.sh — Aggregate 7 days of resolutions into weekly analytics
set -euo pipefail

RESOLUTIONS_LOG="data/resolutions/log.json"
WEEKLY_DIR="data/analytics/weekly"
DATE=$(date +%Y%m%d)
OUTPUT_FILE="$WEEKLY_DIR/${DATE}-weekly.json"

mkdir -p "$WEEKLY_DIR"

# Read resolutions from the past 7 days
python3 -c "
import json, sys
from datetime import datetime, timedelta

# Load resolution log
try:
    with open('$RESOLUTIONS_LOG') as f:
        log = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    log = []

# Filter to last 7 days
cutoff = datetime.utcnow() - timedelta(days=7)
recent = []
for record in log:
    try:
        resolved_at = datetime.fromisoformat(record.get('resolved_at', '').replace('Z', '+00:00'))
        if resolved_at.replace(tzinfo=None) >= cutoff:
            recent.append(record)
    except:
        recent.append(record)  # Include if date parsing fails

# Calculate metrics
total = len(recent)
approved = [r for r in recent if r.get('verdict') in ['full-credit', 'partial-credit', 'goodwill-credit']]
denied = [r for r in recent if r.get('verdict') == 'no-credit']
escalated = [r for r in recent if r.get('verdict') == 'escalate']

total_credits = sum(r.get('credit_amount', 0) for r in approved)
avg_credit = total_credits / len(approved) if approved else 0

# Disputes by verdict
verdicts = {}
for r in recent:
    v = r.get('verdict', 'unknown')
    verdicts[v] = verdicts.get(v, 0) + 1

output = {
    'date': '$DATE',
    'period_days': 7,
    'total_disputes': total,
    'approval_count': len(approved),
    'denial_count': len(denied),
    'escalation_count': len(escalated),
    'approval_rate': round(len(approved) / total * 100, 1) if total else 0,
    'total_credits_issued': round(total_credits, 2),
    'average_credit_amount': round(avg_credit, 2),
    'verdicts_breakdown': verdicts,
    'recent_disputes': recent
}

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(output, f, indent=2)

print(f'Weekly aggregate written: {total} disputes, {len(approved)} approved, \${total_credits:.2f} credits')
"

echo "Weekly aggregation complete: $OUTPUT_FILE"
exit 0
