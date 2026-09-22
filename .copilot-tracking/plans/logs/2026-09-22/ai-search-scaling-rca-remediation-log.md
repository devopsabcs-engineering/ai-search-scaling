<!-- markdownlint-disable-file -->
# Planning Log: Azure AI Search Scaling RCA and Remediation Package

## Discrepancy Log

Gaps and differences identified between research findings and the implementation plan.

### Unaddressed Research Items

* DR-01: Ingestion pipeline redesign (ADF → Function Apps, embedding preparation, upsert semantics)
  * Source: .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 24-39)
  * Reason: Declared out of scope in the research document. The plan carries only the indexer-scheduling mitigation (move indexing out of business hours), not a pipeline redesign.
  * Impact: low

* DR-02: Embedding model selection and index schema redesign beyond consolidation
  * Source: .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 24-39)
  * Reason: Explicitly out of scope. The plan documents the consolidation target schema (`businessUnit` filterable field plus `search.in()` trimming) but does not design the full consolidated index.
  * Impact: medium — if the customer accepts the consolidation recommendation, a follow-on planning cycle is required.

* DR-03: Seven "Potential Next Research" items, including confirming whether the 206s are exclusively `Transient` or whether `CapacityOverloaded` also appears
  * Source: .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 415-424)
  * Reason: All seven require data from the customer's environment or answers from the customer. The plan converts them into runnable diagnostics (Phase 2, Phase 3) and explicit questions (Phase 7 Step 7.1) rather than attempting to resolve them during implementation.
  * Impact: medium — the package is complete and shippable, but several conclusions remain labelled inferred until the customer returns data.

* DR-04: Power BI reporting currently used by the customer alongside Application Insights
  * Source: assets/meetingNotes.md (43:36)
  * Reason: The research established the Azure Monitor and workbook path as the recommendation. Integrating or migrating the existing Power BI reporting was not investigated.
  * Impact: low

* DR-05: D10 (`sessionId` pinning traffic to one replica set) is not carried into the 206 RCA document
  * Source: .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 184-187)
  * Reason: The research names D10 as the candidate explanation for why S1 resolved the problem only "in large part". The plan places `sessionId` solely in Phase 5 Step 5.1 as mitigation action 4. Phase 1 Step 1.1 — the document that answers the user requirement "why does that work" — lists no content requirement and no success criterion covering the residual failures after the tier change.
  * Impact: major — the user requirement quotes "in large part" verbatim, so the residual is part of the question asked. As planned, the RCA explains why the tier change helped but not why it did not fully resolve the symptom, and the reader must reach a different document to find the candidate answer.

* DR-06: Application Insights is shared across Copilot Studio, Azure AI Search, and the Function Apps; no plan step requires the KQL to scope to the correct component
  * Source: assets/meetingNotes.md (43:36); .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 40-56)
  * Reason: Phase 3 Steps 3.1 through 3.3 specify header comments for purpose, data source, and prerequisites, but no step requires a role or component filter. Queries against `dependencies` in a shared component will aggregate ingestion-pipeline and Search-side spans alongside connector spans.
  * Impact: minor — recoverable at authoring time, but the connector 403 rate alert defined in Phase 4 Step 4.3 (`dependencies` `resultCode == "403"` over 1% of calls) computes its denominator across every caller in the shared component unless scoped.

* DR-07: Copilot Studio "Log conversation details" is a Scenario 3 Step 0 prerequisite and is absent from the telemetry enablement step
  * Source: .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Line 271)
  * Reason: Phase 2 Step 2.3 covers the Search diagnostic setting, APIM `GatewayLogs` with response-body logging, and the `DisableLocalAuth` pre-flight, but not the Copilot Studio toggle. The toggle is a Power Platform surface with no `az` CLI path, which plausibly explains the omission from a script-shaped step.
  * Impact: minor — the prerequisite is real and is not captured anywhere else in the plan, so it should appear as a manual step in the Phase 3 or Phase 7 prerequisites rather than be dropped.

### Plan Deviations from Research

* DD-01: Research surfaces a documentation conflict between "10 concurrent queries per replica" and "2/3/4 per search unit"; the plan builds all capacity math on the per-search-unit table
  * Research recommends: raise the conflict as ticket question #1 without selecting a side
  * Plan implements: the per-search-unit table as the working model for the capacity script and the RCA document, with the conflict retained as an explicit open item and a named ticket question
  * Rationale: the per-search-unit figures are the more conservative of the two and are the ones that actually predict the observed failure at Basic with 1 search unit. Building on the less favourable number means the recommendation does not collapse if Microsoft confirms the stricter reading.

