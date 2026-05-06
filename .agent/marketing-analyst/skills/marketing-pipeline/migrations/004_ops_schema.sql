-- Migration 004: Ops schema — конфигурация студий, алерты, HITL-gates
-- Независимая миграция (не зависит от raw/staging/metrics)

CREATE SCHEMA IF NOT EXISTS ops;

-- ============================================================
-- Table: ops.studios — регистр студий
-- ============================================================
CREATE TABLE IF NOT EXISTS ops.studios (
    studio_id       VARCHAR(50) PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    yc_company_id   BIGINT,                          -- ID компании в YClients
    amo_domain      VARCHAR(255),                    -- поддомен AMO CRM
    amo_pipeline_id BIGINT,                          -- ID воронки в AMO
    gs_sheet_id     VARCHAR(255),                    -- ID Google Sheets
    timezone        VARCHAR(50) DEFAULT 'Europe/Moscow',
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- Table: ops.active_alerts — активные алерты (A01-A04)
-- ============================================================
CREATE TABLE IF NOT EXISTS ops.active_alerts (
    id              SERIAL PRIMARY KEY,
    studio_id       VARCHAR(50) NOT NULL,
    alert_type      VARCHAR(10) NOT NULL,            -- A01 / A02 / A03 / A04
    severity        VARCHAR(20) NOT NULL,             -- warning / critical
    metric_name     VARCHAR(100),                     -- conversion_lead_to_booking / no_show_rate / cac / discrepancy
    metric_value    NUMERIC(12, 2),
    threshold       NUMERIC(12, 2),
    recommendation  TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ                      -- NULL = активен
);

CREATE INDEX IF NOT EXISTS idx_active_alerts_studio
    ON ops.active_alerts (studio_id);

CREATE INDEX IF NOT EXISTS idx_active_alerts_active
    ON ops.active_alerts (resolved_at)
    WHERE resolved_at IS NULL;

-- ============================================================
-- Table: ops.gates — HITL-gates (только для A04)
-- Блокирует pipeline для студии, пока не подтверждён
-- ============================================================
CREATE TABLE IF NOT EXISTS ops.gates (
    id              SERIAL PRIMARY KEY,
    alert_id        INTEGER REFERENCES ops.active_alerts(id) ON DELETE CASCADE,
    studio_id       VARCHAR(50) NOT NULL,
    alert_type      VARCHAR(10) NOT NULL DEFAULT 'A04',
    status          VARCHAR(20) NOT NULL DEFAULT 'open',   -- open / acknowledged / resolved
    ack_by          VARCHAR(100),                           -- кто подтвердил
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ                             -- NULL = gate активен
);

CREATE INDEX IF NOT EXISTS idx_gates_open
    ON ops.gates (studio_id, status)
    WHERE status = 'open';

-- ============================================================
-- Table: ops.config — пороги и настройки (per-studio или общие)
-- ============================================================
CREATE TABLE IF NOT EXISTS ops.config (
    key             VARCHAR(100) NOT NULL,
    studio_id       VARCHAR(50) NOT NULL DEFAULT 'all',     -- 'all' = общий порог
    value           JSONB NOT NULL,
    description     TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (key, studio_id)
);

-- ============================================================
-- Default config values
-- ============================================================
INSERT INTO ops.config (key, studio_id, value, description) VALUES
    ('alert_thresholds', 'all', '{
        "A01_max_no_show_rate": 30,
        "A01_min_conversion_lead_to_booking": 30,
        "A02_max_no_show_rate_7d": 25,
        "A03_max_cac_deviation_pct": 20,
        "A04_max_discrepancy_pct": 10
    }'::jsonb, 'Пороги срабатывания алертов A01-A04'),
    ('pipeline_settings', 'all', '{
        "daily_report_time": "22:30",
        "weekly_report_day": 1,
        "weekly_report_time": "14:00",
        "monthly_report_day": 1,
        "monthly_report_time": "11:00",
        "alert_scan_interval_hours": 4
    }'::jsonb, 'Настройки расписания pipeline')
ON CONFLICT (key, studio_id) DO NOTHING;
