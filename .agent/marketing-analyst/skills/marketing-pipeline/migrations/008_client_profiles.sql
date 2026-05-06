-- Migration 008: Client profiles table
-- Одна строка — один клиент (уникальный телефон в пределах студии)
-- Позволяет отслеживать сквозную воронку по клиенту, а не по источнику

CREATE TABLE IF NOT EXISTS staging.client_profiles (
    client_id       UUID DEFAULT gen_random_uuid(),
    studio_id       VARCHAR(50) NOT NULL,
    client_phone    VARCHAR(50),
    client_name     VARCHAR(255),
    first_source    VARCHAR(50),        -- amo / yclients / gsheets
    first_seen_at   TIMESTAMPTZ,
    last_seen_at    TIMESTAMPTZ,
    funnel_stage    VARCHAR(100),
    total_visits    INT DEFAULT 0,
    total_revenue   NUMERIC(12,2) DEFAULT 0,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (studio_id, client_id)
);

CREATE INDEX IF NOT EXISTS idx_client_profiles_phone
    ON staging.client_profiles (studio_id, client_phone);

-- Добавляем client_id в leads_normalized
ALTER TABLE staging.leads_normalized
    ADD COLUMN IF NOT EXISTS client_id UUID;
