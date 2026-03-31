# Telecom Billing Dispute Resolution — Build Plan

## Overview

Billing dispute resolution pipeline for telecom operations — ingest dispute tickets from
CSV/JSON files, parse call detail records (CDRs) to validate claimed usage, cross-reference
rate plans and contract terms, determine adjustment eligibility based on configurable rules,
calculate credit amounts, generate resolution letters with itemized findings, track dispute
outcomes for pattern detection, and produce monthly dispute analytics reports with root cause
breakdowns.

All operations use real, existing tools: `jq` and `awk` via command phases for CDR parsing
and rate calculations, filesystem MCP for reading dispute files and writing resolution
documents, sequential-thinking MCP for complex eligibility reasoning, and memory MCP for
tracking dispute patterns and repeat customer history.

---

## Agents (5)

| Agent | Model | Role |
|---|---|---|
| **ticket-parser** | claude-haiku-4-5 | Fast extraction — reads dispute tickets from CSV/JSON inbox, normalizes into canonical dispute format, extracts customer ID, account number, disputed charges, billing period |
| **cdr-analyst** | claude-sonnet-4-6 | Usage validation — reads CDR files for the disputed billing period, reconciles actual usage against billed usage, flags discrepancies in call duration, data usage, roaming charges |
| **eligibility-engine** | claude-sonnet-4-6 | Decision maker — cross-references rate plans, contract terms, and usage findings to determine credit eligibility, calculates adjustment amounts, applies business rules |
| **resolution-writer** | claude-sonnet-4-6 | Letter generation — produces customer-facing resolution letters with itemized findings, credit calculations, and next steps; generates internal memos for denied disputes |
| **analytics-reporter** | claude-sonnet-4-6 | Pattern analysis — aggregates dispute outcomes, detects billing error patterns, identifies root causes (system bugs, rate plan confusion, training gaps), produces analytics reports |

### MCP Servers Used by Agents

- **filesystem** — all agents read dispute files, CDRs, rate plans, and write output documents
- **sequential-thinking** — eligibility-engine uses for complex multi-factor eligibility reasoning (overlapping promotions, contract amendments, partial credit scenarios)
- **memory** (@modelcontextprotocol/server-memory) — analytics-reporter stores dispute patterns, repeat customer history, and billing error trends across runs

---

## Workflows (3)

### 1. `resolve-disputes` (primary — scheduled daily)

Core dispute resolution loop: intake tickets -> validate CDRs -> determine eligibility -> generate letters.

**Phases:**

1. **intake-disputes** (command)
   - Script: `scripts/intake-disputes.sh`
   - Scans `inbox/` directory for new dispute ticket files (CSV and JSON)
   - For each file:
     - Validates basic schema (has required fields: customer_id, account_number, disputed_amount, billing_period)
     - Assigns a dispute ID (DSP-YYYYMMDD-NNN)
     - Moves raw file to `data/raw/{dispute_id}.json` (normalizes CSV to JSON via `jq`)
   - Writes `data/intake/{date}-batch.json` with all disputes ingested in this run
   - Moves processed files to `inbox/processed/`
   - Exit 0 always (malformed files logged to `data/intake/errors.json`, not failures)
   - Timeout: 60 seconds

2. **parse-tickets** (agent: ticket-parser)
   - Reads latest batch from `data/intake/{date}-batch.json`
   - For each dispute ticket, extracts and normalizes:
     - `{dispute_id, customer_id, account_number, customer_name, plan_type, disputed_charges[], billing_period_start, billing_period_end, customer_claim, contact_info}`
   - Validates customer exists in `config/customers.json` (sample customer database)
   - Looks up rate plan details from `config/rate-plans.yaml`
   - Writes `data/parsed/{dispute_id}.json` for each dispute with enriched data
   - Writes `data/queue/{date}-queue.json` listing all dispute IDs ready for analysis

