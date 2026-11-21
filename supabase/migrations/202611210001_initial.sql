-- Constelmec: initial tenant-isolated domain model. Review and test before applying to production.
create extension if not exists pgcrypto;
create schema if not exists app_private;
create type public.member_role as enum ('admin','technician','customer');
create type public.gate_operational_state as enum ('operational','observations','out_of_service');
create type public.visit_status as enum ('draft','in_progress','closed');
create type public.control_result as enum ('ok','fault','not_applicable','unverifiable');
create table public.companies(id uuid primary key default gen_random_uuid(),name text not null check(length(trim(name)) between 2 and 180),created_at timestamptz not null default now());
create table public.memberships(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,company_id uuid not null references public.companies(id) on delete cascade,role public.member_role not null,active boolean not null default true,created_at timestamptz not null default now(),unique(user_id,company_id));
create table public.facilities(id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id),name text not null,created_at timestamptz not null default now(),unique(id,company_id));
create table public.gates(id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id),facility_id uuid not null,code text not null,description text not null,model text,serial_number text,operational_state public.gate_operational_state not null default 'observations',reference_photo_path text,created_at timestamptz not null default now(),unique(company_id,code),unique(id,company_id),foreign key(facility_id,company_id) references public.facilities(id,company_id));
create table public.visits(id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id),gate_id uuid not null,status public.visit_status not null default 'draft',responsible_user_id uuid not null references auth.users(id),started_at timestamptz,closed_at timestamptz,created_at timestamptz not null default now(),unique(id,company_id),foreign key(gate_id,company_id) references public.gates(id,company_id));
create table public.inspection_controls(id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id),visit_id uuid not null,control_key text not null,control_label text not null,result public.control_result not null,note text,created_at timestamptz not null default now(),foreign key(visit_id,company_id) references public.visits(id,company_id),unique(visit_id,control_key));
create table public.customer_observations(id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id),gate_id uuid not null,author_user_id uuid not null references auth.users(id),body text not null check(length(trim(body)) between 1 and 2000),created_at timestamptz not null default now(),foreign key(gate_id,company_id) references public.gates(id,company_id));
create table public.audit_events(id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id),gate_id uuid,visit_id uuid,actor_user_id uuid not null references auth.users(id),event_type text not null,event_payload jsonb not null default '{}'::jsonb,client_occurred_at timestamptz,recorded_at timestamptz not null default now(),idempotency_key uuid not null,unique(company_id,idempotency_key),foreign key(gate_id,company_id) references public.gates(id,company_id),foreign key(visit_id,company_id) references public.visits(id,company_id));
create index on public.memberships(user_id,company_id) where active;
create index on public.gates(company_id,facility_id);
create index on public.visits(company_id,gate_id,created_at desc);
create index on public.audit_events(company_id,recorded_at desc);
create or replace function app_private.has_membership(p_company uuid,p_roles public.member_role[] default null) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.memberships m where m.company_id=p_company and m.user_id=(select auth.uid()) and m.active and (p_roles is null or m.role=any(p_roles)))$$;
revoke all on function app_private.has_membership(uuid,public.member_role[]) from public;
grant usage on schema app_private to authenticated;
grant execute on function app_private.has_membership(uuid,public.member_role[]) to authenticated;
create or replace function app_private.is_technician(p_company uuid) returns boolean language sql stable security definer set search_path='' as $$select app_private.has_membership(p_company,array['admin','technician']::public.member_role[])$$;
revoke all on function app_private.is_technician(uuid) from public;
grant execute on function app_private.is_technician(uuid) to authenticated;
create or replace function app_private.audit_immutable() returns trigger language plpgsql set search_path='' as $$begin raise exception 'Audit events are append-only'; end$$;
create trigger audit_no_update before update or delete on public.audit_events for each row execute function app_private.audit_immutable();
-- Technical inspection rows and customer observations are immutable: corrections must be separate records.
create trigger controls_no_update before update or delete on public.inspection_controls for each row execute function app_private.audit_immutable();
create trigger observations_no_update before update or delete on public.customer_observations for each row execute function app_private.audit_immutable();
alter table public.companies enable row level security;
alter table public.memberships enable row level security;
alter table public.facilities enable row level security;
alter table public.gates enable row level security;
alter table public.visits enable row level security;
alter table public.inspection_controls enable row level security;
alter table public.customer_observations enable row level security;
alter table public.audit_events enable row level security;
create policy companies_read on public.companies for select to authenticated using(app_private.has_membership(id));
create policy memberships_read on public.memberships for select to authenticated using(user_id=(select auth.uid()));
create policy facilities_read on public.facilities for select to authenticated using(app_private.has_membership(company_id));
create policy gates_read on public.gates for select to authenticated using(app_private.has_membership(company_id));
create policy visits_read on public.visits for select to authenticated using(app_private.has_membership(company_id));
create policy controls_read on public.inspection_controls for select to authenticated using(app_private.has_membership(company_id));
create policy observations_read on public.customer_observations for select to authenticated using(app_private.has_membership(company_id));
create policy audit_read on public.audit_events for select to authenticated using(app_private.has_membership(company_id,array['admin','technician']::public.member_role[]));
create policy observations_insert on public.customer_observations for insert to authenticated with check(author_user_id=(select auth.uid()) and app_private.has_membership(company_id));
-- Explicitly prevent API roles from modifying immutable records; the insert policy is the only client write.
revoke update,delete on public.customer_observations from anon,authenticated;
-- Writes to technical tables and audit_events deliberately disabled for clients.
-- Implement transactional SECURITY DEFINER RPCs with authorization, validation, and idempotency.
revoke insert,update,delete on public.companies,public.memberships,public.facilities,public.gates,public.visits,public.inspection_controls,public.audit_events from anon,authenticated;
-- Membership provisioning must be done via trusted backend with strict authorization.
