<!-- markdownlint-disable-file -->
# Implementation Details: Azure AI Search Scaling RCA and Remediation Package

## Context Reference

Sources:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md — primary research document
* .copilot-tracking/research/subagents/2026-09-22/206-partial-response-tier-capacity-research.md — 206 semantics, semantic ranker limits, capacity math
* .copilot-tracking/research/subagents/2026-09-22/403-connector-apim-research.md — ranked 403 hypotheses, APIM attribution
* .copilot-tracking/research/subagents/2026-09-22/observability-workbooks-kql-research.md — KQL library, workbook gallery, alert rules
* .copilot-tracking/research/subagents/2026-09-22/copilot-studio-fanout-and-css-escalation-research.md — fan-out mechanics, CSS decision tree
* assets/meetingNotes.md — authoritative customer evidence
* assets/usefulScreenshots.md — 403 dependency record, 206 partial-response fields
* assets/additionalInfo.md — themed customer context

This engagement produces a customer-facing advisory package inside this repository. No customer Azure resources are modified by this plan; scripts are read-only diagnostics plus opt-in telemetry enablement the customer runs themselves.

## Implementation Phase 1: RCA Advisory Documents

<!-- parallelizable: true -->

### Step 1.1: Author the 206 partial-response RCA document

Write the defensible root-cause explanation for the 206 partial semantic responses, anchored on the published semantic-ranker concurrency limits, and explain precisely why Basic → S1 plus added replicas resolved most of the symptoms.

Content must include:

* The semantic ranker queuing mechanism quoted verbatim from Microsoft Learn.
* The tier limits table (Basic 2 concurrent + 4 queued; S1 3 + 6; S2/S3 4 + 8) with the note that limits are **per search unit** and search units = replicas × partitions.
* The capacity table showing Basic @ 1 SU = 6 in flight versus the agent's 7 concurrent semantic requests per turn.
* The explicit framing that this is an **arity problem, not a load problem** — which is why 7–15 users/hour never looked like a plausible cause.
* The `Transient` + `BaseResults` enum decode: L1 results only, no `@search.rerankerScore`, no `@search.captions`, no `@search.answers` — which is the mechanism behind "empty answers despite data in the index".
* Why zero 429s is expected: three separate throttle paths (query → 503 with a metric, indexing → 207, semantic queue overflow → 206 body annotation counted by no metric). 206 is a 2xx, so APIM passes it and retry policies keyed on 429/5xx never fire.
* The `semanticErrorHandling` anomaly: documented default is `fail`, yet partials are arriving, and the Copilot Studio connector exposes neither `semanticErrorHandling` nor `semanticMaxWaitInMilliseconds`.
* The documentation conflict callout: "10 concurrent queries per replica" versus "2/3/4 per search unit" — flagged as ticket question #1.
* **The residual question — why S1 fixed it only "in large part".** Two candidate explanations, both labelled inferred: a constant `sessionId` pins traffic to one replica set and defeats the scale-out, since the REST reference warns that *"reusing the same sessionID values repeatedly can interfere with the load balancing"*; and the semantic ranker free plan caps at 1,000 requests per month, which this fan-out exhausts in one to three days.
* An explicit "why RCA still matters" section: the fix is a capacity band-aid on an architectural fan-out problem and will re-break on S1 as concurrency grows.

Terminology anchor: use the vocabulary fixed in .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 6-14) — "fan-out", "search unit", "in flight", "arity problem, not a load problem". Steps 1.2, 1.3, and 5.2 draw from the same anchor so the documents can be authored concurrently without diverging.

Files:

* docs/rca-206-semantic-concurrency.md - primary 206 root-cause analysis

Discrepancy references:

* Implements D1, D2, D3, D4, D5, D10 from the research document.
* Addresses DR-05 — D10 is the research's answer to the residual symptom and belongs in the RCA, not only in the mitigations list.
* Carries U1, U2, U3, U4 forward as explicitly labelled open items rather than asserting them as fact.

Success criteria:

* Document states the numeric mechanism (6 in flight on Basic @ 1 SU versus 7 required) in the first screen of content.
* Every Microsoft claim carries an inline Microsoft Learn link.
* Inferred conclusions are visually distinguished from documented ones.
* The "why Basic → S1 worked" question is answered quantitatively, not narratively.
* The "in large part" residual is addressed explicitly with the `sessionId` and semantic-plan candidates, both labelled inferred.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 80-141) - D1 through D5
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 180-187) - D9 and D10, the residual explanations
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 425-440) - U1 through U4
* .copilot-tracking/research/subagents/2026-09-22/206-partial-response-tier-capacity-research.md (Lines 324-400) - semantic limits table detail
* .copilot-tracking/research/subagents/2026-09-22/206-partial-response-tier-capacity-research.md (Lines 963-1055) - mechanism narrative

Dependencies:

* None.

