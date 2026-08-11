---
name: opensearch-dips
description: >
  Use when the user asks questions about our OpenSearch cluster's otel-v1-apm-*
  data: spans/trace groups, OTel application logs and Kubernetes events, OTel
  metrics (RED-style ASP.NET Core/k8s/network metrics), the service
  dependency map, or per-user activity in the DIPS Arena Desktop Client logs
  (userid/username). Trigger on keywords like "opensearch", "otel-v1-apm",
  "span", "trace group", "service map", "find slow requests", "service
  errors", "apm logs", "k8s event", "metrics", "aspnetcore metrics", "which
  user", "user activity", "userid", "what did this user do". Also trigger
  whenever an opensearch-mcp tool (ListIndexTool, IndexMappingTool,
  SearchIndexTool, CountTool, MsearchTool, ClusterHealthTool, GetShardsTool,
  ExplainTool, GenericOpenSearchApiTool) would be the right way to answer a
  question about this data, even if the user didn't name OpenSearch explicitly.
---

# OpenSearch — otel-v1-apm-* (our cluster `opensearch-stack`)

Scope: **only the four `otel-v1-apm-*` index patterns.** This cluster also has
Jaeger trace indices, `otel-logs-*`/`logservice-*` pod logs, and
`iam-auth-events-*` — deliberately out of scope here; don't reach into them
for this skill.

Always call `IndexMappingTool` on the specific index you're about to hit if
anything here looks stale — mappings drift as new OTel semantic-convention
attributes land.

---

## The 4 index patterns

| Pattern | What it is | Volume | Notes |
|---|---|---|---|
| `otel-v1-apm-span-*` | Rollover-numbered (`-000001` … `-000041`, not date-suffixed) Data Prepper span/trace-group index. | **~3,800 docs total across all 41 rollover indices** | Low volume and sparse — most sampled docs only populate `serviceName`, `traceGroupName`, `hashId`; `kind`/`destination`/`target` are frequently `null`. Treat as a coarse "what talked to what" signal, not full per-request span detail. |
| `otel-v1-apm-logs-otel-*` | Date-suffixed (`YYYY.MM.DD`) Data Prepper OTel logs. Carries app log lines, raw **Kubernetes Event objects** (`log.attributes.k8s@event@*`), and — from the DIPS Arena Desktop Client via `instrumentationScope.name: "otlp/webhookevent"` — **per-user activity logs** with `resource.attributes.userid` / `resource.attributes.username`. | ~200K docs/day | Live, the most reliable of the four for day-to-day queries. The only one of the four with user-identity fields (confirmed 0 hits for `userid` in `otel-v1-apm-metrics-*` and `otel-v1-apm-span-*`). |
| `otel-v1-apm-metrics-*` | Date-suffixed (`YYYY.MM.DD`) Data Prepper OTel metrics — ASP.NET Core request metrics, k8s/network/process metrics, per-request histograms. | ~18.5M docs/day | Very high volume — always filter by time range + `serviceName` before scanning. |
| `otel-v1-apm-service-map` | Single static index (no date/rollover suffix) — precomputed service dependency edges. | small | Just pull it all; no time filter needed. |

`otel-v1-apm-span-*` and `otel-v1-apm-logs-otel-*`/`otel-v1-apm-metrics-*` use
different suffix schemes — span indices are numbered rollovers, the other two
are calendar-dated. Use `ListIndexTool` with the pattern
(`otel-v1-apm-span-*`, `otel-v1-apm-logs-otel-*`, `otel-v1-apm-metrics-*`) to
see what currently exists rather than guessing a suffix.

---

## Field-naming gotchas

1. **Dot-to-`@` flattening, consistently across all four.** OTel
   attribute/resource keys have every `.` replaced with `@` when promoted to
   a field name: `k8s.namespace.name` → `k8s@namespace@name`,
   `http.response.status_code` → `http@response@status_code`,
   `service.name` → `service@name`. This is uniform across
   `resource.attributes.*`, `log.attributes.*`, and
   `attributes.metric.attributes.*` / `attributes.resource.attributes.*` — no
   family-specific exceptions within this scope.

2. **Metrics attributes are nested two levels deep.** In
   `otel-v1-apm-metrics-*`, per-request dimensions live under
   `attributes.metric.attributes.<key>` (e.g.
   `attributes.metric.attributes.http@response@status_code`,
   `attributes.metric.attributes.http@route`), while resource/infra dimensions
   live under `attributes.resource.attributes.<key>` (e.g.
   `attributes.resource.attributes.k8s@pod@name`,
   `attributes.resource.attributes.deployment@environment`,
   `attributes.resource.attributes.aid`). Don't confuse the two paths — a
   query for `env` needs `attributes.resource.attributes.env`, not
   `attributes.metric.attributes.env`.

