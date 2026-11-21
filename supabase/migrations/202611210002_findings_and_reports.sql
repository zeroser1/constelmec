-- Constelmec: append-only corrective events, technical findings and report metadata.
-- Requires 202611210001_initial.sql. Do not run on production before RLS tests.
create type public.finding_severity as enum ('low','medium','high','critical');
create type public.finding_status as enum ('open','resolved','dismissed');
create table public.findings(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  gate_id uuid not null,
  visit_id uuid,
  severity public.finding_severity not null,
  title text not null check(length(trim(title)) between 2 and 250),
  description text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique(id,company_id),
  foreign key(gate_id,company_id) references public.gates(id,company_id),
  foreign key(visit_id,company_id) references public.visits(id,company_id)
);
create table public.finding_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  finding_id uuid not null,
  actor_user_id uuid not null references auth.users(id),
  event_type text not null check(event_type in ('created','commented','resolved','reopened','dismissed')),
  reason text not null check(length(trim(reason)) between 1 and 2000),
  created_at timestamptz not null default now(),
  idempotency_key uuid not null,
  unique(company_id,idempotency_key),
  foreign key(finding_id,company_id) references public.findings(id,company_id)
);
create table public.inspection_corrections(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  inspection_control_id uuid not null references public.inspection_controls(id),
  actor_user_id uuid not null references auth.users(id),
  corrected_result public.control_result not null,
  reason text not null check(length(trim(reason)) between 3 and 2000),
  created_at timestamptz not null default now(),
  idempotency_key uuid not null,
  unique(company_id,idempotency_key)
);
create table public.report_versions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  visit_id uuid not null,
  version integer not null check(version > 0),
  private_storage_path text not null,
  content_sha256 text not null check(content_sha256 ~ '^[0-9a-f]{64}$'),
  generated_at timestamptz not null default now(),
  unique(visit_id,version),
  foreign key(visit_id,company_id) references public.visits(id,company_id)
);
create index on public.findings(company_id,gate_id,created_at desc);
create index on public.finding_events(company_id,finding_id,created_at desc);
create index on public.report_versions(company_id,visit_id);
alter table public.findings enable row level security;
alter table public.finding_events enable row level security;
alter table public.inspection_corrections enable row level security;
alter table public.report_versions enable row level security;
create policy findings_read on public.findings for select to authenticated using(app_private.has_membership(company_id));
create policy finding_events_read on public.finding_events for select to authenticated using(app_private.has_membership(company_id));
create policy corrections_read on public.inspection_corrections for select to authenticated using(app_private.has_membership(company_id));
create policy reports_read on public.report_versions for select to authenticated using(app_private.has_membership(company_id));
create trigger findings_no_update before update or delete on public.findings for each row execute function app_private.audit_immutable();
create trigger finding_events_no_update before update or delete on public.finding_events for each row execute function app_private.audit_immutable();
create trigger corrections_no_update before update or delete on public.inspection_corrections for each row execute function app_private.audit_immutable();
create trigger reports_no_update before update or delete on public.report_versions for each row execute function app_private.audit_immutable();
revoke insert,update,delete on public.findings,public.finding_events,public.inspection_corrections,public.report_versions from anon,authenticated;
-- TODO: RPCs must validate cross-company inspection_control_id and all actor IDs server-side.
-- Report storage must be private; report_versions does not grant object access by itself.
