# Constelmec — Frente 6: Matriz de Pruebas de Portales

**Versión:** 1.0.0  
**Fecha:** 23/11/2026  
**Fase:** Frente 6 — Validación integral de portales  
**Autor:** Auditoría automática (Claude Code — Frente 7)  
**Referencia:** [Fase 3 — Auditoría de seguridad](./03-security-audit.md)

---

## 1. Requisitos del entorno de pruebas

| Requisito | Descripción |
|-----------|-------------|
| Supabase local | `supabase start` con migraciones 001–010 aplicadas sin errores |
| O staging Supabase Cloud | Proyecto separado de producción — no el proyecto remoto productivo |
| Usuarios creados manualmente | Supabase Auth dashboard o `supabase.auth.admin.createUser()` vía service_role |
| Datos base | Empresas, instalaciones, portones, órdenes y técnicos de prueba (ver sección 3) |
| Build | `npm run build` limpio antes de ejecutar pruebas manuales |

> **Producción permanece congelada.** Las pruebas de esta matriz se ejecutan exclusivamente en entorno aislado.

---

## 2. Identidades de prueba

| ID | Email de prueba | Rol | Empresa | Propósito |
|----|----------------|-----|---------|-----------|
| U-A-ADM | _test-admin-a@constelmec.test | admin | Empresa A | Admin de empresa A |
| U-A-TECH | _test-tech-a@constelmec.test | technician | Empresa A | Técnico de empresa A |
| U-B-ADM | _test-admin-b@constelmec.test | admin | Empresa B | Admin de empresa B |
| U-B-TECH | _test-tech-b@constelmec.test | technician | Empresa B | Técnico de empresa B — víctima en tests cruzados |
| U-PLATFORM | _test-platform@constelmec.test | platform_admin | N/A | Administrador de plataforma |
| U-INACTIVE | _test-inactive@constelmec.test | technician | Empresa A | Técnico con membresía desactivada — para T-50/T-51/T-52 |

> Convención: usar prefijo `_test-` para distinguir identidades de prueba de usuarios reales.

---

## 3. Datos base requeridos

Crear con U-PLATFORM (admin de plataforma) antes de ejecutar pruebas:

| Entidad | Cantidad | Detalles |
|---------|----------|---------|
| Empresas | 2 | Empresa A, Empresa B — ambas activas |
| Instalaciones | 2 por empresa | 1 activa, 1 inactiva por empresa |
| Portones | 2 por instalación | Ambos activos |
| Órdenes de servicio | 1 por empresa | Estado `scheduled` |
| Perfiles de técnico | 1 por empresa | Vinculados a U-A-TECH y U-B-TECH respectivamente |
| Asignaciones de técnico a orden | 1 por empresa | Técnico A asignado a orden A; Técnico B a orden B |
| QR emitido | 1 | Para un portón de Empresa A |
| Membresía inactiva | 1 | U-INACTIVE con membresía en Empresa A, `active=false` |

---

## 4. Escenarios de prueba

### Grupo 1 — Autenticación y enrutamiento

| ID | Escenario | Identidad | Resultado esperado | Tipo | Estado |
|----|-----------|-----------|-------------------|------|--------|
| T-01 | Login con credenciales válidas (admin) | U-A-ADM | Sesión activa, `role=admin`, `company_id` = ID de Empresa A | Manual | Pendiente |
| T-02 | Login con contraseña incorrecta | — | Error 400, sin sesión creada | Manual | Pendiente |
| T-03 | Acceder a URL de la app sin sesión activa | — | Redirige a pantalla de login | Manual | Pendiente |
| T-04 | Admin redirigido al panel de administración | U-A-ADM | `AdminControl.tsx` montado; nav muestra secciones de admin | Manual | Pendiente |
| T-05 | Técnico redirigido al portal de técnico | U-A-TECH | `TechnicianPortal.tsx` montado; sin acceso a secciones de admin | Manual | Pendiente |
| T-06 | Técnico no puede ver panel de admin navegando manualmente | U-A-TECH | Panel de admin no visible ni accesible; sin error 500 | Manual | Pendiente |
| T-07 | Platform admin redirigido a panel de plataforma | U-PLATFORM | `PlatformAdminControl.tsx` montado | Manual | Pendiente |

