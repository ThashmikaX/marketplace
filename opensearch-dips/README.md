# opensearch-dips

Tailored OpenSearch skill for our cluster (`opensearch-stack`), scoped to the
four `otel-v1-apm-*` index patterns. Unlike a generic OpenSearch/PPL
reference, this encodes the *actual* mappings and naming quirks discovered on
our cluster via the `opensearch-mcp` tools — so questions about this data get
answered correctly on the first query instead of guessing field names.

## Skill

### `opensearch-dips:opensearch-dips`

Triggered when the user asks about our `otel-v1-apm-*` data: spans/trace
groups, OTel application logs and Kubernetes events, OTel metrics
(ASP.NET Core/k8s/network RED-style), the service dependency map, or
per-user activity in the DIPS Arena Desktop Client logs.

**Trigger examples:**
- "find slow requests for ehrstore in the last hour"
- "any OOMKilled events in the iam namespace"
- "error rate by status code for HealthRecord-Indexer"
- "show me the service dependency map"
- "what did user 2014723 do in the last hour"
- "most active users today"

## Prerequisites

- `opensearch-mcp` MCP server connected (tools: `ListIndexTool`, `IndexMappingTool`,
  `SearchIndexTool`, `CountTool`, `MsearchTool`, `ClusterHealthTool`,
  `GetShardsTool`, `ExplainTool`, `GenericOpenSearchApiTool`)

## What this covers that a generic OpenSearch skill doesn't

- Which of the four `otel-v1-apm-*` patterns is dense vs. sparse (e.g.
  `otel-v1-apm-span-*` has ~3,800 docs total across all 41 rollover indices —
  treat it as a coarse signal, not full per-request trace detail)
- The dot-to-`@` field flattening convention, and the two-levels-deep
  `attributes.metric.attributes.*` vs `attributes.resource.attributes.*`
  split in the metrics index
- That there's no trace-id exemplar linking metrics to spans in this data —
  correlate via `serviceName` + pod + time window instead
- The different suffix schemes: numbered rollover (`-000041`) for spans vs.
  calendar-dated (`2026.08.11`) for logs/metrics vs. no suffix for the
  service map
- That `resource.attributes.userid`/`username` (DIPS Arena Desktop Client
  activity) exist only in `otel-v1-apm-logs-otel-*` — confirmed 0 hits in the
  metrics and span indices — and that `traceId`/`spanId` are empty strings on
  those same docs, so there's no direct join from a user's log line to a span

## Out of scope (by request)

Jaeger trace indices, `otel-logs-*`/`logservice-*` pod logs, and
`iam-auth-events-*` also exist on this cluster but are deliberately excluded
from this skill.
