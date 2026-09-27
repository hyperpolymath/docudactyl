# Docudactyl agent instructions

Read `0-AI-MANIFEST.a2ml` and `.machine_readable/6a2/AGENTIC.a2ml` first.
Repository-specific constraints take precedence over generic scaffolding.

## Sources and scope

The estate standards source is `hyperpolymath/standards`; the operational
scaffold is `hyperpolymath/rsr-template-repo`. Do not confuse a draft,
historical checklist, or generated status report with ratified policy.
The 2026-09-26 review and source revisions are recorded in
`docs/compliance/2026-09-26-repository-audit.adoc`.

## Actual implementation languages

- Chapel: HPC orchestration and distributed processing.
- Zig: native FFI and parser integrations.
- Idris2: ABI types and proofs.
- OCaml: offline Scheme transformation; Ada: standalone TUI.
- Julia: existing legacy code, not the HPC hot path.
- Bash: minimal CI/build automation. Guile Scheme/A2ML: existing metadata.
- Agda: deferred distributed-invariant formalisation, not an existing proof.

Do not migrate these components into an unrelated preferred language.
No new Python, Go, TypeScript, ReScript, Nix, or Deno code/configuration.
If JavaScript tooling is needed, use plain JavaScript with Bun and a pinned
manifest/lockfile; do not introduce AffineScript as an invented requirement.
The current estate tooling order makes npm a last resort, not a blanket ban.
Use Guix rather than Nix, and Podman/Containerfile rather than Docker.

## Required behaviour

1. Fix soundness/security holes before features or performance work.
2. Run the actual tools. Missing prerequisites and skipped checks are not green.
3. Never bypass a gate, invent evidence, or call a model of assumptions a proof
   of this implementation. Read the audit before making production claims.
4. Keep state under `.machine_readable/`; do not move canonical files blindly
   when upstream directory layouts differ.
5. Preserve existing licences. No automated relicensing, licence sweeps, or
   changes to third-party notices. Escalate conflicting notices to the owner.
6. Never commit secrets; pin remote dependencies and Actions; use HTTPS.
7. Run the relevant checks in `CONTRIBUTING.adoc`, including regression tests
   and `git diff --check`, and report exact scope and blockers.
8. Use signed commits for estate submissions. Publishing and external service
   operations require deliberate authorisation; local edits are not deployment.
