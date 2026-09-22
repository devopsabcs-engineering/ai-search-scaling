---
applyTo: '.copilot-tracking/changes/2026-09-22/ai-search-scaling-rca-remediation-changes.md'
---
<!-- markdownlint-disable-file -->
# Implementation Plan: Azure AI Search Scaling RCA and Remediation Package

## Overview

Build a customer-facing advisory package that explains the 206 semantic partial responses and the 613 connector 403 errors, supplies runnable diagnostics and observability assets, and delivers submittable CSS escalation drafts.

## Objectives

### User Requirements

* Advise the customer on how to help them with the Azure AI Search scaling problem — Source: conversation, "advise on how to help customer: assets\additionalInfo.md"
* Ground the advice in `assets/meetingNotes.md` rather than the raw transcript — Source: conversation, "Use meetingNotes instead of transcript then"
* Recommend opening a CSS ticket where warranted — Source: conversation, "recommend customer to open a css ticket if needed"
* Leverage out-of-box solutions such as workbooks, dashboards, and Application Insights KQL — Source: conversation, "leverage out of the box solutions such as workbooks and dashboards and KQL queries"
* Search Microsoft documentation for answered solutions to similar problems — Source: conversation, "search for answered solution in microsoft docs for similar problems"
* Determine whether this is a common Copilot Studio pattern — Source: conversation, "perhaps this is common with copilot studio"
* Explain why Basic → S1 resolved the error in large part, and why an RCA is still needed — Source: conversation, "why does that work and why we should find RCA"

### Derived Objectives

* Separate the 206 and 403 problems into independent workstreams — Derived from: research D6 proving Azure AI Search never returns 403 for quota or storage, so the tier change cannot explain both symptoms.
* Deliver diagnostics as runnable scripts rather than prose instructions — Derived from: eleven unverified items (U1–U11) that can only be closed with data from the customer's environment.
* Treat fan-out reduction as the strategic recommendation and tier scaling as a stopgap — Derived from: research D1 and D7 showing every limit in the path is multiplied by seven, so capacity purchases defer rather than resolve the failure.
* Label every threshold and inferred conclusion explicitly — Derived from: Microsoft publishing no thresholds for these signals, and a documented conflict between two Microsoft pages on semantic concurrency units.

## Context Summary

### Project Files

* assets/meetingNotes.md - Authoritative customer evidence: fan-out behaviour, replica effects, APIM placement, ingestion pipeline, load profile
* assets/usefulScreenshots.md - The 403 dependency record and the 206 partial-response field values
* assets/additionalInfo.md - Themed customer context and the key systemic insight
* README.md - Currently a stub; becomes the package index in Phase 7

### References

* .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md - Primary research document: headline answer, D1–D11, Scenarios 1–4, U1–U11, thirteen customer questions
* .copilot-tracking/research/subagents/2026-09-22/206-partial-response-tier-capacity-research.md - 206 semantics, semantic ranker limits, capacity planning
* .copilot-tracking/research/subagents/2026-09-22/403-connector-apim-research.md - Ranked 403 hypotheses and APIM attribution
* .copilot-tracking/research/subagents/2026-09-22/observability-workbooks-kql-research.md - KQL library, workbook gallery inventory, alert rules
* .copilot-tracking/research/subagents/2026-09-22/copilot-studio-fanout-and-css-escalation-research.md - Fan-out mechanics, architecture alternatives, CSS decision tree
* https://learn.microsoft.com/en-us/azure/search/search-limits-quotas-capacity - Semantic ranker throttling limits per search unit
* https://learn.microsoft.com/en-us/azure/search/semantic-how-to-query-request - Expected workloads and the instruction to file a support ticket
* https://learn.microsoft.com/en-us/rest/api/searchservice/http-status-codes - 403 means authorization failure, not quota
* https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio - The 25-knowledge-source filtering threshold

### Standards References

* .github/instructions/hve-core/markdown.instructions.md — Markdown authoring conventions (resolved from the hve-core extension when absent locally)
* .github/instructions/hve-core/writing-style.instructions.md — Voice, tone, and language conventions (resolved from the hve-core extension when absent locally)

## Implementation Checklist

`parallelizable` means **safe to author concurrently**. Dependencies that name a diagnostic setting or a customer environment are runtime prerequisites for running a deliverable, not authoring gates.

### [x] Implementation Phase 1: RCA Advisory Documents

<!-- parallelizable: true -->

* [x] Step 1.1: Author the 206 partial-response RCA document
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 23-71)
* [x] Step 1.2: Author the 403 connector triage document
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 72-109)
* [x] Step 1.3: Author the Copilot Studio fan-out explainer
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 110-146)
* [x] Step 1.4: Validate phase changes
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 147-154)

### [x] Implementation Phase 2: Diagnostic and Evidence-Collection Scripts

<!-- parallelizable: true -->

* [x] Step 2.1: Create the Azure AI Search diagnostic script
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 159-199)
* [x] Step 2.2: Create the APIM and network policy audit script
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 200-238)
* [x] Step 2.3: Create the telemetry enablement script
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 239-277)
* [x] Step 2.4: Validate phase changes
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 278-285)

