-- Company contacts: 1-many relation between a company and its named contacts.
-- Contacts are operational identities (people to call) — separate from app users.
-- A contact can be company-wide (facility_id IS NULL) or linked to one installation.
--
-- Design decisions:
--   • contact_category enum covers the common functional roles; 'other' as escape hatch.
--   • facility_id FK is nullable; validated against company_id in RPCs to prevent
--     cross-company association.
--   • Write authorisation: is_platform_admin() OR company-level 'admin' role.
--   • Soft-delete via active flag (same pattern as facilities/gates).

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Enum
-- ══════════════════════════════════════════════════════════════════════════════

create type public.contact_category as enum
  ('commercial', 'administrative', 'technical', 'emergency', 'other');

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Table
-- ══════════════════════════════════════════════════════════════════════════════

create table public.company_contacts (
  id          uuid                    primary key default gen_random_uuid(),
  company_id  uuid                    not null references public.companies(id),
  facility_id uuid                    references public.facilities(id),
  first_name  text                    not null,
  last_name   text                    not null,
  category    public.contact_category not null default 'administrative',
  email       text,
  phone       text,
  notes       text,
  active      boolean                 not null default true,
  created_at  timestamptz             not null default now(),
  updated_at  timestamptz             not null default now()
);

create index on public.company_contacts(company_id);
create index on public.company_contacts(company_id, facility_id);

drop trigger if exists company_contacts_updated_at on public.company_contacts;
create trigger company_contacts_updated_at
  before update on public.company_contacts
  for each row execute function app_private.set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. RLS
-- ══════════════════════════════════════════════════════════════════════════════

alter table public.company_contacts enable row level security;

create policy contacts_read on public.company_contacts
  for select to authenticated
  using(
    app_private.has_membership(company_id, array['admin']::public.member_role[])
    or app_private.is_platform_admin()
  );

revoke insert,update,delete on public.company_contacts from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Write RPCs
-- ══════════════════════════════════════════════════════════════════════════════

-- 4a. Create a contact under an active company.
create or replace function public.admin_create_company_contact(
  p_company_id  uuid,
  p_first_name  text,
  p_last_name   text,
  p_category    public.contact_category default 'administrative',
  p_email       text    default null,
  p_phone       text    default null,
  p_notes       text    default null,
  p_facility_id uuid    default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_id         uuid;
  v_first_name text;
  v_last_name  text;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.companies where id = p_company_id and active) then
    raise exception 'company not found or inactive' using errcode = 'P0002';
  end if;
  if p_first_name is null or length(trim(p_first_name)) < 2 then
    raise exception 'first name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_first_name)) > 100 then
    raise exception 'first name must not exceed 100 characters' using errcode = '22023';
  end if;
  if p_last_name is null or length(trim(p_last_name)) < 2 then
    raise exception 'last name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_last_name)) > 100 then
    raise exception 'last name must not exceed 100 characters' using errcode = '22023';
  end if;
  if p_email is not null and trim(p_email) != '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email address' using errcode = '22023';
  end if;
  if p_phone is not null and length(trim(p_phone)) > 30 then
    raise exception 'phone must not exceed 30 characters' using errcode = '22023';
  end if;
  if p_notes is not null and length(trim(p_notes)) > 1000 then
    raise exception 'notes must not exceed 1000 characters' using errcode = '22023';
  end if;
  if p_facility_id is not null then
    if not exists (
      select 1 from public.facilities
      where id = p_facility_id and company_id = p_company_id and active
    ) then
      raise exception 'facility not found, inactive, or belongs to a different company'
        using errcode = 'P0002';
    end if;
  end if;
  v_first_name := trim(p_first_name);
  v_last_name  := trim(p_last_name);
  insert into public.company_contacts
    (company_id, facility_id, first_name, last_name, category, email, phone, notes)
  values (
    p_company_id,
    p_facility_id,
    v_first_name,
    v_last_name,
    p_category,
    nullif(trim(coalesce(p_email,'')),''),
    nullif(trim(coalesce(p_phone,'')),''),
    nullif(trim(coalesce(p_notes,'')),'')
  )
  returning id into v_id;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(), 'contact_created',
    jsonb_build_object(
      'contact_id',  v_id,
      'first_name',  v_first_name,
      'last_name',   v_last_name,
      'category',    p_category::text,
      'facility_id', p_facility_id
    ),
    gen_random_uuid());
  return v_id;
end;
$$;
revoke execute on function public.admin_create_company_contact(uuid,text,text,public.contact_category,text,text,text,uuid) from public;
revoke execute on function public.admin_create_company_contact(uuid,text,text,public.contact_category,text,text,text,uuid) from anon;
grant  execute on function public.admin_create_company_contact(uuid,text,text,public.contact_category,text,text,text,uuid) to authenticated;

