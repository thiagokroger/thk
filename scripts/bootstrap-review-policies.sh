#!/usr/bin/env bash
# Bootstrap the `review` block of <targetRepo>/.thk/policies.json
# with thk's defaults if missing. Never overwrites existing values — only
# fills the gaps.
#
# Usage: bootstrap-review-policies.sh <targetRepo>
#
# Defaults written:
#   review.meeting_decision           = "auto"   # "auto" | "always" | "never"
#   review.counselor_on_simple_path   = true     # run Counselor at Step 6a even on no-meeting flow
#   review.counselor_on_meeting_path  = true     # Counselor closes Round 2 of every meeting
#
# Same merge semantics as _capture-planetscale and _run-verification:
# - if policies.json is missing → create with _meta + review block
# - if policies.json exists but lacks `review` → merge the block in
# - if review.* keys exist → leave each one alone (per-key idempotency)

set -euo pipefail

target_repo="${1:?targetRepo required}"
policies_dir="$target_repo/.thk"
policies="$policies_dir/policies.json"

mkdir -p "$policies_dir"

if [ ! -f "$policies" ]; then
  cat > "$policies" <<'EOF'
{
  "_meta": {
    "generatedBy": "_scaffold-session/bootstrap-review-policies",
    "generatedAt": "__BOOTSTRAP_TS__",
    "note": "Edit freely. thk reads this verbatim on subsequent runs. Hand-edited values are NOT overwritten — auto-bootstrap only fills missing keys."
  },
  "review": {
    "meeting_decision": "auto",
    "counselor_on_simple_path": true,
    "counselor_on_meeting_path": true
  }
}
EOF
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # macOS sed needs '' after -i; Linux sed doesn't. Detect and branch.
  if sed --version >/dev/null 2>&1; then
    sed -i "s/__BOOTSTRAP_TS__/$ts/" "$policies"
  else
    sed -i '' "s/__BOOTSTRAP_TS__/$ts/" "$policies"
  fi
  echo "bootstrap-review-policies: created $policies with default review block." >&2
  exit 0
fi

# policies.json already exists — merge missing review.* keys without
# clobbering hand-edited values.
node - <<NODE "$policies"
const fs = require("node:fs");
const path = process.argv[2];
const raw = fs.readFileSync(path, "utf8");
let cfg;
try {
  cfg = JSON.parse(raw);
} catch (e) {
  console.error(\`bootstrap-review-policies: \${path} is not valid JSON; refusing to touch.\`);
  process.exit(1);
}

const desired = {
  meeting_decision: "auto",
  counselor_on_simple_path: true,
  counselor_on_meeting_path: true,
};

cfg.review = cfg.review || {};
let changed = false;
for (const [k, v] of Object.entries(desired)) {
  if (!Object.prototype.hasOwnProperty.call(cfg.review, k)) {
    cfg.review[k] = v;
    changed = true;
  }
}

if (!changed) {
  console.error(\`bootstrap-review-policies: \${path} already has review.* — no change.\`);
  process.exit(0);
}

cfg._meta = cfg._meta || {};
cfg._meta.lastBootstrap = new Date().toISOString();
cfg._meta.lastBootstrapBy = "_scaffold-session/bootstrap-review-policies";

fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n", "utf8");
console.error(\`bootstrap-review-policies: merged missing review.* keys into \${path}. Review and commit.\`);
NODE
