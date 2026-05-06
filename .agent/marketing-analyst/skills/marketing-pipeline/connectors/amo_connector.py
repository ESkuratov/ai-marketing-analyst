"""
amo_connector.py — коннектор к AMO CRM.

Загружает лиды из всех воронок студии.
Использует OAuth2-авторизацию с refresh_token.
"""

import json
import os
import time
from datetime import datetime, timedelta
from typing import Any
from urllib.request import Request, urlopen
from urllib.error import HTTPError

import psycopg2.extras

from connectors.base_connector import BaseConnector


class AmoConnector(BaseConnector):
    """Загрузка лидов из AMO CRM."""

    API_BASE = "https://{domain}.amocrm.ru/api/v4"

    # Маппинг статусов на филиалы (из названий статусов)
    STATUS_TO_STUDIO = {
        # Рязанский
        74087582: "studio_a",  # НЕ ВЗЯЛИ ТРУБКУ Рязанский
        74087586: "studio_a",  # ПЕРЕГОВОРЫ Рязанский
        # Люблино
        84866066: "studio_b",  # не взяли трубку люблино
        84866070: "studio_b",  # ПЕРЕГОВОРЫ Люблино
    }

    # Маппинг пользователей на филиалы
    USER_TO_STUDIO = {
        12112418: "studio_a",  # XSIZE Рязанский пр-т
        12112458: "studio_b",  # Админ1 (предположительно Люблино)
    }

    # Pipeline statuses cache (обновлено 2026-05-04)
    STATUSES = {
        74087430: 'Неразобранное',
        74087434: 'НОВАЯ ЗАЯВКА',
        74087582: 'НЕ ВЗЯЛИ ТРУБКУ Рязанский',
        84866066: 'не взяли трубку люблино',
        84866070: 'ПЕРЕГОВОРЫ Люблино',
        74087586: 'ПЕРЕГОВОРЫ Рязанский',
        74087590: 'НАЗНАЧЕН ВИЗИТ',
        74087594: 'НЕ ПРИШЛА НА СЕАНС',
        84237074: 'внесла залог',
        74087598: 'НЕ КУПИЛА',
        83303646: 'НЕ ПРОДЛИЛА',
        84237070: 'Ходит разово',
        142: 'Успешно реализовано',
        143: 'Закрыто и не реализовано',
    }

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._access_token: str | None = None
        self._refresh_token: str | None = None
        self._token_expires_at: float = 0
        self._client_id: str = ""
        self._client_secret: str = ""
        self._redirect_uri: str = "https://example.com"
        self._domain: str = ""

    # ----------------------------------------------------------
    # Конфигурация
    # ----------------------------------------------------------
    def _load_config(self) -> bool:
        """Загрузить конфигурацию из .env или настроек."""
        # Пробуем загрузить из .env файла
        env_paths = [
            os.path.join(os.getcwd(), '.env'),
            os.path.join(os.path.dirname(__file__), '../../../../.env'),  # корень проекта
            '.env',
        ]

        env_vars = {}
        for env_path in env_paths:
            if os.path.exists(env_path):
                with open(env_path) as f:
                    for line in f:
                        line = line.strip()
                        if '=' in line and not line.startswith('#'):
                            key, value = line.split('=', 1)
                            value = value.strip().strip("'\"")
                            env_vars[key.strip()] = value
                break

        self._domain = self.studio.amo_domain or env_vars.get('AMO_BASE_URL', '').replace('https://', '').replace('.amocrm.ru', '')
        self._access_token = env_vars.get('AMO_TOKEN', '')
        self._refresh_token = env_vars.get('AMO_REFRESH_TOKEN', '')
        self._client_id = env_vars.get('AMO_INTEGRATION_ID', '')
        self._client_secret = env_vars.get('AMO_SECRET_KEY', '')
        self._redirect_uri = env_vars.get('AMO_REDIRECT_URI', 'https://example.com')

        # If token exists, assume it's valid (will be refreshed if needed)
        if self._access_token:
            self._token_expires_at = time.time() + 3600  # Assume 1 hour validity

        if not self._domain or not self._access_token:
            self.log.warning("AMO CRM не настроен для студии %s", self.studio.studio_id)
            return False

        return True

    # ----------------------------------------------------------
    # Авторизация
    # ----------------------------------------------------------
    def _refresh_access_token(self) -> bool:
        """Обновить access_token используя refresh_token."""
        if not self._refresh_token or not self._client_id or not self._client_secret:
            self.log.error("Нет refresh_token или credentials для обновления")
            return False

        url = f"https://{self._domain}.amocrm.ru/oauth2/access_token"
        data = {
            "client_id": self._client_id,
            "client_secret": self._client_secret,
            "grant_type": "refresh_token",
            "refresh_token": self._refresh_token,
            "redirect_uri": self._redirect_uri,
        }

        try:
            req = Request(
                url,
                data=json.dumps(data).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            with urlopen(req, timeout=15) as resp:
                result = json.loads(resp.read().decode())

                if "access_token" in result:
                    self._access_token = result["access_token"]
                    self._token_expires_at = time.time() + result.get("expires_in", 86400)

                    # Обновляем refresh_token (amoCRM выдаёт новый)
                    if "refresh_token" in result:
                        self._refresh_token = result["refresh_token"]
                        self.log.info("Tokens refreshed successfully")
                        # TODO: Сохранить новый refresh_token в .env

                    return True

        except HTTPError as e:
            error_body = e.read().decode()
            self.log.error("Token refresh failed: %s", error_body[:500])
        except Exception as e:
            self.log.error("Token refresh error: %s", str(e))

        return False

    def _auth(self) -> str:
        """Получить access_token (с auto-refresh при необходимости)."""
        if not self._access_token:
            if not self._load_config():
                return ""

        # Если токен ещё не истёк - используем его
        if self._access_token and time.time() < self._token_expires_at:
            return self._access_token

        # Пробуем обновить токен
        if self._refresh_token and self._refresh_access_token():
            return self._access_token

        self.log.error("Не удалось получить валидный access_token")
        return ""

    # ----------------------------------------------------------
    # API запросы
    # ----------------------------------------------------------
    def _make_request(self, endpoint: str, method: str = "GET",
                     params: dict | None = None, data: dict | None = None,
                     retry: bool = True) -> dict:
        """Выполнить API запрос с auto-refresh при 401."""
        if not self._domain:
            return {"error": "Domain not configured"}

        url = f"https://{self._domain}.amocrm.ru{endpoint}"
        if params:
            from urllib.parse import urlencode
            url += "?" + urlencode(params)

        headers = {
            "Authorization": f"Bearer {self._access_token}",
            "Accept": "application/json"
        }

        if data:
            headers["Content-Type"] = "application/json"

        try:
            req_body = json.dumps(data).encode() if data else None
            req = Request(url, data=req_body, headers=headers, method=method)

            with urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())

        except HTTPError as e:
            # Auto-refresh на 401
            if e.code == 401 and retry and self._refresh_token:
                self.log.warning("401 Unauthorized - attempting token refresh...")
                if self._refresh_access_token():
                    # Повторяем запрос с новым токеном
                    return self._make_request(endpoint, method, params, data, retry=False)

            error_body = e.read().decode()
            self.log.error("HTTP %s: %s", e.code, error_body[:500])
            return {"error": e.code, "message": error_body[:500]}

        except Exception as e:
            self.log.error("Request error: %s", str(e))
            return {"error": "request_failed", "message": str(e)}

    # ----------------------------------------------------------
    # Загрузка лидов
    # ----------------------------------------------------------
    def fetch(self, date_from: str | None = None, date_to: str | None = None) -> int:
        """Загрузить лиды из AMO CRM и сохранить в raw.amo_leads.

        Args:
            date_from: Дата начала в формате 'YYYY-MM-DD'
            date_to: Дата окончания в формате 'YYYY-MM-DD'
        """
        if not self._load_config():
            return 0

        token = self._auth()
        if not token:
            return 0

        # Параметры запроса
        params = {
            "page": 1,
            "limit": 250,
            "with": "contacts",
            "order[created_at]": "desc",
        }

        # Добавляем фильтр по дате если указан
        if date_from:
            from_ts = int(datetime.strptime(date_from, '%Y-%m-%d').timestamp())
            params["filter[created_at][from]"] = from_ts
        if date_to:
            to_ts = int(datetime.strptime(date_to, '%Y-%m-%d').timestamp()) + 86399
            params["filter[created_at][to]"] = to_ts

        page = 1
        total = 0

        while True:
            params["page"] = page
            self.log.debug("Fetching page %s", page)

            data = self._make_request("/api/v4/leads", params=params)

            if "error" in data:
                self.log.error("AMO API error: %s", data)
                break

            records = data.get("_embedded", {}).get("leads", [])
            if not records:
                break

            saved = self._save_leads(records)
            total += saved
            self.log.info("Студия %s | AMO стр. %s: сохранено %s",
                         self.studio.studio_id, page, saved)

            # Проверяем есть ли ещё страницы
            if len(records) < 250:
                break

            page += 1

        self.log.info("Студия %s | AMO: всего сохранено %s лидов",
                     self.studio.studio_id, total)
        return total

    def fetch_by_date(self, date_str: str) -> int:
        """Загрузить лиды за конкретную дату.

        Args:
            date_str: Дата в формате 'YYYY-MM-DD'
        """
        return self.fetch(date_from=date_str, date_to=date_str)

    # ----------------------------------------------------------
    # Маппинг полей
    # ----------------------------------------------------------
    def _save_leads(self, raw_leads: list[dict]) -> int:
        """Маппинг полей AMO → raw.amo_leads и сохранение.

        Дополнительно загружает детали контактов (клиентов).
        """
        records: list[dict] = []
        contact_cache: dict[int, dict] = {}  # Кэш контактов для batch-запросов

        for lead in raw_leads:
            cf = self._extract_custom_fields(lead.get("custom_fields_values", []))

            # Получаем статус по ID
            status_id = lead.get("status_id")
            status_name = self.STATUSES.get(status_id, f"Status_{status_id}")

            # Определяем филиал
            studio_id = self._detect_studio(lead)

            # Получаем данные клиента из связанных контактов
            contact_info = self._extract_client_info(lead, contact_cache)

            records.append({
                "id": lead["id"],
                "studio_id": studio_id,
                "source": "amo",
                "status": status_id,
                "status_name": status_name,
                "utm_source": cf.get("utm_source"),
                "utm_campaign": cf.get("utm_campaign"),
                "utm_medium": cf.get("utm_medium"),
                "utm_content": cf.get("utm_content"),
                "utm_term": cf.get("utm_term"),
                "pipeline_id": lead.get("pipeline_id"),
                "responsible_id": lead.get("responsible_user_id"),
                "created_at": self._ts_to_datetime(lead.get("created_at")),
                "updated_at": self._ts_to_datetime(lead.get("updated_at")),
                "closed_at": self._ts_to_datetime(lead.get("closed_at")),
                "price": lead.get("price", 0),
                "name": lead.get("name", ""),
                # Поля клиента
                "client_id": contact_info.get("id"),
                "client_name": contact_info.get("name"),
                "client_first_name": contact_info.get("first_name"),
                "client_last_name": contact_info.get("last_name"),
                "client_phone": self.clean_phone(contact_info.get("phone")),
                "client_email": contact_info.get("email"),
                "client_responsible_id": contact_info.get("responsible_user_id"),
                "raw_data": psycopg2.extras.Json(lead),
            })

        return self._save_to_raw("amo_leads", records)

    def _extract_client_info(self, lead: dict, contact_cache: dict[int, dict]) -> dict[str, Any]:
        """Извлечь информацию о клиенте из лида.

        Использует кэш чтобы минимизировать API-запросы.
        """
        contacts = lead.get("_embedded", {}).get("contacts", [])
        if not contacts:
            return {}

        # Берём главный контакт (is_main=True) или первый
        main_contact = next((c for c in contacts if c.get("is_main")), contacts[0])
        contact_id = main_contact.get("id")

        if not contact_id:
            return {}

        # Проверяем кэш
        if contact_id in contact_cache:
            return contact_cache[contact_id]

        # Загружаем детали контакта
        contact_details = self._get_contact_details(contact_id)
        if contact_details:
            # Парсим кастомные поля
            cf = contact_details.get("custom_fields_values", [])
            phone = self._extract_contact_field(cf, "PHONE")
            email = self._extract_contact_field(cf, "EMAIL")

            result = {
                "id": contact_details.get("id"),
                "name": contact_details.get("name"),
                "first_name": contact_details.get("first_name"),
                "last_name": contact_details.get("last_name"),
                "phone": phone,
                "email": email,
                "responsible_user_id": contact_details.get("responsible_user_id"),
                "created_at": contact_details.get("created_at"),
            }
            contact_cache[contact_id] = result
            return result

        return {}

    def _get_contact_details(self, contact_id: int) -> dict | None:
        """Получить детали контакта по ID (с кастомными полями)."""
        result = self._make_request(f"/api/v4/contacts/{contact_id}", params={"with": "custom_fields"})
        if "error" in result:
            self.log.warning("Failed to fetch contact %s: %s", contact_id, result.get("error"))
            return None
        return result

    @staticmethod
    def _extract_contact_field(fields: list[dict], field_code: str) -> str | None:
        """Извлечь значение поля контакта по коду."""
        for field in fields:
            if field.get("field_code") == field_code or field.get("field_name") == field_code:
                values = field.get("values", [])
                if values:
                    return values[0].get("value")
        return None

    @staticmethod
    def _ts_to_datetime(ts: int | None) -> datetime | None:
        """Конвертировать Unix timestamp в datetime."""
        if ts:
            return datetime.fromtimestamp(ts)
        return None

    @staticmethod
    def _extract_custom_fields(fields: list[dict] | None) -> dict[str, str]:
        """Извлечь кастомные поля (UTM и др.) из AMO."""
        result: dict[str, str] = {}
        if not fields:
            return result
        for field_group in fields:
            field_code = field_group.get("field_code", "")
            values = field_group.get("values", [])
            if values and field_code:
                result[field_code] = values[0].get("value", "")
        return result

    def _detect_studio(self, lead: dict) -> str:
        """Определить филиал по статусу или ответственному.

        Приоритет:
        1. Маппинг по status_id (если статус содержит филиал в названии)
        2. Маппинг по responsible_user_id
        3. Fallback на studio из конструктора
        """
        status_id = lead.get("status_id")
        if status_id in self.STATUS_TO_STUDIO:
            return self.STATUS_TO_STUDIO[status_id]

        user_id = lead.get("responsible_user_id")
        if user_id in self.USER_TO_STUDIO:
            return self.USER_TO_STUDIO[user_id]

        return self.studio.studio_id

    # ----------------------------------------------------------
    # Утилиты
    # ----------------------------------------------------------
    def get_pipelines(self) -> dict:
        """Получить список воронок и статусов."""
        if not self._load_config():
            return {}

        token = self._auth()
        if not token:
            return {}

        return self._make_request("/api/v4/leads/pipelines")

    def get_account_info(self) -> dict:
        """Получить информацию об аккаунте."""
        if not self._load_config():
            return {}

        token = self._auth()
        if not token:
            return {}

        return self._make_request("/api/v4/account")