* DD-02: Research ranks index consolidation first and Tools conversion second; the plan sequences Tools conversion first in the delivery recommendation
  * Research recommends: consolidation as the highest-ranked option by fan-out reduction
  * Plan implements: both are documented with consolidation ranked first on impact, but the delivery guidance sequences Tools conversion ahead of it
  * Rationale: Tools conversion delivers description-driven routing without an index rebuild or a re-permissioning exercise, and the two options compose. Ranking by impact and sequencing by cost are not in conflict; the plan makes the distinction explicit.

* DD-03: Research provides KQL as inline code blocks; the plan externalises them into individual `.kql` files
  * Research recommends: no particular packaging
  * Plan implements: one query per file with a header comment, plus an index with run order
  * Rationale: individually runnable files can be pasted directly into Log Analytics and referenced unambiguously from the workbook and the ticket drafts. It also creates a single place to record each query's prerequisites and the hypothesis it tests.

* DD-04: Research treats the design-mode finding as one observation among many; the plan elevates it to a gating check
  * Research recommends: check whether the 403s are design-mode only, listed as mitigation #7
  * Plan implements: a dedicated KQL query marked as the zero-setup first check, plus a prominent placement in the 403 triage document and the Copilot Studio ticket draft
  * Rationale: if all 613 failures originate from the authoring canvas, the production impact is nil and the entire engagement reframes. A finding that can change the scope that much belongs at the front of the workflow, not in the middle of a list.

* DD-05: Research records the `Transient`-to-capacity link as inferred; the plan's top-level success criterion names it "the 206 root cause"
  * Research recommends: U1 states that no Microsoft source links `Transient` (as distinct from `CapacityOverloaded`) to tier or capacity, so the correlation is real but inferred
  * Plan implements: Phase 1 Step 1.1 correctly requires U1 through U4 be carried forward as labelled open items, but the plan-file Success Criteria section reads "The 206 root cause is stated quantitatively ... and is defensible to a Microsoft support engineer"
  * Rationale: the step-level instruction is correct and the deviation is confined to the summary wording. Left unqualified, the success criterion invites an implementer to state a proven root cause in the customer-facing document while the step it summarises asks for a labelled inference. Recommend rewording to "the 206 mechanism" or appending "with the `Transient` attribution labelled as inferred pending customer data".
  * Impact: minor

## Plan-Internal Findings

Findings from the plan and details files themselves rather than from a research-to-plan comparison. Recorded here at the requester's instruction; they are not research discrepancies.

### Parallelization

* PV-01: Phase 4 is marked `parallelizable: true` but cannot run concurrently with Phase 3 (major)
  * Evidence: details Step 4.2 and Step 4.3 both declare `Dependencies: Phase 3 queries authored`. Step 4.2 adds the success criterion "Every tile's query matches the corresponding `kql/` file so the two do not drift", which is a content dependency on files Phase 3 creates, not merely an ordering preference.
  * Impact: an orchestrator honouring the marker will author the workbook against queries that do not yet exist, and the anti-drift criterion becomes unverifiable at the time it is checked.
  * Recommendation: mark Phase 4 `parallelizable: false`, or split it — Step 4.1 (workbook import guide) has `Dependencies: None` and is genuinely parallel; Steps 4.2 and 4.3 are not.

* PV-02: Phase 5 is marked `parallelizable: true` but Step 5.2 depends on a Phase 1 step (major)
  * Evidence: details Step 5.2 declares `Dependencies: Step 1.3 fan-out explainer, for consistent terminology`.
  * Impact: Step 5.1 is genuinely independent; Step 5.2 is not. Running Phase 5 alongside Phase 1 produces two fan-out narratives authored against no shared vocabulary, which is the specific outcome the dependency was written to prevent.
  * Recommendation: either drop the dependency and move the shared terminology into the plan's Context Summary so both steps read from one source, or mark Phase 5 sequential after Phase 1.

