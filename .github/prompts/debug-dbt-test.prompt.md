---
name: debug-dbt-test
description: "Debug a failing dbt test in the hdb-cash pipeline. Provide the test name to diagnose the root cause and get a fix."
---

# Debug a Failing dbt Test

Diagnose and fix a failing dbt test in the hdb-cash pipeline.

## What to do

1. Read `.github/skills/dbt-hdb/SKILL.md` to load the full diagnostics table of known failure modes.
2. Run the failing test in isolation to capture the full error:
   ```bash
   cd /home/fredc/codeforfun/hdb-cash && source .venv/bin/activate && cd dbt
   dbt test --select ${input:testName:Test or model name, e.g. stg_hdb_resale_transactions}
   ```
3. Match the error against the known pitfalls in the dbt-hdb skill.
4. If unmatched, inspect the compiled SQL in `dbt/target/compiled/hdb_cash/` for the failing test.
5. Propose and apply the minimal fix.
6. Re-run the test to confirm it passes.
