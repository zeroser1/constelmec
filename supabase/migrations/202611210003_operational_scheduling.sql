-- Operational scheduling and technician directory. Applied to Supabase on 2026-11-21.
create table if not exists public.technician_profiles (
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 user_id uuid references auth.users(id) on delete set null,
 first_name text not null check(length(trim(first_name)) between 1 and 100),
 last_name text not null check(length(trim(last_name)) between 1 and 100),
 work_phone text, work_email text, specialty text,
 driving_authorized boolean not null default false,
 license_expires_on date, active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(id,company_id), unique(company_id,user_id)
);
create table if not exists public.service_orders (
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id),
 facility_id uuid not null, gate_id uuid not null,
 assigned_technician_id uuid,
 service_type text not null check(service_type in ('preventive','corrective','installation','emergency')),
 status text not null default 'scheduled' check(status in ('unassigned','scheduled','in_progress','completed','rescheduled','cancelled')),
 scheduled_start timestamptz not null, scheduled_end timestamptz not null,
 completed_at timestamptz, next_service_at timestamptz, notes text,
 created_at timestamptz not null default now(),
 check(scheduled_end>scheduled_start), unique(id,company_id),
 foreign key(facility_id,company_id) references public.facilities(id,company_id),
 foreign key(gate_id,company_id) references public.gates(id,company_id),
 foreign key(assigned_technician_id,company_id) references public.technician_profiles(id,company_id)
);
create index if not exists service_orders_company_schedule on public.service_orders(company_id,scheduled_start);
create index if not exists service_orders_technician_schedule on public.service_orders(assigned_technician_id,scheduled_start);
alter table public.technician_profiles enable row level security;
alter table public.service_orders enable row level security;
create policy technician_profiles_admin_read on public.technician_profiles for select to authenticated using(app_private.has_membership(company_id,array['admin']::public.member_role[]));
create policy service_orders_admin_read on public.service_orders for select to authenticated using(app_private.has_membership(company_id,array['admin']::public.member_role[]));
revoke insert,update,delete on public.technician_profiles,public.service_orders from anon,authenticated;
grant select on public.technician_profiles,public.service_orders to authenticated;