* PV-03: Phase 3 declares dependencies on Phase 2 without stating whether they are authoring-time or runtime (major)
  * Evidence: details Step 3.1 declares `Dependencies: Diagnostic settings enabled (Phase 2 Step 2.3), or pre-existing telemetry`; Step 3.3 declares `Dependencies: APIM GatewayLogs with response-body logging enabled (Phase 2 Step 2.3)`.
  * Impact: both dependencies are satisfied in the customer's environment at execution time, not in this repository at authoring time — the `.kql` files can be written with no telemetry enabled anywhere. As written, the dependency is indistinguishable from an authoring gate, so it will either serialize the phase unnecessarily or be ignored along with the real gates.
  * Recommendation: label these explicitly as runtime prerequisites for the customer, distinct from the authoring dependencies used elsewhere in the details file.

* PV-04: Phases 1 and 5 write to the same directory and run the same validation gate while both are marked parallel (minor)
  * Evidence: Phase 1 Step 1.4 and Phase 5 Step 5.3 both run `npx --yes markdownlint-cli2 "docs/**/*.md"`. Phase 1 writes three files into `docs/`; Phase 5 writes two more.
  * Impact: each phase's gate lints the other phase's in-progress output. A phase can fail its own validation on files it does not own, and a passing gate does not establish that the phase's own files are clean.
  * Recommendation: scope each gate to the files that phase creates.

* PV-05: Phases 1, 2, 3 (authoring), 6, and 7 sequencing is otherwise sound (informational)
  * Phase 1 and Phase 2 steps all declare `Dependencies: None` and write to disjoint directories (`docs/` and `scripts/`) — genuinely parallel.
  * Phase 6 is correctly marked sequential: Step 6.2 depends on Steps 1.1, 2.1, and 6.1; Step 6.3 depends on Step 6.2.
  * Phase 7 is correctly marked sequential: Step 7.1 depends on Phases 1 through 6; Step 7.2 depends on all prior phases.

### Cross-References

* PV-06: All 29 `Details:` line ranges in the plan file resolve correctly (informational)
  * Every range begins on the target step heading and ends on the line before the next heading. Verified against details headings at lines 23, 66, 104, 138, 150, 191, 230, 266, 278, 306, 335, 366, 382, 392, 426, 460, 498, 509, 551, 601, 611, 646, 692, 723, 733, 762, 785, 794, 798.

* PV-07: Four details-to-research ranges point at the wrong content (minor)
  * Step 3.2 cites research Lines 292-320 as "fan-out and result-code queries". The fan-out query `Q1b-FanOutRatio` is at research lines 276-291 and is excluded; the range instead extends into the `Q8c-Apim403Triage` header at line 313. Step 3.2's first deliverable is `kql/10-fan-out-ratio.kql`, so its source query is outside its own citation.
  * Step 3.3 cites Lines 320-340 as "the attribution and partial-capture queries". The attribution query header begins at line 313 and the partial-capture query body runs 341-350 — the range starts mid-query and stops before the second query it names.
  * Step 3.1 cites Lines 340-360 as "discovery query and the schema-mismatch warning". That content begins at line 351; lines 340-350 are the partial-capture query belonging to Step 3.3.
  * Step 4.2 cites Lines 292-360 as "source queries", which omits the fan-out query although "Fan-out ratio over time" is the workbook's first listed section.
  * Impact: recoverable — the research document has clear headings and is short — but each range sends the implementer to neighbouring content, and Step 3.2's case omits the source for a named output file.
  * All other details-to-research and details-to-subagent ranges were spot-checked and resolve correctly, including Steps 1.1, 1.2, 1.3, 2.1, 2.3, 4.3, 5.1, 5.2, 6.1, 6.2, 6.3, 7.1 and the subagent citations at 206-partial Lines 324-400 and 403-connector Lines 189-250.

* PV-08: Standards References use machine-specific absolute paths (minor)
  * Evidence: the plan cites `c:\Users\emknafo\.vscode\extensions\ise-hve-essentials.hve-core-3.2.2\.github\instructions\hve-core\markdown.instructions.md` and the sibling writing-style file. Both exist on the authoring machine.
  * Impact: unresolvable for any other implementer, and version-pinned to `hve-core-3.2.2`.

* PV-09: All other referenced paths exist (informational)
  * Confirmed present: `assets/meetingNotes.md`, `assets/usefulScreenshots.md`, `assets/additionalInfo.md`, `README.md`, and all four subagent research documents under `.copilot-tracking/research/subagents/2026-09-22/`.

### Requirement Traceability