-- 4b. Update a contact (optimistic lock via expected_updated_at).
create or replace function public.admin_update_company_contact(
  p_contact_id          uuid,
  p_company_id          uuid,
  p_first_name          text,
  p_last_name           text,
  p_category            public.contact_category,
  p_email               text        default null,
  p_phone               text        default null,
  p_notes               text        default null,
  p_facility_id         uuid        default null,
  p_expected_updated_at timestamptz default null
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_old        record;
  v_first_name text;
  v_last_name  text;
  v_email      text;
  v_phone      text;
  v_notes      text;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.companies where id = p_company_id and active) then
    raise exception 'company not found or inactive' using errcode = 'P0002';
  end if;
  if p_first_name is null or length(trim(p_first_name)) < 2 then
    raise exception 'first name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_first_name)) > 100 then
    raise exception 'first name must not exceed 100 characters' using errcode = '22023';
  end if;
  if p_last_name is null or length(trim(p_last_name)) < 2 then
    raise exception 'last name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_last_name)) > 100 then
    raise exception 'last name must not exceed 100 characters' using errcode = '22023';
  end if;
  if p_email is not null and trim(p_email) != '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email address' using errcode = '22023';
  end if;
  if p_phone is not null and length(trim(p_phone)) > 30 then
    raise exception 'phone must not exceed 30 characters' using errcode = '22023';
  end if;
  if p_notes is not null and length(trim(p_notes)) > 1000 then
    raise exception 'notes must not exceed 1000 characters' using errcode = '22023';
  end if;
  if p_facility_id is not null then
    if not exists (
      select 1 from public.facilities
      where id = p_facility_id and company_id = p_company_id and active
    ) then
      raise exception 'facility not found, inactive, or belongs to a different company'
        using errcode = 'P0002';
    end if;
  end if;
  if p_expected_updated_at is null then
    raise exception 'p_expected_updated_at is required' using errcode = '22023';
  end if;
  select * into v_old from public.company_contacts
    where id = p_contact_id and company_id = p_company_id for update;
  if not found then
    raise exception 'contact not found' using errcode = 'P0002';
  end if;
  if v_old.updated_at is distinct from p_expected_updated_at then
    raise exception 'concurrent edit conflict: contact was modified by another user'
      using errcode = 'P0001';
  end if;
  v_first_name := trim(p_first_name);
  v_last_name  := trim(p_last_name);
  v_email      := nullif(trim(coalesce(p_email,'')),'');
  v_phone      := nullif(trim(coalesce(p_phone,'')),'');
  v_notes      := nullif(trim(coalesce(p_notes,'')),'');
  update public.company_contacts set
    first_name  = v_first_name,
    last_name   = v_last_name,
    category    = p_category,
    email       = v_email,
    phone       = v_phone,
    notes       = v_notes,
    facility_id = p_facility_id
  where id = p_contact_id and company_id = p_company_id;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(), 'contact_updated',
    jsonb_build_object(
      'contact_id', p_contact_id,
      'before', jsonb_build_object(
        'first_name',  v_old.first_name,
        'last_name',   v_old.last_name,
        'category',    v_old.category::text,
        'email',       v_old.email,
        'phone',       v_old.phone,
        'facility_id', v_old.facility_id
      ),
      'after', jsonb_build_object(
        'first_name',  v_first_name,
        'last_name',   v_last_name,
        'category',    p_category::text,
        'email',       v_email,
        'phone',       v_phone,
        'facility_id', p_facility_id
      )
    ),
    gen_random_uuid());
end;
$$;
revoke execute on function public.admin_update_company_contact(uuid,uuid,text,text,public.contact_category,text,text,text,uuid,timestamptz) from public;
revoke execute on function public.admin_update_company_contact(uuid,uuid,text,text,public.contact_category,text,text,text,uuid,timestamptz) from anon;
grant  execute on function public.admin_update_company_contact(uuid,uuid,text,text,public.contact_category,text,text,text,uuid,timestamptz) to authenticated;

-- 4c. Activate or deactivate a contact (optimistic lock prevents concurrent toggle conflicts).
create or replace function public.admin_set_company_contact_active(
  p_contact_id          uuid,
  p_company_id          uuid,
  p_active              boolean,
  p_expected_updated_at timestamptz
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_old record;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_expected_updated_at is null then
    raise exception 'p_expected_updated_at is required' using errcode = '22023';
  end if;
  select * into v_old from public.company_contacts
    where id = p_contact_id and company_id = p_company_id for update;
  if not found then
    raise exception 'contact not found' using errcode = 'P0002';
  end if;
  if v_old.updated_at is distinct from p_expected_updated_at then
    raise exception 'concurrent edit conflict: contact was modified by another user'
      using errcode = 'P0001';
  end if;
  update public.company_contacts set active = p_active
    where id = p_contact_id and company_id = p_company_id;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(),
    case when p_active then 'contact_activated' else 'contact_deactivated' end,
    jsonb_build_object('contact_id', p_contact_id), gen_random_uuid());
end;
$$;
revoke execute on function public.admin_set_company_contact_active(uuid,uuid,boolean,timestamptz) from public;
revoke execute on function public.admin_set_company_contact_active(uuid,uuid,boolean,timestamptz) from anon;
grant  execute on function public.admin_set_company_contact_active(uuid,uuid,boolean,timestamptz) to authenticated;
