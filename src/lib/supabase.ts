import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
// supabase-js uses the anon key as the apikey; the publishable key is accepted as a fallback.
const key = (import.meta.env.VITE_SUPABASE_ANON_KEY
  || import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY) as string | undefined;

// True only when both public env vars are present. Views use this to show a
// "connection pending" state instead of crashing on a null client.
export const supabaseConfigured = Boolean(url && key);

// A single shared client. persistSession + autoRefreshToken replace the
// hand-rolled localStorage/refresh logic that lived in RealAccess.tsx.
export const supabase = supabaseConfigured
  ? createClient(url!, key!, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        storageKey: 'constelmec:auth:v2',
      },
    })
  : null;
