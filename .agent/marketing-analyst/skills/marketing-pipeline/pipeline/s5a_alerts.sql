-- S5a: Alerts — проверка алертов A01-A04
-- Читает: metrics.daily_summary, metrics.channel_roi
-- Пишет:  ops.active_alerts
-- Параметр: %(studio_id)s

-- ============================================================
-- A01: Конверсия лид→запись < 30%% три дня подряд
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s,
    'A01' AS alert_type,
    'warning' AS severity,
    'conversion_lead_to_booking' AS metric_name,
    recent.conversion_avg,
    30 AS threshold,
    'Конверсия лид→запись < 30%% уже '
    || recent.consecutive_days || ' дня подряд. '
    || 'Проверьте качество лидов или процесс обработки.'
FROM (
    WITH daily_conv AS (
        SELECT
            date,
            conversion_lead_to_booking,
            CASE WHEN conversion_lead_to_booking < 30 THEN 1 ELSE 0 END AS below_threshold
        FROM metrics.daily_summary
        WHERE studio_id = %(studio_id)s
          AND channel = 'all'
          AND conversion_lead_to_booking IS NOT NULL
        ORDER BY date DESC
        LIMIT 5
    ),
    streak AS (
        SELECT
            date,
            conversion_lead_to_booking,
            below_threshold,
            SUM(below_threshold) OVER (ORDER BY date DESC ROWS UNBOUNDED PRECEDING) AS streak_days
        FROM daily_conv
        WHERE below_threshold = 1
    )
    SELECT
        COUNT(*) AS consecutive_days,
        ROUND(AVG(conversion_lead_to_booking), 2) AS conversion_avg
    FROM streak
    HAVING COUNT(*) >= 3
) recent
WHERE NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s
      AND a.alert_type = 'A01'
      AND a.resolved_at IS NULL
);

-- ============================================================
-- A02: Неявки > порога за 7 дней
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s,
    'A02' AS alert_type,
    'warning' AS severity,
    'no_show_rate_7d' AS metric_name,
    ROUND(AVG(ds.no_show_rate), 2) AS avg_no_show_7d,
    (cfg.value->>'A02_max_no_show_rate_7d')::numeric AS threshold,
    'Доля неявок за 7 дней: '
    || ROUND(AVG(ds.no_show_rate), 2) || '%%'
    || '. Превышает допустимый порог.'
FROM metrics.daily_summary ds
CROSS JOIN ops.config cfg
WHERE ds.studio_id = %(studio_id)s
  AND ds.channel = 'all'
  AND ds.date >= NOW()::date - 7
  AND ds.no_show_rate IS NOT NULL
  AND cfg.key = 'alert_thresholds'
  AND (cfg.studio_id = %(studio_id)s OR cfg.studio_id = 'all')
GROUP BY cfg.value
HAVING AVG(ds.no_show_rate) > COALESCE(
    (cfg.value->>'A02_max_no_show_rate_7d')::numeric,
    25
)
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A02' AND a.resolved_at IS NULL
);

-- ============================================================
-- A03: CAC канала > средний + 20%%
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
WITH channel_cac AS (
    SELECT
        channel,
        cac
    FROM metrics.channel_roi
    WHERE studio_id = %(studio_id)s
      AND cac IS NOT NULL
      AND month >= date_trunc('month', NOW() - interval '2 months')
),
avg_cac AS (
    SELECT AVG(cac) AS overall_avg_cac FROM channel_cac
)
SELECT
    %(studio_id)s,
    'A03' AS alert_type,
    'warning' AS severity,
    'cac_' || cc.channel,
    cc.cac,
    overall_avg_cac * 1.2 AS threshold_value,
    'CAC канала "' || cc.channel || '" (' || cc.cac
    || ') превышает средний +20%% (' || ROUND(overall_avg_cac * 1.2, 2) || ').'
FROM channel_cac cc, avg_cac ac
WHERE cc.cac > ac.overall_avg_cac * 1.2
  AND NOT EXISTS (
      SELECT 1 FROM ops.active_alerts a
      WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A03' AND a.resolved_at IS NULL
  )
LIMIT 5;

-- ============================================================
-- A04: Расхождение AMO↔YC > 10%%
-- Создаёт HITL gate — блокирует pipeline до подтверждения
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s,
    'A04' AS alert_type,
    'critical' AS severity,
    'amo_vs_yclients_discrepancy' AS metric_name,
    discrepancy_pct,
    10 AS threshold,
    CASE WHEN discrepancy_pct > 10
        THEN '🔴 HITL: расхождение AMO↔YC ' || discrepancy_pct
             || '%% — pipeline заблокирован. '
             || 'Проверьте данные и подтвердите в Telegram.'
        ELSE 'OK'
    END
