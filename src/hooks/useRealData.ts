import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { AdminGate, CompanyContact, ContactCategory, Membership, OrderTechnician, OrderTechnicianRole, RealFacility, RealGate, RealObservation, RealVisit, TechAssignedOrder } from '../lib/types';
import type { Company, ServiceOrder, Technician } from '../AdminControl';

export function usePlatformAdmin(userId: string | undefined) {
  return useQuery({
    queryKey: ['platform-admin', userId],
    enabled: !!userId && !!supabase,
    queryFn: async (): Promise<boolean> => {
      const { data, error } = await supabase!.rpc('i_am_platform_admin');
      if (error) {
        // PGRST202 = PostgREST schema cache miss ("Could not find the function").
        // 42883   = PostgreSQL "function does not exist" (stale cache edge case).
        // Both mean migration 004 is not yet applied — degrade gracefully.
        if (error.code === 'PGRST202' || error.code === '42883') return false;
        // All other errors (42501 permission, auth failure, server error) must surface.
        // Never silently grant admin access when verification fails.
        throw new Error(error.message);
      }
      return data ?? false;
    },
  });
}

// isPlatformAdmin must be explicitly true before this hook fetches — it calls
// admin_list_all_companies() which raises 42501 for non-admins.
export function usePlatformAdminData(userId: string | undefined, isPlatformAdmin: boolean) {
  return useQuery({
    queryKey: ['platform-admin-data', userId],
    enabled: isPlatformAdmin && !!userId && !!supabase,
    queryFn: async (): Promise<{ companies: Company[]; orders: ServiceOrder[]; technicians: Technician[] }> => {
      const { data: companies, error: compError } = await supabase!.rpc('admin_list_all_companies');
      if (compError) throw new Error(compError.message);
      const [orders, technicians] = await Promise.all([
        supabase!.from('service_orders')
          .select('id,company_id,gate_id,assigned_technician_id,service_type,status,scheduled_start,scheduled_end,completed_at,next_service_at,notes,gates(code,description),facilities(name),technician_profiles(first_name,last_name)')
          .order('scheduled_start', { ascending: true }),
        supabase!.from('technician_profiles')
          .select('id,company_id,first_name,last_name,work_phone,work_email,specialty,driving_authorized,license_expires_on,active')
          .order('last_name', { ascending: true }),
      ]);
      if (orders.error) throw new Error(orders.error.message);
      if (technicians.error) throw new Error(technicians.error.message);      return {
        companies: unwrap<Company[]>(companies),
        orders: unwrap<ServiceOrder[]>(orders.data),
        technicians: unwrap<Technician[]>(technicians.data),
      };
    },
  });
}

// supabase-js returns embedded to-one relations typed loosely without generated
// DB types; we cast through unknown at each boundary.
function unwrap<T>(data: unknown): T {
  return data as T;
}

// The active membership for the signed-in user (one company per the demo scope).
// Keyed by user id so a re-login in the same tab never reads the prior user's cache.
export function useMembership(userId: string | undefined) {
  return useQuery({
    queryKey: ['membership', userId],
    enabled: !!userId && !!supabase,
    queryFn: async (): Promise<Membership | null> => {
      const { data, error } = await supabase!
        .from('memberships')
        .select('company_id,role,companies(name)')
        .eq('active', true)
        .limit(1);
      if (error) throw new Error(error.message);
      return unwrap<Membership[]>(data)[0] ?? null;
    },
  });
}

