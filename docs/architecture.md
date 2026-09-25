# Архитектура обхода блокировок

```
Телефон (Xray-клиент)
  ├─ Режим A (обычный интернет): VLESS + Reality ───────────────► зарубежный VPS :443
  └─ Режим B (белые списки LTE): VLESS + XHTTP / TLS
        SNI = домен Яндекса из белого списка
          └─► Yandex Cloud (фронт — выбирается по результатам тестов) ──► VPS :8443 (Caddy → Xray)

Зарубежный VPS (Xray, server/install.sh):
  inbound  VLESS-Reality :443
  inbound  VLESS-XHTTP за Caddy :8443 (TLS через Let's Encrypt, домен <ip>.sslip.io)
  outbound Google/Gemini/OpenAI/Anthropic ──► Cloudflare WARP
  outbound остальное ────────────────────────► direct (IPv4)
```

Клиент: основной путь — Reality, при недоступности — XHTTP через Яндекс; RU-домены и IP напрямую.

## Gemini / определение страны
1. Google-трафик выходит через WARP (не RU и не «хостинговый» IP).
2. На клиенте блокировать QUIC (UDP/443) и не пускать IPv6 мимо тоннеля.
3. Страна Google-аккаунта: policies.google.com → Country association.
4. iOS-приложение Gemini — только в App Store не RU региона.

## Yandex Cloud
- Каталог `default` (`b1ggs8tlauj1ndihf49b`), сервисный аккаунт `vpn-bot` (роль editor на каталог).
- IAM-токен: `yc/iam_token.sh` (рядом `sa_key.json`, в git не коммитится).
- Тестовый шлюз: `https://d5de3inaqm07734mduh7.y0g3kng5.apigw.yandexcloud.net/`

### Результаты проверки фронтов
| Фронт | Стриминг ответа | Query / свои заголовки | Вывод |
|---|---|---|---|
| API Gateway, `type: http` | нет (ответ буферизуется целиком) | обрезаются | для XHTTP не подходит напрямую |
| Serverless Containers (HTTP) | нет (буферизуется) | проходят | для XHTTP не подходит |
| Serverless Containers (WebSocket напрямую) | — | — | не поддерживается («not websocket protocol») |
| API Gateway WebSocket + Cloud Function | да, через `connections:send` | ID соединения в событии | **рабочий кандидат для релея** |
| Yandex Cloud CDN | не проверено | не проверено | нужен свой домен |

### Замеры API Gateway WebSocket (из тестового контейнера в США)
- Сообщение клиента → функция → ответ: ~200–400 мс.
- `connections:send`: максимум 131072 байт на сообщение.
- Последовательно (сохраняет порядок): ~3.5 Мбит/с на одно соединение при 128 КБ.
- Параллельно (порядок не гарантирован): ~20 Мбит/с.
- Порядок входящих сообщений **не сохраняется** (функция вызывается параллельно),
  а сообщения с интервалом < ~20 мс **теряются** (проверено изнутри Yandex Cloud, `ws-probe`).
  => стандартный Xray WS-клиент через API Gateway WebSocket работать не будет.

### Вывод
Провайдер друзей обходит белые списки через **Yandex Cloud CDN** (`cdn2.mrammor.com` →
`*.topology.gslb.yccdn.ru`) и VK Cloud CDN (`cdn-vk.mrammor.com` → `*.cdn.msk.vkcs.cloud`),
транспорт VLESS + XHTTP packet-up. Идём тем же путём: Yandex Cloud CDN → VPS :8443.
Для CDN нужен свой домен (CNAME на yccdn.ru + сертификат Let's Encrypt).

## Статус
- [x] Доступ к API Yandex Cloud
- [x] Тестовый API Gateway
- [ ] Доступность `*.apigw.yandexcloud.net` из RU LTE при белых списках
- [x] VPS куплен: is*hosting, Нидерланды, 185.93.104.30 (Ubuntu 22.04)
- [ ] `server/install.sh` отработал полностью (Caddy упал на 1-м запуске — исправлено, ждём перезапуск)
- [x] Домен wandlegacy.com (Njalla), DNS-зона в Yandex Cloud DNS `dnsafatqc1f5ka1e82gq`
- [ ] NS домена → ns1/ns2.yandexcloud.net
- [ ] Тест Serverless Containers / CDN
- [ ] Клиентский конфиг
