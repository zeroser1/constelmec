import { test, expect, type Page } from '@playwright/test';

// Enter the technician demo regardless of whether Supabase env is configured.
// Configured  -> RealAccess shows "Explorar demostración del técnico".
// Unconfigured -> RealAccess shows "Conexión pendiente" + "Abrir demostración".
// Both lead to the same demo workspace, so tests stay hermetic in CI (no creds).
async function enterDemo(page: Page) {
  await page.goto('/');
  const configured = page.getByRole('button', { name: /Explorar demostración del técnico/ });
  const pending = page.getByRole('button', { name: /Abrir demostración/ });
  if (await configured.count()) await configured.first().click();
  else await pending.first().click();
}

// 1. The app shell renders and offers a way into the demo (either env state).
test('app renders with a demo entry point', async ({ page }) => {
  await page.goto('/');
  const entry = page.getByRole('button', { name: /Explorar demostración del técnico|Abrir demostración/ });
  await expect(entry.first()).toBeVisible();
});

// 2. A technician can open a gate, run the checklist and close the visit.
test('technician completes an inspection', async ({ page }) => {
  await enterDemo(page);
  await expect(page.getByRole('heading', { name: 'Control de mantenimiento' })).toBeVisible();

  await page.getByRole('button', { name: /Portón principal/ }).first().click();
  await page.getByRole('button', { name: /Iniciar inspección/ }).click();

  const okButtons = page.getByRole('button', { name: 'OK', exact: true });
  const count = await okButtons.count();
  expect(count).toBe(6);
  for (let i = 0; i < count; i++) await okButtons.nth(i).click();

  const finish = page.getByRole('button', { name: /Finalizar inspección/ });
  await expect(finish).toBeEnabled();
  await finish.click();
  await expect(page.getByText(/Visita de demostración cerrada/)).toBeVisible();
});

// 3. Invariant: closing a visit must NOT lift an out-of-service gate.
test('out-of-service gate stays out of service after a clean visit', async ({ page }) => {
  await enterDemo(page);

  await page.getByRole('button', { name: /Portón lateral/ }).first().click();
  await expect(page.locator('.detail-head .status')).toContainText('Fuera de servicio');

  await page.getByRole('button', { name: /Iniciar inspección/ }).click();
  const okButtons = page.getByRole('button', { name: 'OK', exact: true });
  const count = await okButtons.count();
  for (let i = 0; i < count; i++) await okButtons.nth(i).click();
  await page.getByRole('button', { name: /Finalizar inspección/ }).click();

  await expect(page.locator('.detail-head .status')).toContainText('Fuera de servicio');
  await expect(page.locator('.detail-head .status')).not.toContainText('Operativo');
});

// 4. Customer role exposes the observation form, not the inspection checklist.
test('customer sees the observation form', async ({ page }) => {
  await enterDemo(page);
  await page.getByRole('button', { name: 'Cliente', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Mis instalaciones' })).toBeVisible();
  await page.getByRole('button', { name: /Portón principal/ }).first().click();
  await expect(page.getByLabel('Enviar observación')).toBeVisible();
  await expect(page.getByRole('button', { name: /Iniciar inspección/ })).toHaveCount(0);
});