FROM (
    WITH counts AS (
        SELECT
            COUNT(*) FILTER (WHERE source = 'amo') AS amo_count,
            COUNT(*) FILTER (WHERE source = 'yclients') AS yc_count
        FROM staging.leads_normalized
        WHERE studio_id = %(studio_id)s
          AND created_at >= NOW() - interval '30 days'
    )
    SELECT
        CASE
            WHEN amo_count = 0 AND yc_count = 0 THEN 0
            WHEN amo_count = 0 THEN 100
            ELSE ROUND(
                ABS(amo_count - yc_count)::numeric
                / GREATEST(amo_count, 1) * 100, 2
            )
        END AS discrepancy_pct
    FROM counts
) calc
WHERE discrepancy_pct > 10
  AND NOT EXISTS (
      SELECT 1 FROM ops.active_alerts a
      WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A04' AND a.resolved_at IS NULL
  );

-- ============================================================
-- A05: Клиент завис в «Переговорах» > N дней
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A05', 'warning',
    'negotiation_stuck_count', COUNT(DISTINCT ln.lead_id),
    COALESCE((cfg.value->>'A05_max_negotiation_days')::int, 7),
    'Клиентов зависло в переговорах > '
    || COALESCE((cfg.value->>'A05_max_negotiation_days')::int, 7)
    || ' дней: ' || COUNT(DISTINCT ln.lead_id)
    || '. Проверьте статусы в AMO.'
FROM staging.leads_normalized ln
CROSS JOIN LATERAL (
    SELECT value FROM ops.config
    WHERE key = 'alert_thresholds_stage'
      AND (studio_id = %(studio_id)s OR studio_id = 'all')
    LIMIT 1
) cfg
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'negotiation'
  AND ln.created_at < NOW() - (COALESCE((cfg.value->>'A05_max_negotiation_days')::int, 7) || ' days')::interval
  AND ln.closed_at IS NULL
GROUP BY cfg.value
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A05' AND a.resolved_at IS NULL
);

-- ============================================================
-- A06: Клиент потерян («не взяли трубку» > N дней)
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A06', 'warning',
    'no_answer_lost_count', COUNT(DISTINCT ln.lead_id),
    COALESCE((cfg.value->>'A06_max_no_answer_days')::int, 5),
    'Клиентов не берут трубку > '
    || COALESCE((cfg.value->>'A06_max_no_answer_days')::int, 5)
    || ' дней: ' || COUNT(DISTINCT ln.lead_id)
    || '. Возможно, клиент потерян.'
FROM staging.leads_normalized ln
CROSS JOIN LATERAL (
    SELECT value FROM ops.config
    WHERE key = 'alert_thresholds_stage'
      AND (studio_id = %(studio_id)s OR studio_id = 'all')
    LIMIT 1
) cfg
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'no_answer'
  AND ln.updated_at < NOW() - (COALESCE((cfg.value->>'A06_max_no_answer_days')::int, 5) || ' days')::interval
  AND ln.closed_at IS NULL
GROUP BY cfg.value
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A06' AND a.resolved_at IS NULL
);

-- ============================================================
-- A07: Назначен визит в AMO, но нет записи в YC
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A07', 'warning',
    'appointment_no_yc_count', COUNT(DISTINCT ln.lead_id),
    NULL,
    'Назначен визит в AMO без записи в YClients: ' || COUNT(DISTINCT ln.lead_id)
    || ' клиентов. Проверьте, создана ли запись.'
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'appointment'
  AND ln.yc_booking_id IS NULL
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A07' AND a.resolved_at IS NULL
);

-- ============================================================
-- A08: Расхождение статуса визита (AMO no_show, YC visited)
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A08', 'warning',
    'visit_mismatch_count', COUNT(DISTINCT ln.lead_id),
    NULL,
    'Расхождение статуса: AMO «не пришла», но YClients «visited» — '
    || COUNT(DISTINCT ln.lead_id) || ' клиентов.'
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'no_show'
  AND ln.visit_status = 'visited'
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A08' AND a.resolved_at IS NULL
);

-- ============================================================
-- A09: Визит был, но покупки нет (AMO not_bought, YC visited)
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A09', 'info',
    'visit_no_purchase_count', COUNT(DISTINCT ln.lead_id),
    NULL,
    'Клиентов с визитом, но без покупки: ' || COUNT(DISTINCT ln.lead_id)
    || '. Проверьте статусы в AMO.'
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'not_bought'
  AND ln.visit_status = 'visited'
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A09' AND a.resolved_at IS NULL
);

-- ============================================================
-- A10: Расхождение выручки (success AMO.price vs YC.sum)
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A10', 'warning',
    'revenue_mismatch_count', COUNT(DISTINCT ln.lead_id),
    COALESCE((cfg.value->>'A10_max_revenue_discrepancy_pct')::int, 10),
    'Расхождение выручки у успешных сделок: ' || COUNT(DISTINCT ln.lead_id)
    || ' клиентов. AMO.price > YC.sum.'
