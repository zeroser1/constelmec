-- Facility and gate management: extend existing facilities and gates tables with
-- business metadata, add updated_at / active lifecycle columns, and introduce
-- gate_qr_codes for QR lifecycle management.
--
-- Design decisions:
--   • facilities.active / gates.active = operational soft-delete; does NOT block
--     RLS (membership-level access). Active flag is a filtering signal for the UI,
--     not a security perimeter (companies.active owns that).
--   • gate_qr_codes: each QR maps to one gate; partial unique index enforces at most
--     one active QR per gate at DB level. Raw token is returned once and never stored.
--   • Write authorisation: is_platform_admin() OR company-level 'admin' role.
--   • app_private.set_updated_at() is reused from migration 005 (clock_timestamp()).

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Extend public.facilities
-- ══════════════════════════════════════════════════════════════════════════════

alter table public.facilities
  add column if not exists address          text,
  add column if not exists location_notes   text,
  add column if not exists contact_name     text,
  add column if not exists contact_phone    text,
  add column if not exists active           boolean not null default true,
  add column if not exists updated_at       timestamptz default now();

drop trigger if exists facilities_updated_at on public.facilities;
create trigger facilities_updated_at
  before update on public.facilities
  for each row execute function app_private.set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Extend public.gates
-- ══════════════════════════════════════════════════════════════════════════════

alter table public.gates
  add column if not exists location_description text,
  add column if not exists active               boolean not null default true,
  add column if not exists updated_at           timestamptz default now();

drop trigger if exists gates_updated_at on public.gates;
create trigger gates_updated_at
  before update on public.gates
  for each row execute function app_private.set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. gate_qr_codes
-- ══════════════════════════════════════════════════════════════════════════════

create table public.gate_qr_codes (
  id          uuid        primary key default gen_random_uuid(),
  company_id  uuid        not null references public.companies(id),
  gate_id     uuid        not null,
  token_hash  text        not null,
  status      text        not null default 'active'
                          check(status in ('active','revoked')),
  issued_at   timestamptz not null default now(),
  revoked_at  timestamptz,
  issued_by   uuid        not null references auth.users(id),
  foreign key (gate_id, company_id) references public.gates(id, company_id)
);

-- At most one active QR per gate (DB-enforced via partial unique index)
create unique index gate_qr_one_active
  on public.gate_qr_codes(gate_id)
  where status = 'active';

create index on public.gate_qr_codes(company_id, gate_id);

alter table public.gate_qr_codes enable row level security;

create policy qr_codes_read on public.gate_qr_codes
  for select to authenticated
  using(
    app_private.has_membership(company_id, array['admin','technician']::public.member_role[])
    or app_private.is_platform_admin()
  );

revoke insert,update,delete on public.gate_qr_codes from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Facility write RPCs
-- ══════════════════════════════════════════════════════════════════════════════

-- 4a. Create a facility under an active company.
create or replace function public.admin_create_facility(
  p_company_id      uuid,
  p_name            text,
  p_address         text    default null,
  p_location_notes  text    default null,
  p_contact_name    text    default null,
  p_contact_phone   text    default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_name text;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.companies where id = p_company_id and active) then
    raise exception 'company not found or inactive' using errcode = 'P0002';
  end if;
  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'facility name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_name)) > 200 then
    raise exception 'facility name must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_address is not null and length(trim(p_address)) > 500 then
    raise exception 'address must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_location_notes is not null and length(trim(p_location_notes)) > 1000 then
    raise exception 'location notes must not exceed 1000 characters' using errcode = '22023';
  end if;
  if p_contact_name is not null and length(trim(p_contact_name)) > 200 then
    raise exception 'contact name must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_contact_phone is not null and length(trim(p_contact_phone)) > 50 then
    raise exception 'contact phone must not exceed 50 characters' using errcode = '22023';
  end if;
  v_name := trim(p_name);
  insert into public.facilities (company_id, name, address, location_notes, contact_name, contact_phone)
  values (p_company_id, v_name,
    nullif(trim(coalesce(p_address,'')),''),
    nullif(trim(coalesce(p_location_notes,'')),''),
    nullif(trim(coalesce(p_contact_name,'')),''),
    nullif(trim(coalesce(p_contact_phone,'')),''))
  returning id into v_id;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(), 'facility_created',
    jsonb_build_object('facility_id', v_id, 'name', v_name), gen_random_uuid());
  return v_id;