3. **No trace-id exemplar linking metrics to spans.** Unlike some OTel
   backends, `otel-v1-apm-metrics-*` documents here have no `exemplar`/
   `traceId` field — you cannot jump from a slow metric bucket straight to
   the causing trace. Correlate instead via shared dimensions: `serviceName`
   + `attributes.resource.attributes.k8s@pod@name` +a matching time window.

4. **`aid`** is our internal numeric application ID
   (`attributes.resource.attributes.aid` in metrics; also present in span/log
   resource attributes) — a stable join key across the four indices when
   `serviceName` strings don't line up exactly.

5. **Timestamp fields differ per index:**
   - `otel-v1-apm-span-*`: `startTime` / `endTime` are `date_nanos`. Range
     queries need nanosecond epoch values or ISO8601 with nanos.
   - `otel-v1-apm-logs-otel-*`: `time` and `observedTimestamp` are standard
     `date` (ISO 8601) — use
     `"format": "strict_date_optional_time||epoch_millis"`.
   - `otel-v1-apm-metrics-*`: `startTime` and `time` are standard `date`.
   - `otel-v1-apm-service-map`: no timestamp — it's a precomputed snapshot.

6. **`otel-v1-apm-span-*` sparsity is real, not a sampling artifact** —
   confirmed via `CountTool` across the full rollover set (~3,800 docs total,
   `GetShardsTool` shows single-digit doc counts per current write shard). If
   the user needs full per-request trace detail this index alone likely
   won't have it; say so rather than presenting a `null`-heavy doc as if it
   were complete.

7. **User identity (`userid`/`username`) exists in exactly one place, and
   only partially links to traces.** In `otel-v1-apm-logs-otel-*`, docs from
   `instrumentationScope.name: "otlp/webhookevent"` (DIPS Arena Desktop
   Client) carry `resource.attributes.userid` and
   `resource.attributes.username` — both `text` with a `.keyword` subfield,
   so use `.keyword` for `term`/`terms`/`aggs`, plain field for `match`.
   Also promoted alongside them: `resource.attributes.sid` (session id),
   `resource.attributes.aid`, `resource.attributes.env`,
   `resource.attributes.host@name`, `resource.attributes.logger`. **Not**
   promoted — confirmed by an empty `terms` agg on
   `resource.attributes.hospital.keyword` despite `hospital` being present in
   every doc's raw body: `hospital`, `department`, `userroleid`,
   `userroleposition`, and the log's own trace/span correlation fields `trid`/
   `spid`. To get those, `match`/`wildcard` the `body` field (it's the raw
   JSON string) or parse it after fetching.
   On these same docs the **top-level `traceId`/`spanId` are empty strings**
   — confirmed by direct inspection, not derived — so you cannot join a
   user's desktop-client log line to `otel-v1-apm-span-*` via the indexed
   `traceId` field. If you need that link, extract `trid`/`spid` from `body`
   and compare by value, and treat it as unverified until you confirm the ID
   format matches. Absent that, correlate a user's activity to spans/metrics
   by `resource.attributes.env` + `resource.attributes.host@name` + a
   matching time window instead — there is no direct `userid` field on
   `otel-v1-apm-span-*` or `otel-v1-apm-metrics-*` (both confirmed 0 via
   `CountTool`).

---

## Query recipes

`SearchIndexTool`'s `query_dsl` is the **entire** search request body — you
can add `size`, `_source`, `aggs`, `sort` as sibling keys next to `query`.

### Trace groups / spans for a service

```json
{
  "query": {"term": {"serviceName": "cdr-etl-orchestrator"}},
  "size": 50
}
```
Index: `otel-v1-apm-span-*`. Expect sparse fields — check `traceGroupName`
and `hashId` before assuming `kind`/`destination`/`target` are populated.

### Kubernetes events (e.g. OOMKilled, Evicted) from the logs index

```json
{
  "query": {
    "bool": {
      "must": [
        {"term": {"log.attributes.k8s@event@reason": "OOMKilling"}},
        {"term": {"resource.attributes.k8s@namespace@name": "iam"}}
      ],
      "filter": [{"range": {"time": {"gte": "now-24h", "format": "strict_date_optional_time"}}}]
    }
  },
  "sort": [{"time": "desc"}]
}
```
Index: `otel-v1-apm-logs-otel-*`.