FROM staging.leads_normalized ln
JOIN raw.amo_leads amo ON amo.studio_id = ln.studio_id AND amo.id = ln.raw_amo_id
LEFT JOIN (
    SELECT client_phone, studio_id, SUM(sum) AS yc_sum
    FROM raw.yc_visits WHERE status = 'visited'
    GROUP BY client_phone, studio_id
) yc_total ON yc_total.studio_id = amo.studio_id
    AND yc_total.client_phone = amo.client_phone
CROSS JOIN LATERAL (
    SELECT value FROM ops.config
    WHERE key = 'alert_thresholds_stage'
      AND (studio_id = %(studio_id)s OR studio_id = 'all')
    LIMIT 1
) cfg
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'success'
  AND amo.price > COALESCE(yc_total.yc_sum, 0)
GROUP BY cfg.value
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A10' AND a.resolved_at IS NULL
);

-- ============================================================
-- A11: Расхождение залога (deposit AMO.price vs YC.sum)
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A11', 'warning',
    'deposit_mismatch_count', COUNT(DISTINCT ln.lead_id),
    COALESCE((cfg.value->>'A11_max_deposit_discrepancy_pct')::int, 5),
    'Расхождение сумм залогов: ' || COUNT(DISTINCT ln.lead_id)
    || ' клиентов. Проверьте AMO.price vs YC.payments.'
FROM staging.leads_normalized ln
JOIN raw.amo_leads amo ON amo.studio_id = ln.studio_id AND amo.id = ln.raw_amo_id
LEFT JOIN (
    SELECT client_phone, studio_id, SUM(sum) AS yc_sum
    FROM raw.yc_visits
    GROUP BY client_phone, studio_id
) yc_pay ON yc_pay.studio_id = amo.studio_id
    AND yc_pay.client_phone = amo.client_phone
CROSS JOIN LATERAL (
    SELECT value FROM ops.config
    WHERE key = 'alert_thresholds_stage'
      AND (studio_id = %(studio_id)s OR studio_id = 'all')
    LIMIT 1
) cfg
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'deposit'
  AND ABS(amo.price - COALESCE(yc_pay.yc_sum, 0)) > 0
GROUP BY cfg.value
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A11' AND a.resolved_at IS NULL
);

-- ============================================================
-- A12: Высокий % закрытых без продажи
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
WITH stage_counts AS (
    SELECT
        COUNT(*) FILTER (WHERE funnel_stage = 'closed') AS closed_count,
        COUNT(*) FILTER (WHERE funnel_stage IN ('success', 'closed')) AS total_resolved
    FROM staging.leads_normalized
    WHERE studio_id = %(studio_id)s
      AND source = 'amo'
      AND created_at >= NOW() - interval '30 days'
)
SELECT
    %(studio_id)s, 'A12', 'warning',
    'closure_rate_pct',
    ROUND(closed_count::numeric / NULLIF(total_resolved, 0) * 100, 1),
    COALESCE((cfg.value->>'A12_max_closure_rate_pct')::int, 30),
    'Процент закрытых без продажи: '
    || ROUND(closed_count::numeric / NULLIF(total_resolved, 0) * 100, 1)
    || '%%. Превышает порог.'
FROM stage_counts
CROSS JOIN LATERAL (
    SELECT value FROM ops.config
    WHERE key = 'alert_thresholds_stage'
      AND (studio_id = %(studio_id)s OR studio_id = 'all')
    LIMIT 1
) cfg
GROUP BY cfg.value
HAVING total_resolved > 0
  AND ROUND(closed_count::numeric / NULLIF(total_resolved, 0) * 100, 1)
      > COALESCE((cfg.value->>'A12_max_closure_rate_pct')::int, 30)
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A12' AND a.resolved_at IS NULL
);

-- ============================================================
-- A13: Обнаружен ломаный номер телефона
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A13', 'info',
    'invalid_phone_count', COUNT(DISTINCT ln.lead_id),
    NULL,
    'Обнаружено ' || COUNT(DISTINCT ln.lead_id)
    || ' лидов с ломаным номером телефона. Проверьте AMO.'
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND ln.phone_valid = FALSE
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A13' AND a.resolved_at IS NULL
);

-- ============================================================
-- A14: Лиды с неизвестным рекламным каналом
-- ============================================================
INSERT INTO ops.active_alerts (
    studio_id, alert_type, severity,
    metric_name, metric_value, threshold,
    recommendation
)
SELECT
    %(studio_id)s, 'A14', 'info',
    'unknown_ad_channel_count', COUNT(DISTINCT ln.lead_id),
    NULL,
    'Лидов с неизвестным рекламным каналом: ' || COUNT(DISTINCT ln.lead_id)
    || '. Вероятно, не из рекламы.'
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND ln.ad_channel_unknown = TRUE
  AND ln.funnel_stage = 'new'
HAVING COUNT(DISTINCT ln.lead_id) > 0
AND NOT EXISTS (
    SELECT 1 FROM ops.active_alerts a
    WHERE a.studio_id = %(studio_id)s AND a.alert_type = 'A14' AND a.resolved_at IS NULL
);