### Step 1.2: Author the 403 connector triage document

Write the 403 analysis as a **ranked hypothesis list with a discriminating test per hypothesis**, leading with the explicit statement that the tier change does not explain the 403s.

Content must include:

* The verbatim Azure AI Search status-code semantics: 403 = authorization failure; 429 = throttling and low storage; 402 = semantic free-plan exhaustion. Therefore the storage/quota theory is dead.
* The ranked hypothesis table: Search IP firewall versus connector egress prefixes (High), APIM `quota`/`quota-by-key` (High), APIM `ip-filter` (High), per-index RBAC scoping (Med-High), multiple connection instances (Med-High), APIM subscription key (ruled out — returns 401), Search storage quota (contradicted).
* The two telemetry tells: `duration: 2566` ms is far too slow for an APIM inbound short-circuit and points at a backend-originated rejection; `DesignMode: True` with `channelId: pva-studio` means all 613 failures came from the authoring test canvas rather than the published channel.
* The recommended diagnostic order: enable APIM `GatewayLogs` and run the attribution query first, because branching on `BackendResponseCode` collapses thirteen hypotheses to about four. The zero-setup 30-second check (are 100% of the 403s design-mode?) runs in parallel.
* The coincidence question the customer must answer: what else changed in the same window as the Basic → S1 scale — firewall edits, key regeneration, APIM policy changes?

Files:

* docs/rca-403-connector-triage.md - ranked 403 hypotheses with discriminating tests

Discrepancy references:

* Implements D6 from the research document.
* Carries U9, U10 forward as open items.

Success criteria:

* Document opens by stating the 403s and the 206s are independent problems.
* Every hypothesis row has a concrete, executable discriminating test.
* Ruled-out and contradicted hypotheses are retained with their disproving citation rather than deleted.
* The design-mode-only check is called out as the cheapest first action.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 142-163) - D6 and the hypothesis table
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 61-68) - the two telemetry tells
* .copilot-tracking/research/subagents/2026-09-22/403-connector-apim-research.md (Lines 189-250) - 206/403 log semantics

Dependencies:

* None.

### Step 1.3: Author the Copilot Studio fan-out explainer

Document why all 7 knowledge sources are queried on every turn, confirm the customer's belief is correct, and correct the one point where their conclusion overreaches.

Content must include:

* The verbatim Microsoft statement that generative orchestration filters knowledge sources with an internal GPT model **only when there are more than 25 different knowledge sources** — with 7, that filter never engages.
* The correction: "not possible while we keep a single agent with knowledge sources" is true only while they remain *knowledge sources*. Re-expressed as **Tools** or **child/connected agents**, the orchestrator selects by name and description. This is the architectural unlock.
* The second independent cause of empty answers to rule out: if "Allow ungrounded responses" is off, Copilot Studio suppresses answers it cannot cite.
* The explicit warning not to add knowledge sources to exceed 25 in order to trigger GPT filtering.

Terminology anchor: use the vocabulary fixed in .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 6-14) — "fan-out", "search unit", "in flight", "arity problem, not a load problem". Step 5.2 draws from the same anchor and its output must match this document's terminology, which is what makes the two safe to author concurrently.

Files:

* docs/copilot-studio-fanout.md - fan-out mechanics and the routing correction

Discrepancy references:

* Implements D7, D8 from the research document.
* Carries U7 forward (Azure AI Search does not appear in the documented supported-knowledge-sources table).

Success criteria:

* The 25-source threshold is quoted verbatim with its Microsoft Learn link.
* The Tools / connected-agents unlock is stated as the actionable correction, not buried.
* The "Allow ungrounded responses" check is present as a distinct rule-out.
* Terminology matches the shared anchor, so docs/fan-out-reduction-architecture.md can be written against the same vocabulary.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 164-179) - D7 and D8

Dependencies:

* None.

### Step 1.4: Validate phase changes

Run markdown linting for the files created in this phase only. Scope the glob to this phase's files so it does not lint Phase 5's in-progress documents.

Validation commands:

* `npx --yes markdownlint-cli2 "docs/rca-206-semantic-concurrency.md" "docs/rca-403-connector-triage.md" "docs/copilot-studio-fanout.md"` - lint this phase's three advisory documents

## Implementation Phase 2: Diagnostic and Evidence-Collection Scripts

<!-- parallelizable: true -->

### Step 2.1: Create the Azure AI Search diagnostic script

A read-only PowerShell script that collects every Search-side fact the RCA and the CSS ticket depend on.

Must collect and emit:

* Service name, region, SKU (tier), `replicaCount`, `partitionCount`, and the derived search-unit count.
* `properties.semanticSearch` — the single highest-priority check, because a value of `free` caps semantic ranking at 1,000 requests per month, which this workload exhausts in one to three days.
* `properties.publicNetworkAccess` and `networkRuleSet.ipRules`, plus the resource's last-modified timestamp where available.
* Service creation date — services created before 2024-04-03 cap Basic at 1 partition and 3 SU, which changes the capacity math.
* Whether a diagnostic setting exists and whether it includes both `OperationLogs` and `AllMetrics`.
* A computed capacity verdict: in-flight semantic capacity versus the 7-request-per-turn requirement.

Must be strictly read-only. Use `az search service show` and `az monitor diagnostic-settings list`. Emit both human-readable output and a JSON file suitable for attaching to a support ticket.

Files:

* scripts/Get-SearchServiceDiagnostics.ps1 - read-only Search service capacity and configuration audit

Discrepancy references:

* Addresses D9 (semantic free plan), D1 (capacity math), and the evidence checklist in Scenario 4.

Success criteria:

* Script performs no write operations of any kind.
* `semanticSearch` plan is reported first and flagged loudly when it is `free`.
* Output includes the computed in-flight capacity and a pass/fail against a configurable concurrent-turn target.
* JSON output file is written for ticket attachment.
* Script runs cleanly under PSScriptAnalyzer with no errors.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 80-102) - capacity math
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 180-183) - D9 semantic free plan
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 400-414) - CSS evidence checklist

Dependencies:

* Azure CLI authenticated with at least Reader on the Search service.

### Step 2.2: Create the APIM and network policy audit script

A read-only script that dumps the facts needed to discriminate among the 403 hypotheses.

Must collect and emit:

* APIM SKU/tier — Consumption tier supports no resource logs at all, which invalidates the gateway-log diagnostic plan and must be detected early.
* Policy XML at global, product, API, and operation scopes, with a scan for `<quota>`, `<quota-by-key>`, `<rate-limit>`, `<ip-filter>`, `<validate-jwt>`, and `<on-error>` elements.
* An explicit flag for any `<quota>` element, since it is the only APIM throttling policy that returns 403 rather than 429.
* Whether a diagnostic setting exists for `GatewayLogs` and whether request/response body logging is configured.
* The current Search `networkRuleSet.ipRules` set alongside the current `AzureConnectors.<Region>` service-tag prefixes for the relevant geography, with a diff showing prefixes present in the service tag but absent from the allow-list.

Files:

* scripts/Get-ApimPolicyAudit.ps1 - APIM tier, policy scan, and gateway-log readiness
* scripts/Compare-ConnectorEgressPrefixes.ps1 - Search IP allow-list versus current AzureConnectors service tags

Discrepancy references:

* Addresses D6 hypotheses 1, 2, and 3.
* Addresses U9 (APIM tier unknown).

Success criteria:

* Both scripts are strictly read-only.
* Presence of any `<quota>` policy produces a prominent finding.
* Consumption-tier APIM produces an explicit warning that gateway logs are unavailable.
* The prefix comparison emits the missing-prefix list, which is the direct evidence for hypothesis 1.
* Both scripts run cleanly under PSScriptAnalyzer.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 142-163) - D6 hypothesis table
* .copilot-tracking/research/subagents/2026-09-22/403-connector-apim-research.md (Lines 189-250) - APIM attribution detail

Dependencies:

* Azure CLI authenticated with Reader on the APIM instance and the Search service.

### Step 2.3: Create the telemetry enablement script

A script the customer runs to close the observability gaps identified in the research. This is the only script in the package that writes, and it must require explicit confirmation.

Must enable:

* Search diagnostic setting with **both** `OperationLogs` and `AllMetrics`.
* APIM `GatewayLogs` at 100% sampling with headers and **response-body logging**, because `@search.semanticPartialResponseReason` exists only in the response body and is absent from the Search resource-log schema.
* Copilot Studio → Application Insights export with **"Log conversation details" on**, without which the connector dependency spans the 403 queries depend on are not emitted.
* A pre-flight check for `DisableLocalAuth` on the target Application Insights component, since Copilot Studio telemetry export fails **silently** when it is set.

Must support `-WhatIf` and must refuse to run against Consumption-tier APIM.

Files:

* scripts/Enable-DiagnosticSettings.ps1 - opt-in telemetry enablement with confirmation and WhatIf support

Discrepancy references:

* Addresses D11 and the Scenario 3 Step 0 prerequisites.
* Addresses DR-07 — the Copilot Studio "Log conversation details" toggle.

Success criteria:

* Script supports `-WhatIf` and prompts before every write.
* `DisableLocalAuth` pre-flight check is present and blocks with a clear message.
* Consumption-tier APIM is detected and the gateway-log step is skipped with an explanation.
* The Copilot Studio export toggle is covered, and where it cannot be set programmatically the script emits the portal steps.
* Script runs cleanly under PSScriptAnalyzer.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 188-200) - D11 observability assets and the schema limitation
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 271-274) - Scenario 3 Step 0 and the two warnings

Dependencies:

* Azure CLI authenticated with Contributor on the Search service, APIM instance, and the Log Analytics workspace.

### Step 2.4: Validate phase changes

Run PowerShell static analysis for the scripts created in this phase.

Validation commands:

* `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Error,Warning` - static analysis

## Implementation Phase 3: KQL Query Library

<!-- parallelizable: true -->

The `parallelizable` marker in this plan means **safe to author concurrently**. Every dependency below that names a diagnostic setting is a **customer-environment runtime prerequisite** for executing the query, not an authoring gate — the `.kql` files can be written with no telemetry enabled anywhere.

### Step 3.1: Create the discovery queries

The customer's observed span shape (`type == "Connector"`, `attributes.conversationId`) matches **neither** documented Copilot Studio telemetry schema, which publishes `GenAI`/`ExecuteTool` and `gen_ai.conversation.id`. Discovery must therefore run before any dashboard is built on assumed column names.

Files:

* kql/00-discover-dependency-types.kql - enumerate actual dependency type/name/target combinations
* kql/01-discover-search-diagnostic-shape.kql - confirm which `AzureDiagnostics` columns the Search service actually populates

Discrepancy references:

* Addresses U8 (span shape mismatch) and U6 (whether `resultSignature_d` ever emits 206).

Success criteria:

* Each file carries a header comment stating its purpose, the target data source, and its prerequisites.
* Discovery queries are explicitly labelled as "run these first".
* U6 and U8 are named in the file headers as the open questions the query resolves.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 353-361) - the dependency discovery query
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Line 351) - the span-shape mismatch warning
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 425-440) - U6, U8

Dependencies:

* Authoring: none.
* Runtime: diagnostic settings enabled (Phase 2 Step 2.3), or pre-existing telemetry.

### Step 3.2: Create the fan-out and capacity queries

Files:

* kql/10-fan-out-ratio.kql - proves the 7× per-turn amplification from `AzureDiagnostics`
* kql/11-search-by-http-result-code.kql - buckets Search results by status with the 206/403/429/503 distinction
* kql/12-semantic-capacity-headroom.kql - concurrent semantic requests per minute against the computed in-flight limit

Each file must carry a header comment naming the data source, required diagnostic categories, and any unverified assumption. The 206 bucket in `11-search-by-http-result-code.kql` must be annotated as **unverified** — no Microsoft example confirms that Search emits 206 into `resultSignature_d`.

Discrepancy references:

* Addresses D1, D4.
* Carries U6 as an inline annotation rather than an unqualified claim.

Success criteria:

* Every query has a header comment with purpose, source table, and prerequisites.
* The unverified 206 bucket is annotated inline.
* Queries use only columns confirmed present in the documented schema, or are explicitly gated behind the discovery step.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 276-291) - the fan-out ratio query
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 293-310) - the result-code bucketing query with the inline UNVERIFIED annotation

Dependencies:

* Authoring: none.
* Runtime: Step 3.1 discovery results confirm column availability.

### Step 3.3: Create the 403 and 206 attribution queries

The APIM attribution query is the highest-value single diagnostic in the entire package: branching on `BackendResponseCode` answers "did APIM reject it, or did the backend?" and collapses thirteen hypotheses to roughly four.

Files:

* kql/20-apim-403-triage.kql - attributes each 403 to APIM policy versus Search backend
* kql/21-apim-206-semantic-partial-capture.kql - extracts `semanticPartialResponseReason` from the response body
* kql/22-connector-403-by-index.kql - groups connector 403s by target index to test the per-index RBAC hypothesis
* kql/23-design-mode-vs-published.kql - splits failures by `DesignMode` to test whether production is affected at all

Discrepancy references:

* Addresses D6 hypotheses 1 through 5.
* `21-apim-206-semantic-partial-capture.kql` is the only mechanism that resolves U1 and U2 — it captures whether the reason is `Transient` or `CapacityOverloaded` and reveals the effective `semanticErrorHandling` value.

Success criteria:

* `20-apim-403-triage.kql` uses only verified `ApiManagementGatewayLogs` columns.
* `21-apim-206-semantic-partial-capture.kql` documents its hard dependency on response-body logging.
* `23-design-mode-vs-published.kql` is marked as the zero-setup 30-second first check.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 312-336) - the 403 attribution query and the ResponseCode versus BackendResponseCode explanation
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 338-349) - the 206 partial-reason capture query
* .copilot-tracking/research/subagents/2026-09-22/observability-workbooks-kql-research.md (Lines 900-1000) - APIM query detail

Dependencies:

* Authoring: none.
* Runtime: APIM `GatewayLogs` with response-body logging enabled (Phase 2 Step 2.3).

### Step 3.4: Write the KQL library index

Files:

* kql/README.md - run order, prerequisites per query, and what each query proves or disproves

Success criteria:

* Run order is explicit and starts with the discovery queries.
* Each entry states its prerequisite diagnostic category.
* Each entry states the hypothesis it tests.

Dependencies:

* Authoring: Steps 3.1 through 3.3 complete — the index enumerates the files they create. This is an intra-phase gate; it does not affect Phase 3's parallelism with other phases.
* Runtime: none.

### Step 3.5: Validate phase changes

Validation commands:

* `npx --yes markdownlint-cli2 "kql/**/*.md"` - lint the KQL index

## Implementation Phase 4: Workbooks and Alert Rules

<!-- parallelizable: false -->

This phase is sequential because Steps 4.2 and 4.3 consume the query text authored in Phase 3 — each workbook tile and each alert rule must match its `kql/` file exactly so the two cannot drift. Step 4.1 alone has no such dependency and may be started earlier if convenient.

### Step 4.1: Write the workbook import guide

Two Microsoft-published workbooks exist and should be imported rather than rebuilt. No Azure AI Search workbook template exists in either Microsoft gallery repository, so that part must be authored.

Files:

* workbooks/README.md - what exists out of the box, what does not, and how to import

Content must cover:

* Copilot Studio Dashboard — <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Copilot%20Studio>
* APIM Analytics — <https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20API%20Management/Analytics>
* Power Platform KQL pack — <https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services/Power%20Platform>
* Application Insights "Agents (preview)" blades — portal-only, no template.
* The explicit statement that **no Azure AI Search workbook template exists** and that Search logs land in `AzureDiagnostics` with no dedicated table.

Discrepancy references:

* Implements D11.

Success criteria:

* Gallery links are present and correct.
* The "does not exist" findings are stated plainly so the customer does not waste time searching.
* Import steps are concrete enough to follow without further research.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 188-200) - D11 asset inventory

Dependencies:

* None.

### Step 4.2: Author the Azure AI Search semantic-capacity workbook

Build the workbook that does not exist out of the box, composed from the Phase 3 queries.

Files:

* workbooks/ai-search-semantic-capacity.workbook.json - deployable Azure Monitor workbook

Sections to include:

* Fan-out ratio over time.
* Search results by HTTP status with the 206 bucket separated.
* Semantic capacity headroom against the computed in-flight limit.
* 403 attribution split by APIM policy versus backend.
* Design-mode versus published-channel failure split.

Discrepancy references:

* Implements D11, consumes Phase 3 queries.

Success criteria:

* Workbook JSON is valid and importable through the Azure portal gallery import.
* Parameters exist for subscription, resource group, Search service, and time range.
* Every tile's query matches the corresponding `kql/` file so the two do not drift.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 276-361) - the five source queries

Dependencies:

* Phase 3 queries authored.

### Step 4.3: Define the alert rules

Microsoft publishes no thresholds for these signals. Every threshold in this deliverable is an engineering recommendation and must be labelled as such, with an instruction to tune against two weeks of baseline.

Files:

* alerts/alert-rules.md - rule definitions, rationale, and tuning guidance
* alerts/alert-rules.bicep - deployable scheduled query rules

Rules to define:

| Rule | Signal | Condition | Severity |
| --- | --- | --- | --- |
| Semantic partial (206) at APIM | `ApiManagementGatewayLogs` `BackendResponseCode == 206` | `count() > 0` per 15 min | 2 |
| Connector 403 rate | `dependencies` `resultCode == "403"` | `> 1%` of calls or `count() > 10` per 15 min | 1 |
| Search throttling critical | `ThrottledSearchQueriesPercentage` | `> 5%` per 5 min | 1 |
| Search throttling warning | `ThrottledSearchQueriesPercentage` | `> 1%` per 5 min | 3 |
| Search latency p95 | `AzureDiagnostics` `DurationMs` | `percentile(DurationMs, 95) > 1000` ms | 2 |
| Ingestion/query contention | composite | indexing ops > 0 AND query p95 > 2× baseline in the same bucket | 2 |

The Application Insights component is shared across Copilot Studio, Azure AI Search, and the Function Apps. The connector 403 rule must therefore scope its denominator to Copilot Studio connector dependencies only — filter on `type == "Connector"` and the `shared_azureaisearch` target established by the Step 3.1 discovery results. An unscoped `> 1% of calls` ratio would be diluted by Function App traffic and would never fire.

Discrepancy references:

* Implements the Scenario 3 alerting table.
* Addresses DR-06 — shared Application Insights scoping.

Success criteria:

* Every threshold is explicitly labelled as a recommendation, not a Microsoft-published value.
* Tuning guidance names a two-week baseline period.
* The connector 403 rule scopes its denominator to Copilot Studio connector dependencies.
* Bicep deploys without validation errors.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 360-373) - alerting table and the threshold caveat

Dependencies:

* Phase 3 queries authored.

### Step 4.4: Validate phase changes

Validation commands:

* `npx --yes markdownlint-cli2 "workbooks/**/*.md" "alerts/**/*.md"` - lint
* `az bicep build --file alerts/alert-rules.bicep --stdout` - Bicep compilation check

## Implementation Phase 5: Remediation and Architecture Guidance

<!-- parallelizable: true -->

Parallel with Phase 1. Terminology consistency with Step 1.3 is maintained through the shared research anchor rather than through ordering, and the phase lint gate is scoped to this phase's own files.

### Step 5.1: Author the immediate mitigations document

The eight actions the customer can take while the RCA completes, in priority order with confidence ratings.

Files:

* docs/immediate-mitigations.md - prioritised interim actions

Actions to document:

| # | Action | Basis | Confidence |
| --- | --- | --- | --- |
| 1 | Verify `properties.semanticSearch == "standard"`, not `"free"` | 1,000 free semantic requests per month exhausts in days at this fan-out | High |
| 2 | Size search units against `ceil(7 × peak_concurrent_turns / 9)` on S1, not against average QPS | semantic limits table | High |
| 3 | Keep at least 2 replicas for the read SLA; 3 if indexers write during query hours | reliability guidance, capacity planning | High |
| 4 | Audit the `sessionId` the agent passes — a constant value pins traffic to one replica set | Search POST REST reference | High |
| 5 | Instrument 206 at the APIM layer; `ThrottledSearchQueriesPercentage` will never show it | monitor data reference | High |
| 6 | Move indexer schedules out of business hours — indexing and queries share resources with no prioritisation | capacity planning | Medium |
| 7 | Confirm whether the 403s are design-mode only; if so, production may be healthy and the engagement reframes | customer telemetry `DesignMode: True` | High |
| 8 | If explicit `semanticErrorHandling` control is required, bypass the built-in connector via a custom connector, HTTP action, or APIM `set-body` | connector parameter list | High |

Must also state the operational constraints: replica scaling is online and the service remains fully operational, but it can take several hours and **cannot be cancelled**; the SLA rule is 2 replicas for read and 3 for read-write, and partitions do not affect SLA. All Search service property changes must use PATCH, never PUT.

Discrepancy references:

* Implements Scenario 2 in full.
* Addresses D9 (semantic plan) and D10 (`sessionId`).

Success criteria:

* Actions are ordered by priority with a confidence rating each.
* The PATCH-not-PUT warning is prominent.
* The "cannot be cancelled" scaling caveat is stated before any scaling recommendation.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 254-268) - Scenario 2

Dependencies:

* None.

### Step 5.2: Author the fan-out reduction architecture document

The strategic recommendation, with the full ranked alternatives table so the customer can see what was considered and why it was rejected.

Files:

* docs/fan-out-reduction-architecture.md - selected approach plus ranked alternatives

Content must include:

* The sizing argument: at 10 concurrent turns the 7-index design needs roughly 24 search units versus about 4 consolidated — a 6× reduction.
* The selected approach: consolidate 7 indexes into 1 with a filterable `businessUnit` field and `search.in()` security trimming, including the index field definition and a sample filtered query.
* The `search.in()` rationale quoted from Microsoft: `or`-chained equality expressions slow query response "by many seconds" whereas `search.in` yields "subsecond" times.
* A pointer to built-in document-level access control as the newer alternative where the source system supports it.
* The before/after fan-out diagram.
* The ranked alternatives table with rejection reasons:

| # | Option | Reduces fan-out? | Effort | Key risk |
| --- | --- | --- | --- | --- |
| 1 | Consolidate to one index plus filter | Yes — 7 to 1 | High | Re-index and re-permission; loses per-index isolation |
| 2 | Convert knowledge sources to Tools | Yes — description-selected | Medium | Description quality is the gate; loses built-in citation rendering |
| 3 | Child or connected agents per business unit | Yes per hop | Med-High | Added latency; no multi-level chaining |
| 4 | Explicit topic plus conditional logic | Yes, deterministic | Low-Med | Brittle to new intents; regresses generative UX |
| 5 | Agentic retrieval / Foundry IQ | Conditional — trap | High | `minimal` reasoning effort uses all sources and **adds** parallel subqueries |
| 6 | Scale replicas or tier | No | Low | Masks the design problem; breaks again as users grow |
| 7 | Disable semantic ranker on some indexes | No to fan-out, yes to the 206 | Low | Relevance regression |
| 8 | Add sources to exceed 25 and trigger GPT filtering | Technically yes | — | Do not do this — perverse incentive, adds latency and cost |

* The sequencing recommendation: option 2 first because it delivers description-driven routing without an index rebuild, then option 1. The two compose.

Terminology anchor: use the vocabulary fixed in .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 6-14), the same anchor Steps 1.1 and 1.3 use, so this document can be authored concurrently with Phase 1 without diverging.

Discrepancy references:

* Implements Scenario 1 and its Considered Alternatives table.
* Implements D7.

