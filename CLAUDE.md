# Spore

## janitor (agent memory + structural edits)

- Start sessions with `janitor wake --budget 3000`; for one question,
  `janitor wake --task "<query>" --budget 300` (ceiling: 350).
- Structural edits go through `janitor apply --diff` (dry-run first). Never sed
  structural changes.
- Record durable decisions: `janitor note "<fact>"` (+ `--ptr` span from scan,
  `--commit`; `--confidence low` when unverified). Cap: 280 bytes.
- On `E_NAP_PENDING`, settle via `janitor nap` (the request names the slot; you
  write the summary).
Full guidance ships inside every wake payload (GLOBAL.md). MCP tools:
janitor_wake/scan/apply/note/nap/status.
