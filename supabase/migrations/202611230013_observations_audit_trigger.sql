-- Migration 013: audit trigger for customer_observations.
--
-- Context (GAP-SEC-02, Media prioridad):
--   Direct INSERTs into customer_observations leave no entry in audit_events.
--   If a technician or customer abuses the observation form, there is no trail
--   to identify who inserted what or when.
--
-- Fix:
--   AFTER INSERT trigger on customer_observations that inserts into audit_events.
--   Payload includes observation_id and gate_id — NOT body (text libre, PII risk).
--
-- Atomicity decision:
--   This is an AFTER trigger.  If the trigger raises an exception, the original
--   INSERT is also rolled back (the transaction is atomic).  This is intentional:
--   an observation without an audit record is undesirable.  No exception handling
--   is added to suppress audit failures — a failed audit means a failed insert.
--
-- Idempotency: gen_random_uuid() for idempotency_key.  Collision probability is
--   negligible (2^122); no retry mechanism is needed.
--
-- NOT safe to apply to production until ChatGPT gives explicit approval for the
-- full 011–015 set.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Trigger function in app_private (excluded from Data API, not queryable)
-- ══════════════════════════════════════════════════════════════════════════════

create or replace function app_private.observations_audit_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.audit_events (
    company_id,
    gate_id,
    actor_user_id,
    event_type,
    event_payload,
    idempotency_key
  ) values (
    new.company_id,
    new.gate_id,
    new.author_user_id,
    'observation_created',
    jsonb_build_object(
      'observation_id', new.id
      -- gate_id stored in the gate_id column above; not duplicated in payload
      -- body excluded: text libre may contain PII — see GAP-SEC-02
    ),
    gen_random_uuid()
  );
  return new;
end;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. AFTER INSERT trigger on customer_observations
-- ══════════════════════════════════════════════════════════════════════════════
-- Fires after each INSERT row.  If the audit INSERT fails (e.g. constraint
-- violation), the entire transaction including the original observation INSERT
-- is rolled back.

drop trigger if exists observations_audit on public.customer_observations;

create trigger observations_audit
  after insert on public.customer_observations
  for each row
  execute function app_private.observations_audit_trigger();

-- ══════════════════════════════════════════════════════════════════════════════
-- Required regression tests (run in staging, not production):
-- ══════════════════════════════════════════════════════════════════════════════
--   1. INSERT into customer_observations → audit_events receives row with
--      event_type='observation_created', gate_id = gate_id of observation
--   2. event_payload has observation_id but NOT body
--   3. Simulate audit INSERT failure (e.g. duplicate idempotency_key) →
--      customer_observations INSERT also rolls back
--   4. The existing observations_no_update trigger (mig_001) still fires:
--      UPDATE or DELETE on customer_observations still raises an exception
