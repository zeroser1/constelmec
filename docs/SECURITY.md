# Security boundaries (implementation plan)

The UI is a **demo only**. Its role switch is not authorization. Never use it to decide access to real customer data.

## Required before production
- Supabase Auth with admin MFA, invite-only enrollment and session management.
- Per-company RLS for all records, realtime subscriptions and private storage objects.
- Gate QR is a random opaque identifier, not an access token.
- Technical writes only via authenticated, authorized transactional RPCs. Never let clients choose audit actor or overwrite immutable inspections.
- Add append-only corrections and safe-state transitions; closure of visit must never automatically restore a gate to operational.
- Offline events need UUID idempotency keys, occurred_at and synced_at; resolve conflicts server-side.
- Reports are immutable/versioned and accessible only with authorized signed links.
- Test customer A vs customer B, technician permissions, anonymous access, forged company IDs, stale sessions and storage policies.
- Separate DB backups from Drive archive; test restores.
- Do not put Supabase service-role key or other secrets in browser environment variables.

## Current migration
The first SQL migration provides tenant-linked tables, initial RLS read policies and blocks direct technical writes. It is a **starting schema**, not a complete production authorization system. Do not apply it to production without security review and migration tests.