end;
$$;
revoke execute on function public.admin_create_facility(uuid,text,text,text,text,text) from public;
revoke execute on function public.admin_create_facility(uuid,text,text,text,text,text) from anon;
grant  execute on function public.admin_create_facility(uuid,text,text,text,text,text) to authenticated;

-- 4b. Update facility business fields (optimistic lock via expected_updated_at).
create or replace function public.admin_update_facility(
  p_facility_id         uuid,
  p_company_id          uuid,
  p_name                text,
  p_address             text        default null,
  p_location_notes      text        default null,
  p_contact_name        text        default null,
  p_contact_phone       text        default null,
  p_expected_updated_at timestamptz default null
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_old            record;
  v_name           text;
  v_address        text;
  v_location_notes text;
  v_contact_name   text;
  v_contact_phone  text;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'facility name must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_name)) > 200 then
    raise exception 'facility name must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_address is not null and length(trim(p_address)) > 500 then
    raise exception 'address must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_location_notes is not null and length(trim(p_location_notes)) > 1000 then
    raise exception 'location notes must not exceed 1000 characters' using errcode = '22023';
  end if;
  if p_contact_name is not null and length(trim(p_contact_name)) > 200 then
    raise exception 'contact name must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_contact_phone is not null and length(trim(p_contact_phone)) > 50 then
    raise exception 'contact phone must not exceed 50 characters' using errcode = '22023';
  end if;
  if p_expected_updated_at is null then
    raise exception 'p_expected_updated_at is required' using errcode = '22023';
  end if;
  select * into v_old from public.facilities
    where id = p_facility_id and company_id = p_company_id for update;
  if not found then
    raise exception 'facility not found' using errcode = 'P0002';
  end if;
  if v_old.updated_at is distinct from p_expected_updated_at then
    raise exception 'concurrent edit conflict: facility was modified by another user'
      using errcode = 'P0001';
  end if;
  v_name           := trim(p_name);
  v_address        := nullif(trim(coalesce(p_address,'')),'');
  v_location_notes := nullif(trim(coalesce(p_location_notes,'')),'');
  v_contact_name   := nullif(trim(coalesce(p_contact_name,'')),'');
  v_contact_phone  := nullif(trim(coalesce(p_contact_phone,'')),'');
  update public.facilities set
    name           = v_name,
    address        = v_address,
    location_notes = v_location_notes,
    contact_name   = v_contact_name,
    contact_phone  = v_contact_phone
  where id = p_facility_id and company_id = p_company_id;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(), 'facility_updated',
    jsonb_build_object(
      'facility_id', p_facility_id,
      'before', jsonb_build_object(
        'name',           v_old.name,
        'address',        v_old.address,
        'location_notes', v_old.location_notes,
        'contact_name',   v_old.contact_name,
        'contact_phone',  v_old.contact_phone
      ),
      'after', jsonb_build_object(
        'name',           v_name,
        'address',        v_address,
        'location_notes', v_location_notes,
        'contact_name',   v_contact_name,
        'contact_phone',  v_contact_phone
      )
    ),
    gen_random_uuid());
end;
$$;
revoke execute on function public.admin_update_facility(uuid,uuid,text,text,text,text,text,timestamptz) from public;
revoke execute on function public.admin_update_facility(uuid,uuid,text,text,text,text,text,timestamptz) from anon;
grant  execute on function public.admin_update_facility(uuid,uuid,text,text,text,text,text,timestamptz) to authenticated;

