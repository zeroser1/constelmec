-- Company management: extend public.companies with business fields, update has_membership
-- to enforce company.active on all RLS paths, and add platform-admin write RPCs.
--
-- v2 corrections: full before/after audit on all fields, email format + length validations,
-- optimistic locking in admin_update_company (p_expected_updated_at).
--
-- Corrections from migration 004 (safe no-op if already applied):
--   REVOKE ... FROM anon is explicit — REVOKE FROM PUBLIC does not remove
--   privileges granted directly to the anon role.
revoke execute on function public.i_am_platform_admin() from anon;
revoke execute on function public.admin_list_all_companies() from anon;

-- 1. CUIT validator (Argentine tax ID: 11 digits, weighted sum check digit).
--    Returns true for valid CUIT/CUIL, false otherwise.
--    Input may contain hyphens (20-05536168-2 or 20055361682 both accepted).
create or replace function app_private.validate_cuit(p_cuit text)
  returns boolean language plpgsql immutable set search_path=''
as $$
declare
  digits text;
  factors int[] := array[5,4,3,2,7,6,5,4,3,2];
  total   int := 0;
  i       int;
  rem     int;
begin
  digits := regexp_replace(p_cuit, '[-\s]', '', 'g');
  if length(digits) != 11 or digits !~ '^[0-9]+$' then return false; end if;
  for i in 1..10 loop
    total := total + (substring(digits, i, 1)::int) * factors[i];
  end loop;
  rem := total % 11;
  if rem = 1 then return false; end if;
  if rem = 0 then
    return (substring(digits, 11, 1)::int) = 0;
  else
    return (substring(digits, 11, 1)::int) = (11 - rem);
  end if;
end;
$$;
revoke all on function app_private.validate_cuit(text) from public;
grant execute on function app_private.validate_cuit(text) to authenticated;

-- 2. Extend public.companies with business metadata.
--    All new columns are nullable so existing rows are unaffected.
alter table public.companies
  add column if not exists legal_name    text check(legal_name   is null or length(trim(legal_name))   between 2 and 200),
  add column if not exists tax_id        text,
  add column if not exists contact_name  text,
  add column if not exists contact_email text,
  add column if not exists contact_phone text,
  add column if not exists address       text,
  add column if not exists active        boolean not null default true,
  add column if not exists notes         text,
  add column if not exists updated_at    timestamptz default now();

-- 3. Auto-set updated_at on every UPDATE.
create or replace function app_private.set_updated_at()
  returns trigger language plpgsql set search_path=''
as $$
begin new.updated_at = now(); return new; end;
$$;
revoke all on function app_private.set_updated_at() from public;

drop trigger if exists companies_updated_at on public.companies;
create trigger companies_updated_at
  before update on public.companies
  for each row execute function app_private.set_updated_at();

-- 4. Update has_membership to also check companies.active.
--    All 13 tables whose RLS policies call has_membership() automatically inherit
--    this change — deactivating a company blocks access across the entire schema
--    without ALTER POLICY on each table.
create or replace function app_private.has_membership(
  p_company uuid,
  p_roles   public.member_role[] default null
) returns boolean language sql stable security definer set search_path=''
as $$
  select exists(
    select 1
    from   public.memberships m
    join   public.companies   c on c.id = m.company_id
    where  m.company_id = p_company
      and  m.user_id    = (select auth.uid())
      and  m.active
      and  c.active
      and  (p_roles is null or m.role = any(p_roles))
  )
$$;

-- 5. Update companies_read RLS: platform admin sees inactive companies too;
--    regular users only see active ones (enforced by the has_membership() join above,
--    but the explicit `active` guard here is defense-in-depth).
alter policy companies_read on public.companies
  using(
    app_private.is_platform_admin()
    or (active and app_private.has_membership(id))
  );

-- 5b. Update memberships_read RLS: platform admin sees all memberships;
--     regular users only see memberships for ACTIVE companies.
--     has_membership() already blocks operational access, but without this fix a user
--     can still query their own membership row for an inactive company, which leaks
--     the fact that the company exists and that they belonged to it.
alter policy memberships_read on public.memberships
  using(
    app_private.is_platform_admin()
    or (
      user_id = (select auth.uid())
      and exists (
        select 1 from public.companies c
        where c.id = company_id and c.active
      )
    )
  );

-- 6. Write RPCs — platform admin only.
--    Pattern: check is_platform_admin() → raise 42501, validate input, mutate,
--    record to audit_events (append-only).

