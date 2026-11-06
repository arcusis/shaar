# Route performance budgets

Shaar reads and writes project budgets at `.shaar/budgets.json`. The file is
UTF-8 JSON with schema version 1. Route keys are exact URL paths; query strings
are ignored. A limit is inclusive, and all values use milliseconds, CLS score,
bytes, or request count as named.

```json
{
  "schemaVersion": 1,
  "routes": [
    {
      "route": "/dashboard",
      "lcpMilliseconds": 2500,
      "inpMilliseconds": 200,
      "cls": 0.1,
      "javascriptBytes": 500000,
      "requestCount": 30
    }
  ]
}
```

Each limit can be `null` to disable that check. Shaar reports a configured
check as unavailable when the current page load has not produced that metric.
Truncated resource lists also leave request count unavailable unless the page
performance observer has supplied a complete count. JavaScript bytes sum the
encoded body sizes for script initiated resources; if the browser withholds a
script size, that check is unavailable. Exported route reports are JSON and
include each configured metric's observed value, limit, and status.
