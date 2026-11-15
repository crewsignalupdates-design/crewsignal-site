# Merger & Integration Weekly Report Standard

Use `templates/mi-weekly-report.template.html` as the starting point for every new weekly Merger & Integration report.

## Canonical section titles
- Status Summary
- Integration Dashboard
- CrewSignal Watch Points
- Notable Public References
- Related Contract Architecture
- Contract Comparison

## Rules
- Do not copy an old weekly report to create a new one.
- Do not change section IDs, section order, or CSS class names.
- Do not wrap `<li>` items inside `<p>` tags.
- Keep list markup as:
  - `<ul class="cs-report__list">`
  - `<li class="cs-report__list-item">`
- Related Contract Architecture must include:
  - the Contract Architecture library link
  - both carrier contract-analysis links
- Contract Comparison must include the pair-specific comparison link.
- Content may change from week to week.
- Structure should remain canonical.

## Public-copy boundary and release checks

- Show the carrier pair and the reader-facing `Week ending YYYY.MM.DD` date. Do not put internal production microcopy in report bodies, titles, descriptions, ARIA labels, social metadata, or structured data.
- Internal historical-window labels, editorial cutoff timestamps, UTC conversions, research timezones, retrieval logs, approval status, and editor-to-researcher instructions belong in private briefs, source registers, and QA records, not in report HTML. Keep private-review status in the delivery folder and README rather than in candidate public pages.
- Before release, explicitly reject production notes such as `Historical window:`, `Editorial cutoff:`, and `Cutoff:` timestamps. Check the rendered page as well as its HTML and metadata.
- Do not remove substantive event dates, source publication dates, necessary evidentiary qualifications, or timezone information material to the reported facts. Keep bounded findings bounded; removing workflow notes must not strengthen a claim.
- Use the shared `/assets/css/main.css` stylesheet and the standard visible `cs-report__back` link to `/reports/merger-integration/`. Reject embedded research-preview stylesheets and background overrides. Verify the backlink and styling before publication.
