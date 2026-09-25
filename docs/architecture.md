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
  outbound всё ──► direct (IPv4, IP VPS в Нидерландах); блок: приватные сети, BitTorrent
```

Клиент: основной путь — Reality, при недоступности — XHTTP через Яндекс; RU-домены и IP напрямую.

## Gemini / определение страны
1. Gemini и YouTube работают напрямую с IP VPS (NL), в т.ч. с аккаунтом региона РФ (проверено на iPhone).
2. Через Cloudflare WARP Gemini отвечает «недоступен в вашей стране»: IP WARP помечены как relay/privacy.
3. Если Gemini откажет: выйти из аккаунта и войти заново; страна аккаунта — policies.google.com → Country association.

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

## Yandex CDN (рабочая схема)
- CDN-ресурс `bc8rl3nt7u5eprwicxas`: `assets.wandlegacy.com` → origin `wandlegacy.com:8443` (HTTPS, Host: wandlegacy.com), кэш выключен.
- CNAME `assets` → `965657b5cdcd71d7.topology.gslb.yccdn.ru` (IP 188.72.103.4 — тот же, что у cdn2.mrammor.com провайдера).
- **POST в Yandex CDN запрещён** (и при создании, и после) → XHTTP packet-up с `uplinkHTTPMethod: GET`,
  padding obfs как у провайдера (`_dc` / `X-Request-Context` / tokenish). Настройки padding на сервере и клиенте совпадают.
- Тело у GET-запроса CDN не пропускает, а по умолчанию (`uplinkDataPlacement: auto`) клиент кладёт данные именно в тело →
  на клиенте `uplinkDataPlacement: header` (заголовок `X-Data`) и `uplinkChunkSize: "3000-4000"`, чтобы уложиться в лимит заголовков CDN.
  Сервер в режиме `auto` читает данные и из тела, и из заголовка, и из cookie — менять его не нужно.
- Сертификат: Certificate Manager `fpqmc32pid48r4h1iduc` (Let's Encrypt, DNS-проверка через CNAME `_acme-challenge.assets`).
- Локальный e2e-тест (xray 26.3.27 + caddy): XHTTP GET-uplink и Reality проходят; без сервера — падают.
- Reality на :443 маскируется под собственный сайт (dest 127.0.0.1:8443, Caddy), сертификат Let's Encrypt wandlegacy.com.

### Важно: кэш CDN
Опция `disableCache` при создании ресурса молча игнорируется, и по умолчанию включается `edgeCacheSettings` (86400 с),
из-за чего XHTTP через CDN не работает. Нужно явно выставить `edgeCacheSettings.enabled = false` и сделать purge.

### WARP (убран)
- Пробовали пускать Google через WARP: встроенный WireGuard Xray рвал часть TLS, официальный `warp-cli` работал,
  но Gemini через него — «недоступен в стране» (IP WARP = relay). WARP удалён, всё идёт direct.
- Зависания YouTube/Gemini на самом деле были из-за лимита заголовков XHTTP (ниже), а не из-за IP хостинга.
- `routeOnly` не используется: с ним IPv6-адреса от телефона шли на VPS без IPv6 (`network is unreachable`).
- iOS: в Happ приложение YouTube не работало, в Streisand — работает (до исправления лимита заголовков).

### Лимит заголовков XHTTP (причина зависаний YouTube/Gemini)
- С `uplinkDataPlacement: header` клиент кладёт данные в заголовки `X-Data-0..N` (по `uplinkChunkSize` каждый),
  а весь запрос ограничен `scMaxEachPostBytes` (было 512 КБ).
- Сервер Xray по умолчанию принимает всего 8 КБ заголовков → Caddy: `http2: request header list larger than peer's
  advertised limit`, 502, данные теряются. Страдали «тяжёлые» приложения, лёгкий трафик проходил.
- Исправление: сервер `serverMaxHeaderBytes: 1048576`, клиент `scMaxEachPostBytes: 16384` (запрос ≲ 22 КБ заголовков;
  через Яндекс CDN проходили запросы ~24 КБ).