// Read-only gates for a company. Disabled until a company id is known.
export function useRealGates(companyId: string | undefined) {
  return useQuery({
    queryKey: ['real-gates', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<RealGate[]> => {
      const { data, error } = await supabase!
        .from('gates')
        .select('id,code,description,model,serial_number,operational_state,facilities(name)')
        .eq('company_id', companyId!)
        .order('code', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<RealGate[]>(data);
    },
  });
}

type AdminData = { companies: Company[]; orders: ServiceOrder[]; technicians: Technician[] };

export type CompanyFormInput = {
  name: string;
  legal_name: string;
  tax_id: string;
  contact_name: string;
  contact_email: string;
  contact_phone: string;
  address: string;
  notes: string;
};

// Wraps the three platform-admin write RPCs. Invalidates platform-admin-data on success
// so the company list refreshes automatically after any mutation.
export function useAdminCompanyMutations() {
  const queryClient = useQueryClient();
  const invalidate = () => queryClient.invalidateQueries({ queryKey: ['platform-admin-data'] });

  const createCompany = useMutation({
    mutationFn: async (input: CompanyFormInput): Promise<string> => {
      const { data, error } = await supabase!.rpc('admin_create_company', {
        p_name:          input.name,
        p_legal_name:    input.legal_name  || null,
        p_tax_id:        input.tax_id      || null,
        p_contact_name:  input.contact_name  || null,
        p_contact_email: input.contact_email || null,
        p_contact_phone: input.contact_phone || null,
        p_address:       input.address     || null,
        p_notes:         input.notes       || null,
      });
      if (error) throw new Error(error.message);
      return data as string;
    },
    onSuccess: invalidate,
  });

  const updateCompany = useMutation({
    mutationFn: async (input: CompanyFormInput & { id: string; expected_updated_at?: string | null }): Promise<void> => {
      const { error } = await supabase!.rpc('admin_update_company', {
        p_company_id:            input.id,
        p_name:                  input.name,
        p_legal_name:            input.legal_name  || null,
        p_tax_id:                input.tax_id      || null,
        p_contact_name:          input.contact_name  || null,
        p_contact_email:         input.contact_email || null,
        p_contact_phone:         input.contact_phone || null,
        p_address:               input.address     || null,
        p_notes:                 input.notes       || null,
        p_expected_updated_at:   input.expected_updated_at ?? null,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: invalidate,
  });

  const setCompanyActive = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }): Promise<void> => {
      const { error } = await supabase!.rpc('admin_set_company_active', {
        p_company_id: id,
        p_active:     active,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: invalidate,
  });

  return { createCompany, updateCompany, setCompanyActive };
}

// Admin control-center bundle: companies, service orders and technicians across
// every company the user administers. User-scoped key, fetched in parallel.
export function useAdminData(isAdmin: boolean, userId: string | undefined) {  return useQuery({
    queryKey: ['admin-data', userId],
    enabled: isAdmin && !!userId && !!supabase,
    queryFn: async (): Promise<AdminData> => {
      const memberships = await supabase!
        .from('memberships')
        .select('company_id,role')
        .eq('active', true)
        .eq('role', 'admin');
      if (memberships.error) throw new Error(memberships.error.message);
      const ids = [...new Set(unwrap<{ company_id: string }[]>(memberships.data).map(m => m.company_id))];
      if (!ids.length) return { companies: [], orders: [], technicians: [] };

      const [companies, orders, technicians] = await Promise.all([
        supabase!.from('companies').select('id,name').in('id', ids),
        supabase!
          .from('service_orders')
          .select('id,company_id,gate_id,assigned_technician_id,service_type,status,scheduled_start,scheduled_end,completed_at,next_service_at,notes,gates(code,description),facilities(name),technician_profiles(first_name,last_name)')
          .in('company_id', ids)
          .order('scheduled_start', { ascending: true }),
        supabase!
          .from('technician_profiles')
          .select('id,company_id,first_name,last_name,work_phone,work_email,specialty,driving_authorized,license_expires_on,active')
          .in('company_id', ids)
          .order('last_name', { ascending: true }),
      ]);
      for (const r of [companies, orders, technicians]) {
        if (r.error) throw new Error(r.error.message);
      }
      return {
        companies: unwrap<Company[]>(companies.data),
        orders: unwrap<ServiceOrder[]>(orders.data),
        technicians: unwrap<Technician[]>(technicians.data),
      };
    },
  });
}

// ── Facility hooks (migration 006) ────────────────────────────────────────

export type FacilityFormInput = {
  name: string;
  address: string;
  location_notes: string;
  contact_name: string;
  contact_phone: string;
};

export function useFacilities(companyId: string | undefined) {
  return useQuery({
    queryKey: ['facilities', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<RealFacility[]> => {
      const { data, error } = await supabase!
        .from('facilities')
        .select('id,company_id,name,address,location_notes,contact_name,contact_phone,active,created_at,updated_at')
        .eq('company_id', companyId!)
        .order('name', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<RealFacility[]>(data);
    },
  });
}

export function useFacilityMutations(companyId: string | undefined) {
  const qc = useQueryClient();
  const inv = () => qc.invalidateQueries({ queryKey: ['facilities', companyId] });

  const createFacility = useMutation({
    mutationFn: async (input: FacilityFormInput): Promise<string> => {
      const { data, error } = await supabase!.rpc('admin_create_facility', {
        p_company_id:     companyId,
        p_name:           input.name,
        p_address:        input.address        || null,
        p_location_notes: input.location_notes || null,
        p_contact_name:   input.contact_name   || null,
        p_contact_phone:  input.contact_phone  || null,
      });
      if (error) throw new Error(error.message);
      return data as string;
    },
    onSuccess: inv,
  });

  const updateFacility = useMutation({
    mutationFn: async (
      input: FacilityFormInput & { id: string; expected_updated_at?: string | null }
    ): Promise<void> => {
      const { error } = await supabase!.rpc('admin_update_facility', {
        p_facility_id:         input.id,
        p_company_id:          companyId,
        p_name:                input.name,
        p_address:             input.address        || null,
        p_location_notes:      input.location_notes || null,
        p_contact_name:        input.contact_name   || null,
        p_contact_phone:       input.contact_phone  || null,
        p_expected_updated_at: input.expected_updated_at ?? null,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: inv,
  });

  const setFacilityActive = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }): Promise<void> => {
      const { error } = await supabase!.rpc('admin_set_facility_active', {
        p_facility_id: id,
        p_company_id:  companyId,
        p_active:      active,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: inv,
  });

  return { createFacility, updateFacility, setFacilityActive };
}

// ── Gate hooks (migration 006) ─────────────────────────────────────────────

export type GateFormInput = {
  code: string;
  description: string;
  model: string;
  serial_number: string;
  location_description: string;
  operational_state: string;
};

// Fetches gates for a facility, embedding each gate's QR history (all statuses).
// The active QR is the first entry with status === 'active'.
export function useAdminGates(facilityId: string | undefined, companyId: string | undefined) {
  return useQuery({
    queryKey: ['admin-gates', facilityId],
    enabled: !!facilityId && !!companyId && !!supabase,
    queryFn: async (): Promise<AdminGate[]> => {
      const { data, error } = await supabase!
        .from('gates')
        .select(
          'id,company_id,facility_id,code,description,model,serial_number,' +
          'location_description,operational_state,active,created_at,updated_at,' +
          'gate_qr_codes(id,status,issued_at,revoked_at)'
        )
        .eq('facility_id', facilityId!)
        .eq('company_id', companyId!)
        .order('code', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<AdminGate[]>(data);
    },
  });
}

export function useGateMutations(companyId: string | undefined, facilityId: string | undefined) {
  const qc = useQueryClient();
  const inv = () => qc.invalidateQueries({ queryKey: ['admin-gates', facilityId] });

  const createGate = useMutation({
    mutationFn: async (input: GateFormInput): Promise<string> => {
      const { data, error } = await supabase!.rpc('admin_create_gate', {
        p_company_id:           companyId,
        p_facility_id:          facilityId,
        p_code:                 input.code,
        p_description:          input.description,
        p_model:                input.model               || null,
        p_serial_number:        input.serial_number        || null,
        p_location_description: input.location_description || null,
      });
      if (error) throw new Error(error.message);
      return data as string;
    },
    onSuccess: inv,
  });

  const updateGate = useMutation({
    mutationFn: async (
      input: GateFormInput & { id: string; expected_updated_at?: string | null }
    ): Promise<void> => {
      const { error } = await supabase!.rpc('admin_update_gate', {
        p_gate_id:              input.id,
        p_company_id:           companyId,
        p_description:          input.description,
        p_model:                input.model               || null,
        p_serial_number:        input.serial_number        || null,
        p_location_description: input.location_description || null,
        p_operational_state:    input.operational_state    || null,
        p_expected_updated_at:  input.expected_updated_at ?? null,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: inv,
  });

  const setGateActive = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }): Promise<void> => {
      const { error } = await supabase!.rpc('admin_set_gate_active', {
        p_gate_id:    id,
        p_company_id: companyId,
        p_active:     active,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: inv,
  });

  return { createGate, updateGate, setGateActive };
}

// ── QR mutation hooks (migration 006) ─────────────────────────────────────

// Invalidates the gates query so QR state refreshes without a separate QR query.
export function useQRMutations(companyId: string | undefined, facilityId: string | undefined) {
  const qc = useQueryClient();
  const inv = () => qc.invalidateQueries({ queryKey: ['admin-gates', facilityId] });

  const issueQR = useMutation({
    mutationFn: async (gateId: string): Promise<string> => {
      const { data, error } = await supabase!.rpc('admin_issue_gate_qr', {
        p_gate_id:    gateId,
        p_company_id: companyId,
      });
      if (error) throw new Error(error.message);
      return data as string;
    },
    onSuccess: inv,
  });

  const revokeQR = useMutation({
    mutationFn: async (qrId: string): Promise<void> => {
      const { error } = await supabase!.rpc('admin_revoke_gate_qr', {
        p_qr_id:      qrId,
        p_company_id: companyId,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: inv,
  });

  return { issueQR, revokeQR };
}

// ── Contact hooks (migration 007) ─────────────────────────────────────────

export type ContactFormInput = {
  first_name: string;
  last_name: string;
  category: ContactCategory;
  email: string;
  phone: string;
  notes: string;
  facility_id: string | null;
};

export function useCompanyContacts(companyId: string | undefined) {
  return useQuery({
    queryKey: ['contacts', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<CompanyContact[]> => {
      const { data, error } = await supabase!
        .from('company_contacts')
        .select('id,company_id,facility_id,first_name,last_name,category,email,phone,notes,active,created_at,updated_at')
        .eq('company_id', companyId!)
        .order('last_name', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<CompanyContact[]>(data);
    },
  });
}

export function useCompanyContactMutations(companyId: string | undefined) {
  const qc = useQueryClient();
  const inv = () => qc.invalidateQueries({ queryKey: ['contacts', companyId] });

  const createContact = useMutation({
    mutationFn: async (input: ContactFormInput): Promise<string> => {
      if (!companyId) throw new Error('companyId is required');
      const { data, error } = await supabase!.rpc('admin_create_company_contact', {
        p_company_id:  companyId,
        p_first_name:  input.first_name,
        p_last_name:   input.last_name,
        p_category:    input.category,
        p_email:       input.email      || null,
        p_phone:       input.phone      || null,
        p_notes:       input.notes      || null,
        p_facility_id: input.facility_id ?? null,
      });
      if (error) throw new Error(error.message);
      return data as string;
    },
    onSuccess: inv,
  });

  const updateContact = useMutation({
    mutationFn: async (
      input: ContactFormInput & { id: string; expected_updated_at?: string | null }
    ): Promise<void> => {
      if (!companyId) throw new Error('companyId is required');
      const { error } = await supabase!.rpc('admin_update_company_contact', {
        p_contact_id:          input.id,
        p_company_id:          companyId,
        p_first_name:          input.first_name,
        p_last_name:           input.last_name,
        p_category:            input.category,
        p_email:               input.email      || null,
        p_phone:               input.phone      || null,
        p_notes:               input.notes      || null,
        p_facility_id:         input.facility_id ?? null,
        p_expected_updated_at: input.expected_updated_at ?? null,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: inv,
  });

  const setContactActive = useMutation({
    mutationFn: async ({
      id, active, expected_updated_at,
    }: { id: string; active: boolean; expected_updated_at: string }): Promise<void> => {
      if (!companyId) throw new Error('companyId is required');
      const { error } = await supabase!.rpc('admin_set_company_contact_active', {
        p_contact_id:          id,
        p_company_id:          companyId,
        p_active:              active,
        p_expected_updated_at: expected_updated_at,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: inv,
  });

  return { createContact, updateContact, setContactActive };
}

// ── Technician hooks (migration 008) ──────────────────────────────────────

export type TechnicianCompanyAssignment = {
  id: string;
  technician_id: string;
  company_id: string;
  active: boolean;
};

export type TechnicianFacilityAssignment = {
  id: string;
  technician_id: string;
  facility_id: string;
  company_id: string;
  active: boolean;
};

export function useTechnicianProfiles(companyId: string | undefined) {
  return useQuery({
    queryKey: ['technicians', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<Technician[]> => {
      const { data, error } = await supabase!
        .from('technician_profiles')
        .select('id,company_id,first_name,last_name,work_phone,work_email,specialty,driving_authorized,license_expires_on,active')
        .eq('company_id', companyId!)
        .order('last_name', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<Technician[]>(data);
    },
  });
}

export function useTechnicianCompanyAssignments(companyId: string | undefined) {
  return useQuery({
    queryKey: ['tech-company-assignments', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<TechnicianCompanyAssignment[]> => {
      const { data, error } = await supabase!
        .from('technician_company_assignments')
        .select('id,technician_id,company_id,active')
        .eq('company_id', companyId!);
      if (error) throw new Error(error.message);
      return unwrap<TechnicianCompanyAssignment[]>(data);
    },
  });
}

export function useTechnicianFacilityAssignments(
  companyId: string | undefined,
  technicianId: string | undefined,
) {
  return useQuery({
    queryKey: ['tech-facility-assignments', companyId, technicianId],
    enabled: !!companyId && !!technicianId && !!supabase,
    queryFn: async (): Promise<TechnicianFacilityAssignment[]> => {
      const { data, error } = await supabase!
        .from('technician_facility_assignments')
        .select('id,technician_id,facility_id,company_id,active')
        .eq('technician_id', technicianId!)
        .eq('company_id', companyId!);
      if (error) throw new Error(error.message);
      return unwrap<TechnicianFacilityAssignment[]>(data);
    },
  });
}

export function useTechnicianMutations() {
  const qc = useQueryClient();

  const setCompanyActive = useMutation({
    mutationFn: async ({ active, cId, tId }: { active: boolean; cId: string; tId: string }): Promise<void> => {
      const { error } = await supabase!.rpc('admin_set_technician_company', {
        p_company_id:    cId,
        p_technician_id: tId,
        p_active:        active,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: ['tech-company-assignments', variables.cId] });
      // Disabling cascades to facility assignments via SQL trigger — refresh both.
      qc.invalidateQueries({ queryKey: ['tech-facility-assignments', variables.cId, variables.tId] });
    },
  });

  const setFacilityActive = useMutation({
    mutationFn: async ({ facilityId, active, cId, tId }: { facilityId: string; active: boolean; cId: string; tId: string }): Promise<void> => {
      const { error } = await supabase!.rpc('admin_set_technician_facility', {
        p_company_id:    cId,
        p_technician_id: tId,
        p_facility_id:   facilityId,
        p_active:        active,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: ['tech-facility-assignments', variables.cId, variables.tId] });
    },
  });

  return { setCompanyActive, setFacilityActive };
}

// ── Order-technician hooks (migration 009) ────────────────────────────────

export function useOrderTechnicians(
  companyId: string | undefined,
  orderId: string | undefined,
) {
  return useQuery({
    queryKey: ['order-technicians', companyId, orderId],
    enabled: !!companyId && !!orderId && !!supabase,
    queryFn: async (): Promise<OrderTechnician[]> => {
      const { data, error } = await supabase!
        .from('service_order_technicians')
        .select(
          'id,service_order_id,technician_id,company_id,role,assigned_at,active,' +
          'technician_profiles(first_name,last_name,specialty)',
        )
        .eq('service_order_id', orderId!)
        .eq('company_id', companyId!)
        .eq('active', true)
        .order('assigned_at', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<OrderTechnician[]>(data);
    },
  });
}

export function useOrderTechnicianMutations() {
  const qc = useQueryClient();

  const assignTechnician = useMutation({
    mutationFn: async ({
      companyId,
      orderId,
      technicianId,
      role,
    }: {
      companyId: string;
      orderId: string;
      technicianId: string;
      role: OrderTechnicianRole;
    }): Promise<string> => {
      const { data, error } = await supabase!.rpc('admin_assign_order_technician', {
        p_company_id:    companyId,
        p_order_id:      orderId,
        p_technician_id: technicianId,
        p_role:          role,
      });
      if (error) throw new Error(error.message);
      return data as string;
    },
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: ['order-technicians', variables.companyId, variables.orderId] });
    },
  });

  const removeTechnician = useMutation({
    mutationFn: async ({
      companyId,
      orderId,
      technicianId,
    }: {
      companyId: string;
      orderId: string;
      technicianId: string;
    }): Promise<void> => {
      const { error } = await supabase!.rpc('admin_remove_order_technician', {
        p_company_id:    companyId,
        p_order_id:      orderId,
        p_technician_id: technicianId,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: ['order-technicians', variables.companyId, variables.orderId] });
    },
  });

  return { assignTechnician, removeTechnician };
}

// ── Portal hooks (migrations 001 + 010) ──────────────────────────────────────

// All visits for a company (readable by all membership roles via migration 001).
export function useVisits(companyId: string | undefined) {
  return useQuery({
    queryKey: ['visits', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<RealVisit[]> => {
      const { data, error } = await supabase!
        .from('visits')
        .select('id,gate_id,company_id,status,started_at,closed_at,created_at')
        .eq('company_id', companyId!)
        .order('created_at', { ascending: false });
      if (error) throw new Error(error.message);
      return unwrap<RealVisit[]>(data);
    },
  });
}

// Observations for one gate (readable by all membership roles via migration 001).
export function useGateObservations(companyId: string | undefined, gateId: string | undefined) {
  return useQuery({
    queryKey: ['gate-observations', companyId, gateId],
    enabled: !!companyId && !!gateId && !!supabase,
    queryFn: async (): Promise<RealObservation[]> => {
      const { data, error } = await supabase!
        .from('customer_observations')
        .select('id,gate_id,company_id,author_user_id,body,created_at')
        .eq('company_id', companyId!)
        .eq('gate_id', gateId!)
        .order('created_at', { ascending: false });
      if (error) throw new Error(error.message);
      return unwrap<RealObservation[]>(data);
    },
  });
}

// Mutation: submit a customer observation via idempotent RPC.
export function useObservationMutations(companyId: string | undefined) {
  const qc = useQueryClient();
  const addObservation = useMutation({
    mutationFn: async ({ gateId, body, idempotencyKey }: { gateId: string; body: string; authorId: string; idempotencyKey: string }): Promise<void> => {
      const { error } = await supabase!.rpc('customer_create_observation', {
        p_company_id: companyId,
        p_gate_id: gateId,
        p_body: body,
        p_idempotency_key: idempotencyKey,
      });
      if (error) throw new Error(
        error.message.includes('does not exist') || error.message.includes('no existe')
          ? 'Función de observaciones en preparación.'
          : error.message
      );
    },
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: ['gate-observations', companyId, variables.gateId] });
    },
  });
  return { addObservation };
}

// All service_orders for a company (needs migration 010: service_orders_member_read).
// Used by CustomerPortal to show upcoming + past services per gate.
export function useCompanyServiceOrders(companyId: string | undefined) {
  return useQuery({
    queryKey: ['company-service-orders', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<ServiceOrder[]> => {
      const { data, error } = await supabase!
        .from('service_orders')
        .select(
          'id,company_id,gate_id,assigned_technician_id,service_type,status,scheduled_start,scheduled_end,' +
          'completed_at,next_service_at,notes,' +
          'gates(code,description),facilities(name),technician_profiles(first_name,last_name)',
        )
        .eq('company_id', companyId!)
        .order('scheduled_start', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<ServiceOrder[]>(data);
    },
  });
}

// Technician's own profile row (needs migration 010: technician_profiles_self_read).
export function useMyTechnicianProfile(userId: string | undefined, companyId: string | undefined) {
  return useQuery({
    queryKey: ['my-tech-profile', userId, companyId],
    enabled: !!userId && !!companyId && !!supabase,
    queryFn: async (): Promise<Technician | null> => {
      const { data, error } = await supabase!
        .from('technician_profiles')
        .select('id,company_id,first_name,last_name,work_phone,work_email,specialty,driving_authorized,license_expires_on,active')
        .eq('user_id', userId!)
        .eq('company_id', companyId!)
        .maybeSingle();
      if (error) throw new Error(error.message);
      return unwrap<Technician | null>(data);
    },
  });
}

// Orders assigned to a technician via service_order_technicians.
// Needs migration 010 (service_orders_member_read) for the embedded service_orders join.
export function useMyAssignedOrders(companyId: string | undefined, techProfileId: string | undefined) {
  return useQuery({
    queryKey: ['my-assigned-orders', companyId, techProfileId],
    enabled: !!companyId && !!techProfileId && !!supabase,
    queryFn: async (): Promise<TechAssignedOrder[]> => {
      const { data, error } = await supabase!
        .from('service_order_technicians')
        .select(
          'id,service_order_id,role,assigned_at,active,' +
          'service_orders(id,company_id,gate_id,service_type,status,scheduled_start,scheduled_end,notes,' +
          'gates(code,description),facilities(name))',
        )
        .eq('company_id', companyId!)
        .eq('technician_id', techProfileId!)
        .eq('active', true)
        .order('assigned_at', { ascending: false });
      if (error) throw new Error(error.message);
      return unwrap<TechAssignedOrder[]>(data);
    },
  });
}

// ── Service order creation (migration 015) ──────────────────────────────────

export type ServiceOrderTechInput = {
  technicianId: string;
  role: OrderTechnicianRole;
};

export type CreateServiceOrderInput = {
  companyId: string;
  facilityId: string;
  gateId: string;
  serviceType: string;
  scheduledStart: string; // ISO string
  scheduledEnd: string;   // ISO string
  technicians?: ServiceOrderTechInput[];
};

export type CreateServiceOrderResult = {
  orderId: string;
  assignedTechs: string[];
  failedTechs: Array<{ technicianId: string; error: string }>;
  scheduled: boolean;
};

export function useCreateServiceOrder() {
  const qc = useQueryClient();

  const createOrder = useMutation({
    mutationFn: async (input: CreateServiceOrderInput): Promise<CreateServiceOrderResult> => {
      const idempotencyKey = crypto.randomUUID();

      const { data: newId, error: createError } = await supabase!.rpc('admin_create_service_order', {
        p_company_id:      input.companyId,
        p_facility_id:     input.facilityId,
        p_gate_id:         input.gateId,
        p_service_type:    input.serviceType,
        p_scheduled_start: input.scheduledStart,
        p_scheduled_end:   input.scheduledEnd,
        p_idempotency_key: idempotencyKey,
      });
      if (createError) throw new Error(createError.message);
      const orderId = newId as string;

      const assignedTechs: string[] = [];
      const failedTechs: Array<{ technicianId: string; error: string }> = [];

      for (const tech of input.technicians ?? []) {
        const { error: assignError } = await supabase!.rpc('admin_assign_order_technician', {
          p_company_id:    input.companyId,
          p_order_id:      orderId,
          p_technician_id: tech.technicianId,
          p_role:          tech.role,
        });
        if (assignError) {
          failedTechs.push({ technicianId: tech.technicianId, error: assignError.message });
        } else {
          assignedTechs.push(tech.technicianId);
        }
      }

      let scheduled = false;
      if (assignedTechs.length > 0) {
        const { error: schedError } = await supabase!.rpc('admin_schedule_service_order', {
          p_company_id: input.companyId,
          p_order_id:   orderId,
        });
        if (schedError) {
          failedTechs.push({ technicianId: '__schedule__', error: schedError.message });
        } else {
          scheduled = true;
        }
      }

      return { orderId, assignedTechs, failedTechs, scheduled };
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-data'] });
      qc.invalidateQueries({ queryKey: ['company-service-orders'] });
      qc.invalidateQueries({ queryKey: ['my-assigned-orders'] });
    },
  });

  return { createOrder };
}

// ── Company-wide order technician map (migration 008) ──────────────────────────
// Used by WorkDashboard to build the tech filter dropdown and filter orders
// without relying on the legacy assigned_technician_id field.

type CompanyOrderTechEntry = {
  service_order_id: string;
  technician_id: string;
  technician_profiles: { first_name: string; last_name: string } | null;
};

export function useCompanyOrderTechnicians(companyId: string | undefined) {
  return useQuery({
    queryKey: ['company-order-technicians', companyId],
    enabled: !!companyId && !!supabase,
    queryFn: async (): Promise<CompanyOrderTechEntry[]> => {
      const { data, error } = await supabase!
        .from('service_order_technicians')
        .select('service_order_id,technician_id,technician_profiles(first_name,last_name)')
        .eq('company_id', companyId!)
        .eq('active', true)
        .order('assigned_at', { ascending: true });
      if (error) throw new Error(error.message);
      return unwrap<CompanyOrderTechEntry[]>(data);
    },
  });
}
