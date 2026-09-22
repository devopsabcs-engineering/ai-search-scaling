<!-- markdownlint-disable-file -->
# Release Changes: Azure AI Search Scaling RCA and Remediation Package

**Related Plan**: ai-search-scaling-rca-remediation-plan.instructions.md
**Implementation Date**: 2026-09-22

## Summary

Builds a customer-facing advisory package that explains the 206 semantic partial responses and the 613 connector 403 errors, supplies runnable diagnostics and observability assets, and delivers submittable CSS escalation drafts.

## Changes

### Added

* docs/rca-206-semantic-concurrency.md - 206 partial-response RCA; leading hypothesis framed as 7 concurrent semantic requests against 6 in-flight slots on Basic at 1 search unit, with the Basic-to-S1 capacity table and the `sessionId` and semantic-free-plan residual candidates
* docs/rca-403-connector-triage.md - 403 connector triage; declares the two problems independent, kills the storage/quota theory with verbatim status-code semantics, ranks six live hypotheses each with an executable discriminating test, and retains ruled-out hypotheses with their disproving citations
* docs/copilot-studio-fanout.md - fan-out mechanics; 25-source threshold quoted verbatim, the Tools and connected-agents unlock surfaced as the actionable correction, the ungrounded-responses rule-out, and a caution against padding sources past 25
* docs/immediate-mitigations.md - eight interim actions in priority order with paired evidence and confidence labels, PATCH-not-PUT and cannot-be-cancelled constraints placed ahead of all actions, and a closing statement that none of the eight reduces the fan-out
* docs/fan-out-reduction-architecture.md - stopgap framing, the 24-versus-4 search unit sizing comparison, the consolidation design with `businessUnit` filtering and `search.in()` trimming, and eight ranked alternatives including both negative recommendations
* scripts/Get-SearchServiceDiagnostics.ps1 - read-only; checks `properties.semanticSearch` first, computes search units and semantic in-flight capacity against the per-tier table, reports network posture and the creation-date partition ceiling, emits JSON evidence
* scripts/Get-ApimPolicyAudit.ps1 - read-only; enumerates policy at all scopes, separates `quota` and `quota-by-key` from `rate-limit`, flags the Consumption tier as critical
* scripts/Compare-ConnectorEgressPrefixes.ps1 - read-only; merges allow-list ranges before containment testing and reports each connector prefix as Covered, Partial, or Missing with a supported/refuted hypothesis status
* scripts/Enable-DiagnosticSettings.ps1 - the only writing script; `SupportsShouldProcess` with `ConfirmImpact = 'High'`, `DisableLocalAuth` pre-flight, refuses APIM gateway configuration on Consumption tier
* kql/00-discover-dependency-types.kql - mandatory first query; resolves the customer span shape against the undocumented schema
* kql/01-discover-search-diagnostic-shape.kql - confirms the actual `AzureDiagnostics` column projection for the Search resource
* kql/10-fan-out-ratio.kql - quantifies searches per conversation turn
* kql/11-search-by-http-result-code.kql - result-code distribution with the 206 bucket marked unverified pending U6
* kql/12-semantic-capacity-headroom.kql - parameterised tier limits with the U4 documentation conflict stated inline
* kql/20-apim-403-triage.kql - branches on `BackendResponseCode` versus `ResponseCode` and states what each branch eliminates
* kql/21-apim-206-semantic-partial-capture.kql - captures `@search.semanticPartialResponseReason` from the APIM response body, the only place it exists
* kql/22-connector-403-by-index.kql - two sections; connector-side counts plus Search-side `IndexName_s` grouping for the per-index RBAC test
* kql/23-design-mode-vs-published.kql - zero-setup first check; splits the 613 failures by authoring canvas versus published channel
* kql/README.md - run order, prerequisites by diagnostic category, and an open-items resolution table
* .markdownlint.json - repository lint configuration; MD013 at 500 characters with tables and code blocks exempt, matching the hve-core house style
* workbooks/README.md - import guide for the three importable gallery assets and the portal-only Agents blades; states the two absences (no Azure AI Search workbook template, no dedicated Search Log Analytics table) as findings
* workbooks/ai-search-semantic-capacity.workbook.json - the workbook that does not exist in the gallery; five tiles covering fan-out ratio, Search results by HTTP status with 206 separated, semantic capacity headroom, 403 attribution by policy versus backend, and the design-mode split; eight parameters, no hard-coded resource identifiers
* alerts/alert-rules.md - six rules, each with detection description, source query, threshold, threshold rationale, prerequisites, and an explicit re-baselining requirement
* alerts/alert-rules.bicep - four scheduled query rules plus two metric alerts; every threshold a parameter, deploys disabled with no action group by default
* support/README.md - escalation decision guide; opens with a free-diagnostics gate of eight checks, a "when not to open a ticket" table mapping six likely asks back to the documents that already answer them, routing stated twice, and both Power Platform traps plus the entitlement warning ahead of the draft links
* support/azure-ai-search-ticket.md - leads with the Microsoft Learn "please file a support ticket so that we can provision for your workload" quote; 22-row placeholder table, copy-paste title and problem description, four named asks including the U4 documentation conflict, and a three-part evidence checklist
* support/copilot-studio-ticket.md - routed to the Power Platform admin center; leads with the `DesignMode: "True"` / `channelId: "pva-studio"` scope finding and carries a "what to keep out of this case" table
* support/apim-ticket.md - gated behind a blocking do-not-file precondition and a four-row gate-check table that must point the same way before filing
* docs/open-items.md - all eleven unverified items U1 through U11, each with what is unverified, why it matters, and the named script, query, or ticket ask that resolves it
* docs/customer-questions.md - the thirteen research questions plus the Power Platform entitlement question as #14, with an "answer these four first" quick-win table and a closing map from each answer to the documents it updates

