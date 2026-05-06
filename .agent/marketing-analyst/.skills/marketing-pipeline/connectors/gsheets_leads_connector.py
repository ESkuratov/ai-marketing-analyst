"""
gsheets_leads_connector.py — коннектор к Google Sheets с лидами.

Загружает таблицу лидов из рекламных каналов (публичный доступ, CSV).
Пишет в raw.gsheets_leads (отдельная таблица).

Формат таблицы:
  Источник | Дата | Имя | Номер клиента | Студия | Акция\Форма | ID сделки
"""

import csv
import io
import logging
from datetime import datetime
from typing import Any

import psycopg2
import requests

from connectors.config import settings, get_studios
from connectors.base_connector import BaseConnector

log = logging.getLogger("connector.gsheets_leads")

# Публичная ссылка на CSV-экспорт (постоянная для этого sheet_id)
EXPORT_URL = "https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv"

# Маппинг названий студий из таблицы → studio_id в ops.studios
STUDIO_NAME_MAP = {
    "рязанский проспект": "studio_a",
    "рязанский": "studio_a",
    "люблино": "studio_b",
    "м. рязанский проспект, ул. академика скрябина, д. 3/1 к1": "studio_a",
}


class GsheetsLeadsConnector:
    """Загрузка лидов из Google Sheets."""

    def __init__(self, sheet_id: str, db_url: str):
        self.sheet_id = sheet_id
        self.db_url = db_url

    def fetch(self) -> int:
        """Загрузить лиды из таблицы и сохранить в raw.amo_leads."""
        rows = self._fetch_csv()
        if not rows:
            log.warning("Нет данных из Google Sheets")
            return 0

        records = self._parse_rows(rows[1:])  # пропустить заголовок
        if not records:
            return 0

        saved = self._save_to_db(records)
        log.info("Google Sheets лиды: сохранено %s из %s строк", saved, len(records))
        return saved

    # ----------------------------------------------------------
    # Загрузка CSV
    # ----------------------------------------------------------
    def _fetch_csv(self) -> list[list[str]]:
        """Скачать CSV по публичной ссылке."""
        url = EXPORT_URL.format(sheet_id=self.sheet_id)
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()

        content = resp.content.decode("utf-8-sig")
        reader = csv.reader(io.StringIO(content))
        return list(reader)

    # ----------------------------------------------------------
    # Маппинг полей
    # ----------------------------------------------------------
    def _parse_rows(self, rows: list[list[str]]) -> list[dict[str, Any]]:
        """Маппинг строк таблицы → raw.amo_leads."""
        records: list[dict[str, Any]] = []
        errors = 0

        for i, row in enumerate(rows):
            if not row or not row[0].strip():
                continue

            try:
                rec = self._parse_row(row)
                if rec:
                    records.append(rec)
            except Exception as e:
                errors += 1
                if errors <= 3:
                    log.warning("Строка %s: ошибка — %s", i + 2, e)

        if errors:
            log.warning("Всего ошибок парсинга: %s", errors)

        return records

    def _parse_row(self, row: list[str]) -> dict[str, Any] | None:
        """Распарсить одну строку CSV в raw.gsheets_leads."""
        source_name = row[0].strip() if len(row) > 0 else ""
        date_str = row[1].strip() if len(row) > 1 else ""
        client_name = row[2].strip() if len(row) > 2 else ""
        client_phone = row[3].strip() if len(row) > 3 else ""
        studio_name_raw = row[4].strip() if len(row) > 4 else ""
        promotion = row[5].strip() if len(row) > 5 else ""
        deal_id = row[6].strip() if len(row) > 6 else ""

        if not source_name or not deal_id:
            return None

        created_at = self._parse_date(date_str)
        if not created_at:
            return None

        studio_id = STUDIO_NAME_MAP.get(studio_name_raw.lower(), "studio_a")
        phone_clean = self._clean_phone(client_phone)

        # Маппинг source_name → utm_source
        utm_source_map = {
            "ВК": "vk",
            "РСЯ": "yandex_display",
            "Сайт": "site",
            "Instagram": "instagram",
            "Telegram": "telegram",
            "Яндекс": "yandex",
            "Google": "google",
        }
        utm_source = utm_source_map.get(source_name, source_name.lower())

        return {
            "studio_id": studio_id,
            "deal_id": int(deal_id) if deal_id.isdigit() else None,
            "source_name": source_name,
            "utm_source": utm_source,
            "utm_campaign": promotion if promotion else None,
            "client_name": client_name or None,
            "client_phone": phone_clean or None,
            "studio_name": studio_name_raw or None,
            "created_at": created_at,
            "raw_data": {
                "source": source_name,
                "date": date_str,
                "name": client_name,
                "phone": client_phone,
                "studio": studio_name_raw,
                "promotion": promotion,
                "deal_id": deal_id,
            },
        }

    @staticmethod
    def _parse_date(date_str: str) -> str | None:
        """Распарсить дату из формата '2025-03-26 1:17' в ISO."""
        if not date_str:
            return None
        try:
            for fmt in [
                "%Y-%m-%d %H:%M",
                "%Y-%m-%d %H:%M:%S",
                "%Y-%m-%d",
                "%d.%m.%Y %H:%M",
                "%d.%m.%Y",
            ]:
                try:
                    dt = datetime.strptime(date_str, fmt)
                    return dt.isoformat()
                except ValueError:
                    continue
            # fallback: просто вернуть дату
            return date_str[:10] + "T00:00:00"
        except Exception:
            return None

    @staticmethod
    def _clean_phone(phone: str) -> str | None:
        """Очистить номер телефона (делегировано BaseConnector)."""
        return BaseConnector.clean_phone(phone)

    # ----------------------------------------------------------
    # Сохранение в БД
    # ----------------------------------------------------------
    def _save_to_db(self, records: list[dict[str, Any]]) -> int:
        """Bulk-insert в raw.gsheets_leads (SERIAL id, не нужно передавать)."""
        conn = psycopg2.connect(self.db_url)
        try:
            with conn.cursor() as cur:
                for rec in records:
                    cur.execute(
                        """
                        INSERT INTO raw.gsheets_leads
                            (studio_id, deal_id, source_name, utm_source, utm_campaign,
                             client_name, client_phone, studio_name, created_at, raw_data)
                        VALUES
                            (%(studio_id)s, %(deal_id)s, %(source_name)s, %(utm_source)s,
                             %(utm_campaign)s, %(client_name)s, %(client_phone)s,
                             %(studio_name)s, %(created_at)s, %(raw_data)s::jsonb)
                        """,
                        rec,
                    )
            conn.commit()
            return len(records)
        finally:
            conn.close()
