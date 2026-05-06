"""
base_connector.py — абстрактный базовый класс коннектора.

Предоставляет:
- retry + exponential backoff
- Логгирование
- Сохранение в raw слой PostgreSQL
"""

import logging
from abc import ABC, abstractmethod
from typing import Any

import psycopg2
import psycopg2.extras
import requests
from tenacity import (
    before_sleep_log,
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from connectors.config import StudioConfig, settings

# Настройка логгера
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("connector")


class BaseConnector(ABC):
    """Базовый класс для всех коннекторов данных."""

    def __init__(self, studio: StudioConfig, db_url: str):
        self.studio = studio
        self.db_url = db_url
        self.log = logging.getLogger(f"connector.{self.__class__.__name__}.{studio.studio_id}")

    # ----------------------------------------------------------
    # HTTP-запрос с retry + exponential backoff
    # ----------------------------------------------------------
    @retry(
        stop=stop_after_attempt(settings.max_retries),
        wait=wait_exponential(multiplier=settings.backoff_base),
        retry=retry_if_exception_type(
            (requests.ConnectionError, requests.Timeout, requests.HTTPError)
        ),
        before_sleep=before_sleep_log(logger, logging.WARNING),
        reraise=True,
    )
    def _request(self, method: str, url: str, **kwargs: Any) -> requests.Response:
        """HTTP-запрос со встроенным retry на сетевые ошибки и 5xx."""
        kwargs.setdefault("timeout", settings.request_timeout)
        resp = requests.request(method, url, **kwargs)
        if resp.status_code >= 500:
            resp.raise_for_status()
        return resp

    # ----------------------------------------------------------
    # Нормализация телефона
    # ----------------------------------------------------------
    @staticmethod
    def clean_phone(phone: str | None) -> str | None:
        """Очистить номер телефона от лишних символов.

        Формат на выходе: 7XXXXXXXXXX (11 цифр, без +).
        """
        if not phone or phone == "#ERROR!":
            return None
        digits = "".join(c for c in str(phone) if c.isdigit())
        if len(digits) == 11 and digits.startswith("7"):
            return "7" + digits[1:]
        if len(digits) == 10:
            return "7" + digits
        if len(digits) == 11 and digits.startswith("8"):
            return "7" + digits[1:]
        return digits if digits else None

    # ----------------------------------------------------------
    # Сохранение в raw слой
    # ----------------------------------------------------------
    def _save_to_raw(
        self,
        table: str,
        records: list[dict[str, Any]],
        schema: str = "raw",
    ) -> int:
        """Bulk-insert записей в таблицу schema.table.

        Использует INSERT … ON CONFLICT DO NOTHING для идемпотентности.
        Возвращает количество вставленных строк.
        """
        if not records:
            return 0

        conn = psycopg2.connect(self.db_url)
        try:
            columns = list(records[0].keys())
            placeholders = ", ".join([f"%({c})s" for c in columns])
            cols_fmt = ", ".join(columns)

            # Добавляем studio_id если его нет в records
            for rec in records:
                rec.setdefault("studio_id", self.studio.studio_id)

            pk_columns = self._pk_columns(table, schema)

            sql = (
                f"INSERT INTO {schema}.{table} ({cols_fmt})\n"
                f"VALUES ({placeholders})\n"
                f"ON CONFLICT ({pk_columns}) DO NOTHING"
            )

            with conn.cursor() as cur:
                psycopg2.extras.execute_batch(cur, sql, records)
            conn.commit()
            return len(records)
        finally:
            conn.close()

    def _pk_columns(self, table: str, schema: str) -> str:
        """Возвращает PK-колонки таблицы (заглушка — переопределить при надобности)."""
        return "studio_id, id"

    # ----------------------------------------------------------
    # Абстрактный метод — каждая реализация своя
    # ----------------------------------------------------------
    @abstractmethod
    def fetch(self) -> int:
        """Загрузить данные из источника и сохранить в raw.

        Returns:
            Количество сохранённых записей.
        """
        ...
