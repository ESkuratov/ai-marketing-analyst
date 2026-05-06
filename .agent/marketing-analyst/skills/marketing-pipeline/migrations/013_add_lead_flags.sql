-- Migration 013: Add lead validation flags and per-stage alert thresholds
-- Добавляет phone_valid и ad_channel_unknown в staging.leads_normalized
-- Добавляет пороги per-stage алертов A05-A14 в ops.config

-- ============================================================
-- 1. Новые колонки в staging.leads_normalized
-- ============================================================
ALTER TABLE staging.leads_normalized
    ADD COLUMN IF NOT EXISTS phone_valid BOOLEAN DEFAULT TRUE;

ALTER TABLE staging.leads_normalized
    ADD COLUMN IF NOT EXISTS ad_channel_unknown BOOLEAN DEFAULT FALSE;

-- ============================================================
-- 2. Пороги для per-stage алертов
-- ============================================================
INSERT INTO ops.config (key, studio_id, value, description) VALUES
    ('alert_thresholds_stage', 'all', '{
        "A05_max_negotiation_days": 7,
        "A06_max_no_answer_days": 5,
        "A07_appointment_check_enabled": true,
        "A08_visit_mismatch_check_enabled": true,
        "A09_visit_no_purchase_check_enabled": true,
        "A10_max_revenue_discrepancy_pct": 10,
        "A11_max_deposit_discrepancy_pct": 5,
        "A12_max_closure_rate_pct": 30
    }'::jsonb, 'Пороги для per-stage алертов A05-A14')
ON CONFLICT (key, studio_id) DO NOTHING;