3. **analyze-cdrs** (agent: cdr-analyst)
   - Reads dispute queue from `data/queue/{date}-queue.json`
   - For each dispute:
     - Reads the parsed ticket from `data/parsed/{dispute_id}.json`
     - Reads relevant CDR files from `data/cdrs/` for the billing period
     - Reconciles actual usage vs billed usage for each disputed charge:
       - Voice minutes: sum call durations from CDRs, compare to billed minutes
       - Data usage: sum data transfer from CDRs, compare to billed data
       - Roaming: identify calls/data during roaming periods, validate roaming charges
       - Fees: validate activation fees, early termination, equipment charges against contract
     - Calculates discrepancy for each line item: `{charge_type, billed_amount, actual_amount, discrepancy, evidence[]}`
   - Writes `data/analysis/{dispute_id}.json` with full usage reconciliation
   - Decision contract: `{verdict: "discrepancy-found" | "billing-correct" | "needs-escalation", discrepancies[], total_overcharge, reasoning}`

4. **determine-eligibility** (agent: eligibility-engine)
   - Reads analysis from `data/analysis/{dispute_id}.json`
   - Reads rate plan from `config/rate-plans.yaml` and contract terms from `config/contracts.yaml`
   - Reads business rules from `config/eligibility-rules.yaml`
   - Uses sequential-thinking for complex cases (e.g., overlapping promotions, mid-cycle plan changes, grandfathered rates)
   - Applies eligibility rules:
     - **Full credit**: clear billing system error, overcharge > $5, customer not at fault
     - **Partial credit**: shared responsibility (e.g., customer exceeded plan but rate was wrong)
     - **Goodwill credit**: billing was correct but customer is high-value (tenure > 2 years, no prior disputes)
     - **No credit**: billing correct, customer claim unsupported by CDR evidence
     - **Escalate**: complex case requiring human review (disputed amount > $500, legal implications, fraud suspicion)
   - Calculates exact credit amount with breakdown
   - Writes `data/decisions/{dispute_id}.json`:
     - `{dispute_id, verdict, credit_amount, credit_breakdown[], eligibility_factors[], reasoning}`
   - Decision contract: `{verdict: "full-credit" | "partial-credit" | "goodwill-credit" | "no-credit" | "escalate", credit_amount, reasoning}`

5. **generate-resolution** (agent: resolution-writer)
   - Reads decision from `data/decisions/{dispute_id}.json` and parsed ticket from `data/parsed/{dispute_id}.json`
   - For each dispute, generates:
     - **Customer letter** (`output/letters/{dispute_id}-letter.md`):
       - Professional tone, references specific charges and findings
       - For credits: itemized credit breakdown, expected timeline for account adjustment
       - For denials: clear explanation with CDR evidence, appeal instructions
     - **Internal memo** (`output/memos/{dispute_id}-memo.md`):
       - Full analysis details, eligibility reasoning, risk assessment
       - Flagged patterns (repeat customer, systematic billing error)
     - **Credit memo** (if credit approved) (`output/credits/{dispute_id}-credit.md`):
       - Formatted for billing system: account number, credit amount, GL codes, authorization
   - Updates `data/resolutions/{dispute_id}.json` with final outcome and document paths
   - Appends to `data/resolutions/log.json` (running log of all resolutions)

**Routing:**
- `analyze-cdrs` verdict "needs-escalation" -> skip eligibility, write escalation notice, end
- `determine-eligibility` verdict "escalate" -> skip letter generation, write escalation notice, end
- All other verdicts flow through the full pipeline

### 2. `weekly-pattern-analysis` (scheduled weekly — Mondays)

Detects systematic billing errors and dispute trends.

**Phases:**

1. **aggregate-disputes** (command)
   - Script: `scripts/aggregate-weekly.sh`
   - Reads all resolution logs from `data/resolutions/log.json` for the past 7 days
   - Calculates:
     - Total disputes, approval/denial rates, average credit amount
     - Disputes by category (voice, data, roaming, fees)
     - Disputes by rate plan (which plans generate the most disputes)
     - Repeat customers (2+ disputes in the period)
     - Credit totals by category
   - Writes `data/analytics/weekly/{date}.json`

