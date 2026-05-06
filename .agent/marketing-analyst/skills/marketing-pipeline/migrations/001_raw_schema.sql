-- Migration 001: Raw schema — сырые данные из источников
-- Создаётся до staging/metrics/ops, т.к. коннекторы пишут сразу в raw

CREATE SCHEMA IF NOT EXISTS raw;

-- ============================================================
-- Table: raw.amo_leads — лиды из AMO CRM
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.amo_leads (
    id              BIGINT NOT NULL,
    studio_id       VARCHAR(50) NOT NULL,
    source          VARCHAR(255),
    status          VARCHAR(100),
    utm_source      VARCHAR(255),
    utm_campaign    VARCHAR(255),
    utm_medium      VARCHAR(255),
    utm_content     VARCHAR(255),
    utm_term        VARCHAR(255),
    pipeline_id     BIGINT,
    stage_id        BIGINT,
    responsible_id  BIGINT,
    created_at      TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ,
    closed_at       TIMESTAMPTZ,
    price           NUMERIC(12, 2),
    client_name     VARCHAR(255),
    client_phone    VARCHAR(50),
    raw_data        JSONB,
    loaded_at       TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, id)
);

CREATE INDEX IF NOT EXISTS idx_amo_leads_studio_created
    ON raw.amo_leads (studio_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_amo_leads_studio_status
    ON raw.amo_leads (studio_id, status);

-- ============================================================
-- Table: raw.yc_visits — записи/визиты из YClients
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.yc_visits (
    id              BIGINT NOT NULL,
    studio_id       VARCHAR(50) NOT NULL,
    client_id       BIGINT,
    client_name     VARCHAR(255),
    client_phone    VARCHAR(50),
    service_id      BIGINT,
    service_name    VARCHAR(255),
    master_id       BIGINT,
    master_name     VARCHAR(255),
    date            DATE NOT NULL,
    time            TIME,
    sum             NUMERIC(12, 2),
    discount        NUMERIC(12, 2),
    status          VARCHAR(50),      -- visited / not_visited / canceled
    is_first_visit  BOOLEAN DEFAULT FALSE,
    comment         TEXT,
    raw_data        JSONB,
    loaded_at       TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, id)
);

CREATE INDEX IF NOT EXISTS idx_yc_visits_studio_date
    ON raw.yc_visits (studio_id, date DESC);

CREATE INDEX IF NOT EXISTS idx_yc_visits_studio_status
    ON raw.yc_visits (studio_id, status);

-- ============================================================
-- Table: raw.gs_expenses — расходы из Google Sheets
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.gs_expenses (
    id              SERIAL,
    studio_id       VARCHAR(50) NOT NULL,
    date            DATE NOT NULL,
    article         VARCHAR(255) NOT NULL,   -- статья расходов
    amount          NUMERIC(12, 2) NOT NULL,
    channel         VARCHAR(100),             -- канал трафика (для маркетинговых)
    description     TEXT,
    raw_data        JSONB,
    loaded_at       TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, id)
);

CREATE INDEX IF NOT EXISTS idx_gs_expenses_studio_date
    ON raw.gs_expenses (studio_id, date DESC);

CREATE INDEX IF NOT EXISTS idx_gs_expenses_studio_article
    ON raw.gs_expenses (studio_id, article);
