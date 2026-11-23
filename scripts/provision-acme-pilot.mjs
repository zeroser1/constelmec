// One-off ACME pilot setup. Run only from a trusted local/server environment.
// Required: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ACME_TEST_PASSWORD,
// GUILLLIMAN_TEST_PASSWORD (or GUILLIMAN_TEST_PASSWORD).
// Example: node scripts/provision-acme-pilot.mjs
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
const customerPassword = process.env.ACME_TEST_PASSWORD;
const technicianPassword = process.env.GUILLIMAN_TEST_PASSWORD ?? process.env.GUILLLIMAN_TEST_PASSWORD;
if (!url || !key || !customerPassword || !technicianPassword) {
  throw new Error('Missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ACME_TEST_PASSWORD or GUILLIMAN_TEST_PASSWORD');
}
const db = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
function check(result, context) {
  if (result.error) throw new Error(context + ': ' + result.error.message);
  return result.data;
}
async function getUser(email, password) {
  // Pagination prevents accidentally creating duplicate users beyond page one.
  for (let page = 1; ; page++) {
    const data = check(await db.auth.admin.listUsers({ page, perPage: 1000 }), 'List auth users');
    const existing = data.users.find(u => u.email?.toLowerCase() === email.toLowerCase());
    if (existing) return existing;
    if (data.users.length < 1000) break;
  }
  return check(await db.auth.admin.createUser({
    email, password, email_confirm: true,
    app_metadata: { pilot_account: true },
  }), 'Create auth user ' + email).user;
}
const company = check(await db.from('companies').select('id').eq('name', 'ACME Industrias S.A. (PRUEBA)').single(), 'Find ACME');
async function provision(email, password, role) {
  const user = await getUser(email, password);
  const memberships = check(await db.from('memberships').select('id,role').eq('user_id', user.id).eq('company_id', company.id), 'Find membership');
  if (memberships.length === 0) {
    check(await db.from('memberships').insert({ user_id: user.id, company_id: company.id, role, active: true }), 'Create membership');
  } else if (memberships[0].role !== role) {
    throw new Error('Existing membership role mismatch for ' + email + ': manual review required');
  }
  return user;
}
const customer = await provision('acme@acme.com', customerPassword, 'customer');
const tech = await provision('guilliman@constelmec.test', technicianPassword, 'technician');
const profiles = check(await db.from('technician_profiles').select('id').eq('user_id', tech.id).eq('company_id', company.id), 'Find technician profile');
if (!profiles.length) {
  check(await db.from('technician_profiles').insert({
    user_id: tech.id, company_id: company.id,
    first_name: 'Roboute', last_name: 'Guilliman',
    work_email: 'guilliman@constelmec.test', specialty: 'Mantenimiento de portones (PRUEBA)', active: true,
  }), 'Create technician profile');
}
console.log(JSON.stringify({ company_id: company.id, customer_id: customer.id, technician_id: tech.id, status: 'provisioned' }));
