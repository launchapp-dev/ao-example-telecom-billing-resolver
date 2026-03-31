#!/usr/bin/env bash
# aggregate-monthly.sh — Aggregate weekly data into monthly report
set -euo pipefail

WEEKLY_DIR="data/analytics/weekly"
RESOLUTIONS_LOG="data/resolutions/log.json"
MONTHLY_DIR="data/analytics/monthly"
MONTH=$(date +%Y%m)
OUTPUT_FILE="$MONTHLY_DIR/${MONTH}-monthly.json"

mkdir -p "$MONTHLY_DIR"

python3 -c "
import json, os, glob
from datetime import datetime, timedelta

# Load all weekly aggregates for this month
month = '$MONTH'
weekly_files = glob.glob('$WEEKLY_DIR/${month}*.json')
weekly_data = []
for f in sorted(weekly_files):
    try:
        with open(f) as fp:
            weekly_data.append(json.load(fp))
    except:
        pass

# Load full resolution log for the month
try:
    with open('$RESOLUTIONS_LOG') as f:
        all_resolutions = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    all_resolutions = []

# Filter to current month
month_resolutions = []
for r in all_resolutions:
    resolved_at = r.get('resolved_at', '')
    if resolved_at.startswith(f'{month[:4]}-{month[4:6]}'):
        month_resolutions.append(r)

total = len(month_resolutions)
approved = [r for r in month_resolutions if r.get('verdict') in ['full-credit', 'partial-credit', 'goodwill-credit']]
denied = [r for r in month_resolutions if r.get('verdict') == 'no-credit']
escalated = [r for r in month_resolutions if r.get('verdict') == 'escalate']

total_credits = sum(r.get('credit_amount', 0) for r in approved)
avg_credit = total_credits / len(approved) if approved else 0

# Credits by verdict type
credits_by_type = {}
for r in approved:
    v = r.get('verdict', 'unknown')
    credits_by_type[v] = credits_by_type.get(v, 0) + r.get('credit_amount', 0)

output = {
    'month': month,
    'total_disputes': total,
    'approval_count': len(approved),
    'denial_count': len(denied),
    'escalation_count': len(escalated),
    'approval_rate': round(len(approved) / total * 100, 1) if total else 0,
    'total_credits_issued': round(total_credits, 2),
    'average_credit_amount': round(avg_credit, 2),
    'projected_annual_impact': round(total_credits * 12, 2),
    'credits_by_verdict_type': {k: round(v, 2) for k, v in credits_by_type.items()},
    'weekly_summaries': weekly_data,
    'weekly_count': len(weekly_data)
}

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(output, f, indent=2)

print(f'Monthly aggregate written: {total} disputes, {len(approved)} approved, \${total_credits:.2f} total credits')
print(f'Projected annual impact: \${total_credits * 12:.2f}')
"

echo "Monthly aggregation complete: $OUTPUT_FILE"
exit 0