-- 4c. Activate or deactivate a facility.
create or replace function public.admin_set_facility_active(
  p_facility_id uuid,
  p_company_id  uuid,
  p_active      boolean
) returns void language plpgsql security definer set search_path=''
as $$
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  update public.facilities set active = p_active
    where id = p_facility_id and company_id = p_company_id;
  if not found then
    raise exception 'facility not found' using errcode = 'P0002';
  end if;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(),
    case when p_active then 'facility_activated' else 'facility_deactivated' end,
    jsonb_build_object('facility_id', p_facility_id), gen_random_uuid());
end;
$$;
revoke execute on function public.admin_set_facility_active(uuid,uuid,boolean) from public;
revoke execute on function public.admin_set_facility_active(uuid,uuid,boolean) from anon;
grant  execute on function public.admin_set_facility_active(uuid,uuid,boolean) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. Gate write RPCs
-- ══════════════════════════════════════════════════════════════════════════════

-- 5a. Create a gate under an active facility.
--     code is the permanent operational identifier — set at creation, never changed.
create or replace function public.admin_create_gate(
  p_company_id           uuid,
  p_facility_id          uuid,
  p_code                 text,
  p_description          text,
  p_model                text    default null,
  p_serial_number        text    default null,
  p_location_description text    default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.facilities
    where id = p_facility_id and company_id = p_company_id and active
  ) then
    raise exception 'facility not found or inactive' using errcode = 'P0002';
  end if;
  if p_code is null or length(trim(p_code)) = 0 then
    raise exception 'gate code is required' using errcode = '22023';
  end if;
  if p_description is null or length(trim(p_description)) < 2 then
    raise exception 'gate description must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_description)) > 500 then
    raise exception 'gate description must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_model is not null and length(trim(p_model)) > 200 then
    raise exception 'gate model must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_serial_number is not null and length(trim(p_serial_number)) > 100 then
    raise exception 'serial number must not exceed 100 characters' using errcode = '22023';
  end if;
  if p_location_description is not null and length(trim(p_location_description)) > 500 then
    raise exception 'location description must not exceed 500 characters' using errcode = '22023';
  end if;
  insert into public.gates (company_id, facility_id, code, description, model, serial_number, location_description)
  values (p_company_id, p_facility_id,
    trim(p_code), trim(p_description),
    nullif(trim(coalesce(p_model,'')),''),
    nullif(trim(coalesce(p_serial_number,'')),''),
    nullif(trim(coalesce(p_location_description,'')),''))
  returning id into v_id;
  insert into public.audit_events (company_id, gate_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, v_id, auth.uid(), 'gate_created',
    jsonb_build_object('gate_id', v_id, 'code', trim(p_code), 'facility_id', p_facility_id),
    gen_random_uuid());
  return v_id;
end;
$$;
revoke execute on function public.admin_create_gate(uuid,uuid,text,text,text,text,text) from public;
revoke execute on function public.admin_create_gate(uuid,uuid,text,text,text,text,text) from anon;
grant  execute on function public.admin_create_gate(uuid,uuid,text,text,text,text,text) to authenticated;

