-- S3: Reconcile — сверка источников данных
-- Читает: staging.leads_normalized, raw.amo_leads, raw.yc_visits
-- Пишет:  ops.active_alerts (если расхождение > порога)
-- Параметр: %(studio_id)s

-- ============================================================
-- 1. Сверка AMO ↔ YClients (количество лидов за период)
-- ============================================================
WITH
amo_stats AS (
    SELECT
        COUNT(*) AS amo_count,
        COUNT(*) FILTER (
            WHERE created_at::date >= COALESCE(%(period_start)s::date, NOW() - '30 days'::interval)
        ) AS amo_recent
    FROM staging.leads_normalized
    WHERE studio_id = %(studio_id)s AND source = 'amo'
),
yc_stats AS (
    SELECT
        COUNT(*) AS yc_count
    FROM staging.leads_normalized
    WHERE studio_id = %(studio_id)s AND source = 'yclients'
),
reconciliation AS (
    SELECT
        amo_stats.amo_count,
        yc_stats.yc_count,
        CASE
            WHEN amo_stats.amo_count = 0 AND yc_stats.yc_count = 0 THEN 0
            WHEN amo_stats.amo_count = 0 THEN 100
            ELSE ROUND(
                ABS(amo_stats.amo_count - yc_stats.yc_count)::numeric
                / GREATEST(amo_stats.amo_count, 1) * 100, 2
            )
        END AS discrepancy_pct
    FROM amo_stats, yc_stats
)
SELECT
    %(studio_id)s AS studio_id,
    'A04' AS alert_type,
    CASE
        WHEN discrepancy_pct > 10 THEN 'critical'
        WHEN discrepancy_pct > 5 THEN 'warning'
        ELSE 'info'
    END AS severity,
    'amo_vs_yclients' AS metric_name,
    discrepancy_pct AS metric_value,
    10 AS threshold,
    CASE
        WHEN discrepancy_pct > 10
        THEN 'Критическое расхождение AMO↔YC: ' || discrepancy_pct || '%%'
        WHEN discrepancy_pct > 5
        THEN 'Расхождение AMO↔YC: ' || discrepancy_pct || '%% (требуется внимание)'
        ELSE 'Расхождение AMO↔YC: ' || discrepancy_pct || '%% (в пределах нормы)'
    END AS recommendation
FROM reconciliation;

-- ============================================================
-- 2. Сверка AMO ↔ Google Sheets (расходы / лиды)
-- ============================================================
WITH
gs_stats AS (
    SELECT COUNT(*) AS gs_count
    FROM raw.gs_expenses
    WHERE studio_id = %(studio_id)s
      AND date >= COALESCE(%(period_start)s::date, '1970-01-01'::date)
      AND date < COALESCE(%(period_end)s::date, NOW()::date + 1)
),
amo_leads_for_period AS (
    SELECT COUNT(*) AS amo_lead_count
    FROM raw.amo_leads
    WHERE studio_id = %(studio_id)s
      AND created_at::date >= COALESCE(%(period_start)s::date, '1970-01-01'::date)
      AND created_at::date < COALESCE(%(period_end)s::date, NOW()::date + 1)
)
SELECT
    %(studio_id)s AS studio_id,
    'A04' AS alert_type,
    CASE
        WHEN gs_stats.gs_count = 0 AND amo_leads_for_period.amo_lead_count > 0 THEN 'warning'
        ELSE 'info'
    END AS severity,
    'amo_vs_gsheets' AS metric_name,
    amo_leads_for_period.amo_lead_count AS metric_value,
    0 AS threshold,
    CASE
        WHEN gs_stats.gs_count = 0
        THEN 'Нет записей расходов в Google Sheets за период'
        ELSE 'OK'
    END AS recommendation
FROM gs_stats, amo_leads_for_period;

