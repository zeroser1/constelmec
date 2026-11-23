// Shared domain types for the Constelmec demo + real-access flows.
// Mirrors the enums in supabase/migrations/202611210001_initial.sql.

export type Role = 'technician' | 'customer';
export type MemberRole = 'admin' | 'technician' | 'customer';
export type GateState = 'Operativo' | 'Con observaciones' | 'Fuera de servicio';
export type ControlStatus = 'Pendiente' | 'OK' | 'Falla' | 'N/A' | 'No verificable';

export type Gate = {
  id: string;
  name: string;
  code: string;
  location: string;
  model: string;
  state: GateState;
  last: string;
  next: string;
  observations: number;
};

export type Control = { id: string; label: string; status: ControlStatus; note: string };
export type Visit = { gateId: string; completedAt: string; issueCount: number; technician: string };
export type Observation = { gateId: string; text: string; author: string; createdAt: string };

// Real (Supabase) row shapes used by the authenticated read views.
export type Membership = {
  company_id: string;
  role: MemberRole;
  companies: { name: string } | null;
};

export type RealGate = {
  id: string;
  code: string;
  description: string;
  model: string | null;
  serial_number: string | null;
  operational_state: string;
  facilities: { name: string } | null;
};

// ── Facility + Gate admin types (migration 006) ───────────────────────────

export type GateOperationalState = 'operational' | 'with_observations' | 'out_of_service';

export type RealFacility = {
  id: string;
  company_id: string;
  name: string;
  address: string | null;
  location_notes: string | null;
  contact_name: string | null;
  contact_phone: string | null;
  active: boolean;
  created_at: string | null;
  updated_at: string | null;
};

export type GateQR = {
  id: string;
  status: string;
  issued_at: string;
  revoked_at: string | null;
};

// AdminGate embeds the gate's QR history so a single query covers both.
export type AdminGate = {
  id: string;
  company_id: string;
  facility_id: string;
  code: string;
  description: string;
  model: string | null;
  serial_number: string | null;
  location_description: string | null;
  operational_state: GateOperationalState;
  active: boolean;
  created_at: string | null;
  updated_at: string | null;
  gate_qr_codes?: GateQR[];
};