* PV-10: User requirement 2 has an objective but no success criterion and no guardrail (minor)
  * Evidence: "Use meetingNotes instead of transcript then" appears in the plan's User Requirements list. No entry in the plan's Success Criteria section references `meetingNotes.md` or the deprecated transcript, and no step instructs the implementer to exclude transcript-derived material.
  * Impact: the requirement is a negative constraint — it deprecates a source. A plan that names the preferred source but never forbids the deprecated one cannot fail validation if transcript material reappears.

* PV-11: `assets/additionalInfo.md` is cited by no step (minor)
  * Evidence: the file is the one the user named in requirement 1 and appears in both the plan's Context Summary and the details file's Context Reference, but no step's `Context references` block cites it.
  * Impact: the themed customer context and the systemic insight it holds are available to the implementer only if they read outside the step they are executing.

* PV-12: The remaining six user requirements each trace to an objective and a success criterion (informational)
  * Requirement 1 (advise the customer) maps to the plan Overview and the package as a whole; requirements 3 through 7 each have a named success criterion carrying an explicit `Traces to:` clause back to research D-items or scenarios.

### Over-Claiming

* PV-13: Step-level handling of the unverified items is sound (informational)
  * All eleven U-items are carried forward by at least one step: U1-U4 (Step 1.1, Step 6.2), U5 (Step 7.1, and addressed operationally by Step 2.1 and Step 5.1 mitigation 1), U6 (Steps 3.1, 3.2), U7 (Step 1.3), U8 (Step 3.1), U9 (Steps 1.2, 2.2), U10 (Step 1.2), U11 (Step 6.1), and all eleven again in Step 7.1.
  * Step 3.2 explicitly requires the 206 bucket be annotated unverified inline. Step 1.2 requires ruled-out hypotheses be retained with their disproving citation rather than deleted. Step 4.3 requires every alert threshold be labelled an engineering recommendation. Step 7.1 requires the inferred-versus-documented distinction be preserved.
  * The one exception is the summary wording recorded as DD-05.

### Re-Validation Findings (Pass 2)

Findings from the focused re-validation run after the first remediation round. Scope limited to PV-01, PV-02, PV-03, PV-04, PV-07, DR-05, the 29 `Details:` line ranges, and edit-induced regressions.

* PV-14: Step 3.1's two research citations still resolve to the wrong content after the PV-07 remediation (major)
  * Evidence: Step 3.1 cites research Lines 347-358 as "the dependency discovery query". Lines 347-349 are the tail and closing fence of `Q8d-Apim206SemanticPartialCapture` — the 206 partial-capture query that belongs to Step 3.3 — and the range stops at line 358, truncating the discovery query before its `by type, name, target` clause (359), its `| order by Calls desc` (360), and its closing fence (361). Step 3.1 also cites Lines 346-346 as "the span-shape mismatch warning"; line 346 is the `| summarize Count = count(), Reasons = ...` line inside the same Q8d query. The span-shape mismatch warning is the prose paragraph at line 351.
  * Impact: the one citation PV-07 was raised to fix is the one citation that remains wrong in both directions — it opens inside another step's query and closes before the query it names is complete. The corrected ranges are Lines 353-361 for the discovery query and Line 351 for the span-shape warning.

* PV-15: The PV-02 terminology-anchor fix is incoherent — Step 1.3 carries no anchor and Step 1.1 names the wrong sibling (major)
  * Evidence: Step 5.2's anchor paragraph reads "the same anchor Steps 1.1 and 1.3 use". Step 1.1's anchor paragraph reads "Steps 1.2 and 5.2 draw from the same anchor". Step 1.3 (details Lines 110-143) contains no terminology anchor paragraph at all.
  * Impact: PV-02 was closed by replacing an ordering dependency with a shared anchor, but the anchor is not actually shared with Step 1.3 — the step whose output Step 5.2's own success criterion names ("Terminology matches `docs/copilot-studio-fanout.md`"). The removed dependency is therefore no longer backstopped by anything for the specific pairing it was written to protect. Step 1.1's reference to Step 1.2 is also a factual error: Step 1.2 is the 403 triage document, which shares no fan-out vocabulary.
  * Recommendation: add the anchor paragraph to Step 1.3, and correct Step 1.1's list to name Steps 1.3 and 5.2.