### [x] Implementation Phase 3: KQL Query Library

<!-- parallelizable: true -->

* [x] Step 3.1: Create the discovery queries
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 292-321)
* [x] Step 3.2: Create the fan-out and capacity queries
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 322-352)
* [x] Step 3.3: Create the 403 and 206 attribution queries
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 353-385)
* [x] Step 3.4: Write the KQL library index
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 386-402)
* [x] Step 3.5: Validate phase changes
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 403-408)

### [x] Implementation Phase 4: Workbooks and Alert Rules

<!-- parallelizable: false -->

Sequential after Phase 3 — Steps 4.2 and 4.3 consume the query text authored in Phase 3 and must match it exactly so the two cannot drift. Step 4.1 alone is independent and may start earlier.

* [x] Step 4.1: Write the workbook import guide
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 415-448)
* [x] Step 4.2: Author the Azure AI Search semantic-capacity workbook
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 449-482)
* [x] Step 4.3: Define the alert rules
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 483-524)
* [x] Step 4.4: Validate phase changes
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 525-531)

### [x] Implementation Phase 5: Remediation and Architecture Guidance

<!-- parallelizable: true -->

Parallel with Phase 1. Terminology consistency with Step 1.3 is maintained through a shared anchor in the research document rather than through ordering; lint scopes are per-file so the two phases do not lint each other's in-progress work.

* [x] Step 5.1: Author the immediate mitigations document
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 538-579)
* [x] Step 5.2: Author the fan-out reduction architecture document
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 580-632)
* [x] Step 5.3: Validate phase changes
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 633-640)

### [x] Implementation Phase 6: CSS Escalation Packages

<!-- parallelizable: false -->

* [x] Step 6.1: Write the escalation decision guide
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 645-679)
* [x] Step 6.2: Draft the Azure AI Search support ticket
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 680-725)
* [x] Step 6.3: Draft the Copilot Studio and APIM support tickets
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 726-756)
* [x] Step 6.4: Validate phase changes
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 757-762)

### [x] Implementation Phase 7: Customer Questions, Open Items, and Repository Index

<!-- parallelizable: false -->

* [x] Step 7.1: Write the customer questions and open items documents
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 767-795)
* [x] Step 7.2: Rewrite the repository README as the package index
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 796-819)
* [x] Step 7.3: Run full project validation
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 820-829)
* [x] Step 7.4: Fix minor validation issues
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 830-833)
* [x] Step 7.5: Report blocking issues
  * Details: .copilot-tracking/details/2026-09-22/ai-search-scaling-rca-remediation-details.md (Lines 834-842)

## Planning Log

See .copilot-tracking/plans/logs/2026-09-22/ai-search-scaling-rca-remediation-log.md for discrepancy tracking, implementation paths considered, and suggested follow-on work.

## Dependencies

* Azure CLI (`az`) with the `search` and `apim` command groups
* Azure Bicep CLI
* PowerShell 7+ with `PSScriptAnalyzer`
* Node.js with `npx` for `markdownlint-cli2`
* Reader access to the customer's Search service, APIM instance, and Application Insights component; Contributor for telemetry enablement

## Success Criteria

* The leading 206 hypothesis is stated quantitatively — 6 in-flight semantic slots on Basic at 1 search unit versus the 7 concurrent requests the agent issues per turn — is defensible to a Microsoft support engineer, and is presented as the strongest supported explanation rather than a confirmed cause, consistent with U1 — Traces to: research D1, D2, U1; user requirement "why does that work and why we should find RCA"
* The residual "in large part" gap is answered in the 206 RCA document with the `sessionId` replica-pinning and semantic-free-plan candidates, both labelled inferred — Traces to: research D9, D10; user requirement "Basic to S1 did resolve the error in large part"
* The 403 analysis is presented as a ranked hypothesis list with an executable discriminating test per hypothesis and never asserts an unproven cause — Traces to: research D6
* Out-of-box workbooks are identified and import instructions provided; the absent Azure AI Search workbook is authored — Traces to: research D11; user requirement "leverage out of the box solutions"
* The Copilot Studio fan-out behaviour is confirmed against documented Microsoft behaviour, including the 25-source threshold — Traces to: research D7; user requirement "perhaps this is common with copilot studio"
* Both CSS ticket drafts are submittable with only customer-specific values filled in, and route to the correct portals — Traces to: research Scenario 4; user requirement "recommend customer to open a css ticket if needed"
* Every Microsoft claim carries an inline Microsoft Learn link, and inferred conclusions are visually distinguished from documented ones — Traces to: research U1–U11; user requirement "search for answered solution in microsoft docs"
* No deliverable cites assets/transcript.md; all meeting-derived evidence traces to assets/meetingNotes.md, and assets/additionalInfo.md is cited in the package index — Traces to: user requirement "Use meetingNotes instead of transcript then"; user requirement "advise on how to help customer: assets/additionalInfo.md"
* All markdown, PowerShell, and Bicep validation passes — Traces to: derived objective on deliverable quality
