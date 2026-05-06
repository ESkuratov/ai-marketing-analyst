-- Migration 006: Add pipeline/stage columns to staging.leads_normalized
-- Позволяет отслеживать этапы воронки AMO CRM в нормализованных данных

ALTER TABLE staging.leads_normalized
    ADD COLUMN IF NOT EXISTS pipeline_id BIGINT,
    ADD COLUMN IF NOT EXISTS stage_id BIGINT;
