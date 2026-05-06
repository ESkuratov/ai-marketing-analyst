-- Migration 012: Funnel stages reference table
-- Единый справочник этапов воронки с порядком следования и категориями

-- ============================================================
-- Table: ops.funnel_stages — справочник этапов воронки
-- ============================================================
CREATE TABLE IF NOT EXISTS ops.funnel_stages (
    stage_id        SERIAL PRIMARY KEY,
    studio_id       VARCHAR(50) NOT NULL DEFAULT 'all',  -- 'all' = для всех студий

    -- Идентификация этапа
    stage_code      VARCHAR(100) NOT NULL,                -- технический код (new, negotiation, etc)
    stage_name      VARCHAR(255) NOT NULL,                -- человекочитаемое название

    -- Порядок и группировка
    stage_order     INTEGER DEFAULT 0,                   -- порядок в воронке (0, 1, 2...)
    stage_group     VARCHAR(50) NOT NULL,                -- new / active / closed / lost

    -- Сопоставление с внешними системами
    amo_stage_id    BIGINT,                             -- ID статуса в AMO CRM
    amo_pipeline_id BIGINT,                             -- ID воронки в AMO (если разные)

    -- Визуализация
    color           VARCHAR(7) DEFAULT '#6366f1',         -- цвет для UI (#hex)
    is_visible      BOOLEAN DEFAULT TRUE,                -- показывать в отчетах?

    -- Описание и логика
    description     TEXT,                               -- описание этапа
    exit_criteria   TEXT,                               -- критерии перехода на следующий этап

    -- Метаданные
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),

    -- Constraints
    UNIQUE (studio_id, stage_code),
    CONSTRAINT chk_stage_group CHECK (stage_group IN ('new', 'active', 'closed_won', 'closed_lost', 'paused'))
);

-- Индексы
CREATE INDEX IF NOT EXISTS idx_funnel_stages_studio_order
    ON ops.funnel_stages (studio_id, stage_order);

CREATE INDEX IF NOT EXISTS idx_funnel_stages_amo
    ON ops.funnel_stages (amo_stage_id, amo_pipeline_id)
    WHERE amo_stage_id IS NOT NULL;

-- ============================================================
-- Default stages (общие для всех студий)
-- ============================================================
INSERT INTO ops.funnel_stages (stage_code, stage_name, stage_order, stage_group, description) VALUES
    ('new', 'Новый лид', 0, 'new', 'Только что создан, еще не обработан'),
    ('contacted', 'Контакт установлен', 1, 'active', 'Менеджер связался с клиентом'),
    ('negotiation', 'Переговоры', 2, 'active', 'Обсуждение услуг и цен'),
    ('booking_made', 'Запись создана', 3, 'active', 'Клиент записан на прием'),
    ('visited', 'Визит состоялся', 4, 'closed_won', 'Клиент пришел на массаж'),
    ('abonement_sold', 'Абонемент продан', 5, 'closed_won', 'Продана подписка/абонемент'),
    ('no_show', 'Неявка', 99, 'closed_lost', 'Клиент не пришел на запись'),
    ('canceled', 'Отмена', 99, 'closed_lost', 'Клиент отменил запись'),
    ('lost', 'Потерян', 99, 'closed_lost', 'Клиент не отвечает/отказался'),
    ('duplicate', 'Дубликат', 100, 'paused', 'Дубль существующего лида')
ON CONFLICT (studio_id, stage_code) DO UPDATE SET
    stage_name = EXCLUDED.stage_name,
    stage_order = EXCLUDED.stage_order,
    stage_group = EXCLUDED.stage_group,
    description = EXCLUDED.description,
    updated_at = NOW();

-- ============================================================
-- View: для удобного использования в запросах
-- ============================================================
CREATE OR REPLACE VIEW ops.v_funnel_stages AS
SELECT
    stage_id,
    studio_id,
    stage_code,
    stage_name,
    stage_order,
    stage_group,
    CASE stage_group
        WHEN 'new' THEN 1
        WHEN 'active' THEN 2
        WHEN 'closed_won' THEN 3
        WHEN 'closed_lost' THEN 4
        WHEN 'paused' THEN 5
    END AS group_order,
    amo_stage_id,
    amo_pipeline_id,
    color,
    is_visible,
    description,
    exit_criteria
FROM ops.funnel_stages
WHERE is_visible = TRUE
ORDER BY stage_order;

-- ============================================================
-- Function: обновление updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION ops.update_funnel_stages_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_funnel_stages_updated_at ON ops.funnel_stages;
CREATE TRIGGER trg_funnel_stages_updated_at
    BEFORE UPDATE ON ops.funnel_stages
    FOR EACH ROW
    EXECUTE FUNCTION ops.update_funnel_stages_updated_at();

-- ============================================================
-- Comments
-- ============================================================
COMMENT ON TABLE ops.funnel_stages IS
    'Справочник этапов воронки продаж. Определяет порядок следования и группировку этапов.';

COMMENT ON COLUMN ops.funnel_stages.stage_code IS
    'Уникальный код этапа (snake_case), используется в staging.lead_events.stage_from/to';

COMMENT ON COLUMN ops.funnel_stages.stage_group IS
    'Группа: new (новые), active (в работе), closed_won (успех), closed_lost (провал), paused (приостановлено)';