* PV-16: The PV-04 lint rescope drops one of Phase 1's own deliverables (minor)
  * Evidence: Step 1.4 runs `npx --yes markdownlint-cli2 "docs/rca-206-semantic-concurrency.md" "docs/rca-403-connector-triage.md"`. Phase 1 creates three files; `docs/copilot-studio-fanout.md` from Step 1.3 is not linted.
  * Impact: the disjointness objective of PV-04 is met — Step 1.4 and Step 5.3 now cover non-overlapping sets — but Phase 1's gate no longer covers Phase 1's full output. The file is caught only by the Phase 7 full-tree run, which is after every dependent phase has consumed it.

* PV-17: Two corrected research ranges truncate the query block they cite (minor)
  * Evidence: Step 3.3 cites Lines 334-345 as "the 206 partial-reason capture query"; the query runs to line 349. Step 3.3 also cites Lines 312-332 as "the 403 attribution query and the `ResponseCode` versus `BackendResponseCode` explanation"; the query ends at 333 and the explanation is at line 336 — outside that range, though incidentally recovered by the adjacent 334-345 citation. Step 4.2 cites Lines 276-358 as "the five source queries"; the fifth query ends at 361.
  * Impact: recoverable — an implementer reading to the end of a range lands mid-query and will read on — but each range stops short of the content it names. Corrected ranges: 334-349, 312-336, and 276-361.
  * Note: Step 3.2 (Lines 276-291, 293-310) and Step 4.3 (Lines 360-373) resolve correctly. Step 3.2's second range omits only the closing fence at 311; Step 4.3's range opens three lines inside the preceding query but contains the full alerting table (365-372) and the threshold caveat (363).

* PV-18: Step 3.4 declares an authoring dependency inside a phase marked `parallelizable: true` (minor)
  * Evidence: Phase 3 is `parallelizable: true` and its preamble now states that dependencies naming a diagnostic setting are runtime prerequisites. Step 3.4 declares `Dependencies: Steps 3.1 through 3.3 complete` — an authoring gate, not a runtime one, and it is not split into `Authoring:` / `Runtime:` lines the way Steps 3.1 through 3.3 now are.
  * Impact: surfaced by the PV-03 fix rather than introduced by it. Under the newly explicit definition the marker now reads as a claim Step 3.4 contradicts. The index cannot be written before the queries it indexes exist.
  * Recommendation: state Step 3.4 as sequential-last within the phase, or split its `Dependencies` in the same `Authoring:` form as its siblings.

* PV-19: The DD-05 rewording left a dangling predicate in the plan's success criterion (informational)
  * Evidence: "The leading 206 hypothesis is stated quantitatively — 6 in-flight semantic slots ... versus the 7 concurrent requests the agent issues per turn — is defensible to a Microsoft support engineer, and is labelled as ...". The conjunction before the second predicate was lost when "The 206 root cause is stated ... and is defensible" was rewritten.
  * Impact: editorial only; the criterion's three requirements remain individually legible.

* PV-20: Phase 4's sequencing rationale appears in both files; Phase 5's appears only in the plan (informational)
  * Evidence: the plan's Phase 5 heading carries a preamble explaining the shared-anchor and per-file-lint arrangement. The details file's Phase 5 has no corresponding preamble, unlike Phase 3 and Phase 4, which now carry theirs in both files.
  * Impact: an implementer working from the details file alone sees Step 5.2's `Dependencies: None` and the anchor paragraph, but not the phase-level statement of why Phase 5 is safe alongside Phase 1.

## Validation Resolutions

Actions taken after the first `Plan Validator` pass. Findings are retained above unedited; this section records the disposition of each.

### Clarifying questions answered

* Q1 — marker semantics: `parallelizable` means **safe to author concurrently in this repository**. Customer-environment prerequisites are runtime concerns and are now labelled as such. The definition is stated at the top of the plan's Implementation Checklist and repeated in the details file's Phase 3 preamble.
* Q2 — DR-05 intent: Step 1.1 **is** intended to answer the residual "in large part" question. Confining `sessionId` to the mitigations document was an oversight, not a deliberate deferral.
* Q3 — Standards References: authoring-time only. They do not ship with the customer package. The absolute machine paths have been replaced with repository-relative paths that resolve through the hve-core fallback rule.

### Dispositions

