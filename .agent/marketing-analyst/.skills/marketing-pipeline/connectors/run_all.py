"""
run_all.py — оркестратор коннекторов.

Читает список активных студий из ops.studios,
запускает для каждой студии все три коннектора.

Usage:
    python run_all.py
    python run_all.py --date-from=2026-01-01 --date-to=2026-01-31
"""

import argparse
import logging
import sys
from datetime import datetime

from connectors.config import settings, get_studios

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("orchestrator")


def run_connectors(
    db_url: str,
    date_from: str | None = None,
    date_to: str | None = None,
) -> None:
    """Запустить все коннекторы для всех активных студий.

    Args:
        db_url: строка подключения к БД
        date_from: дата начала периода 'YYYY-MM-DD' (для AMO и YClients)
        date_to: дата окончания периода 'YYYY-MM-DD' (для AMO и YClients)
    """
    studios = get_studios(db_url)
    if not studios:
        log.warning("Нет активных студий в ops.studios")
        return

    log.info("Запуск коннекторов для %s студий", len(studios))
    if date_from:
        log.info("Период: %s → %s", date_from, date_to or date_from)
    start = datetime.now()

    total_amo = 0
    total_yc = 0
    total_gs = 0

    for studio in studios:
        log.info("=" * 50)
        log.info("Студия: %s (%s)", studio.name, studio.studio_id)
        log.info("=" * 50)

        # AMO CRM
        if studio.amo_domain:
            try:
                from connectors.amo_connector import AmoConnector

                conn = AmoConnector(studio, db_url)
                total_amo += conn.fetch(date_from=date_from, date_to=date_to)
            except Exception as e:
                log.error("AMO CRM ошибка для %s: %s", studio.studio_id, e)
        else:
            log.info("AMO: пропущен (нет домена)")

        # YClients
        if studio.yc_company_id:
            try:
                from connectors.yclients_connector import YClientsConnector

                conn = YClientsConnector(studio=studio)
                total_yc += conn.fetch(date_from=date_from, date_to=date_to)
            except Exception as e:
                log.error("YClients ошибка для %s: %s", studio.studio_id, e)
        else:
            log.info("YClients: пропущен (нет company_id)")

        # Google Sheets (расходы)
        if studio.gs_sheet_id:
            try:
                from connectors.gsheets_connector import GsheetsConnector

                conn = GsheetsConnector(studio, db_url)
                total_gs += conn.fetch()
            except Exception as e:
                log.error("Google Sheets ошибка для %s: %s", studio.studio_id, e)
        else:
            log.info("Google Sheets: пропущен (нет sheet_id)")

    # Google Sheets — лиды из рекламных каналов
    total_gs_leads = 0
    if settings.gs_leads_sheet_id:
        try:
            from connectors.gsheets_leads_connector import GsheetsLeadsConnector

            conn = GsheetsLeadsConnector(settings.gs_leads_sheet_id, db_url)
            total_gs_leads = conn.fetch()
        except Exception as e:
            log.error("Google Sheets (лиды) ошибка: %s", e)
    else:
        log.info("Google Sheets (лиды): пропущен (нет GS_LEADS_SHEET_ID)")

    elapsed = (datetime.now() - start).total_seconds()

    log.info("=" * 50)
    log.info("ИТОГО:")
    log.info("  AMO CRM:      %s лидов", total_amo)
    log.info("  YClients:     %s визитов", total_yc)
    log.info("  Google Sheets: %s записей", total_gs)
    log.info("  GS Leads:     %s лидов", total_gs_leads)
    log.info("  Время:        %.1f сек", elapsed)
    log.info("=" * 50)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="S1 Collect — загрузка данных из AMO CRM, YClients и Google Sheets"
    )
    parser.add_argument(
        "--date-from",
        help="Дата начала периода (YYYY-MM-DD)",
    )
    parser.add_argument(
        "--date-to",
        help="Дата окончания периода (YYYY-MM-DD)",
    )

    args = parser.parse_args()

    db_url = settings.database_url
    log.info("Подключение к БД: %s", db_url)
    run_connectors(db_url, date_from=args.date_from, date_to=args.date_to)


if __name__ == "__main__":
    main()
