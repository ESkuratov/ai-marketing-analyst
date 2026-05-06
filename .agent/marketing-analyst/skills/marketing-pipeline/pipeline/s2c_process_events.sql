-- S2c: Process Events — генерация событий из raw-данных с client_id + stage mapping
-- Читает: raw.amo_leads, raw.yc_visits, ops.funnel_stages (для маппинга)
-- Пишет:  staging.lead_events (с client_id), staging.lead_snapshots (с client_id)
-- Параметр: %(studio_id)s, %(since)s (опционально, для backfill)

-- ============================================================
-- 0. Утилита: получить или создать client_id по телефону
-- ============================================================
WITH client_upsert AS (
    INSERT INTO staging.client_profiles (
        studio_id, client_phone, client_name, first_source, first_seen_at, last_seen_at
    )
    SELECT DISTINCT ON (aml.studio_id, aml.client_phone)
        aml.studio_id,
        aml.client_phone,
        aml.client_name,
        'amo'::varchar(50) AS first_source,
        aml.created_at AS first_seen_at,
        aml.updated_at AS last_seen_at
    FROM raw.amo_leads aml
    WHERE aml.studio_id = %(studio_id)s
      AND aml.client_phone IS NOT NULL
      AND (%(since)s::timestamptz IS NULL OR aml.created_at >= %(since)s::timestamptz)
      AND NOT EXISTS (
          SELECT 1 FROM staging.client_profiles cp
          WHERE cp.studio_id = aml.studio_id AND cp.client_phone = aml.client_phone
      )
    ON CONFLICT (studio_id, client_phone) DO NOTHING
    RETURNING studio_id, client_phone, client_id
),
yc_client_upsert AS (
    INSERT INTO staging.client_profiles (
        studio_id, client_phone, client_name, first_source, first_seen_at, last_seen_at
    )
    SELECT DISTINCT ON (ycv.studio_id, ycv.client_phone)
        ycv.studio_id,
        ycv.client_phone,
        ycv.client_name,
        'yclients'::varchar(50) AS first_source,
        (ycv.date + COALESCE(ycv.time, '00:00'::time))::timestamptz AS first_seen_at,
        (ycv.date + COALESCE(ycv.time, '00:00'::time))::timestamptz AS last_seen_at
    FROM raw.yc_visits ycv
    WHERE ycv.studio_id = %(studio_id)s
      AND ycv.client_phone IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM staging.client_profiles cp
          WHERE cp.studio_id = ycv.studio_id AND cp.client_phone = ycv.client_phone
      )
    ON CONFLICT (studio_id, client_phone) DO NOTHING
    RETURNING studio_id, client_phone, client_id
)
SELECT 1; -- CTE должно что-то вернуть

-- ============================================================
-- Stage Mapping Cache: маппинг AMO stage_id → наш stage_code
-- ============================================================
-- Создаем временную таблицу для быстрого lookup
-- NOTE: используем fallback на старые названия если маппинг не настроен

-- ============================================================
-- 1. Генерация событий из AMO CRM (status_changed) с client_id
-- Stage mapping: используем ops.funnel_stages для нормализации статусов
-- ============================================================
INSERT INTO staging.lead_events (
    studio_id,
    lead_id,
    source,
    client_id,
    client_phone,
    event_type,
    stage_from,
    stage_to,
    utm_source,
    utm_campaign,
    utm_medium,
    utm_content,
    utm_term,
    event_timestamp,
    raw_data
)
WITH ranked_amo AS (
    SELECT
        aml.*,
        cp.client_id,
        LAG(aml.status) OVER (PARTITION BY aml.studio_id, aml.id ORDER BY aml.updated_at) AS prev_status,
        -- Маппинг текущего статуса
        COALESCE(fs_to.stage_code, aml.status, 'unknown') AS mapped_stage_to,
        -- Маппинг предыдущего статуса (если есть)
        COALESCE(fs_from.stage_code, LAG(aml.status) OVER (PARTITION BY aml.studio_id, aml.id ORDER BY aml.updated_at), NULL) AS mapped_stage_from
    FROM raw.amo_leads aml
    LEFT JOIN staging.client_profiles cp
        ON cp.studio_id = aml.studio_id AND cp.client_phone = aml.client_phone
    LEFT JOIN ops.funnel_stages fs_to
        ON fs_to.amo_stage_id = aml.stage_id
        AND (fs_to.studio_id = aml.studio_id OR fs_to.studio_id = 'all')
    LEFT JOIN ops.funnel_stages fs_from
        ON fs_from.amo_stage_id = LAG(aml.stage_id) OVER (PARTITION BY aml.studio_id, aml.id ORDER BY aml.updated_at)
        AND (fs_from.studio_id = aml.studio_id OR fs_from.studio_id = 'all')
    WHERE aml.studio_id = %(studio_id)s
      AND aml.updated_at IS NOT NULL
      AND (%(since)s::timestamptz IS NULL OR aml.updated_at >= %(since)s::timestamptz)
)
SELECT
    studio_id,
    id AS lead_id,
    'amo' AS source,
    client_id,
    client_phone,
    'status_changed' AS event_type,
    mapped_stage_from AS stage_from,
    mapped_stage_to AS stage_to,
    utm_source,
    utm_campaign,
    utm_medium,
    utm_content,
    utm_term,
    updated_at AS event_timestamp,
    jsonb_build_object(
        'price', price,
        'pipeline_id', pipeline_id,
        'stage_id', stage_id,
        'raw_status', status,  -- оригинальный статус AMO
        'responsible_id', responsible_id,
        'raw_data', raw_data
    ) AS raw_data
