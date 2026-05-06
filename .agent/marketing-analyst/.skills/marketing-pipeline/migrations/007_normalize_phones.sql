-- Migration 007: Normalize phone numbers across all raw tables
-- Формат: 7XXXXXXXXXX (11 цифр, без +, без 8)
-- Используется для корректного кросс- source матчинга по телефону

-- ============================================================
-- 1. Нормализация телефонов в AMO leads
-- ============================================================
UPDATE raw.amo_leads
SET client_phone = regexp_replace(client_phone, '\D', '', 'g')
WHERE client_phone IS NOT NULL;

UPDATE raw.amo_leads
SET client_phone = '7' || client_phone
WHERE client_phone IS NOT NULL
  AND LENGTH(client_phone) = 10;

UPDATE raw.amo_leads
SET client_phone = '7' || substring(client_phone, 2)
WHERE client_phone IS NOT NULL
  AND LENGTH(client_phone) = 11
  AND client_phone LIKE '8%';

UPDATE raw.amo_leads
SET client_phone = NULL
WHERE client_phone IS NOT NULL
  AND client_phone = '';

-- ============================================================
-- 2. Нормализация телефонов в YClients visits
-- ============================================================
UPDATE raw.yc_visits
SET client_phone = regexp_replace(client_phone, '\D', '', 'g')
WHERE client_phone IS NOT NULL;

UPDATE raw.yc_visits
SET client_phone = '7' || client_phone
WHERE client_phone IS NOT NULL
  AND LENGTH(client_phone) = 10;

UPDATE raw.yc_visits
SET client_phone = '7' || substring(client_phone, 2)
WHERE client_phone IS NOT NULL
  AND LENGTH(client_phone) = 11
  AND client_phone LIKE '8%';

UPDATE raw.yc_visits
SET client_phone = NULL
WHERE client_phone IS NOT NULL
  AND client_phone = '';

-- ============================================================
-- 3. Нормализация телефонов в Google Sheets leads
-- ============================================================
UPDATE raw.gsheets_leads
SET client_phone = regexp_replace(client_phone, '\D', '', 'g')
WHERE client_phone IS NOT NULL;

UPDATE raw.gsheets_leads
SET client_phone = '7' || client_phone
WHERE client_phone IS NOT NULL
  AND LENGTH(client_phone) = 10;

UPDATE raw.gsheets_leads
SET client_phone = '7' || substring(client_phone, 2)
WHERE client_phone IS NOT NULL
  AND LENGTH(client_phone) = 11
  AND client_phone LIKE '8%';

UPDATE raw.gsheets_leads
SET client_phone = NULL
WHERE client_phone IS NOT NULL
  AND client_phone = '';
