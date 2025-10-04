# Sentinel Content Packs

Managed security content aligned with the automation platform.

- `analytics/` — Scheduled analytics rules (ARM JSON schema).
- `playbooks/` — Logic App templates implementing remediation workflows.
- `workbooks/` — Workbooks for dashboards and reporting.
- `watchlists/` — CSV assets loaded into Sentinel watchlists.
- `policies/` — Automation decision policies consumed by the decision engine.

## Packaging
Use `scripts/package_content.py` to bundle content into versioned artifacts. Each manifest release is tracked in storage and deployed through CI pipelines.
