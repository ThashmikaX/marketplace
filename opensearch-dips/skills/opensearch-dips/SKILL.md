---
name: opensearch-dips
description: >
  Use when the user asks questions about our OpenSearch cluster's data:
  distributed traces/spans, slow requests, service errors, application or pod
  logs, IAM/Keycloak/oauth2-proxy auth events, or OpenSearch cluster/query
  health. Trigger on keywords like "opensearch", "trace id", "span", "jaeger",
  "find traces", "slow request", "service errors", "pod logs", "search logs",
  "auth events", "oauth2-proxy", "who logged in", "top queries", "cluster
  health", "index mapping". Also trigger whenever an opensearch-mcp tool
  (ListIndexTool, IndexMappingTool, SearchIndexTool, CountTool, MsearchTool,
  ClusterHealthTool, GetShardsTool, ExplainTool, GenericOpenSearchApiTool)
  would be the right way to answer a question, even if the user didn't name
  OpenSearch explicitly (e.g. "why was this request slow", "did this user
  authenticate").
---

# OpenSearch — our cluster (`opensearch-stack`)

This is a map of what's *actually* in our cluster, learned by querying it
directly — not generic OpenSearch advice. Green, 11 nodes / 6 data nodes.
Read the index map below before writing any query: several index families
look similar but use different field-naming conventions, and one is dead.

Always call `IndexMappingTool` on the specific dated index you're about to hit
if anything here looks stale — mappings can drift.

---

## Index map

| Pattern | What it is | Volume | Live? |
|---|---|---|---|
| `jaeger-span-YYYY-MM-DD` | **Distributed traces — the real one.** Every span from every .NET/OTel-instrumented service. | ~600K+ docs/day | ✅ primary |
| `jaeger-service-YYYY-MM-DD` | Lightweight `serviceName`/`operationName` pairs only, feeds Jaeger UI's dropdowns. | small | Skip for real queries |
| `otel-logs-YYYY.MM.DD` | Kubernetes pod stdout/stderr, all namespaces, OTel Collector `k8s.*` schema (dots, not `@`). | ~22M docs/day | ✅ primary pod-log firehose |
| `logservice-YYYY.MM.DD` | Kubernetes pod logs too, but only for a handful of infra namespaces seen so far (`kube-system`, `monitoring`, `messaging`, `iam`, `linkerd`) and a Serilog/CLEF-style schema (`@t`, `@l`, `msg`, `k.ci`/`k.cn`). Mostly collector/infra-component self-logs in samples. | ~3M docs/day | ✅ but narrower scope than `otel-logs-*` — confirm scope before relying on it for app logs |
| `iam-auth-events-*` | oauth2-proxy / Keycloak edge auth log lines (who authenticated, from where, at what stage). **The place to look for auth investigations.** | moderate | ✅ primary for IAM |
| `otel-v1-apm-span-*` | OpenSearch's own Trace Analytics (Data Prepper) span format. | 8 docs total, mostly null | ❌ dead — use `jaeger-span-*` instead |
| `otel-v1-apm-logs-otel-*` | Data Prepper OTel logs format (`resource.attributes.*` / `log.attributes.*`, `@`-flattened). | ~200K docs/day | ✅ live, secondary log path |
| `otel-v1-apm-metrics-*` | Data Prepper OTel metrics — ASP.NET Core / k8s / network RED-style metrics per request. | ~18M docs/day | ✅ live, very high volume |
| `otel-v1-apm-service-map` | Precomputed service dependency edges (source→destination). | small | ✅ for service-map questions |
| `metrics-otel-v1-*` | A separate data-stream-based metrics index. | 0 docs | ❌ dead, ignore |
| `security-auditlog-YYYY.MM.DD` | OpenSearch Security plugin's own audit log — who queried *the cluster*, not the app. | — | Cluster security audits only |
| `top_queries-YYYY.MM.DD-*` | OpenSearch Query Insights — slow/expensive queries *against this cluster*. | — | OpenSearch perf tuning only |
| `.plugins-ml-*`, `.plugins-flow-framework-*`, `.opensearch-observability`, `.opendistro_security`, `.opendistro-job-scheduler-lock`, `.kibana_1`, `.ql-datasources` | Internal system indices. `.ql-datasources` is empty — no external PPL/SQL federated datasources configured. | — | Never query directly |
| `opensearch_dashboards_sample_data_*`, `test-d1-*` | OSD demo data / empty scratch indices. | — | Ignore |

Trace/log/audit indices are **date-suffixed and roll daily** — don't hardcode
a date. Use `ListIndexTool` with a pattern (e.g. `jaeger-span-*`) to see what
exists, or query a wildcard directly (e.g. `jaeger-span-2026-08-*` for a
month, `otel-logs-2026.08.1*` for a few days) and let OpenSearch resolve it.
**Always add a timestamp range filter on wildcard queries** — `otel-logs-*`
and `otel-v1-apm-metrics-*` alone run tens of millions of docs/day.

---

## Field-naming gotchas (read this before writing DSL)

1. **Dot-to-`@` flattening.** In `otel-v1-apm-*` and `iam-auth-events-*`,
   OTel attribute/resource keys have every `.` replaced with `@` when
   promoted to a field name: `k8s.namespace.name` → `k8s@namespace@name`,
   `http.response.status_code` → `http@response@status_code`. **This does
   NOT apply to `otel-logs-*`**, which keeps literal dots (`k8s.namespace.name`,
   `container.image.name`) — check which family you're in before guessing a
   field name.

2. **`env` means different things in different indices.** In
   `jaeger-span-*` (process tags) and `otel-v1-apm-metrics-*` (resource
   attributes), `env` is the **deployment environment** (e.g. `thor`, `ak02`,
   `production`, `sldev`). In `logservice-*`, top-level `env` is the
   **Kubernetes namespace** (`kube-system`, `monitoring`, `iam`, ...). Don't
   assume — check the index family first.

3. **Jaeger tags are nested — term queries on a dotted path won't match.**
   Span attributes live in a `tags` nested array (`{"key":..., "value":...,
   "tagType":...}`), and process-level attributes (`env`, `aid`, `host.name`,
   `service.instance.id`, `dotnet-core`) live in `process.tags`, same shape.
   A flat `tag.<key>` field sometimes exists (e.g. `tag.span@kind`) but is
   **only sparsely populated** — don't rely on it for filtering. Always use a
   `nested` query (see recipes below) to filter by any tag/process-tag.

4. **Jaeger's dynamic template still promotes some tags to `tag.<key>`** with
   dots turned to `@` (e.g. `tag.db@system`, `tag.http@method`) — these are
   leftover/partial from the ingest pipeline and inconsistent across docs.
   Treat them as a fast-path optimization to try first with a fallback to the
   nested query, never as the only filter.

5. **Timestamp fields differ by family:**
   - `jaeger-span-*`: `startTimeMillis` (epoch millis, use for range queries),
     `startTime` (epoch **micros**, don't range-filter on this directly).
     `duration` is in **microseconds**.
   - `otel-logs-*`, `otel-v1-apm-logs-otel-*`, `iam-auth-events-*`,
     `logservice-*`: `@timestamp` (ISO 8601) — use
     `"format": "strict_date_optional_time||epoch_millis"` per the tool's own
     guidance.
   - `otel-v1-apm-span-*`: `startTime`/`endTime` are `date_nanos`.

6. **`aid`** is our internal numeric application ID, tagged consistently
   across `jaeger-span-*` process tags, `otel-v1-apm-metrics-*` resource
   attributes, and `logservice-*` — useful as a stable join key across index
   families when `serviceName` strings differ slightly.

---

## Query recipes

`SearchIndexTool`'s `query_dsl` is the **entire** search request body, not
just the `query` clause — you can include `size`, `_source`, `aggs`, `sort` as
sibling keys.

### Look up a trace by ID

```json
{"query": {"term": {"traceID": "cb15507c2001f6086b90aca391724d51"}}, "size": 100, "sort": [{"startTimeMillis": "asc"}]}
```
Index: `jaeger-span-*` (or narrow to the known day for speed).

### Slow spans for a service in the last hour

```json
{
  "query": {
    "bool": {
      "must": [
        {"term": {"process.serviceName": "HealthRecord-Indexer"}},
        {"range": {"startTimeMillis": {"gte": "now-1h", "lte": "now", "format": "epoch_millis||strict_date_optional_time"}}},
        {"range": {"duration": {"gte": 2000000}}}
      ]
    }
  },
  "size": 50,
  "sort": [{"duration": "desc"}]
}
```
`duration` is microseconds — `2000000` = 2s.

### Filter spans by a process tag (e.g. deployment env) — nested query required

```json
{
  "query": {
    "bool": {
      "must": [
        {"term": {"process.serviceName": "cdr-etl-orchestrator"}},
        {"nested": {"path": "process.tags", "query": {"bool": {"must": [
          {"term": {"process.tags.key": "env"}},
          {"term": {"process.tags.value": "thor"}}
        ]}}}}
      ]
    }
  }
}
```
Same pattern for span-level attributes, just swap `process.tags` → `tags`
(e.g. filter `db.system` = `oracle`).

### Error spans for a service

```json
{
  "query": {
    "bool": {
      "must": [
        {"term": {"process.serviceName": "ehrstore"}},
        {"nested": {"path": "tags", "query": {"term": {"tags.key": "otel.status_code"}}}}
      ],
      "filter": [{"nested": {"path": "tags", "query": {"term": {"tags.value": "ERROR"}}}}]
    }
  }
}
```

### Service dependency map

```json
{"query": {"match_all": {}}, "size": 100}
```
Index: `otel-v1-apm-service-map` — small, just pull it all.

### Pod/application logs by namespace + text search

```json
{
  "query": {
    "bool": {
      "must": [
        {"term": {"k8s.namespace.name": "iam"}},
        {"match": {"Body.value": "error"}}
      ],
      "filter": [{"range": {"@timestamp": {"gte": "now-1h", "format": "strict_date_optional_time"}}}]
    }
  }
}
```
Index: `otel-logs-*`. Note plain dots here, not `@`.

### IAM / oauth2-proxy auth events for a user

```json
{
  "query": {
    "bool": {
      "must": [{"match": {"body": "sithmi.s@creativesoftware.com"}}],
      "filter": [{"range": {"@timestamp": {"gte": "now-24h", "format": "strict_date_optional_time"}}}]
    }
  }
}
```
Index: `iam-auth-events-*`. `body` holds the raw oauth2-proxy access-log line
(client IP, session hash, user email, HTTP verb, path, status, latency).
`auth_stage` (e.g. `edge`) and `serviceName` are also useful filters.

### Cluster / query-performance health

```
ClusterHealthTool           → status, node counts, shard counts
GetShardsTool(index)        → per-shard state for one index
top_queries-* via SearchIndexTool → find OpenSearch's own slow queries
```

---

## Tool cheat sheet

- **`ListIndexTool`** — resolve today's/this-week's actual index names before
  querying a daily-rolling family; pass `include_detail: false` for a quick
  name-only list.
- **`IndexMappingTool`** — call on the specific dated index before writing
  new DSL against a field you haven't confirmed; mappings can drift day to
  day (e.g. new `resource.attributes.*` keys appear as new OTel semantic
  conventions land).
- **`SearchIndexTool`** — main query tool; `size` caps at 100 — use `CountTool`
  first if you just need a number, and add `aggs` instead of pulling raw docs
  for anything cardinality-shaped ("how many errors", "which services").
- **`CountTool`** — cheap existence/volume check before running an expensive
  wildcard search.
- **`MsearchTool`** — batch the same query across several dated indices in
  one round trip (e.g. last 7 days of `jaeger-span-YYYY-MM-DD`) instead of
  relying on wildcard expansion.
- **`ExplainTool`** — why didn't doc X match query Y — rarely needed outside
  relevance debugging.
- **`GenericOpenSearchApiTool`** — escape hatch for anything without a
  dedicated tool (`_cat/indices`, `_alias`, ILM/ISM policy inspection, etc.).

---

## Works well with

- `opensearch@observability` skill — generic PPL/PromQL patterns (RED
  metrics, SLO/SLI, correlation) once you know which index/field to point it at
- `k8s-debug` — cross-check pod/namespace names found in `otel-logs-*` or
  `logservice-*` against live cluster state
- `keycloak-test` — `iam-auth-events-*` is the data trail for Keycloak/
  oauth2-proxy investigations that skill's test runs surface
