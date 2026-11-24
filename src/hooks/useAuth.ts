import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import { queryClient } from '../lib/queryClient';

// Translate the common Supabase auth error strings to Spanish for the UI.
function translateAuthError(message: string): string {
  const m = message.toLowerCase();
  if (m.includes('invalid login credentials')) return 'Correo o contraseña incorrectos.';
  if (m.includes('email not confirmed')) return 'Confirmá tu correo antes de ingresar.';
  if (m.includes('user already registered')) return 'Ya existe una cuenta con ese correo.';
  if (m.includes('password should be at least')) return 'La contraseña es demasiado corta.';
  if (m.includes('rate limit') || m.includes('too many')) return 'Demasiados intentos. Esperá un momento.';
  return message;
}

// Subscribes to Supabase auth state. supabase-js owns token storage and refresh,
// replacing the manual localStorage + refresh_token handling in the old RealAccess.
export function useAuth() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [passwordRecovery, setPasswordRecovery] = useState(() => typeof window !== 'undefined' && (new URLSearchParams(window.location.hash.slice(1)).get('type') === 'recovery' || new URLSearchParams(window.location.search).get('type') === 'recovery'));

  useEffect(() => {
    if (!supabase) { setLoading(false); return; }
    let active = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return;
      setSession(data.session);
      setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, next) => {
      setSession(next);
      if (event === 'PASSWORD_RECOVERY') setPasswordRecovery(true);
    });
    return () => { active = false; sub.subscription.unsubscribe(); };
  }, []);

  return { session, loading, passwordRecovery, setPasswordRecovery };
}

export async function signIn(email: string, password: string) {
  if (!supabase) throw new Error('Supabase no está configurado.');
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new Error(translateAuthError(error.message));
}

export async function signUp(email: string, password: string) {
  if (!supabase) throw new Error('Supabase no está configurado.');
  const { error } = await supabase.auth.signUp({ email, password });
  if (error) throw new Error(translateAuthError(error.message));
}

export async function signOut() {
  if (!supabase) return;
  await supabase.auth.signOut().catch(() => undefined);
  // Drop every cached query so the next user in this tab never sees the
  // previous user's company/role/gates (keys are also user-scoped as backup).
  queryClient.clear();
}

export async function requestPasswordReset(email: string) {
  if (!supabase) throw new Error('Supabase no está configurado.');
  const redirectTo = new URL('/', window.location.origin).toString();
  const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo });
  if (error) throw new Error(translateAuthError(error.message));
}

export async function updatePassword(password: string) {
  if (!supabase) throw new Error('Supabase no está configurado.');
  const { error } = await supabase.auth.updateUser({ password });
  if (error) throw new Error(translateAuthError(error.message));
}
