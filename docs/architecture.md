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
| Serverless Containers | не проверено | не проверено | следующий тест |
| Yandex Cloud CDN | не проверено | не проверено | нужен свой домен |

## Статус
- [x] Доступ к API Yandex Cloud
- [x] Тестовый API Gateway
- [ ] Доступность `*.apigw.yandexcloud.net` из RU LTE при белых списках
- [ ] VPS куплен, `server/install.sh` запущен
- [ ] Тест Serverless Containers / CDN
- [ ] Клиентский конфиг
