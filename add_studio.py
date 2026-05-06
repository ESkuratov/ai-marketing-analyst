"""
add_studio.py — CLI-скрипт для добавления новой студии в ops.studios.

Использование:
    python add_studio.py --studio-id=studio_b --name="Студия Б" \\
        --yc-company-id=12345 --amo-domain=studio_b \\
        --amo-pipeline-id=1 --gs-sheet-id=abc123 \\
        --timezone=Europe/Moscow

    python add_studio.py --list                    # список студий
    python add_studio.py --deactivate=studio_b     # деактивировать
"""

import argparse
import logging
import sys

import psycopg2
import psycopg2.extras

from connectors.config import settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("add_studio")


def add_studio(db_url: str, args: argparse.Namespace) -> None:
    """Добавить новую студию в ops.studios."""
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT EXISTS(SELECT 1 FROM ops.studios WHERE studio_id = %s)
                """,
                (args.studio_id,),
            )
            exists = cur.fetchone()[0]
            if exists:
                log.error("Студия '%s' уже существует", args.studio_id)
                sys.exit(1)

            cur.execute(
                """
                INSERT INTO ops.studios
                    (studio_id, name, yc_company_id, amo_domain,
                     amo_pipeline_id, gs_sheet_id, timezone)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    args.studio_id,
                    args.name,
                    args.yc_company_id,
                    args.amo_domain,
                    args.amo_pipeline_id,
                    args.gs_sheet_id,
                    args.timezone or "Europe/Moscow",
                ),
            )
        conn.commit()
        log.info("Студия '%s' (%s) добавлена", args.studio_id, args.name)
    except Exception as e:
        conn.rollback()
        log.error("Ошибка: %s", e)
        sys.exit(1)
    finally:
        conn.close()


def list_studios(db_url: str) -> None:
    """Показать список всех студий."""
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT * FROM ops.studios ORDER BY name"
            )
            rows = cur.fetchall()

        if not rows:
            log.info("Нет студий в ops.studios")
            return

        print(f"{'ID':<15} {'Название':<25} {'YC ID':<10} {'AMO':<20} {'GS':<25} {'Активна':<8} {'Часовой пояс':<15}")
        print("-" * 120)
        for r in rows:
            print(
                f"{r['studio_id']:<15} {r['name']:<25} "
                f"{str(r.get('yc_company_id', '') or ''):<10} "
                f"{str(r.get('amo_domain', '') or ''):<20} "
                f"{str(r.get('gs_sheet_id', '') or ''):<25} "
                f"{'✅' if r.get('is_active') else '❌':<8} "
                f"{str(r.get('timezone', '') or ''):<15}"
            )
    finally:
        conn.close()


def deactivate_studio(db_url: str, studio_id: str) -> None:
    """Деактивировать студию (soft delete)."""
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE ops.studios SET is_active = FALSE, updated_at = NOW() "
                "WHERE studio_id = %s",
                (studio_id,),
            )
            if cur.rowcount == 0:
                log.error("Студия '%s' не найдена", studio_id)
                sys.exit(1)
        conn.commit()
        log.info("Студия '%s' деактивирована", studio_id)
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Управление студиями в ops.studios"
    )
    parser.add_argument("--studio-id", help="ID студии")
    parser.add_argument("--name", help="Название студии")
    parser.add_argument("--yc-company-id", type=int, help="ID компании в YClients")
    parser.add_argument("--amo-domain", help="Поддомен AMO CRM")
    parser.add_argument("--amo-pipeline-id", type=int, help="ID воронки в AMO")
    parser.add_argument("--gs-sheet-id", help="ID Google Sheets")
    parser.add_argument("--timezone", default="Europe/Moscow", help="Часовой пояс")
    parser.add_argument("--list", action="store_true", help="Показать список студий")
    parser.add_argument("--deactivate", help="Деактивировать студию по ID")

    args = parser.parse_args()

    db_url = settings.database_url

    if args.list:
        list_studios(db_url)
    elif args.deactivate:
        deactivate_studio(db_url, args.deactivate)
    elif args.studio_id:
        if not args.name:
            log.error("--name обязателен при добавлении студии")
            sys.exit(1)
        add_studio(db_url, args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