-- 5b. Update gate fields.
--     code and facility_id are immutable operational identifiers — not in this signature.
create or replace function public.admin_update_gate(
  p_gate_id              uuid,
  p_company_id           uuid,
  p_description          text,
  p_model                text                           default null,
  p_serial_number        text                           default null,
  p_location_description text                           default null,
  p_operational_state    public.gate_operational_state  default null,
  p_expected_updated_at  timestamptz                    default null
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_old               record;
  v_description       text;
  v_model             text;
  v_serial_number     text;
  v_location_desc     text;
  v_operational_state public.gate_operational_state;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_description is null or length(trim(p_description)) < 2 then
    raise exception 'gate description must be at least 2 characters' using errcode = '22023';
  end if;
  if length(trim(p_description)) > 500 then
    raise exception 'gate description must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_model is not null and length(trim(p_model)) > 200 then
    raise exception 'gate model must not exceed 200 characters' using errcode = '22023';
  end if;
  if p_serial_number is not null and length(trim(p_serial_number)) > 100 then
    raise exception 'serial number must not exceed 100 characters' using errcode = '22023';
  end if;
  if p_location_description is not null and length(trim(p_location_description)) > 500 then
    raise exception 'location description must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_expected_updated_at is null then
    raise exception 'p_expected_updated_at is required' using errcode = '22023';
  end if;
  select * into v_old from public.gates
    where id = p_gate_id and company_id = p_company_id for update;
  if not found then
    raise exception 'gate not found' using errcode = 'P0002';
  end if;
  if v_old.updated_at is distinct from p_expected_updated_at then
    raise exception 'concurrent edit conflict: gate was modified by another user'
      using errcode = 'P0001';
  end if;
  v_description       := trim(p_description);
  v_model             := nullif(trim(coalesce(p_model,'')),'');
  v_serial_number     := nullif(trim(coalesce(p_serial_number,'')),'');
  v_location_desc     := nullif(trim(coalesce(p_location_description,'')),'');
  v_operational_state := coalesce(p_operational_state, v_old.operational_state);
  update public.gates set
    description          = v_description,
    model                = v_model,
    serial_number        = v_serial_number,
    location_description = v_location_desc,
    operational_state    = v_operational_state
  where id = p_gate_id and company_id = p_company_id;
  insert into public.audit_events (company_id, gate_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, p_gate_id, auth.uid(), 'gate_updated',
    jsonb_build_object(
      'before', jsonb_build_object(
        'description',          v_old.description,
        'model',                v_old.model,
        'serial_number',        v_old.serial_number,
        'location_description', v_old.location_description,
        'operational_state',    v_old.operational_state::text
      ),
      'after', jsonb_build_object(
        'description',          v_description,
        'model',                v_model,
        'serial_number',        v_serial_number,
        'location_description', v_location_desc,
        'operational_state',    v_operational_state::text
      )
    ),
    gen_random_uuid());
end;
$$;
revoke execute on function public.admin_update_gate(uuid,uuid,text,text,text,text,public.gate_operational_state,timestamptz) from public;
revoke execute on function public.admin_update_gate(uuid,uuid,text,text,text,text,public.gate_operational_state,timestamptz) from anon;
grant  execute on function public.admin_update_gate(uuid,uuid,text,text,text,text,public.gate_operational_state,timestamptz) to authenticated;

-- 5c. Activate or deactivate a gate.
--     Deactivation atomically revokes any active QR for that gate.
create or replace function public.admin_set_gate_active(
  p_gate_id    uuid,
  p_company_id uuid,
  p_active     boolean
) returns void language plpgsql security definer set search_path=''
as $$
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  update public.gates set active = p_active
    where id = p_gate_id and company_id = p_company_id;
  if not found then
    raise exception 'gate not found' using errcode = 'P0002';
  end if;
  if not p_active then
    update public.gate_qr_codes
    set status = 'revoked', revoked_at = clock_timestamp()
    where gate_id = p_gate_id and status = 'active';
  end if;
  insert into public.audit_events (company_id, gate_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, p_gate_id, auth.uid(),
    case when p_active then 'gate_activated' else 'gate_deactivated' end,
    jsonb_build_object('gate_id', p_gate_id), gen_random_uuid());
end;
$$;
revoke execute on function public.admin_set_gate_active(uuid,uuid,boolean) from public;
revoke execute on function public.admin_set_gate_active(uuid,uuid,boolean) from anon;
grant  execute on function public.admin_set_gate_active(uuid,uuid,boolean) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 6. QR lifecycle RPCs
-- ══════════════════════════════════════════════════════════════════════════════

-- 6a. Issue a new QR for a gate. Revokes any previous active QR atomically.
--     Returns the raw token ONCE — the caller must embed it in the QR image.
--     The raw token is never stored and cannot be recovered from the hash.
--     SELECT ... FOR UPDATE on the gate row serializes concurrent issuance so
--     the partial-unique-index constraint is never hit unexpectedly.
--     Requires the full hierarchy to be active: company → facility → gate.
create or replace function public.admin_issue_gate_qr(
  p_gate_id    uuid,
  p_company_id uuid
) returns text language plpgsql security definer set search_path=''
as $$
declare
  v_token            uuid;
  v_hash             text;
  v_qr_id            uuid;
  v_facility_id      uuid;
  v_facility_active  boolean;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  -- Lock the gate row to serialize concurrent issuance; also capture facility_id
  -- so we can validate the facility active state below.
  select facility_id into v_facility_id
  from public.gates
  where id = p_gate_id and company_id = p_company_id and active
  for update;
  if not found then
    raise exception 'gate not found or inactive' using errcode = 'P0002';
  end if;

  -- Validate activation hierarchy: also lock the facility row to prevent a
  -- concurrent admin_set_facility_active(false) from slipping through between
  -- this check and the gate_qr_codes INSERT (FOR UPDATE serializes against
  -- admin_set_facility_active which UPDATEs the same row).
  select active into v_facility_active
  from public.facilities
  where id = v_facility_id and company_id = p_company_id
  for update;
  if not found or not v_facility_active then
    raise exception 'facility is inactive — cannot issue QR for this gate'
      using errcode = 'P0002';
  end if;

  -- Revoke existing active QR for this gate (if any)
  update public.gate_qr_codes
  set status = 'revoked', revoked_at = clock_timestamp()
  where gate_id = p_gate_id and status = 'active';

  -- Generate new token; store only its sha256 hash.
  -- extensions.digest() is required: SET search_path='' means pgcrypto must be
  -- schema-qualified (pgcrypto is installed in the extensions schema in Supabase).
  v_token := gen_random_uuid();
  v_hash  := encode(extensions.digest(v_token::text, 'sha256'), 'hex');
  insert into public.gate_qr_codes (company_id, gate_id, token_hash, issued_by)
  values (p_company_id, p_gate_id, v_hash, auth.uid())
  returning id into v_qr_id;
  insert into public.audit_events (company_id, gate_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, p_gate_id, auth.uid(), 'gate_qr_issued',
    jsonb_build_object('qr_id', v_qr_id), gen_random_uuid());
  return v_token::text;
end;
$$;
revoke execute on function public.admin_issue_gate_qr(uuid,uuid) from public;
revoke execute on function public.admin_issue_gate_qr(uuid,uuid) from anon;
grant  execute on function public.admin_issue_gate_qr(uuid,uuid) to authenticated;

-- 6b. Explicitly revoke a QR code by ID.
create or replace function public.admin_revoke_gate_qr(
  p_qr_id      uuid,
  p_company_id uuid
) returns void language plpgsql security definer set search_path=''
as $$
declare v_gate_id uuid;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  update public.gate_qr_codes
  set status = 'revoked', revoked_at = clock_timestamp()
  where id = p_qr_id and company_id = p_company_id and status = 'active'
  returning gate_id into v_gate_id;
  if not found then
    raise exception 'QR not found, already revoked, or belongs to a different company'
      using errcode = 'P0002';
  end if;
  insert into public.audit_events (company_id, gate_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, v_gate_id, auth.uid(), 'gate_qr_revoked',
    jsonb_build_object('qr_id', p_qr_id), gen_random_uuid());
end;
$$;
revoke execute on function public.admin_revoke_gate_qr(uuid,uuid) from public;
revoke execute on function public.admin_revoke_gate_qr(uuid,uuid) from anon;
grant  execute on function public.admin_revoke_gate_qr(uuid,uuid) to authenticated;
