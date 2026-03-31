# Telecom Billing Dispute Resolution — Agent Instructions

## Context

This AO project automates billing dispute resolution for a telecom operator. It processes
dispute tickets from customers, validates usage claims against call detail records, determines
credit eligibility using business rules, and generates resolution documents.

## Data Conventions

- **Dispute IDs**: `DSP-YYYYMMDD-NNN` format (e.g., DSP-20260331-001)
- **CDR files**: Named `{type}-{YYYYMM}.csv` in `data/cdrs/` (voice, data, roaming)
- **Batch files**: `data/intake/{YYYYMMDD}-batch.json` written by intake script
- **Queue files**: `data/queue/{YYYYMMDD}-queue.json` written by ticket-parser
- **Timestamps**: ISO 8601 UTC (e.g., 2026-03-31T06:00:00Z)

## CDR Data Units

- Voice CDRs: `duration_secs` — convert to minutes by dividing by 60
- Data CDRs: `bytes_used` — convert to GB by dividing by 1,073,741,824
- Roaming CDRs: `data_bytes` — convert to MB by dividing by 1,048,576

## Business Rules Priority

Apply eligibility rules in this order (first match wins):
1. Auto-approve (billing system error, overcharge < $5)
2. Full credit (CDR evidence confirms overcharge > $5)
3. Partial credit (shared responsibility)
4. Goodwill credit (billing correct, high-value customer)
5. Escalate (amount > $500, fraud, legal threat, ambiguity)
6. Deny (CDR confirms billing accurate)

## Rate Plan Lookup

Always read `config/rate-plans.yaml` to determine:
- Included voice minutes (some plans: "unlimited")
- Included data in GB
- Overage rates per minute/GB
- Roaming rates per minute/MB

## File Paths

All paths in agent directives are relative to the project root
(`examples/telecom-billing-resolver/`).

## Resolution Log Format

Append to `data/resolutions/log.json` as a JSON array. Each entry:
```json
{
  "dispute_id": "DSP-20260331-001",
  "verdict": "full-credit",
  "credit_amount": 32.50,
  "letter_path": "output/letters/DSP-20260331-001-letter.md",
  "memo_path": "output/memos/DSP-20260331-001-memo.md",
  "credit_memo_path": "output/credits/DSP-20260331-001-credit.md",
  "resolved_at": "2026-03-31T07:15:00Z"
}
```
