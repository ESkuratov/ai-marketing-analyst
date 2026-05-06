-- Migration 011: Add client_id to event-based tables
-- Создаем связь событий с клиентом через UUID

-- ============================================================
-- 1. Добавляем client_id в staging.lead_events
-- ============================================================
ALTER TABLE staging.lead_events
    ADD COLUMN IF NOT EXISTS client_id UUID;

CREATE INDEX IF NOT EXISTS idx_lead_events_client_id
    ON staging.lead_events (client_id)
    WHERE client_id IS NOT NULL;

-- ============================================================
-- 2. Добавляем client_id в staging.lead_snapshots
-- ============================================================
ALTER TABLE staging.lead_snapshots
    ADD COLUMN IF NOT EXISTS client_id UUID;

CREATE INDEX IF NOT EXISTS idx_lead_snapshots_client_id
    ON staging.lead_snapshots (client_id)
    WHERE client_id IS NOT NULL;

-- ============================================================
-- 3. Индекс для JOIN между событиями и клиентами
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_lead_snapshots_client_valid
    ON staging.lead_snapshots (client_id, valid_from, valid_to)
    WHERE client_id IS NOT NULL;

-- ============================================================
-- 4. Обновляем внешний ключ (опционально, если нужна целостность)
-- ============================================================
-- Примечание: client_profiles может быть создан позже событий,
-- поэтому FK без ON DELETE для избежания циклических зависимостей

-- ALTER TABLE staging.lead_events
--     ADD CONSTRAINT fk_lead_events_client_profiles
--     FOREIGN KEY (studio_id, client_id) REFERENCES staging.client_profiles(studio_id, client_id);

-- ALTER TABLE staging.lead_snapshots
--     ADD CONSTRAINT fk_lead_snapshots_client_profiles
--     FOREIGN KEY (studio_id, client_id) REFERENCES staging.client_profiles(studio_id, client_id);

-- ============================================================
-- 5. Комментарии
-- ============================================================
COMMENT ON COLUMN staging.lead_events.client_id IS
    'UUID клиента из staging.client_profiles. NULL если телефон неизвестен.';

COMMENT ON COLUMN staging.lead_snapshots.client_id IS
    'UUID клиента для сквозного анализа по client_id вместо lead_id.';