### Grupo 2 — Aislamiento de datos positivos (admin)

| ID | Escenario | Identidad | Resultado esperado | Tipo | Estado |
|----|-----------|-----------|-------------------|------|--------|
| T-10 | Admin A ve instalaciones de Empresa A únicamente | U-A-ADM | ≥1 fila con `company_id=A`; 0 filas de Empresa B | Manual | Pendiente |
| T-11 | Admin A ve técnicos de Empresa A únicamente | U-A-ADM | ≥1 fila con `company_id=A`; 0 filas de Empresa B | Manual | Pendiente |
| T-12 | Admin A ve contactos de Empresa A únicamente | U-A-ADM | ≥1 fila con `company_id=A`; 0 filas de Empresa B | Manual | Pendiente |
| T-13 | Admin A ve órdenes de servicio de Empresa A únicamente | U-A-ADM | ≥1 fila; todas con `company_id=A` | Manual | Pendiente |
| T-14 | Admin A puede emitir QR para portón de Empresa A | U-A-ADM | RPC devuelve token UUID, `gate_qr_codes` actualizado | Manual | Pendiente |

### Grupo 3 — Aislamiento de datos positivos (técnico)

| ID | Escenario | Identidad | Resultado esperado | Tipo | Estado |
|----|-----------|-----------|-------------------|------|--------|
| T-20 | Técnico A ve su propio perfil de técnico | U-A-TECH | 1 fila con `user_id` = auth.uid() de U-A-TECH | Manual | Pendiente |
| T-21 | Técnico A ve sus propias órdenes asignadas | U-A-TECH | ≥0 filas; todas con `technician_id` = perfil de U-A-TECH | Manual | Pendiente |
| T-22 | Técnico A ve portones de Empresa A | U-A-TECH | ≥1 fila de Empresa A via `useRealGates` hook | Manual | Pendiente |
| T-23 | `companyId` del técnico proviene de membresía, no de URL | U-A-TECH | Modificar URL no cambia qué empresa ve el técnico (siempre Empresa A) | Manual | Pendiente |

### Grupo 4 — Accesos cruzados negativos (técnico de A intenta acceder a datos de B)

#### 4a — Consultas directas (automatizadas en SQL)

| ID | Escenario | Identidad | Resultado esperado | Tipo | Referencia |
|----|-----------|-----------|-------------------|------|------------|
| T-30 | Técnico A lee `service_orders` de Empresa B por `company_id` | U-A-TECH | 0 filas (RLS bloquea) | Auto (SQL) | `test_migration_010.sql:T1a` |
| T-31 | Técnico A lee `service_orders` de B con UUID conocido | U-A-TECH | 0 filas | Auto (SQL) | `test_migration_010.sql:T1b` |
| T-32 | Técnico A lee `service_order_technicians` de B con UUID conocido | U-A-TECH | 0 filas | Auto (SQL) | `test_migration_010.sql:T1c` |
| T-33 | Técnico A lee `technician_profiles` de B con UUID conocido | U-A-TECH | 0 filas | Auto (SQL) | `test_migration_010.sql:T1d` |
| T-34 | Técnico A lee `company_contacts` de Empresa B | U-A-TECH | 0 filas | Auto (SQL) | `test_migration_010.sql:T1e` |
| T-35 | Técnico A lee `companies` para Empresa B | U-A-TECH | 0 filas | Auto (SQL) | `test_migration_010.sql:T1f` |

#### 4b — Llamadas a RPCs (pruebas manuales)