2. **detect-patterns** (agent: analytics-reporter)
   - Reads weekly aggregate from `data/analytics/weekly/{date}.json`
   - Reads dispute history from memory MCP (entity: "dispute-patterns")
   - Detects patterns:
     - **Billing system errors**: same charge type consistently overcharged across customers
     - **Rate plan confusion**: specific plans with disproportionate dispute rates
     - **Seasonal patterns**: roaming disputes spike during holidays, data disputes during events
     - **Repeat offenders**: customers who dispute every billing cycle
     - **Root causes**: maps patterns to likely root causes (system bug, unclear terms, training gap)
   - Updates memory MCP with latest pattern data
   - Writes `output/analytics/weekly/{date}.md`:
     - Executive summary with KPIs (dispute volume, resolution rate, avg credit, total credits)
     - Pattern breakdown with confidence levels
     - Root cause analysis with recommended actions
     - Customer segment analysis (by plan type, tenure, dispute history)
     - Week-over-week trend comparison
   - Decision contract: `{verdict: "normal" | "pattern-detected" | "urgent-pattern", patterns[], reasoning}`

### 3. `monthly-report` (scheduled monthly — 1st of month)

Comprehensive monthly billing dispute analytics.

**Phases:**

1. **aggregate-monthly** (command)
   - Script: `scripts/aggregate-monthly.sh`
   - Reads all weekly aggregates for the month from `data/analytics/weekly/`
   - Reads all resolution logs for the month
   - Calculates:
     - Monthly KPIs: total disputes, resolution rate, credit total, avg resolution time
     - Trending categories: which dispute types are increasing/decreasing
     - Financial impact: total credits issued, projected annual impact
     - SLA compliance: what percentage resolved within target time
   - Writes `data/analytics/monthly/{month}.json`

2. **write-monthly-report** (agent: analytics-reporter)
   - Reads monthly aggregate and all weekly reports for the month
   - Reads pattern history from memory MCP
   - Produces `output/analytics/monthly/{month}.md`:
     - **Executive dashboard**: KPIs with month-over-month trends
     - **Financial summary**: credits by category, projected annual impact, cost avoidance opportunities
     - **Pattern analysis**: systematic issues discovered, resolution status of previously flagged patterns
     - **Customer insights**: high-dispute segments, at-risk accounts, retention opportunities
     - **Process metrics**: resolution time distribution, escalation rates, auto-resolution rates
     - **Recommendations**: billing system fixes, rate plan simplification, training priorities

---

## Decision Contracts

### analyze-cdrs verdict
```json
{
  "verdict": "discrepancy-found | billing-correct | needs-escalation",
  "discrepancies": [
    {
      "charge_type": "voice_overage",
      "billed_amount": 45.00,
      "actual_amount": 12.50,
      "discrepancy": 32.50,
      "evidence": "CDR shows 125 minutes used, billed for 450 minutes. Rate plan allows 500 included minutes."
    }
  ],
  "total_overcharge": 32.50,
  "reasoning": "System incorrectly calculated overage — customer was within plan limits"
}
```

### determine-eligibility verdict
```json
{
  "verdict": "full-credit | partial-credit | goodwill-credit | no-credit | escalate",
  "credit_amount": 32.50,
  "credit_breakdown": [
    {"charge": "voice_overage", "credit": 32.50, "reason": "billing system error"}
  ],
  "eligibility_factors": ["clear_billing_error", "within_policy_limits", "first_dispute"],
  "reasoning": "Clear billing system error — customer charged for overage despite being within included minutes. Full credit warranted per policy BIL-101."
}
```

### detect-patterns verdict
```json
{
  "verdict": "normal | pattern-detected | urgent-pattern",
  "patterns": [
    {
      "type": "systematic_overcharge",
      "category": "voice_overage",
      "affected_plans": ["unlimited-talk-250", "family-share-1000"],
      "estimated_impact": "$12,400/month across 340 customers",
      "confidence": "high",
      "root_cause": "Overage calculator not recognizing promotional bonus minutes"
    }
  ],
  "reasoning": "Voice overage disputes up 340% this week, concentrated on plans with bonus minute promotions"
}
```