FROM ranked_amo
-- Только если статус изменился (по mapped_stage или по raw status)
WHERE prev_status IS DISTINCT FROM status
   OR mapped_stage_from IS DISTINCT FROM mapped_stage_to
ON CONFLICT DO NOTHING;

-- ============================================================
-- 2. Генерация событий "created" для новых лидов AMO с client_id + stage mapping
-- ============================================================
INSERT INTO staging.lead_events (
    studio_id,
    lead_id,
    source,
    client_id,
    client_phone,
    event_type,
    stage_from,
    stage_to,
    utm_source,
    utm_campaign,
    utm_medium,
    utm_content,
    utm_term,
    event_timestamp,
    raw_data
)
SELECT
    aml.studio_id,
    aml.id AS lead_id,
    'amo' AS source,
    cp.client_id,
    aml.client_phone,
    'created' AS event_type,
    NULL AS stage_from,
    -- Маппинг начального статуса через funnel_stages
    COALESCE(fs.stage_code, aml.status, 'new') AS stage_to,
    aml.utm_source,
    aml.utm_campaign,
    aml.utm_medium,
    aml.utm_content,
    aml.utm_term,
    aml.created_at AS event_timestamp,
    jsonb_build_object(
        'price', aml.price,
        'pipeline_id', aml.pipeline_id,
        'stage_id', aml.stage_id,
        'raw_status', aml.status,
        'responsible_id', aml.responsible_id,
        'client_name', aml.client_name,
        'raw_data', aml.raw_data
    ) AS raw_data
FROM raw.amo_leads aml
LEFT JOIN staging.client_profiles cp
    ON cp.studio_id = aml.studio_id AND cp.client_phone = aml.client_phone
LEFT JOIN ops.funnel_stages fs
    ON fs.amo_stage_id = aml.stage_id
    AND (fs.studio_id = aml.studio_id OR fs.studio_id = 'all')
WHERE aml.studio_id = %(studio_id)s
  AND (%(since)s::timestamptz IS NULL OR aml.created_at >= %(since)s::timestamptz)
  -- Только если нет предыдущих событий для этого лида
  AND NOT EXISTS (
      SELECT 1 FROM staging.lead_events e
      WHERE e.studio_id = aml.studio_id
        AND e.lead_id = aml.id
        AND e.source = 'amo'
        AND e.event_type = 'created'
  )
ON CONFLICT DO NOTHING;

-- ============================================================
-- 3. Генерация событий из YClients с client_id + stage mapping
-- Маппим ycv.status на ops.funnel_stages.stage_code
-- ============================================================
INSERT INTO staging.lead_events (
    studio_id,
    lead_id,
    source,
    client_id,
    client_phone,
    event_type,
    stage_from,
    stage_to,
    utm_source,
    event_timestamp,
    raw_data
)
SELECT
    ycv.studio_id,
    ycv.id AS lead_id,
    'yclients' AS source,
    cp.client_id,
    ycv.client_phone,
    CASE
        WHEN ycv.status = 'visited' THEN 'visit_completed'
        WHEN ycv.status = 'canceled' THEN 'visit_canceled'
        WHEN ycv.status = 'no_show' THEN 'no_show'
        ELSE 'booking_created'
    END AS event_type,
    NULL AS stage_from,
    -- Маппинг статуса YClients на наш stage_code
    COALESCE(fs.stage_code, ycv.status, 'booking_created') AS stage_to,
    NULL AS utm_source,
    (ycv.date + COALESCE(ycv.time, '00:00'::time))::timestamptz AS event_timestamp,
    jsonb_build_object(
        'service_id', ycv.service_id,
        'service_name', ycv.service_name,
        'master_id', ycv.master_id,
        'master_name', ycv.master_name,
        'sum', ycv.sum,
        'discount', ycv.discount,
        'is_first_visit', ycv.is_first_visit,
        'raw_status', ycv.status,
        'comment', ycv.comment
    ) AS raw_data
