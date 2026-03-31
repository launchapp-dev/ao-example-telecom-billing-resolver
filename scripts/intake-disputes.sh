#!/usr/bin/env bash
# intake-disputes.sh — Scan inbox, validate schema, assign dispute IDs, normalize to JSON
set -euo pipefail

INBOX="inbox"
PROCESSED="inbox/processed"
RAW_DIR="data/raw"
INTAKE_DIR="data/intake"
DATE=$(date +%Y%m%d)
BATCH_FILE="$INTAKE_DIR/${DATE}-batch.json"
ERRORS_FILE="$INTAKE_DIR/errors.json"
COUNTER_FILE="$INTAKE_DIR/.counter"

mkdir -p "$PROCESSED" "$RAW_DIR" "$INTAKE_DIR"

# Load or initialize dispute counter for today
if [[ -f "$COUNTER_FILE" ]]; then
  COUNTER=$(cat "$COUNTER_FILE")
else
  COUNTER=0
fi

# Initialize batch and errors arrays
BATCH_DISPUTES="[]"
ERROR_RECORDS="[]"

# Process all JSON dispute files in inbox
for file in "$INBOX"/*.json 2>/dev/null; do
  [[ -f "$file" ]] || continue

  # Validate required fields
  VALID=true
  for field in customer_id account_number disputed_amount billing_period; do
    if ! python3 -c "import json,sys; d=json.load(open('$file')); assert '$field' in d" 2>/dev/null; then
      VALID=false
      echo "WARN: $file missing field: $field" >&2
      ERROR_RECORDS=$(echo "$ERROR_RECORDS" | python3 -c "
import json, sys
errors = json.load(sys.stdin)
errors.append({'file': '$file', 'error': 'missing_field: $field'})
print(json.dumps(errors))
")
      break
    fi
  done

  if [[ "$VALID" == "true" ]]; then
    COUNTER=$((COUNTER + 1))
    DISPUTE_ID="DSP-${DATE}-$(printf '%03d' $COUNTER)"

    # Normalize to canonical format and save to raw/
    python3 -c "
import json, sys
with open('$file') as f:
    ticket = json.load(f)
ticket['dispute_id'] = '$DISPUTE_ID'
ticket['source_file'] = '$file'
ticket['ingested_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('$RAW_DIR/$DISPUTE_ID.json', 'w') as f:
    json.dump(ticket, f, indent=2)
print('$DISPUTE_ID')
"
    # Add to batch
    BATCH_DISPUTES=$(echo "$BATCH_DISPUTES" | python3 -c "
import json, sys
batch = json.load(sys.stdin)
with open('$RAW_DIR/$DISPUTE_ID.json') as f:
    dispute = json.load(f)
batch.append(dispute)
print(json.dumps(batch))
")
    mv "$file" "$PROCESSED/"
    echo "Ingested: $DISPUTE_ID from $(basename $file)"
  fi
done

# Process all CSV dispute files in inbox
for file in "$INBOX"/*.csv 2>/dev/null; do
  [[ -f "$file" ]] || continue

  COUNTER=$((COUNTER + 1))
  DISPUTE_ID="DSP-${DATE}-$(printf '%03d' $COUNTER)"

  # Convert CSV to JSON (assumes first row is header)
  python3 -c "
import csv, json, sys
with open('$file', newline='') as f:
    reader = csv.DictReader(f)
    rows = list(reader)

if rows:
    # Take first row as primary dispute (batch CSVs handled row by row)
    ticket = rows[0]
    ticket['dispute_id'] = '$DISPUTE_ID'
    ticket['source_file'] = '$file'
    ticket['ingested_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
    ticket['batch_rows'] = rows
    with open('$RAW_DIR/$DISPUTE_ID.json', 'w') as f:
        json.dump(ticket, f, indent=2)
    print('OK')
else:
    print('EMPTY')
" && {
    BATCH_DISPUTES=$(echo "$BATCH_DISPUTES" | python3 -c "
import json, sys
batch = json.load(sys.stdin)
with open('$RAW_DIR/$DISPUTE_ID.json') as f:
    dispute = json.load(f)
batch.append(dispute)
print(json.dumps(batch))
")
    mv "$file" "$PROCESSED/"
    echo "Ingested CSV: $DISPUTE_ID from $(basename $file)"
  }
done

# Save counter for next run
echo "$COUNTER" > "$COUNTER_FILE"

# Write batch file
python3 -c "
import json, sys
batch = json.loads('''$(echo $BATCH_DISPUTES)''')
output = {'date': '${DATE}', 'disputes': batch, 'total': len(batch)}
with open('$BATCH_FILE', 'w') as f:
    json.dump(output, f, indent=2)
print(f'Batch written: {len(batch)} disputes to $BATCH_FILE')
"

# Update errors file
if [[ "$ERROR_RECORDS" != "[]" ]]; then
  echo "$ERROR_RECORDS" | python3 -c "
import json, sys
errors = json.load(sys.stdin)
existing = []
try:
    with open('$ERRORS_FILE') as f:
        existing = json.load(f)
except:
    pass
existing.extend(errors)
with open('$ERRORS_FILE', 'w') as f:
    json.dump(existing, f, indent=2)
"
  echo "Errors logged to $ERRORS_FILE"
fi

echo "Intake complete. Total disputes processed: $COUNTER"
exit 0
