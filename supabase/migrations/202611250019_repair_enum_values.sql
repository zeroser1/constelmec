-- Migration 019: Add resolved, partial, critical to control_result enum.
--
-- Only ALTER TYPE ADD VALUE — no table or RPC changes in this migration.
-- PostgreSQL 14+: new enum values cannot be referenced in the same transaction
-- they are added in. Migration 020 (table + RPCs) must run in a separate
-- transaction after this one commits.
--
-- Do NOT apply to production without authorization.

ALTER TYPE public.control_result ADD VALUE IF NOT EXISTS 'resolved';
ALTER TYPE public.control_result ADD VALUE IF NOT EXISTS 'partial';
ALTER TYPE public.control_result ADD VALUE IF NOT EXISTS 'critical';