FROM raw.yc_visits ycv
LEFT JOIN staging.client_profiles cp
    ON cp.studio_id = ycv.studio_id AND cp.client_phone = ycv.client_phone
LEFT JOIN ops.funnel_stages fs
    ON fs.stage_code = CASE
        WHEN ycv.status = 'visited' THEN 'visited'
        WHEN ycv.status = 'canceled' THEN 'canceled'
        WHEN ycv.status = 'no_show' THEN 'no_show'
        ELSE 'booking_made'
    END
    AND (fs.studio_id = ycv.studio_id OR fs.studio_id = 'all')
WHERE ycv.studio_id = %(studio_id)s
  AND (%(since)s::timestamptz IS NULL
       OR (ycv.date + COALESCE(ycv.time, '00:00'::time))::timestamptz >= %(since)s::timestamptz)
  -- Предотвращаем дубликаты
  AND NOT EXISTS (
      SELECT 1 FROM staging.lead_events e
      WHERE e.studio_id = ycv.studio_id
        AND e.lead_id = ycv.id
        AND e.source = 'yclients'
        AND e.event_type = CASE
            WHEN ycv.status = 'visited' THEN 'visit_completed'
            WHEN ycv.status = 'canceled' THEN 'visit_canceled'
            WHEN ycv.status = 'no_show' THEN 'no_show'
            ELSE 'booking_created'
        END
  )
ON CONFLICT DO NOTHING;

-- ============================================================
-- 4. Создание snapshots из events с client_id (SCD Type 2)
-- ============================================================
INSERT INTO staging.lead_snapshots (
    studio_id,
    lead_id,
    source,
    client_id,
    valid_from,
    valid_to,
    stage_name,
    utm_source,
    utm_campaign,
    utm_medium,
    utm_content,
    utm_term,
    amount,
    is_first_visit,
    client_phone,
    event_id
)
WITH events_ordered AS (
    SELECT
        e.*,
        LEAD(event_timestamp) OVER (
            PARTITION BY studio_id, lead_id, source
            ORDER BY event_timestamp
        ) AS next_timestamp
    FROM staging.lead_events e
    WHERE e.studio_id = %(studio_id)s
      AND (%(since)s::timestamptz IS NULL OR e.event_timestamp >= %(since)s::timestamptz)
)
SELECT
    studio_id,
    lead_id,
    source,
    client_id,
    event_timestamp AS valid_from,
    next_timestamp AS valid_to,
    stage_to AS stage_name,
    utm_source,
    utm_campaign,
    utm_medium,
    utm_content,
    utm_term,
    (raw_data->>'price')::numeric AS amount,
    COALESCE((raw_data->>'is_first_visit')::boolean, FALSE) AS is_first_visit,
    client_phone,
    event_id
FROM events_ordered
-- Предотвращаем дубликаты snapshots
WHERE NOT EXISTS (
    SELECT 1 FROM staging.lead_snapshots s
    WHERE s.event_id = events_ordered.event_id
)
ON CONFLICT DO NOTHING;

-- ============================================================
-- 5. Обновление valid_to для предыдущих snapshots (close open intervals)
-- ============================================================
UPDATE staging.lead_snapshots s
SET valid_to = snap.next_valid_from
FROM (
    SELECT
        studio_id,
        lead_id,
        source,
        valid_from,
        LEAD(valid_from) OVER (
            PARTITION BY studio_id, lead_id, source
            ORDER BY valid_from
        ) AS next_valid_from
    FROM staging.lead_snapshots
    WHERE studio_id = %(studio_id)s
) snap
WHERE s.studio_id = snap.studio_id
  AND s.lead_id = snap.lead_id
  AND s.source = snap.source
  AND s.valid_from = snap.valid_from
  AND snap.next_valid_from IS NOT NULL
  AND (s.valid_to IS NULL OR s.valid_to != snap.next_valid_from);