---

## Directory Layout

```
config/
├── rate-plans.yaml               # Telecom rate plans (voice, data, roaming rates, included amounts)
├── contracts.yaml                # Contract term templates (2yr, 1yr, month-to-month with terms)
├── eligibility-rules.yaml        # Business rules for credit eligibility determination
├── customers.json                # Sample customer database (ID, name, plan, tenure, history)
└── charge-codes.yaml             # GL codes and charge type taxonomy

scripts/
├── intake-disputes.sh            # Scan inbox, validate schema, assign IDs, normalize CSV→JSON
├── aggregate-weekly.sh           # Aggregate 7 days of resolutions into weekly analytics
└── aggregate-monthly.sh          # Aggregate weekly data into monthly report

data/
├── raw/{dispute_id}.json         # Raw normalized dispute tickets
├── intake/{date}-batch.json      # Daily intake batches
├── intake/errors.json            # Malformed ticket log
├── parsed/{dispute_id}.json      # Enriched dispute tickets with customer/plan data
├── queue/{date}-queue.json       # Dispute IDs ready for CDR analysis
├── cdrs/                         # Call detail records (sample data)
│   ├── voice-202603.csv          # Voice CDRs for March 2026
│   ├── data-202603.csv           # Data usage CDRs for March 2026
│   └── roaming-202603.csv        # Roaming CDRs for March 2026
├── analysis/{dispute_id}.json    # CDR reconciliation results
├── decisions/{dispute_id}.json   # Eligibility determinations
├── resolutions/
│   ├── {dispute_id}.json         # Final resolution records
│   └── log.json                  # Running resolution log
└── analytics/
    ├── weekly/{date}.json        # Weekly aggregated dispute data
    └── monthly/{month}.json      # Monthly aggregated dispute data

output/
├── letters/{dispute_id}-letter.md    # Customer-facing resolution letters
├── memos/{dispute_id}-memo.md        # Internal analysis memos
├── credits/{dispute_id}-credit.md    # Credit memos for billing system
└── analytics/
    ├── weekly/{date}.md              # Weekly pattern analysis reports
    └── monthly/{month}.md            # Monthly comprehensive reports

inbox/                                # Drop dispute ticket files here
├── processed/                        # Processed tickets moved here
└── (new dispute CSV/JSON files)

sample-disputes/                      # Sample dispute tickets for testing
├── voice-overcharge.json             # Customer disputing voice overage charge
├── roaming-surprise.json             # Unexpected international roaming charges
├── data-throttle-dispute.csv         # Batch of data throttling disputes
├── early-termination.json            # Disputed early termination fee
└── promotional-credit-missing.json   # Promotional credit not applied
```

---

## Config Files

### config/rate-plans.yaml
```yaml
plans:
  - id: basic-talk-300
    name: "Basic Talk 300"
    type: postpaid
    monthly_fee: 29.99
    included:
      voice_minutes: 300
      data_gb: 2
      sms: unlimited
    overage:
      voice_per_min: 0.10
      data_per_gb: 15.00
    roaming:
      voice_per_min: 1.50
      data_per_mb: 0.05

  - id: unlimited-talk-250
    name: "Unlimited Talk & Text"
    type: postpaid
    monthly_fee: 49.99
    included:
      voice_minutes: unlimited
      data_gb: 10
      sms: unlimited
    overage:
      data_per_gb: 10.00
    roaming:
      voice_per_min: 1.00
      data_per_mb: 0.03

  - id: family-share-1000
    name: "Family Share 1000"
    type: postpaid
    monthly_fee: 79.99
    max_lines: 5
    included:
      voice_minutes: 1000           # shared across lines
      data_gb: 20                   # shared across lines
      sms: unlimited
    overage:
      voice_per_min: 0.08
      data_per_gb: 12.00
    roaming:
      voice_per_min: 1.25
      data_per_mb: 0.04

  - id: prepaid-daily
    name: "Prepaid Daily"
    type: prepaid
    daily_fee: 2.00
    included:
      voice_minutes: 60
      data_gb: 0.5
      sms: 100
    overage:
      voice_per_min: 0.15
      data_per_gb: 20.00

  - id: business-enterprise
    name: "Business Enterprise"
    type: postpaid
    monthly_fee: 149.99
    included:
      voice_minutes: unlimited
      data_gb: 50
      sms: unlimited
    overage:
      data_per_gb: 8.00
    roaming:
      voice_per_min: 0.50
      data_per_mb: 0.02
    features: [international_calling, voicemail_pro, conference_bridge]
```

