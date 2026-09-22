---
title: Workbooks
description: Which Azure Monitor workbooks ship out of the box for this architecture, which one does not exist and had to be authored here, and how to import each of them.
author: Microsoft
ms.date: 2026-09-22
ms.topic: how-to
keywords:
  - azure monitor workbooks
  - azure ai search
  - copilot studio
  - api management
  - application insights
estimated_reading_time: 7
---

Three of the four tiers in this request path already have a Microsoft-published workbook. One does not.

Copilot Studio and API Management both ship importable workbook templates, and the Power Platform query pack supplies additional Copilot Studio queries. Azure AI Search ships neither a workbook template nor a dedicated Log Analytics table, which is why [ai-search-semantic-capacity.workbook.json](ai-search-semantic-capacity.workbook.json) exists in this folder. Import the published ones first and author nothing that already exists.

## What exists and what does not

| Asset | Status | Where it lives |
|---|---|---|
| Copilot Studio Dashboard workbook | Exists, importable | [microsoft/Application-Insights-Workbooks, Copilot Studio](https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Copilot%20Studio) |
| API Management Analytics workbook | Exists, importable | [microsoft/Application-Insights-Workbooks, Azure API Management/Analytics](https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20API%20Management/Analytics) |
| Power Platform KQL query pack | Exists, copy queries | [microsoft/AzureMonitorCommunity, Power Platform](https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services/Power%20Platform) |
| Application Insights "Agents (preview)" blades | Exists, portal-only | Azure portal, no template to import |
| Azure AI Search workbook template | Does not exist | Authored here as [ai-search-semantic-capacity.workbook.json](ai-search-semantic-capacity.workbook.json) |
| Dedicated Azure AI Search log table | Does not exist | Search resource logs land in `AzureDiagnostics` |

Two of those rows are findings rather than inventory, and both are worth stating plainly so nobody spends an afternoon hunting for an asset that was never published.

No Azure AI Search workbook template ships in the Search blade gallery, and no Search folder exists in either Microsoft gallery repository. Text searches across `microsoft/Application-Insights-Workbooks` for `Microsoft.Search/searchServices` and for a `Workbooks/Search` path both return nothing.
The Workbooks blade is present on the Search resource because it is present on every Azure resource, but it offers only generic empty templates. The Search monitoring documentation points at workbooks, Power BI, and Grafana as things you build rather than things you import.

Search also has no dedicated Log Analytics table. Its resource logs land in the shared `AzureDiagnostics` table alongside every other provider, and the column names carry type suffixes that differ from the logical names in the data reference. Write `resultSignature_d`, not `ResultSignature`. Every Search query in this package filters on `ResourceProvider == "MICROSOFT.SEARCH"` for that reason.

## Before importing anything

Workbooks render whatever the telemetry contains. When a diagnostic setting is missing, the tiles that depend on it return no rows and look indistinguishable from a healthy system.

Run [scripts/Enable-DiagnosticSettings.ps1](../scripts/Enable-DiagnosticSettings.ps1) first. It enables the Search diagnostic setting with `OperationLogs` and `AllMetrics`, the APIM `GatewayLogs` category, and it performs the two pre-flight checks that block this entire plan:

* APIM on the Consumption tier supports no resource logs at all, which removes every APIM tile and every APIM alert.
* An Application Insights component with `DisableLocalAuth` set makes the Copilot Studio telemetry export fail silently, which removes every connector tile.

Then run the two discovery queries in [kql/README.md](../kql/README.md) before trusting any dashboard built on the connector spans. The span shape observed in this environment matches neither documented Copilot Studio schema, so a dashboard built on the wrong naming convention renders empty and reads as healthy.

## Copilot Studio Dashboard

This is the closest published asset to what was asked for. It queries Application Insights through Azure Workbooks and surfaces total conversations, latency, exceptions, tool usage, and topic analytics in one view.

It ships in the gallery, so no file import is needed:

1. Open the Application Insights component that receives the Copilot Studio telemetry export.
2. Select **Monitoring**, then **Workbooks**.
3. Open **Copilot Studio Dashboard** from the gallery.

The workbook opens editable. Adding a tile that tracks a custom attribute the built-in view does not show is supported and documented, which makes this a reasonable host for the Search tiles if you would rather run one workbook than two. Save it under a new name before editing so the gallery original stays intact. Sharing it requires at least Reader on the connected Application Insights resource.

Prerequisite: Copilot Studio telemetry export to Application Insights, with "Log conversation details" enabled if you want tool arguments and results.

## API Management Analytics

Gateway analytics for the APIM instance in front of Search, including a language models tab.

To import from the gallery repository:

1. Download `Workbooks/Azure API Management/Analytics` from [the gallery repository](https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Azure%20API%20Management/Analytics).
2. Open the APIM instance in the Azure portal.
3. Select **Monitoring**, then **Workbooks**, then **New**.
4. Open the **Advanced Editor** using the `</>` toolbar button.
5. Replace the contents with the downloaded JSON and select **Apply**.
6. Select **Save**, name the workbook, and choose a resource group and location.

Prerequisite: the `GatewayLogs` diagnostic category enabled on a non-Consumption APIM tier.

## Power Platform query pack

The [Power Platform folder in AzureMonitorCommunity](https://github.com/microsoft/AzureMonitorCommunity/tree/master/Azure%20Services/Power%20Platform) holds standalone KQL rather than a workbook. Paste the queries into the Logs blade, or lift one into a new workbook query step when a Copilot Studio signal is needed that the shipped dashboard does not cover.

## Application Insights Agents (preview)

The Agents blades, including the Tools view, exist only in the portal. There is no template and nothing to import. Open the Application Insights component and look under the Agents (preview) section. Worth demonstrating alongside the Copilot Studio Dashboard because it surfaces per-tool failure detail that the dashboard aggregates away.

## The authored Azure AI Search workbook

[ai-search-semantic-capacity.workbook.json](ai-search-semantic-capacity.workbook.json) fills the gap. It carries five tiles, each one lifted verbatim from the corresponding file in [kql](../kql/README.md) so the workbook and the query library cannot drift:

| Tile | Source query | Answers |
|---|---|---|
| Fan-out ratio over time | [10-fan-out-ratio.kql](../kql/10-fan-out-ratio.kql) | How many Search queries one user turn really produces |
| Search results by HTTP status | [11-search-by-http-result-code.kql](../kql/11-search-by-http-result-code.kql) | Whether 206, 403, 429, and 503 appear Search-side, kept separate |
| Semantic capacity headroom | [12-semantic-capacity-headroom.kql](../kql/12-semantic-capacity-headroom.kql) | Whether concurrent semantic load reaches the in-flight ceiling for the tier |
| 403 attribution, APIM against backend | [20-apim-403-triage.kql](../kql/20-apim-403-triage.kql) | Whether APIM policy or Azure AI Search originated each 403 |
| Design mode against published channel | [23-design-mode-vs-published.kql](../kql/23-design-mode-vs-published.kql) | Whether the 403s hit production users or only the authoring canvas |

To import it:

1. Open Azure Monitor, or any resource with a Workbooks blade.
2. Select **Workbooks**, then **New**.
3. Open the **Advanced Editor** using the `</>` toolbar button.
4. Paste the full contents of the JSON file and select **Apply**.
5. Select **Save**, then set the parameters at the top of the workbook.

Five parameters need values, and nothing in the file hard-codes a subscription, a resource group, or a resource name:

| Parameter | What to set it to |
|---|---|
| `TimeRange` | The investigation window. Start at 24 hours |
| `Workspace` | The Log Analytics workspace receiving the Search and APIM diagnostic settings |
| `SearchService` | The Azure AI Search service resource |
| `ApimService` | The API Management instance in front of Search |
| `AppInsights` | The Application Insights component receiving the Copilot Studio export |

The capacity tile also carries three tier constants set as workbook parameters rather than buried in query text: `SearchUnits`, `MaxConcurrentPerSu`, and `MaxQueuePerSu`. Set them from the live service before reading the headroom chart. The defaults describe Basic at one search unit, which is where this environment started. On S1 the concurrency value becomes 3 and the queue value becomes 6.

> [!IMPORTANT]
> The workbook reports a headroom estimate, not a measurement. Concurrency is derived by applying Little's law to throughput and mean latency, because Azure AI Search publishes no queue-depth counter. Read it as an indicator of pressure.
> The two caveats carried in [12-semantic-capacity-headroom.kql](../kql/12-semantic-capacity-headroom.kql), including the conflict between two Microsoft pages on whether the semantic limit is per search unit or per replica, apply to the tile exactly as they apply to the query.

## Keeping the workbook and the query library in step

Each tile in the authored workbook carries a comment naming its source file. When a query changes in [kql](../kql/README.md), change the tile too, and vice versa. Two copies of a diagnostic that disagree are worse than one, because the disagreement usually surfaces during an incident.

## Related material

* [kql/README.md](../kql/README.md) for the nine queries, their run order, and their prerequisites
* [alerts/alert-rules.md](../alerts/alert-rules.md) for the alert rules built on the same queries
* [docs/rca-206-semantic-concurrency.md](../docs/rca-206-semantic-concurrency.md) for what the capacity tile is evidence for
* [docs/rca-403-connector-triage.md](../docs/rca-403-connector-triage.md) for what the two 403 tiles are evidence for
* [Azure Workbooks overview](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview)
* [Create or edit an Azure Workbook](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook)
* [Workbook parameters](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-parameters)