Success criteria:

* The selected approach is unambiguous and the rationale is quantitative.
* All eight alternatives are retained with rejection reasons.
* The agentic-retrieval trap is called out explicitly rather than listed as a neutral option.
* Option 2 is identified as the cheapest first step.
* Terminology matches docs/copilot-studio-fanout.md.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 203-253) - Scenario 1 and the alternatives table

Dependencies:

* None. Terminology consistency with Step 1.3 is maintained through the shared anchor rather than through ordering.

### Step 5.3: Validate phase changes

Scope the glob to this phase's files so it does not lint Phase 1's in-progress documents.

Validation commands:

* `npx --yes markdownlint-cli2 "docs/immediate-mitigations.md" "docs/fan-out-reduction-architecture.md"` - lint this phase's documents

## Implementation Phase 6: CSS Escalation Packages

<!-- parallelizable: false -->

### Step 6.1: Write the escalation decision guide

Files:

* support/README.md - which portal for which symptom, sequencing, severity, and the two traps

Content must include:

* The routing table: 206, `CapacityOverloaded`, semantic concurrency, replica sizing, and APIM 403 go to the **Azure portal**; error 613, connector 403, fan-out behaviour, and Copilot Studio quotas go to the **Power Platform admin center**.
* The decision tree, including the "cannot isolate — open both and cross-reference" branch.
* The sequencing rationale: Azure first because Microsoft's own documentation instructs customers to file, the ask is clearest, and it addresses the actual root cause. Copilot Studio second, referencing the Azure case number. APIM third if confirmed as the 403 source.
* Severity B on both, with the explanation that Severity A risks automatic downgrade because the service is functioning post-mitigation.
* Trap 1: **Power Platform support does not perform RCAs** for single-tenant issues. Frame the ask as "identify and remediate", not "provide an RCA".
* Trap 2: **Power Platform performance cases are capped at 4 hours** of engineer time before closure unless the customer holds Unified or Professional Direct.
* The entitlement warning: an Azure Unified contract does not automatically cover Power Platform.

Discrepancy references:

* Implements Scenario 4.
* Carries U11 forward (support-plan entitlements unknown).

Success criteria:

* The decision tree is reproduced and readable.
* Both traps are stated before the ticket drafts, not after.
* Severity guidance includes the downgrade rationale.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 374-414) - Scenario 4

Dependencies:

* None.

### Step 6.2: Draft the Azure AI Search support ticket

Files:

* support/azure-ai-search-ticket.md - ready-to-submit ticket draft

The draft must lead with the Microsoft Learn sentence that instructs customers to file: *"If you anticipate consistent throughput requirements near, at, or higher than this level, please file a support ticket so that we can provision for your workload."* This is the strongest single justification available.

Named asks:

1. Resolve the documentation conflict: "10 concurrent queries per replica" versus "2/3/4 per search unit plus queue". Which is authoritative?
2. Confirm or raise the semantic-ranker concurrency allocation for this service given a 7-index fan-out per turn.
3. Confirm whether `Transient` (as distinct from `CapacityOverloaded`) is emitted under capacity pressure.
4. Confirm what sets `semanticErrorHandling` to `partial` when the documented default is `fail`.

Evidence checklist to embed:

* Service name, region, tier, and replica × partition counts **at failure time and now**.
* `properties.semanticSearch` value.
* Service creation date — pre-2024-04-03 Basic caps at 1 partition and 3 SU.
* Exact UTC timestamps plus `request-id` / `x-ms-request-id` response headers.
* Raw 206 response body showing `@search.semanticPartialResponseReason` and `...Type`.
* Application Insights and Log Analytics exports, APIM gateway logs, Copilot Studio `conversationId` values.
* A reproducible query and the observed fan-out of 7 concurrent semantic requests per turn.

Discrepancy references:

* Implements Scenario 4 and the evidence checklist.
* Escalates U1, U2, U3, U4 as the named ticket questions.

Success criteria:

* The Microsoft "please file a support ticket" quote appears in the opening paragraph.
* All four named asks are present and answerable.
* The evidence checklist is a checkbox list the customer can work through.
* Output from `scripts/Get-SearchServiceDiagnostics.ps1` is referenced as the attachment source.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 103-116) - the "please file a support ticket" quote and the doc conflict
* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 400-414) - evidence checklist

Dependencies:

* Step 1.1 (RCA content), Step 2.1 (evidence script), Step 6.1 (routing guide).

### Step 6.3: Draft the Copilot Studio and APIM support tickets

Files:

* support/copilot-studio-ticket.md - error 613 and connector 403 ticket draft
* support/apim-ticket.md - conditional APIM ticket draft

The Copilot Studio draft must be framed as "identify and remediate", never "provide an RCA", and must cross-reference the Azure case number. It must include the `DesignMode: True` finding prominently, because if the failures are design-mode only the scope narrows substantially.