### config/eligibility-rules.yaml
```yaml
# Business rules for credit eligibility determination
rules:
  auto_approve:
    - condition: "billing_system_error"
      action: full_credit
      description: "System-confirmed billing error — auto-approve full credit"
    - condition: "overcharge_under_5"
      action: goodwill_credit
      description: "Small discrepancy under $5 — goodwill credit to maintain satisfaction"

  full_credit:
    - condition: "clear_overcharge_with_cdr_evidence"
      threshold_min: 5.00
      description: "CDR evidence confirms billed amount exceeds actual usage"
    - condition: "promotional_credit_missing"
      description: "Promotion was active but credit not applied"
    - condition: "duplicate_charge"
      description: "Same charge appears twice in billing period"

  partial_credit:
    - condition: "shared_responsibility"
      credit_pct: 50
      description: "Customer exceeded plan limits but rate applied was incorrect"
    - condition: "late_plan_change"
      credit_pct: 75
      description: "Plan change requested but not effective until next cycle"

  goodwill_credit:
    - condition: "billing_correct_but_high_value_customer"
      max_credit: 25.00
      min_tenure_months: 24
      max_prior_disputes: 1
      description: "Billing correct but customer is long-tenured with minimal dispute history"

  escalation:
    - condition: "disputed_amount_exceeds_threshold"
      threshold: 500.00
      description: "High-value dispute requires supervisor review"
    - condition: "fraud_indicators"
      description: "Pattern suggests potential fraud (SIM swap, account takeover)"
    - condition: "legal_threat"
      description: "Customer has mentioned legal action or regulatory complaint"
    - condition: "contract_ambiguity"
      description: "Contract terms are genuinely ambiguous for this scenario"

  denial:
    - condition: "usage_matches_billing"
      description: "CDR evidence confirms billed amounts are accurate"
    - condition: "exceeded_dispute_limit"
      max_disputes_per_year: 6
      description: "Customer has exceeded reasonable dispute frequency"
```

### config/contracts.yaml
```yaml
templates:
  - id: standard-2yr
    term_months: 24
    early_termination_fee: 200.00
    etf_reduction_per_month: 8.33    # ETF reduces monthly over term
    features:
      - device_subsidy
      - locked_rate
    renewal: auto_month_to_month
    dispute_window_days: 90          # Must dispute within 90 days of charge

  - id: standard-1yr
    term_months: 12
    early_termination_fee: 100.00
    etf_reduction_per_month: 8.33
    features:
      - locked_rate
    renewal: auto_month_to_month
    dispute_window_days: 60

  - id: month-to-month
    term_months: 0
    early_termination_fee: 0
    features: []
    renewal: none
    dispute_window_days: 60

  - id: business-3yr
    term_months: 36
    early_termination_fee: 500.00
    etf_reduction_per_month: 13.89
    features:
      - volume_discount
      - dedicated_support
      - locked_rate
      - device_subsidy
    renewal: auto_negotiate
    dispute_window_days: 120
```

