import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Membership, RealGate } from '../lib/types';
import type { Company, ServiceOrder, Technician } from '../AdminControl';

export function usePlatformAdmin(userId: string | undefined) {
  return useQuery({
    queryKey: ['platform-admin', userId],
    enabled: !!userId && !!supabase,
    queryFn: async (): Promise<boolean> => {
      const { data, error } = await supabase!.rpc('i_am_platform_admin');
      if (error) throw new Error(error.message);
      return data ?? false;
    },
  });
}

export function usePlatformAdminData(userId: string | undefined) {
  return useQuery({
    queryKey: ['platform-admin-data', userId],
    enabled: !!userId && !!supabase,
    queryFn: async (): Promise<{ companies: Company[]; orders: ServiceOrder[]; technicians: Technician[] }> => {
      const { data: companies, error: compError } = await supabase!.rpc('admin_list_all_companies');
      if (compError) throw new Error(compError.message);
      const [orders, technicians] = await Promise.all([
        supabase!.from('service_orders')
          .select('id,company_id,service_type,status,scheduled_start,scheduled_end,completed_at,next_service_at,notes,gates(code,description),facilities(name),technician_profiles(first_name,last_name)')
          .order('scheduled_start', { ascending: true }),
        supabase!.from('technician_profiles')
          .select('id,company_id,first_name,last_name,work_phone,work_email,specialty,driving_authorized,license_expires_on,active')
          .order('last_name', { ascending: true }),
      ]);
      if (orders.error) throw new Error(orders.error.message);
      if (technicians.error) throw new Error(technicians.error.message);
      return {
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

// Admin control-center bundle: companies, service orders and technicians across
// every company the user administers. User-scoped key, fetched in parallel.
export function useAdminData(isAdmin: boolean, userId: string | undefined) {
  return useQuery({
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
          .select('id,company_id,service_type,status,scheduled_start,scheduled_end,completed_at,next_service_at,notes,gates(code,description),facilities(name),technician_profiles(first_name,last_name)')
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
