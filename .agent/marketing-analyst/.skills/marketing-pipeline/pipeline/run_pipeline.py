"""
run_pipeline.py — оркестратор pipeline (S2→S5).

Запускает SQL-шаги последовательно для указанной студии.
Каждый шаг читает данные из предыдущих слоёв и пишет в свой.

Использование:
    python run_pipeline.py --studio_id=studio_a
    python run_pipeline.py --studio_id=studio_a --period_start=2025-01-01 --period_end=2025-01-31
    python run_pipeline.py --all-studios              # все активные студии
"""

import argparse
import logging
import os
import sys
from datetime import datetime

import psycopg2
from psycopg2 import sql as pg_sql

from connectors.config import settings, get_studios

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("pipeline")

# Путь к SQL-файлам
PIPELINE_DIR = os.path.dirname(os.path.abspath(__file__))

# Шаги pipeline в порядке выполнения
STEPS = [
    ("S2: Normalize", "s2_normalize.sql"),
    ("S2b: Client Profiles", "s2b_client_profiles.sql"),
    ("S3: Reconcile", "s3_reconcile.sql"),
    ("S4: Metrics",  "s4_metrics.sql"),
    ("S5a: Alerts",  "s5a_alerts.sql"),
    ("S5b: Reports", "s5b_reports.sql"),
]


def run_pipeline(
    db_url: str,
    studio_id: str,
    period_start: str | None = None,
    period_end: str | None = None,
) -> bool:
    """Запустить pipeline для одной студии.

    Args:
        db_url: строка подключения к БД
        studio_id: ID студии
        period_start: начало периода (YYYY-MM-DD)
        period_end: конец периода (YYYY-MM-DD)

    Returns:
        True если все шаги успешны, иначе False.
    """
    # Проверка HITL-gates
    if _has_open_gates(db_url, studio_id):
        log.warning("Студия %s: есть открытые HITL-gates, pipeline пропущен", studio_id)
        return False

    log.info("=" * 50)
    log.info("Pipeline для студии: %s", studio_id)
    if period_start:
        log.info("Период: %s → %s", period_start, period_end or "now")
    log.info("=" * 50)

    all_ok = True
    for step_name, sql_file in STEPS:
        ok = _run_step(db_url, studio_id, step_name, sql_file, period_start, period_end)
        if not ok:
            log.error("Шаг %s упал, pipeline остановлен", step_name)
            all_ok = False
            break

    if all_ok:
        log.info("Студия %s: pipeline завершён успешно", studio_id)
    else:
        log.warning("Студия %s: pipeline завершён с ошибками", studio_id)

    return all_ok


def _run_step(
    db_url: str,
    studio_id: str,
    step_name: str,
    sql_file: str,
    period_start: str | None,
    period_end: str | None,
) -> bool:
    """Выполнить один SQL-шаг pipeline."""
    filepath = os.path.join(PIPELINE_DIR, sql_file)
    if not os.path.exists(filepath):
        log.error("Файл не найден: %s", filepath)
        return False

    with open(filepath) as f:
        sql = f.read()

    log.info("  → %s (%s)...", step_name, sql_file)

    try:
        conn = psycopg2.connect(db_url)
        conn.autocommit = False

        with conn.cursor() as cur:
            # Параметры шаблона (psycopg2)

            params = {
                "studio_id": studio_id,
                "period_start": datetime.strptime(period_start, "%Y-%m-%d").date() if period_start else None,
                "period_end": datetime.strptime(period_end, "%Y-%m-%d").date() if period_end else None,
            }

            cur.execute(sql, params)

        conn.commit()
        conn.close()

        log.info("    ✓ %s выполнен", step_name)
        return True

    except Exception as e:

        log.exception("    ✗ %s: %s", step_name, e)
        try:

            conn.rollback()
            conn.close()
        except Exception:

            pass
        return False


def _has_open_gates(db_url: str, studio_id: str) -> bool:
    """Проверить, есть ли открытые HITL-gates для студии."""
    try:
        conn = psycopg2.connect(db_url)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM ops.gates "
                "WHERE studio_id = %s AND status = 'open'",
                (studio_id,),
            )
            count = cur.fetchone()[0]
        conn.close()
        return count > 0
    except Exception:
        return False


def run_all_studios(db_url: str, **kwargs) -> None:
    """Запустить pipeline для всех активных студий."""
    try:
        from connectors.config import get_studios

        studios = get_studios(db_url)
    except Exception as e:
        log.error("Не удалось загрузить список студий: %s", e)
        return

    if not studios:
        log.warning("Нет активных студий")
        return

    log.info("Запуск pipeline для %s студий", len(studios))
    results: dict[str, bool] = {}

    for studio in studios:
        results[studio.studio_id] = run_pipeline(
            db_url, studio.studio_id, **kwargs
        )

    # Итоги
    success = [s for s, ok in results.items() if ok]
    failed = [s for s, ok in results.items() if not ok]
    log.info("=" * 50)
    log.info("ИТОГО: успешно %s, ошибки %s", len(success), len(failed))
    if failed:
        log.warning("Студии с ошибками: %s", ", ".join(failed))
    log.info("=" * 50)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pipeline marketing-agent (S2→S5)"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--studio_id",
        help="ID студии для запуска",
    )
    group.add_argument(
        "--all-studios",
        action="store_true",
        help="Запустить для всех активных студий",
    )
    parser.add_argument(
        "--period-start",
        help="Начало периода (YYYY-MM-DD)",
    )
    parser.add_argument(
        "--period-end",
        help="Конец периода (YYYY-MM-DD)",
    )

    args = parser.parse_args()
    kwargs = {}
    if args.period_start:
        kwargs["period_start"] = args.period_start
    if args.period_end:
        kwargs["period_end"] = args.period_end

    db_url = settings.database_url
    log.info("Подключение к БД: %s", db_url)

    if args.studio_id:
        log.info("Pipeline для студии: %s", args.studio_id)
        success = run_pipeline(db_url, args.studio_id, **kwargs)

        sys.exit(0 if success else 1)
    else:
        run_all_studios(db_url, **kwargs)


if __name__ == "__main__":
    main()