### Modified

* README.md - stub replaced with the full package index; two independent problems stated above the fold, a nine-step "Start here" path leading with the four zero-cost checks, a separate first-time reading order, and per-file tables for every directory

Corrections applied to files added earlier in this same release, recorded for auditability rather than counted as separate modifications:

* docs/copilot-studio-fanout.md - corrected the agentic retrieval trap from `low` to `minimal` reasoning effort and cross-linked the full evaluation; wrapped one line exceeding 500 characters
* docs/rca-206-semantic-concurrency.md - corrected the Basic partition uplift cutoff from 2026-04-03 to 2024-04-03
* kql/README.md - wrapped one line exceeding 500 characters

Local-only, outside the tracked repository (`assets/` is listed in `.gitignore`):

* assets/meetingNotes.md, assets/usefulScreenshots.md, assets/additionalInfo.md - additive frontmatter and whitespace normalization only; no evidence text, timestamp, or JSON value altered

### Removed

## Additional or Deviating Changes

* `.markdownlint.json` was created by the Phase 1 subagent and is not traced to any plan step
  * Without it, markdownlint defaults gate at 80 characters with tables included, which is unfixable for the package's tables and contradicts the hve-core writing conventions. Phase 5 wrapped its two documents to 80 characters before the config existed, which is tighter than required but still valid.
  * The file was subsequently changed from `{"MD013": false}` to the hve-core house values so the standard is enforced rather than disabled.
* The plan's `npx --yes markdownlint-cli2` validation command cannot execute in this environment
  * The configured registry proxy returns `EALLOWREMOTE` for remote tarball fetches, and no global install exists. All four subagents hit this independently.
  * Substituted the warm npx cache binary at `C:\Users\emknafo\AppData\Local\npm-cache\_npx\5bf8557687b9b9bc\node_modules\.bin\markdownlint-cli2.cmd` (markdownlint-cli2 v0.18.1, markdownlint v0.38.0). Same binary and ruleset as the plan intends.
* A factual conflict arose between two concurrently-authored documents
  * Phase 1's fan-out explainer named `low` reasoning effort as the agentic retrieval trap; Phase 5's architecture document named `minimal`. The documented behaviour is that `minimal` bypasses LLM-based query planning and uses all sources, while `low` and `medium` do perform source selection.
  * Corrected in `docs/copilot-studio-fanout.md` and cross-linked to the architecture document.
* `scripts/Get-SearchServiceDiagnostics.ps1` reads ARM twice rather than relying on `az search service show` alone, as the details file specifies
  * `properties.semanticSearch` and `systemData.createdAt` are not consistently projected by the `az search` extension, and `semanticSearch` is the step's highest-priority check. A raw `az resource show` fallback was added so the top-priority check cannot silently return unknown.
* The two remediation documents deliberately size capacity on different bases
  * `docs/immediate-mitigations.md` uses `ceil((7 * peak_concurrent_turns) / 9)`, admitting queueing; `docs/fan-out-reduction-architecture.md` divides by concurrent slots alone to produce the 24-versus-4 figures the plan requires. Both state the difference and cross-reference each other.