### App log search by severity + free text

```json
{
  "query": {
    "bool": {
      "must": [
        {"term": {"severityText": "ERROR"}},
        {"match": {"body": "timeout"}}
      ],
      "filter": [{"range": {"time": {"gte": "now-1h", "format": "strict_date_optional_time"}}}]
    }
  }
}
```
Index: `otel-v1-apm-logs-otel-*`.

### RED metrics — error rate / status codes for a service in the last hour

```json
{
  "size": 0,
  "query": {
    "bool": {
      "must": [
        {"term": {"serviceName": "ehrstore"}},
        {"range": {"time": {"gte": "now-1h", "format": "strict_date_optional_time"}}}
      ]
    }
  },
  "aggs": {
    "by_status": {
      "terms": {"field": "attributes.metric.attributes.http@response@status_code", "size": 20}
    }
  }
}
```
Index: `otel-v1-apm-metrics-*`. Use `aggs`, not raw doc scans — this index is
18.5M docs/day.

### Filter metrics by deployment environment or pod

```json
{
  "query": {
    "bool": {
      "must": [
        {"term": {"serviceName": "HealthRecord-Indexer"}},
        {"term": {"attributes.resource.attributes.deployment@environment": "thor"}}
      ]
    }
  }
}
```

### Activity log for a specific user

```json
{
  "query": {
    "bool": {
      "must": [{"term": {"resource.attributes.userid.keyword": "2014723"}}],
      "filter": [{"range": {"time": {"gte": "now-24h", "format": "strict_date_optional_time"}}}]
    }
  },
  "sort": [{"time": "asc"}]
}
```
Index: `otel-v1-apm-logs-otel-*`. Match by `userid` (stable numeric ID) rather
than `username` when you have it — usernames are shared domain accounts, IDs
aren't. Read `msg`/other fields out of the raw `body` JSON string for detail
the promoted fields don't carry (`hospital`, `department`, `trid`, `spid`).

### Most active users in a time window

```json
{
  "size": 0,
  "query": {"range": {"time": {"gte": "now-1h", "format": "strict_date_optional_time"}}},
  "aggs": {
    "by_user": {
      "terms": {"field": "resource.attributes.username.keyword", "size": 20}
    }
  }
}
```
Index: `otel-v1-apm-logs-otel-*`. Only covers users of the DIPS Arena Desktop
Client (the `otlp/webhookevent` source) — not every user-facing app is
instrumented into this index.

### Service dependency map

```json
{"query": {"match_all": {}}, "size": 100}
```
Index: `otel-v1-apm-service-map` — small static index, no date suffix, just
pull it all.

---

## Tool cheat sheet

- **`ListIndexTool`** — resolve which rollover (`-000041`) or dated
  (`2026.08.11`) index currently exists before hardcoding a suffix; pass
  `include_detail: false` for a quick name-only list.
- **`IndexMappingTool`** — call on the specific index before writing new DSL
  against a field you haven't confirmed; `attributes.metric.attributes.*` and
  `attributes.resource.attributes.*` grow as new OTel semantic-convention
  attributes land.
- **`SearchIndexTool`** — main query tool; `size` caps at 100 — use
  `CountTool` first if you just need a number, and prefer `aggs` over raw doc
  scans on `otel-v1-apm-metrics-*` (18.5M docs/day).
- **`CountTool`** — cheap existence/volume check before an expensive wildcard
  search; this is how the span index's sparsity above was confirmed.
- **`MsearchTool`** — batch the same query across several dated
  `otel-v1-apm-logs-otel-*`/`otel-v1-apm-metrics-*` indices in one round trip
  instead of relying on wildcard expansion.
- **`ExplainTool`** — why didn't doc X match query Y — rarely needed outside
  relevance debugging.
- **`GenericOpenSearchApiTool`** — escape hatch for anything without a
  dedicated tool (`_cat/indices`, `_alias`, ILM/ISM rollover policy for
  `otel-v1-apm-span-*`, etc.).

---

## Works well with

- `opensearch@observability` skill — generic PPL/PromQL patterns (RED
  metrics, SLO/SLI, correlation) once you know which `otel-v1-apm-*`
  index/field to point it at
- `k8s-debug` — cross-check pod/namespace names found in
  `otel-v1-apm-logs-otel-*` against live cluster state