| Finding | Severity | Disposition |
| --- | --- | --- |
| PV-01 | Major | Fixed. Phase 4 is now `parallelizable: false` in both the plan and the details file, with the Phase 3 content dependency stated inline. Step 4.1's independence is noted so it can be pulled forward. |
| PV-02 | Major | Fixed by removing the dependency rather than serializing. Steps 1.1, 1.3, and 5.2 now share a terminology anchor at research Lines 6-14; Step 5.2's `Dependencies` records that consistency is maintained through the anchor, not through ordering. Phase 5 remains parallel. |
| PV-03 | Major | Fixed. The `parallelizable` definition is stated explicitly, and Steps 3.1, 3.2, 3.3 now split `Dependencies` into `Authoring:` and `Runtime:` lines. |
| DR-05 | Major | Fixed. Step 1.1 gains a content requirement covering the residual, citing D10 (`sessionId` replica pinning) and D9 (semantic free plan exhaustion), both labelled inferred; a matching success criterion; and a research citation at Lines 180-187. A corresponding plan-level success criterion was added. |
| PV-07 | Minor | Fixed. Step 3.1 now cites Lines 347-358 and 346; Step 3.2 cites 276-291 and 293-310; Step 3.3 cites 312-332 and 334-345; Step 4.2 cites 276-358; Step 4.3 cites 360-373. |
| PV-04 | Minor | Fixed. Step 1.4 and Step 5.3 now lint their own named files instead of `docs/**/*.md`. Full-tree linting remains in Phase 7. |
| DR-06 | Minor | Fixed. Step 4.3 now requires the connector 403 rule scope its denominator to Copilot Studio connector dependencies (`type == "Connector"`, `shared_azureaisearch` target), with the shared-component rationale stated. |
| PV-10 | Minor | Fixed. A plan success criterion now forbids citing `assets/transcript.md`, and Step 7.3 adds a verification check for it. |
| DD-05 | Minor | Fixed. The plan success criterion now reads "the leading 206 hypothesis", requires it be labelled the strongest supported explanation rather than a confirmed cause, and traces to U1 alongside D1 and D2. |
| DR-07 | Minor | Fixed. Step 2.3 now covers the Copilot Studio "Log conversation details" toggle, with instructions to emit portal steps where no programmatic path exists. |
| PV-11 | Minor | Fixed. Step 7.2 now cites `assets/additionalInfo.md` alongside `meetingNotes.md` and `usefulScreenshots.md` as source evidence in the package index. |
| PV-08 | Minor | Fixed per Q3. Repository-relative paths, no version pin. |
| PV-05, PV-06, PV-09, PV-12, PV-13 | Informational | No action required. PV-06's heading line numbers are superseded by the post-edit ranges now in the plan file. |

### Pass 2 dispositions

Pass 1 dispositions above are retained as the record of what was attempted. PV-14 and PV-15 carry the correction forward; the Pass 1 rows for PV-07 and PV-02 should be read as partial.

| Finding | Severity | Disposition |
| --- | --- | --- |
| PV-14 | Major | Fixed. Step 3.1 now cites research Lines 353-361 for the discovery query and Line 351 for the span-shape warning. |
| PV-15 | Major | Fixed. Step 1.3 now carries its own terminology anchor paragraph plus a matching success criterion; Step 1.1's anchor now names Steps 1.2, 1.3, and 5.2. The anchor is shared with the step whose output Step 5.2 must match. |
| PV-16 | Minor | Fixed. Step 1.4 now lints all three Phase 1 documents; Step 5.3 lints only its two. The sets remain disjoint. |
| PV-17 | Minor | Fixed. Step 3.3 now cites 312-336 and 338-349; Step 4.2 cites 276-361. |
| PV-18 | Minor | Fixed. Step 3.4's dependency is now split into `Authoring:` and `Runtime:` and labelled an intra-phase gate that does not affect cross-phase parallelism. |
| PV-19 | Informational | Fixed. The DD-05 success criterion now reads "is presented as the strongest supported explanation". |
| PV-20 | Informational | Fixed. The details file now carries a Phase 5 preamble matching the plan file, as Phases 3 and 4 do. |

All 29 `Details:` line ranges were re-derived from the post-edit details headings at 23, 72, 110, 147, 159, 200, 239, 278, 292, 322, 353, 386, 403, 415, 449, 483, 525, 538, 580, 633, 645, 680, 726, 757, 767, 796, 820, 830, 834.

## Implementation Paths Considered

### Selected: Advisory package delivered as repository artifacts