### config/charge-codes.yaml
```yaml
# GL codes and charge type taxonomy for credit memos
charge_types:
  voice:
    - code: VOC-BASE
      description: "Monthly voice service base charge"
    - code: VOC-OVER
      description: "Voice overage charges"
    - code: VOC-ROAM
      description: "Voice roaming charges"
    - code: VOC-INTL
      description: "International calling charges"

  data:
    - code: DAT-BASE
      description: "Monthly data service base charge"
    - code: DAT-OVER
      description: "Data overage charges"
    - code: DAT-ROAM
      description: "Data roaming charges"

  fees:
    - code: FEE-ACT
      description: "Activation fee"
    - code: FEE-ETF
      description: "Early termination fee"
    - code: FEE-EQP
      description: "Equipment charge"
    - code: FEE-LATE
      description: "Late payment fee"
    - code: FEE-REST
      description: "Service restoration fee"

  credits:
    - code: CRD-ADJ
      description: "Billing adjustment credit"
    - code: CRD-GW
      description: "Goodwill credit"
    - code: CRD-PROMO
      description: "Promotional credit"
    - code: CRD-ERR
      description: "System error correction credit"

gl_accounts:
  credit_expense: "6100-CUST-ADJ"
  goodwill_expense: "6200-CUST-GW"
  error_correction: "6300-SYS-ERR"
```

---

## Schedules

```yaml
schedules:
  - id: daily-dispute-resolution
    cron: "0 6 * * *"
    workflow_ref: resolve-disputes
    enabled: true

  - id: weekly-pattern-analysis
    cron: "0 9 * * 1"
    workflow_ref: weekly-pattern-analysis
    enabled: true

  - id: monthly-dispute-report
    cron: "0 8 1 * *"
    workflow_ref: monthly-report
    enabled: true
```

---

## Key Design Decisions

1. **Dispute ID convention** — `DSP-YYYYMMDD-NNN` format provides chronological ordering
   and uniqueness. The date prefix enables efficient file lookups for weekly/monthly
   aggregation without scanning all historical disputes.

2. **Haiku for parsing, Sonnet for reasoning** — the ticket-parser agent uses Haiku because
   ticket extraction is structured data mapping that doesn't need deep reasoning. The
   cdr-analyst, eligibility-engine, and resolution-writer use Sonnet for reconciliation
   analysis, complex rule application, and professional letter writing.

3. **Command phases for data aggregation** — shell scripts with `jq` handle intake validation,
   file management, and metric aggregation. LLM agents handle nuanced analysis (CDR
   reconciliation, eligibility reasoning, letter composition) where they add real value.

4. **Configurable eligibility rules** — business rules in `eligibility-rules.yaml` let
   telecom operators adjust credit policies without modifying agent logic. Rules are
   hierarchical: auto-approve > full credit > partial > goodwill > deny > escalate.

5. **Memory MCP for pattern tracking** — the analytics-reporter stores dispute patterns
   in memory MCP (entities: "pattern:{category}", "customer:{id}") to track trends across
   runs. This enables detection of systematic billing errors that only emerge over time.

6. **Three-tier scheduling** — daily resolution for timely customer response, weekly pattern
   analysis for operational awareness, monthly reporting for executive visibility. Each
   workflow is independent and can run on-demand.

7. **Sample data included** — the repo ships with sample dispute tickets, CDR files, customer
   data, and rate plans so the pipeline runs immediately. Sample data demonstrates several
   dispute scenarios: voice overcharges, roaming surprises, missing promotional credits,
   disputed termination fees.

8. **Escalation paths** — both CDR analysis and eligibility determination can trigger
   escalation, short-circuiting the pipeline for cases requiring human judgment. This
   prevents automated resolution of high-risk or ambiguous disputes.

9. **Financial audit trail** — every dispute generates three documents: customer letter,
   internal memo, and credit memo. The credit memo uses standardized GL codes from
   `charge-codes.yaml` for direct integration with billing systems.

10. **CDR-based evidence** — rather than taking customer claims at face value, the pipeline
    independently validates usage from call detail records. This provides objective evidence
    for both approvals and denials, reducing appeal rates.
