-- Migration 002: Staging schema — нормализованные и дедуплицированные данные
-- Зависит от: 001_raw_schema.sql (читает из raw.*, пишет в staging.*)

CREATE SCHEMA IF NOT EXISTS staging;

-- ============================================================
-- Table: staging.leads_normalized — единая модель лида
-- Нормализация из raw.amo_leads + raw.yc_visits + raw.gs_expenses
-- ============================================================
CREATE TABLE IF NOT EXISTS staging.leads_normalized (
    studio_id           VARCHAR(50) NOT NULL,
    lead_id             BIGINT NOT NULL,          -- ID из источника
    source              VARCHAR(50) NOT NULL,       -- amo / yclients / gsheets
    status              VARCHAR(100),
    funnel_stage        VARCHAR(100),               -- этап воронки

    -- UTM-метки
    utm_source          VARCHAR(255),
    utm_campaign        VARCHAR(255),
    utm_medium          VARCHAR(255),
    utm_content         VARCHAR(255),
    utm_term            VARCHAR(255),

    -- Дата и время
    created_at          TIMESTAMPTZ NOT NULL,
    updated_at          TIMESTAMPTZ,
    closed_at           TIMESTAMPTZ,

    -- Связь с другими источниками
    yc_booking_id       BIGINT,
    booking_date        DATE,
    visit_date          DATE,
    visit_status        VARCHAR(50),               -- visited / not_visited / canceled

    -- Финансы
    amount              NUMERIC(12, 2),
    abonement_type      VARCHAR(100),

    -- Флаги
    is_repeat           BOOLEAN DEFAULT FALSE,      -- повторный клиент
    is_first_visit      BOOLEAN DEFAULT FALSE,
    created_by_admin    BOOLEAN DEFAULT FALSE,      -- лид создан вручную (не через запись)

    -- Технические поля
    raw_amo_id          BIGINT,
    raw_yc_id           BIGINT,
    loaded_at           TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, lead_id, source)
);

CREATE INDEX IF NOT EXISTS idx_leads_normalized_studio_date
    ON staging.leads_normalized (studio_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_leads_normalized_studio_stage
    ON staging.leads_normalized (studio_id, funnel_stage);

CREATE INDEX IF NOT EXISTS idx_leads_normalized_studio_utm
    ON staging.leads_normalized (studio_id, utm_source, utm_campaign);