* Approach: build the deliverable as documents, runnable PowerShell diagnostics, a `.kql` query library, a workbook, alert definitions, and CSS ticket drafts inside this repository.
* Rationale: the workspace contains only `README.md` and `assets/`, which establishes it as an engagement repository rather than an application codebase. The customer needs artifacts they can run and submit, not a narrative. Packaging this way also keeps every claim traceable to the research document and reviewable before it reaches the customer.
* Evidence: .copilot-tracking/research/2026-09-22/ai-search-scaling-206-403-rca-research.md (Lines 15-23) — the six task implementation requests map directly onto documents, observability assets, and a ticket package.

### IP-01: Single consolidated advisory document

* Approach: deliver one long markdown document covering RCA, observability, mitigations, architecture, and escalation.
* Trade-offs: fastest to produce and easiest to read end to end. But scripts and KQL embedded in prose are not runnable, the ticket drafts cannot be submitted without extraction, and the document becomes unmaintainable as customer answers arrive and sections need revision.
* Rejection rationale: the user explicitly asked for out-of-box workbooks, dashboards, and KQL the customer can use. Those are artifacts, not paragraphs.

### IP-02: Direct remediation against the customer's Azure environment

* Approach: run the diagnostics and apply the mitigations directly against the customer's subscription during the engagement.
* Trade-offs: fastest path to a resolved symptom. But it requires credentials this workspace does not have, replica scaling cannot be cancelled once started, and several mitigations touch a production Search service and an APIM instance in the customer's request path.
* Rejection rationale: operationally unsafe without the customer in the loop, and the eleven unverified items mean several actions could be applied against incorrect assumptions. The plan delivers read-only diagnostics plus an opt-in enablement script with `-WhatIf` instead.

### IP-03: Lead with index consolidation as the primary deliverable

* Approach: treat the seven-to-one index consolidation as the headline and build the package around that migration.
* Trade-offs: addresses the true architectural cause and yields the largest capacity reduction. But it is a high-effort change requiring re-indexing and re-permissioning, and it cannot begin until customer question 1 (are the indexes wired as Knowledge sources or as Tools?) is answered.
* Rejection rationale: premature. The headline answer must be the RCA the customer asked for; consolidation is the recommendation that follows from it. Leading with a migration would also strand the 403 workstream, which consolidation does nothing to resolve.

### IP-04: Defer all deliverables until the customer answers the thirteen questions

* Approach: send the question list first, wait for answers, then plan the package against confirmed facts.
* Trade-offs: every conclusion would be verified rather than inferred, and nothing would need revision later.
* Rejection rationale: the 206 root cause is already documented and quantitative — it does not depend on any of the thirteen answers. Withholding a defensible RCA while waiting for data that would only refine it leaves the customer without the explanation they asked for. The plan ships the RCA now and labels the inferred parts.

## Suggested Follow-On Work

Items identified during planning that fall outside current scope.

* WI-01: Consolidated index design and migration plan — schema, `businessUnit` field, security trimming model, re-index strategy, and cutover sequence (high)
  * Source: DR-02, research Scenario 1
  * Dependency: customer accepts the consolidation recommendation; customer question 1 answered

* WI-02: Knowledge sources to Tools conversion playbook — tool descriptions, citation-rendering replacement, and regression test set (high)
  * Source: research D7, Scenario 1 option 2
  * Dependency: confirmation of how the seven indexes are currently wired

* WI-03: Ingestion pipeline review for query-hour contention — indexer scheduling, upsert batching, and the weekly cleanup window (medium)
  * Source: DR-01, research Scenario 2 mitigation 6
  * Dependency: none; can proceed once the observability baseline exists

* WI-04: Load and capacity model for projected growth — concurrent-turn forecasting against the search-unit sizing formula (medium)
  * Source: research Scenario 2 mitigation 2; customer growth expectation in assets/meetingNotes.md
  * Dependency: two weeks of telemetry baseline from Phase 3

* WI-05: Custom connector or APIM `set-body` implementation to expose `semanticErrorHandling` and `semanticMaxWaitInMilliseconds` (medium)
  * Source: research D5, Scenario 2 mitigation 8
  * Dependency: confirmation that the built-in connector is in fact forcing `partial`

* WI-06: Power BI reporting alignment with the new Azure Monitor assets (low)
  * Source: DR-04
  * Dependency: Phase 4 workbook accepted by the customer

* WI-07: Retrospective on monitoring blind spots — 206 was invisible to every dashboard and alert because it is a 2xx counted by no metric (low)
  * Source: research D4
  * Dependency: Phase 4 alert rules deployed