* Phase 1 and Phase 5 use different but equivalent inferred-claim markers
  * Phase 1 uses a bolded `Inferred:` prefix; Phase 5 uses paired evidence and confidence label columns. Both satisfy the success criterion that inferred conclusions are visually distinguished from documented ones. Left as authored rather than forced into one form.
* Phase 4 alert bodies are derived from the Phase 3 queries rather than byte-identical, against the plan's verbatim instruction
  * A strictly verbatim copy is impossible for a scheduled query rule: embedding `| where TimeGenerated > ago(lookback)` double-filters against the rule's own `windowSize`, and a rule firing on row count must end in a threshold predicate the diagnostic query does not have.
  * Resolved by holding the workbook to byte-exact fidelity (5 of 5 tiles), deriving only the alert bodies while keeping every filter, `extend`, and `summarize` line byte-identical, and making each delta auditable in both the Bicep comments and `alerts/alert-rules.md`. Zero unexplained drift.
* Two Phase 4 artifacts are schema-valid rather than deployment-proven
  * The workbook parses as JSON but was not round-tripped through the portal Advanced Editor. The Bicep compiles with zero warnings but no deployment or what-if was run. Both carried forward as follow-on items rather than asserted as verified.
* A date defect in `docs/rca-206-semantic-concurrency.md` was caught by the Phase 6 subagent and fixed outside its own scope
  * The document gave the Basic partition uplift cutoff as 2026-04-03. Every other artifact, including `scripts/Get-SearchServiceDiagnostics.ps1` and Microsoft's documentation, uses 2024-04-03. A support engineer checking the creation date against the real cutoff would have computed a wrong capacity ceiling.
* `assets/transcript.md` does not exist on disk
  * The workspace listing at the start of the engagement showed it, and the plan's Step 7.2 criterion assumed it was present and deprecated. The index now states that `meetingNotes.md` is the only meeting-derived source any document draws on and that the raw transcript is superseded and cited nowhere, which satisfies the criterion without asserting a file exists when it does not.
* The three `assets/` files were modified under Step 7.4 despite being customer-supplied evidence
  * They had never passed lint and contributed 28 of the 43 errors on the first full-project run. In `meetingNotes.md` the eight `---` separators were being parsed as setext heading underlines, silently turning every section into a multi-line H2.
  * Changes were confined to additive frontmatter and whitespace. `assets/` is listed in `.gitignore`, so these edits are local-only and never ship with the package.
* Phase 4 and Phase 6 subagents reported that the plan's `npx --yes markdownlint-cli2` command would block their phases
  * Each was given the cached-binary substitution up front rather than discovering the failure independently. The plan text still carries the original command and should be corrected before reuse.

## Release Summary

Thirty-one files affected in the tracked repository across seven implementation phases: 30 added and 1 modified, plus 3 local-only normalizations under the gitignored `assets/` directory.

| Directory | Files | Purpose |
| --- | --- | --- |
| `docs/` | 7 added | The RCA itself: two problem analyses, the fan-out explainer, two remediation documents, the open items register, and the customer questions |
| `scripts/` | 4 added | Runnable diagnostics; three read-only, one write-gated with `-WhatIf` |
| `kql/` | 10 added | Nine queries in three tiers plus the library index |
| `workbooks/` | 2 added | The import guide for existing gallery assets and the Azure AI Search workbook that does not exist in the gallery |
| `alerts/` | 2 added | Six rules with thresholds as parameters and deployable Bicep |
| `support/` | 4 added | The escalation decision guide and three submittable ticket drafts |
| root | 1 added, 1 modified | `.markdownlint.json` and the package index |

No dependency or infrastructure changes were made to any live environment. Every script defaults to read-only; `scripts/Enable-DiagnosticSettings.ps1` is the sole exception and requires explicit per-write confirmation. `alerts/alert-rules.bicep` deploys disabled with no action group attached, so a deployment cannot page anyone without a further deliberate change.

Deployment notes for the customer: run the four zero-cost checks in the root index "Start here" path before anything else, since several hypotheses are disprovable in minutes without enabling telemetry. Run `kql/00-discover-dependency-types.kql` before any downstream query, because the observed span shape matches neither documented Copilot Studio schema. Alert thresholds are starting points and require re-baselining against two weeks of production telemetry before being enabled.

Validation was re-run independently after all phases completed: markdownlint 18 files 0 errors, PSScriptAnalyzer 0 findings at Warning and Error, `az bicep build` exit 0, workbook JSON parses, 349 relative links resolve, zero citations of `assets/transcript.md`, and zero lint suppressions in customer-facing files.
