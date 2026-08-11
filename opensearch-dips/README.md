# opensearch-dips

Tailored OpenSearch skill for our cluster (`opensearch-stack`). Unlike a generic
OpenSearch/PPL reference, this encodes the *actual* index map, field mappings,
and naming quirks discovered on our cluster via the `opensearch-mcp` tools —
so questions about traces, logs, and IAM auth events get answered correctly on
the first query instead of guessing field names.

## Skill

### `opensearch-dips:opensearch-dips`

Triggered when the user asks about our OpenSearch data: traces, spans, slow
requests, service errors, pod/application logs, IAM/Keycloak/oauth2-proxy auth
events, or cluster/query-performance health.

**Trigger examples:**
- "find traces for HealthRecord-Indexer slower than 2s"
- "look up trace id <traceID>"
- "show auth failures for user X in the last hour"
- "check the top slow queries on opensearch"
- "search pod logs in namespace iam"

## Prerequisites

- `opensearch-mcp` MCP server connected (tools: `ListIndexTool`, `IndexMappingTool`,
  `SearchIndexTool`, `CountTool`, `MsearchTool`, `ClusterHealthTool`,
  `GetShardsTool`, `ExplainTool`, `GenericOpenSearchApiTool`)

## What this covers that a generic OpenSearch skill doesn't

- Which index family is actually live vs. dead (e.g. `otel-v1-apm-span-*` has
  8 docs total — don't use it for trace lookups, use `jaeger-span-*`)
- The dot-to-`@` field flattening convention used on most (but not all) index
  families, and where it doesn't apply
- That `env` means *deployment environment* in trace/metric data but
  *Kubernetes namespace* in `logservice-*` — same field name, different meaning
- That Jaeger tags live in a nested array and need a nested query to filter on

## Works well with

- `opensearch@observability` — generic PPL/PromQL reference for RED metrics,
  SLO/SLI, correlation
- `k8s-debug` — cross-reference pod names / namespaces found in logs with live
  cluster state
- `keycloak-test` — `iam-auth-events-*` is the direct data trail for Keycloak/
  oauth2-proxy auth investigations
