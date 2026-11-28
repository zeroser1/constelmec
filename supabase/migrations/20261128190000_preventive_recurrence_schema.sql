-- CONSTELMEC preventive recurrence definitions (schema only).
-- Apply in a reviewed DEV/QA migration before wiring the UI. Never auto-generate orders here.
create table if not exists public.preventive_schedule_rules (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  gate_id uuid not null references public.gates(id),
  anchor_date date not null,
  every_months integer not null check (every_months in (1,2,3,6,12)),
  schedule_mode text not null check (schedule_mode in ('fixed_day','business_week')),
  day_of_month integer,
  business_week integer,
  active boolean not null default true,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint preventive_schedule_mode_values check (
    (schedule_mode='fixed_day' and day_of_month between 1 and 31 and business_week is null)
    or (schedule_mode='business_week' and business_week between 1 and 5 and day_of_month is null)
  ),
  constraint preventive_schedule_gate_company_fk
    foreign key (gate_id,company_id) references public.gates(id,company_id)
);
create index if not exists preventive_schedule_rules_company_gate_idx
  on public.preventive_schedule_rules(company_id,gate_id);
alter table public.preventive_schedule_rules enable row level security;
revoke all on public.preventive_schedule_rules from anon;
grant select,insert,update,delete on public.preventive_schedule_rules to authenticated;
create policy "admin reads own company preventive rules"
  on public.preventive_schedule_rules for select to authenticated
  using (exists (select 1 from public.memberships m
    where m.user_id=auth.uid() and m.company_id=preventive_schedule_rules.company_id
    and m.role='admin' and m.active));
create policy "admin creates own company preventive rules"
  on public.preventive_schedule_rules for insert to authenticated
  with check (created_by=auth.uid() and exists (select 1 from public.memberships m
    where m.user_id=auth.uid() and m.company_id=preventive_schedule_rules.company_id
    and m.role='admin' and m.active));
create policy "admin updates own company preventive rules"
  on public.preventive_schedule_rules for update to authenticated
  using (exists (select 1 from public.memberships m
    where m.user_id=auth.uid() and m.company_id=preventive_schedule_rules.company_id
    and m.role='admin' and m.active))
  with check (exists (select 1 from public.memberships m
    where m.user_id=auth.uid() and m.company_id=preventive_schedule_rules.company_id
    and m.role='admin' and m.active));
create policy "admin deletes own company preventive rules"
  on public.preventive_schedule_rules for delete to authenticated
  using (exists (select 1 from public.memberships m
    where m.user_id=auth.uid() and m.company_id=preventive_schedule_rules.company_id
    and m.role='admin' and m.active));

-- Occurrences are independent of the recurrence rule and can be rescheduled.
-- A unique series/month key ensures that retrying generation cannot create duplicates.
create table if not exists public.preventive_schedule_occurrences (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references public.preventive_schedule_rules(id) on delete restrict,
  occurrence_month date not null check (extract(day from occurrence_month)=1),
  window_start date not null,
  window_end date not null,
  planned_date date,
  service_order_id uuid unique references public.service_orders(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','scheduled','completed','skipped')),
  created_at timestamptz not null default now(),
  unique(rule_id,occurrence_month),
  check (window_end>=window_start)
);
alter table public.preventive_schedule_occurrences enable row level security;
revoke all on public.preventive_schedule_occurrences from anon;
grant select,insert,update,delete on public.preventive_schedule_occurrences to authenticated;
create policy "admin manages own company preventive occurrences"
  on public.preventive_schedule_occurrences for all to authenticated
  using (exists (select 1 from public.preventive_schedule_rules r
    join public.memberships m on m.company_id=r.company_id
    where r.id=preventive_schedule_occurrences.rule_id and m.user_id=auth.uid()
    and m.role='admin' and m.active))
  with check (exists (select 1 from public.preventive_schedule_rules r
    join public.memberships m on m.company_id=r.company_id
    where r.id=preventive_schedule_occurrences.rule_id and m.user_id=auth.uid()
    and m.role='admin' and m.active));
-- Intentionally no cron, trigger-generated service orders, or RPC grants.