-- ============================================================
-- 3. Сверка AMO ↔ Google Sheets (лиды из рекламных каналов)
--    Сравнивает количество лидов из AMO CRM и Google Sheets
--    за период. Матчинг по телефону клиента.
-- ============================================================
WITH
amo_gs_leads AS (
    SELECT
        COUNT(*) AS amo_count,
        COUNT(*) FILTER (WHERE client_phone IS NOT NULL) AS amo_with_phone,
        COUNT(DISTINCT client_phone) AS amo_unique_phones
    FROM raw.amo_leads
    WHERE studio_id = %(studio_id)s
      AND source = 'amo'
      AND created_at::date >= COALESCE(%(period_start)s::date, '1970-01-01'::date)
      AND created_at::date < COALESCE(%(period_end)s::date, NOW()::date + 1)
),
gs_leads AS (
    SELECT
        COUNT(*) AS gs_count,
        COUNT(DISTINCT client_phone) AS gs_unique_phones
    FROM raw.gsheets_leads
    WHERE studio_id = %(studio_id)s
      AND created_at >= COALESCE(%(period_start)s::date, '1970-01-01'::date)
      AND created_at < COALESCE(%(period_end)s::date, NOW()::date + 1)
),
matched AS (
    SELECT COUNT(*) AS matched_count
    FROM (
        SELECT regexp_replace(a.client_phone, '\D', '', 'g') AS phone_clean
        FROM raw.amo_leads a
        WHERE a.studio_id = %(studio_id)s
          AND a.source = 'amo'
          AND a.client_phone IS NOT NULL
          AND a.created_at::date >= COALESCE(%(period_start)s::date, '1970-01-01'::date)
          AND a.created_at::date < COALESCE(%(period_end)s::date, NOW()::date + 1)
        INTERSECT
        SELECT regexp_replace(g.client_phone, '\D', '', 'g')
        FROM raw.gsheets_leads g
        WHERE g.studio_id = %(studio_id)s
          AND g.client_phone IS NOT NULL
          AND g.created_at >= COALESCE(%(period_start)s::date, '1970-01-01'::date)
          AND g.created_at < COALESCE(%(period_end)s::date, NOW()::date + 1)
    ) matches
),
reconciliation AS (
    SELECT
        amo_gs_leads.amo_count,
        gs_leads.gs_count,
        matched.matched_count,
        CASE
            WHEN gs_leads.gs_count = 0 THEN NULL
            ELSE ROUND(
                (gs_leads.gs_count - matched.matched_count)::numeric
                / gs_leads.gs_count * 100, 2
            )
        END AS pct_not_in_amo,
        CASE
            WHEN amo_gs_leads.amo_count = 0 THEN NULL
            ELSE ROUND(
                (amo_gs_leads.amo_count - matched.matched_count)::numeric
                / amo_gs_leads.amo_count * 100, 2
            )
        END AS pct_not_in_gs
    FROM amo_gs_leads, gs_leads, matched
)
SELECT
    %(studio_id)s AS studio_id,
    'amo_vs_gsheets_leads' AS metric_name,
    reconciliation.amo_count,
    reconciliation.gs_count,
    reconciliation.matched_count,
    reconciliation.pct_not_in_amo,
    reconciliation.pct_not_in_gs,
    CASE
        WHEN reconciliation.pct_not_in_amo > 20
        THEN '⚠️ ' || reconciliation.pct_not_in_amo || '%% лидов из Google Sheets не найдены в AMO CRM'
        WHEN reconciliation.pct_not_in_amo > 10
        THEN 'ℹ️ ' || reconciliation.pct_not_in_amo || '%% лидов из Google Sheets не найдены в AMO CRM'
        ELSE '✓ Расхождение AMO↔GSheets (лиды): ' || COALESCE(reconciliation.pct_not_in_amo::text, 'N/A') || '%%'
    END AS recommendation
FROM reconciliation;

-- ============================================================
-- 4. Stage 4: AMO «appointment» без записи в YC
-- ============================================================
SELECT
    %(studio_id)s AS studio_id,
    'stage4_appointment_no_yc' AS metric_name,
    ln.lead_id,
    amo.client_phone,
    amo.client_name,
    ln.created_at AS amo_created_at
FROM staging.leads_normalized ln
JOIN raw.amo_leads amo ON amo.studio_id = ln.studio_id AND amo.id = ln.raw_amo_id
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'appointment'
  AND ln.yc_booking_id IS NULL
  AND (%(period_start)s::timestamptz IS NULL OR ln.created_at >= %(period_start)s::timestamptz)
  AND (%(period_end)s::timestamptz IS NULL OR ln.created_at < %(period_end)s::timestamptz);

-- ============================================================
-- 5. Stage 5: AMO «no_show» с YC «visited» (расхождение статуса)
-- ============================================================
SELECT
    %(studio_id)s AS studio_id,
    'stage5_visit_mismatch' AS metric_name,
    ln.lead_id,
    amo.client_phone,
    amo.client_name,
    ln.visit_status AS yc_status,
    ln.funnel_stage AS amo_stage
FROM staging.leads_normalized ln
JOIN raw.amo_leads amo ON amo.studio_id = ln.studio_id AND amo.id = ln.raw_amo_id
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'no_show'
  AND ln.visit_status = 'visited'
  AND (%(period_start)s::timestamptz IS NULL OR ln.created_at >= %(period_start)s::timestamptz);

-- ============================================================
-- 6. Stage 7: AMO «not_bought» с YC «visited» (визит был, покупки нет)
-- ============================================================
SELECT
    %(studio_id)s AS studio_id,
    'stage7_visit_no_purchase' AS metric_name,
    ln.lead_id,
    amo.client_phone,
    amo.client_name,
    ln.amount AS yc_visit_sum,
    ln.visit_status
FROM staging.leads_normalized ln
JOIN raw.amo_leads amo ON amo.studio_id = ln.studio_id AND amo.id = ln.raw_amo_id
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'not_bought'
  AND ln.visit_status = 'visited';

-- ============================================================
-- 7. Stage 9: AMO «success» с расхождением выручки
-- ============================================================
SELECT
    %(studio_id)s AS studio_id,
    'stage9_revenue_mismatch' AS metric_name,
    ln.lead_id,
    amo.client_phone,
    amo.client_name,
    amo.price AS amo_price,
    COALESCE(yc_total.yc_sum, 0) AS yc_total_sum,
    amo.price - COALESCE(yc_total.yc_sum, 0) AS discrepancy
FROM staging.leads_normalized ln
JOIN raw.amo_leads amo ON amo.studio_id = ln.studio_id AND amo.id = ln.raw_amo_id
LEFT JOIN (
    SELECT client_phone, studio_id, SUM(sum) AS yc_sum
    FROM raw.yc_visits
    WHERE status = 'visited'
    GROUP BY client_phone, studio_id
) yc_total ON yc_total.studio_id = amo.studio_id
    AND yc_total.client_phone = amo.client_phone
WHERE ln.studio_id = %(studio_id)s
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'success'
  AND amo.price > COALESCE(yc_total.yc_sum, 0);
