# Telecom Billing Dispute Resolution

Automated billing dispute resolution pipeline for telecom operations. Ingests dispute tickets, validates usage against call detail records (CDRs), determines credit eligibility using configurable business rules, generates customer resolution letters, and produces weekly/monthly pattern analytics.

## What It Does

- **Dispute Intake** — Scans `inbox/` for CSV/JSON dispute tickets, validates schema, assigns dispute IDs
- **CDR Validation** — Reconciles customer claims against actual call detail records (voice, data, roaming)
- **Eligibility Determination** — Applies configurable business rules to determine credit type and amount
- **Resolution Letters** — Generates customer-facing letters, internal memos, and credit memos for billing systems
- **Pattern Analytics** — Weekly and monthly reports detecting systematic billing errors and dispute trends

## Agents

| Agent | Model | Role |
|---|---|---|
| **ticket-parser** | claude-haiku-4-5 | Normalizes dispute tickets from CSV/JSON, enriches with customer and rate plan data |
| **cdr-analyst** | claude-sonnet-4-6 | Reconciles billed charges against actual CDR usage, identifies discrepancies |
| **eligibility-engine** | claude-sonnet-4-6 | Applies business rules to determine credit eligibility and exact amounts |
| **resolution-writer** | claude-sonnet-4-6 | Generates customer letters, internal memos, and credit memos |
| **analytics-reporter** | claude-sonnet-4-6 | Detects billing error patterns, produces weekly/monthly executive reports |

## Workflows

| Workflow | Schedule | Description |
|---|---|---|
| `resolve-disputes` | Daily 6am | Full dispute resolution pipeline |
| `weekly-pattern-analysis` | Mondays 9am | Aggregate and detect billing error patterns |
| `monthly-report` | 1st of month 8am | Comprehensive monthly executive analytics |

## Quick Start

```bash
# Install AO
npm install -g @launchapp-dev/ao-cli

# Start the daemon
ao daemon start --autonomous

# Drop dispute tickets into the inbox
cp sample-disputes/*.json inbox/
cp sample-disputes/*.csv inbox/

# Run the dispute resolution workflow now
ao workflow run resolve-disputes

# Watch it work
ao daemon stream --pretty

# Check status
ao status
```

## Required Environment Variables

No external API keys required. All agents use local MCP servers:
- `@modelcontextprotocol/server-filesystem` — file read/write
- `@modelcontextprotocol/server-sequential-thinking` — structured reasoning for complex eligibility cases
- `@modelcontextprotocol/server-memory` — cross-run pattern tracking for analytics

See `.env.example` for the full list.

## Directory Structure

```
inbox/                    # Drop new dispute ticket files here
  processed/              # Processed tickets moved here automatically
sample-disputes/          # Example dispute files to test the pipeline
config/
  rate-plans.yaml         # Telecom plan definitions with rates and included amounts
  eligibility-rules.yaml  # Business rules for credit eligibility
  contracts.yaml          # Contract term templates
  customers.json          # Sample customer database
  charge-codes.yaml       # GL codes for credit memo integration
scripts/
  intake-disputes.sh      # Intake command: validate, assign IDs, normalize CSV→JSON
  aggregate-weekly.sh     # Aggregate 7 days of resolutions
  aggregate-monthly.sh    # Aggregate weekly data into monthly report
data/
  cdrs/                   # Call detail records (voice, data, roaming CSVs)
  raw/                    # Raw normalized dispute tickets
  parsed/                 # Enriched tickets with customer and plan data
  analysis/               # CDR reconciliation results
  decisions/              # Eligibility determinations
  resolutions/            # Final resolution records and running log
  analytics/              # Weekly and monthly aggregated data
output/
  letters/                # Customer-facing resolution letters
  memos/                  # Internal analysis memos
  credits/                # Credit memos formatted for billing systems
  analytics/              # Weekly and monthly pattern reports
```

## Dispute Types Demonstrated

The `sample-disputes/` directory includes five dispute scenarios:

1. **voice-overcharge.json** — Customer on unlimited plan charged for voice overages (billing error)
2. **roaming-surprise.json** — Unexpected international roaming charges (legitimate but not warned)
3. **early-termination.json** — ETF charged to month-to-month customer (contract error)
4. **promotional-credit-missing.json** — Active promotion credit not applied (system error)
5. **data-throttle-dispute.csv** — Business customer disputing data overage (CDR reconciliation required)

## AO Features Demonstrated

- **Multi-agent pipelines** with specialized roles (fast/cheap for parsing, capable for reasoning)
- **Command phases** for data-intensive tasks (shell scripts with `jq`/`python3` for CDR aggregation)
- **Decision contracts** that route disputes through different resolution paths based on CDR findings
- **Scheduled workflows** at daily/weekly/monthly cadences for different operational needs
- **Memory MCP** for cross-run state (pattern detection improves over time as data accumulates)
- **Sequential-thinking MCP** for complex multi-factor eligibility reasoning
- **Three-tier document generation** (customer letter + internal memo + credit memo per dispute)