| ID | Escenario | Identidad | Resultado esperado | Tipo | Estado |
|----|-----------|-----------|-------------------|------|--------|
| T-36 | Técnico A llama `admin_create_company_contact` con `company_id` de B | U-A-TECH | Error 42501 — permission denied | Manual | Pendiente |
| T-37 | Técnico A llama `admin_create_facility` con `company_id` de B | U-A-TECH | Error 42501 | Manual | Pendiente |
| T-38 | Admin A llama `admin_assign_order_technician` con `company_id` de B | U-A-ADM | Error 42501 | Manual | Pendiente |
| T-39 | Admin A llama `admin_issue_gate_qr` con `company_id` de B | U-A-ADM | Error 42501 | Manual | Pendiente |

> Tests T-30 a T-35 están escritos pero aún **no ejecutados** en un entorno real. Requieren `supabase start` con migraciones 001–010 aplicadas.

### Grupo 5 — Revocación de acceso y sesiones

| ID | Escenario | Identidad | Resultado esperado | Tipo | Estado |
|----|-----------|-----------|-------------------|------|--------|
| T-50 | Desactivar membresía de técnico → operaciones RLS fallan | U-INACTIVE | SELECT devuelve 0 filas — `has_membership()` = false | Manual | Pendiente |
| T-51 | Técnico con membresía desactivada: JWT sigue válido hasta expiración | U-INACTIVE | Auth OK (sesión activa); DB rechaza operaciones. Ventana = hasta `jwt_expiry` (3600s) | Manual | Pendiente |
| T-52 | Técnico desactivado no ve sus propias asignaciones en `service_order_technicians` | U-INACTIVE | 0 filas — subquery `WHERE active limit 1` retorna NULL | Manual | Pendiente |

> T-51 documenta un comportamiento esperado (no un bug) — ver `03-security-audit.md` sección 7.1. Registrar como `KNOWN_BEHAVIOR` si se confirma.

### Grupo 6 — Regresión de build

| ID | Escenario | Resultado esperado | Tipo | Estado |
|----|-----------|-------------------|------|--------|
| T-60 | `npm run build` pasa TypeScript + Vite sin errores | Build exitoso, sin errores TS | Auto | **PASADO** — `4a01d48` en origin/main |
| T-61 | `test_migration_010.sql` ejecuta sin FAIL notices (12/12 PASS) | 12 PASS notices, 0 FAIL | Auto (SQL) | Escrito — pendiente ejecución en entorno |

---

## 5. Criterio de aprobación del Frente 6

Todos los siguientes deben cumplirse antes de cerrar el Frente 6:

- [ ] `npm run build` limpio (T-60) — **ya cumplido**
- [ ] Migraciones 001–010 aplicadas en entorno aislado (local `supabase start` o staging)
- [ ] `test_migration_010.sql` ejecutado → 12/12 PASS (T-61)
- [ ] T-01 a T-07 (autenticación/enrutamiento) → todos PASS
- [ ] T-20 a T-23 (técnico positivos) → todos PASS
- [ ] T-36 a T-39 (RPCs negativos de empresa cruzada) → todos PASS (42501)
- [ ] T-50 a T-52 (revocación) → todos documentados (PASS o KNOWN_BEHAVIOR)
- [ ] Cero GAPs de prioridad Crítica o Alta sin plan de remediación documentado

---

## 6. Estado actual de la cobertura

| Grupo | Total | Auto (escrito) | Manual | Ejecutados |
|-------|-------|---------------|--------|-----------|
| G1 — Autenticación | 7 | 0 | 7 | 0 |
| G2 — Admin positivos | 5 | 0 | 5 | 0 |
| G3 — Técnico positivos | 4 | 0 | 4 | 0 |
| G4a — Cruzados SQL | 6 | 6 | 0 | 0 |
| G4b — Cruzados RPC | 4 | 0 | 4 | 0 |
| G5 — Revocación | 3 | 0 | 3 | 0 |
| G6 — Regresión build | 2 | 2 | 0 | 1 (T-60) |
| **Total** | **31** | **8** | **23** | **1** |

**Bloqueo de aprobación:** Las 23 pruebas manuales y los 7 tests SQL no ejecutados requieren un entorno Supabase local o staging con migraciones 001–010 aplicadas. Sin ese entorno, el Frente 6 no puede cerrarse.

---

*Documento generado automáticamente. No contiene datos de producción ni credenciales.*
