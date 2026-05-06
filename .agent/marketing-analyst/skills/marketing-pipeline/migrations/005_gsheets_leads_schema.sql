-- Migration 005: GSheets leads schema — лиды из рекламных каналов
-- Отдельная таблица для данных из Google Sheets (GS_LEADS_SHEET_ID)

CREATE SCHEMA IF NOT EXISTS raw;

-- ============================================================
-- Table: raw.gsheets_leads — лиды из рекламных каналов
-- Источники: ВК, РСЯ, Сайт, Instagram и т.д.
-- ============================================================
CREATE TABLE IF NOT EXISTS raw.gsheets_leads (
    id              SERIAL,
    studio_id       VARCHAR(50) NOT NULL,
    deal_id         BIGINT,                    -- ID сделки из таблицы
    source_name     VARCHAR(255),              -- Источник (ВК, РСЯ, Сайт...)
    utm_source      VARCHAR(255),              -- маппинг source_name
    utm_campaign    VARCHAR(255),              -- Акция\Форма
    client_name     VARCHAR(255),
    client_phone    VARCHAR(50),
    studio_name     VARCHAR(255),              -- сырое название студии
    created_at      TIMESTAMPTZ NOT NULL,
    raw_data        JSONB,
    loaded_at       TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, id)
);

CREATE INDEX IF NOT EXISTS idx_gsheets_leads_studio_created
    ON raw.gsheets_leads (studio_id, created_at DESC);