The APIM draft must be marked **conditional** — file only if `kql/20-apim-403-triage.kql` attributes the 403s to APIM policy rather than the Search backend.

Discrepancy references:

* Implements Scenario 4.
* Consumes the D6 hypothesis ranking.

Success criteria:

* The Copilot Studio draft never uses the phrase "root cause analysis" as the ask.
* The `DesignMode` finding appears in the problem statement.
* The APIM draft carries an explicit "only file if" precondition at the top.
* Both drafts cross-reference the Azure case number placeholder.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 374-414) - Scenario 4 traps and sequencing

Dependencies:

* Step 6.2 complete (Azure ticket is filed first and is referenced by the others).

### Step 6.4: Validate phase changes

Validation commands:

* `npx --yes markdownlint-cli2 "support/**/*.md"` - lint

## Implementation Phase 7: Customer Questions, Open Items, and Repository Index

<!-- parallelizable: false -->

### Step 7.1: Write the customer questions and open items documents

Files:

* docs/customer-questions.md - the thirteen questions that must be answered
* docs/open-items.md - the eleven unverified items with their impact

The questions document must lead with question 1 — how the 7 indexes are wired, as Knowledge sources or as Tools — because the answer changes the headline recommendation. It must also flag questions 2, 3, and 8 as the highest-value quick wins: the semantic plan value, whether `CapacityOverloaded` ever appears alongside `Transient`, and whether the 403s occur on the published agent or only in the test canvas.

The open items document must preserve the distinction between *inferred* and *documented* conclusions so nothing in the package is over-claimed.

Discrepancy references:

* Carries U1 through U11 and all thirteen customer questions forward from the research document verbatim.

Success criteria:

* All thirteen questions are present.
* All eleven open items are present with their impact rating.
* Question 1 is identified as the one that could change the headline answer.

Context references:

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 425-456) - open items and customer questions

Dependencies:

* Phases 1 through 6 complete, so terminology is consistent.

### Step 7.2: Rewrite the repository README as the package index

Files:

* README.md - engagement overview and navigation

Content must include:

* The headline answer in brief: two independent problems, the arity-not-load framing, and the fan-out recommendation.
* A navigation table covering docs, scripts, kql, workbooks, alerts, and support.
* A recommended execution order: run the diagnostics, answer question 1, run the design-mode check, enable telemetry, run the attribution query, then file the Azure ticket.
* A pointer to the research document for the full evidence base, and to assets/meetingNotes.md, assets/usefulScreenshots.md, and assets/additionalInfo.md as the source evidence. Note that assets/transcript.md is superseded by assets/meetingNotes.md and must not be cited.

Success criteria:

* Every directory created by this plan is linked from the README.
* The recommended execution order is numbered and actionable.
* The two-independent-problems framing appears above the fold.
* The three authoritative asset files are cited and transcript.md is marked superseded.

Dependencies:

* All prior phases complete.

### Step 7.3: Run full project validation

Validation commands:

* `npx --yes markdownlint-cli2 "**/*.md" "#.copilot-tracking"` - lint all markdown excluding tracking files
* `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Error,Warning` - PowerShell static analysis
* `az bicep build --file alerts/alert-rules.bicep --stdout` - Bicep compilation
* Verify every relative link in README.md resolves to an existing file.
* Verify no deliverable cites assets/transcript.md, which is superseded by assets/meetingNotes.md.

### Step 7.4: Fix minor validation issues

Iterate on lint errors, PSScriptAnalyzer warnings, Bicep compilation errors, and broken relative links. Apply fixes directly when corrections are straightforward and isolated.

### Step 7.5: Report blocking issues

When validation failures require changes beyond minor fixes:

* Document the issues and affected files.
* Provide the user with next steps.
* Recommend additional research and planning rather than inline fixes.
* Avoid large-scale restructuring within this phase.

## Dependencies

* Azure CLI (`az`) with the `search` and `apim` command groups.
* Azure Bicep CLI for `alerts/alert-rules.bicep`.
* PowerShell 7+ with `PSScriptAnalyzer` for script validation.
* Node.js with `npx` for `markdownlint-cli2`.
* Reader access to the customer's Search service, APIM instance, and Application Insights component for the diagnostic scripts; Contributor for the telemetry enablement script.

## Success Criteria

* The 206 root cause is stated quantitatively and is defensible against a Microsoft support engineer.
* The 403 analysis is a ranked hypothesis list with an executable discriminating test per hypothesis, and never asserts an unproven cause.
* Every Microsoft claim in the package carries an inline Microsoft Learn link.
* Inferred conclusions are visually distinguished from documented ones throughout.
* The customer can run the diagnostic scripts and the KQL library without further research.
* Both CSS ticket drafts are submittable with only customer-specific values filled in.
* All markdown, PowerShell, and Bicep validation passes.
