"""
yclients_connector.py — коннектор к YClients API.

Загружает записи (visits) из YClients для аналитики.
Важно: API игнорирует параметр date — фильтрация клиентская.
"""

import json
import os
import time
from datetime import datetime, timedelta
from typing import Any
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from urllib.parse import urlencode

from connectors.base_connector import BaseConnector


class YClientsConnector(BaseConnector):
    """Загрузка записей из YClients API."""

    API_BASE = "https://api.yclients.com/api/v1"

    STAFF_MASTER = {
        5111463: "Александра",
        3741329: "Анна Зыкова",
        3745349: "Денис Мартынов",
        3757001: "Татьяна Ковалева",
        4964993: "Светлана",
        3910523: "Ольга",
        4181742: "Екатерина",
    }
    STAFF_WAITLIST = 3775989

    ATTENDANCE_NO_SHOW = -1
    ATTENDANCE_WAITING = 0
    ATTENDANCE_VISITED = 1
    ATTENDANCE_CONFIRMED = 2

    ATTENDANCE_MAP = {
        -1: "not_visited",
        0: "waiting",
        1: "visited",
        2: "confirmed",
    }

    def __init__(self, studio: Any, db_url: str = ""):
        if not db_url:
            from connectors.config import settings
            db_url = settings.database_url
        super().__init__(studio, db_url)
        self._bearer_token: str = ""
        self._user_token: str = ""
        self._company_id: int = 0
        self._config_loaded: bool = False

    # ----------------------------------------------------------
    # Конфигурация (с кэшированием)
    # ----------------------------------------------------------
    def _load_config(self) -> bool:
        """Загрузить конфигурацию из .env (однократно)."""
        if self._config_loaded:
            return bool(self._bearer_token and self._user_token)

        env_paths = [
            os.path.join(os.path.dirname(__file__), '.env'),
            os.path.join(os.getcwd(), '.env'),
            os.path.join(os.path.dirname(__file__), '../../../../.env'),
        ]

        for env_path in env_paths:
            abs_path = os.path.abspath(env_path)
            if os.path.exists(abs_path):
                try:
                    from dotenv import load_dotenv
                    load_dotenv(abs_path, override=True)
                except ImportError:
                    with open(abs_path) as f:
                        for line in f:
                            line = line.strip()
                            if '=' in line and not line.startswith('#'):
                                key, value = line.split('=', 1)
                                os.environ[key.strip()] = value.strip().strip("'\"")

        self._bearer_token = os.environ.get('YC_BEARER_TOKEN', '')
        self._user_token = os.environ.get('YC_USER_TOKEN', '')
        self._company_id = self.studio.yc_company_id or 1234490
        self._config_loaded = True

        if not self._bearer_token or not self._user_token:
            self.log.warning("YClients не настроен: отсутствуют токены")
            return False
        return True

    # ----------------------------------------------------------
    # API запросы
    # ----------------------------------------------------------
    def _make_request(self, endpoint: str, params: dict | None = None) -> dict:
        """Выполнить API запрос к YClients."""
        if not self._bearer_token:
            return {"error": "Not configured"}

        url = f"{self.API_BASE}{endpoint}"
        if params:
            url += "?" + urlencode(params)

        headers = {
            "Authorization": f"Bearer {self._bearer_token}, User {self._user_token}",
            "Accept": "application/vnd.yclients.v2+json",
            "Content-Type": "application/json",
        }

        try:
            req = Request(url, headers=headers, method="GET")
            with urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except HTTPError as e:
            error_body = e.read().decode()
            self.log.error("YClients HTTP %s: %s", e.code, error_body[:500])
            return {"error": e.code, "message": error_body[:500]}
        except Exception as e:
            self.log.error("YClients request error: %s", str(e))
            return {"error": "request_failed", "message": str(e)}

    def _fetch_page(self, page: int, per_page: int = 200) -> list[dict]:
        """Получить одну страницу записей."""
        endpoint = f"/records/{self._company_id}"
        result = self._make_request(endpoint, params={"page": page, "per_page": per_page})

        if "error" in result:
            return []
        if isinstance(result, list):
            return result
        return result.get("data", [])

    # ----------------------------------------------------------
    # Загрузка записей — линейный обход
    # ----------------------------------------------------------
    def fetch_records_for_date(self, date_str: str) -> list[dict]:
        """Получить записи за конкретную дату линейным обходом страниц.

        YClients API игнорирует параметр date, поэтому идём по страницам
        пока дата записей >= target_date.
        """
        if not self._load_config():
            return []

        self.log.info("Fetching YClients records for %s", date_str)
        matching: list[dict] = []

        for page in range(1, 200):
            records = self._fetch_page(page)
            if not records:
                break

            for rec in records:
                rec_date = (rec.get("datetime") or "")[:10]
                if rec_date == date_str:
                    matching.append(rec)

            # Записи от новых к старым: если самая старая старше target — хватит
            last_date = (records[-1].get("datetime") or "")[:10]
            if last_date and last_date < date_str:
                break

            time.sleep(0.15)  # щадим API

        self.log.info("Found %s records for %s", len(matching), date_str)
        return matching

    # ----------------------------------------------------------
    # Основной метод fetch
    # ----------------------------------------------------------
    def fetch(self, date_from: str | None = None, date_to: str | None = None) -> int:
        """Загрузить записи из YClients и сохранить в raw.yc_visits."""
        if not self._load_config():
            return 0

        if not date_from:
            date_from = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
        if not date_to:
            date_to = date_from

        total = 0
        current = datetime.strptime(date_from, '%Y-%m-%d')
        end = datetime.strptime(date_to, '%Y-%m-%d')

        while current <= end:
            date_str = current.strftime('%Y-%m-%d')
            records = self.fetch_records_for_date(date_str)
            if records:
                saved = self._save_visits(records)
                total += saved
                self.log.info("YClients %s: сохранено %s записей", date_str, saved)
            current += timedelta(days=1)

        self.log.info("YClients: всего сохранено %s записей за период", total)
        return total

    def fetch_by_date(self, date_str: str) -> int:
        """Загрузить записи за конкретную дату."""
        return self.fetch(date_from=date_str, date_to=date_str)

    # ----------------------------------------------------------
    # Маппинг YClients API → raw.yc_visits
    # ----------------------------------------------------------
    def _save_visits(self, raw_records: list[dict]) -> int:
        """Маппинг YClients → raw.yc_visits."""
        rows: list[dict] = []

        for rec in raw_records:
            staff_id = rec.get("staff_id")
            is_waitlist = staff_id == self.STAFF_WAITLIST

            client = rec.get("client") or {}
            services = rec.get("services") or []
            first_svc = services[0] if services else {}

            attendance = rec.get("attendance", 0)

            # is_first_visit: из API + эвристика по названию услуги
            is_new = rec.get("is_new", False)
            if not is_new and services:
                for svc in services:
                    title = (svc.get("title") or "").lower()
                    if "первый" in title or "first" in title:
                        is_new = True
                        break

            rows.append({
                "id": rec.get("id"),
                "studio_id": self.studio.studio_id,
                "client_id": client.get("id"),
                "client_name": client.get("name"),
                "client_phone": self.clean_phone(client.get("phone")),
                "service_id": first_svc.get("id"),
                "service_name": first_svc.get("title"),
                "master_id": None if is_waitlist else staff_id,
                "master_name": None if is_waitlist else self.STAFF_MASTER.get(staff_id),
                "date": (rec.get("datetime") or "")[:10] if rec.get("datetime") else None,
                "time": (rec.get("datetime") or "")[11:19] if rec.get("datetime") else None,
                "sum": rec.get("price", 0),
                "discount": 0,
                "status": self.ATTENDANCE_MAP.get(attendance, "unknown"),
                "is_first_visit": is_new,
                "comment": rec.get("comment"),
                "raw_data": json.dumps(rec),
            })

        return self._save_to_raw("yc_visits", rows)

    # ----------------------------------------------------------
    # Утилиты
    # ----------------------------------------------------------
    def get_services(self) -> list[dict]:
        """Получить список услуг компании."""
        if not self._load_config():
            return []
        result = self._make_request(f"/company/{self._company_id}/services")
        if isinstance(result, list):
            return result
        return result.get("data", [])

    def get_staff(self) -> dict[int, str]:
        """Получить список мастеров (из констант)."""
        return self.STAFF_MASTER.copy()