-- 6a. Create a new company.
create or replace function public.admin_create_company(
  p_name          text,
  p_legal_name    text    default null,
  p_tax_id        text    default null,
  p_contact_name  text    default null,
  p_contact_email text    default null,
  p_contact_phone text    default null,
  p_address       text    default null,
  p_notes         text    default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_id          uuid;
  v_name        text;
  v_legal_name  text;
  v_tax_id      text;
  v_contact_name  text;
  v_contact_email text;
  v_contact_phone text;
  v_address     text;
  v_notes       text;
begin
  if not app_private.is_platform_admin() then
    raise exception 'permission denied: global admin role required' using errcode = '42501';
  end if;

  -- Name: required, 2–200 chars
  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'company name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_name)) > 200 then
    raise exception 'company name must not exceed 200 characters' using errcode = '22023';
  end if;

  -- Legal name: optional, but if provided must be 2–200 chars (mirrors column CHECK)
  if p_legal_name is not null and trim(p_legal_name) <> '' and length(trim(p_legal_name)) < 2 then
    raise exception 'legal name must be at least 2 characters' using errcode = '22023';
  end if;
  if p_legal_name is not null and length(trim(p_legal_name)) > 200 then
    raise exception 'legal name must not exceed 200 characters' using errcode = '22023';
  end if;

  -- CUIT: optional, must pass check digit when provided
  if p_tax_id is not null and trim(p_tax_id) <> '' and not app_private.validate_cuit(p_tax_id) then
    raise exception 'invalid CUIT: must be 11 digits with valid check digit' using errcode = '22023';
  end if;

  -- Email: optional, must match basic format when provided
  if p_contact_email is not null and trim(p_contact_email) <> ''
     and trim(p_contact_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email format' using errcode = '22023';
  end if;

  -- Length limits on other optional text fields
  if p_contact_name  is not null and length(trim(p_contact_name))  > 200 then
    raise exception 'contact name must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_contact_phone is not null and length(trim(p_contact_phone)) > 50 then
    raise exception 'phone must not exceed 50 characters' using errcode = '22023';
  end if;
  if p_address       is not null and length(trim(p_address))       > 500 then
    raise exception 'address must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_notes         is not null and length(trim(p_notes))         > 2000 then
    raise exception 'notes must not exceed 2000 characters' using errcode = '22023';
  end if;

  -- Compute transformed values once (used in both INSERT and audit)
  v_name          := trim(p_name);
  v_legal_name    := nullif(trim(coalesce(p_legal_name,    '')), '');
  v_tax_id        := nullif(trim(coalesce(p_tax_id,        '')), '');
  v_contact_name  := nullif(trim(coalesce(p_contact_name,  '')), '');
  v_contact_email := nullif(trim(coalesce(p_contact_email, '')), '');
  v_contact_phone := nullif(trim(coalesce(p_contact_phone, '')), '');
  v_address       := nullif(trim(coalesce(p_address,       '')), '');
  v_notes         := nullif(trim(coalesce(p_notes,         '')), '');

  insert into public.companies (name, legal_name, tax_id, contact_name, contact_email, contact_phone, address, notes)
  values (v_name, v_legal_name, v_tax_id, v_contact_name, v_contact_email, v_contact_phone, v_address, v_notes)
  returning id into v_id;

  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (
    v_id,
    auth.uid(),
    'company_created',
    jsonb_build_object(
      'name',          v_name,
      'legal_name',    v_legal_name,
      'tax_id',        v_tax_id,
      'contact_name',  v_contact_name,
      'contact_email', v_contact_email,
      'contact_phone', v_contact_phone,
      'address',       v_address,
      'notes',         v_notes,
      'active',        true
    ),
    gen_random_uuid()
  );

  return v_id;
end;
$$;
revoke execute on function public.admin_create_company(text,text,text,text,text,text,text,text) from public;
revoke execute on function public.admin_create_company(text,text,text,text,text,text,text,text) from anon;
grant  execute on function public.admin_create_company(text,text,text,text,text,text,text,text) to authenticated;

-- 6b. Update an existing company's business fields.
--     Adds optimistic locking via p_expected_updated_at and full before/after audit.
create or replace function public.admin_update_company(
  p_company_id          uuid,
  p_name                text,
  p_legal_name          text        default null,
  p_tax_id              text        default null,
  p_contact_name        text        default null,
  p_contact_email       text        default null,
  p_contact_phone       text        default null,
  p_address             text        default null,
  p_notes               text        default null,
  p_expected_updated_at timestamptz default null
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_old           record;
  v_name          text;
  v_legal_name    text;
  v_tax_id        text;
  v_contact_name  text;
  v_contact_email text;
  v_contact_phone text;
  v_address       text;
  v_notes         text;
begin
  if not app_private.is_platform_admin() then
    raise exception 'permission denied: global admin role required' using errcode = '42501';
  end if;

  -- Name: required, 2–200 chars
  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'company name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_name)) > 200 then
    raise exception 'company name must not exceed 200 characters' using errcode = '22023';
  end if;

  -- Legal name: optional, but if provided must be 2–200 chars (mirrors column CHECK)
  if p_legal_name is not null and trim(p_legal_name) <> '' and length(trim(p_legal_name)) < 2 then
    raise exception 'legal name must be at least 2 characters' using errcode = '22023';
  end if;
  if p_legal_name is not null and length(trim(p_legal_name)) > 200 then
    raise exception 'legal name must not exceed 200 characters' using errcode = '22023';
  end if;

  -- CUIT: optional, must pass check digit when provided
  if p_tax_id is not null and trim(p_tax_id) <> '' and not app_private.validate_cuit(p_tax_id) then
    raise exception 'invalid CUIT: must be 11 digits with valid check digit' using errcode = '22023';
  end if;

  -- Email: optional, must match basic format when provided
  if p_contact_email is not null and trim(p_contact_email) <> ''
     and trim(p_contact_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email format' using errcode = '22023';
  end if;

  -- Length limits on other optional text fields
  if p_contact_name  is not null and length(trim(p_contact_name))  > 200 then
    raise exception 'contact name must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_contact_phone is not null and length(trim(p_contact_phone)) > 50 then
    raise exception 'phone must not exceed 50 characters' using errcode = '22023';
  end if;
  if p_address       is not null and length(trim(p_address))       > 500 then
    raise exception 'address must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_notes         is not null and length(trim(p_notes))         > 2000 then
    raise exception 'notes must not exceed 2000 characters' using errcode = '22023';
  end if;

  -- Lock the row and read current values for audit and concurrency check.
  -- FOR UPDATE prevents a race between reading old values and writing new ones.
  select * into v_old from public.companies where id = p_company_id for update;
  if not found then
    raise exception 'company not found' using errcode = 'P0002';
  end if;

  -- Null guard: p_expected_updated_at must always be provided.
  -- DEFAULT NULL in the signature is for compatibility only; passing null explicitly
  -- would bypass the optimistic lock entirely, so we reject it here.
  if p_expected_updated_at is null then
    raise exception 'p_expected_updated_at is required: read updated_at from the company row before calling this function'
      using errcode = '22023';
  end if;

  -- Optimistic concurrency: reject the update if another user edited the row in between.
  if v_old.updated_at is distinct from p_expected_updated_at then
    raise exception 'concurrent edit conflict: company was modified by another user'
      using errcode = 'P0001';
  end if;

  -- Compute transformed values once (used in both UPDATE and audit)
  v_name          := trim(p_name);
  v_legal_name    := nullif(trim(coalesce(p_legal_name,    '')), '');
  v_tax_id        := nullif(trim(coalesce(p_tax_id,        '')), '');
  v_contact_name  := nullif(trim(coalesce(p_contact_name,  '')), '');
  v_contact_email := nullif(trim(coalesce(p_contact_email, '')), '');
  v_contact_phone := nullif(trim(coalesce(p_contact_phone, '')), '');
  v_address       := nullif(trim(coalesce(p_address,       '')), '');
  v_notes         := nullif(trim(coalesce(p_notes,         '')), '');

  update public.companies set
    name          = v_name,
    legal_name    = v_legal_name,
    tax_id        = v_tax_id,
    contact_name  = v_contact_name,
    contact_email = v_contact_email,
    contact_phone = v_contact_phone,
    address       = v_address,
    notes         = v_notes
  where id = p_company_id;

  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (
    p_company_id,
    auth.uid(),
    'company_updated',
    jsonb_build_object(
      'before', jsonb_build_object(
        'name',          v_old.name,
        'legal_name',    v_old.legal_name,
        'tax_id',        v_old.tax_id,
        'contact_name',  v_old.contact_name,
        'contact_email', v_old.contact_email,
        'contact_phone', v_old.contact_phone,
        'address',       v_old.address,
        'notes',         v_old.notes
      ),
      'after', jsonb_build_object(
        'name',          v_name,
        'legal_name',    v_legal_name,
        'tax_id',        v_tax_id,
        'contact_name',  v_contact_name,
        'contact_email', v_contact_email,
        'contact_phone', v_contact_phone,
        'address',       v_address,
        'notes',         v_notes
      )
    ),
    gen_random_uuid()
  );
end;
$$;
revoke execute on function public.admin_update_company(uuid,text,text,text,text,text,text,text,text,timestamptz) from public;
revoke execute on function public.admin_update_company(uuid,text,text,text,text,text,text,text,text,timestamptz) from anon;
grant  execute on function public.admin_update_company(uuid,text,text,text,text,text,text,text,text,timestamptz) to authenticated;

-- 6c. Activate or deactivate a company (soft delete — preserves all history).
--     When a company is deactivated, the updated has_membership() blocks access
--     to all its related tables via RLS without touching membership records.
create or replace function public.admin_set_company_active(
  p_company_id uuid,
  p_active     boolean
) returns void language plpgsql security definer set search_path=''
as $$
begin
  if not app_private.is_platform_admin() then
    raise exception 'permission denied: global admin role required' using errcode = '42501';
  end if;

  update public.companies set active = p_active where id = p_company_id;

  if not found then
    raise exception 'company not found' using errcode = 'P0002';
  end if;

  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (
    p_company_id,
    auth.uid(),
    case when p_active then 'company_activated' else 'company_deactivated' end,
    jsonb_build_object('active', p_active),
    gen_random_uuid()
  );
end;
$$;
revoke execute on function public.admin_set_company_active(uuid,boolean) from public;
revoke execute on function public.admin_set_company_active(uuid,boolean) from anon;
grant  execute on function public.admin_set_company_active(uuid,boolean) to authenticated;
