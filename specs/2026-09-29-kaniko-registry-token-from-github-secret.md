id: 2026-09-29-kaniko-registry-token-from-github-secret
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

В задаче TD-1665 экшен `actions/kaniko-build` был переведен на дефолт `docker_secret: 'thedevs-registry-secret'` с жесткой pre-flight проверкой наличия K8s-секрета в сборочном namespace (код возврата 1 при отсутствии).

Это создает операционную проблему: для каждого сборочного неймспейса флота (`dev`, `master`, `su`, `gorodchickov`, `monitoring33` и новых изолированных сред) требуется вручную предсоздавать K8s-секрет `thedevs-registry-secret`. Если в каком-либо сборочном namespace секрет отсутствует (как наблюдалось в `euromobil-2`), конвейер падает до запуска сборки.

Целевое решение — перенести аутентификацию корпоративного реестра `registry.thedevs.ru` на уровень GitHub Secrets организации (`REGISTRY_TOKEN` / `REGISTRY_PASSWORD`). Экшен `actions/kaniko-build` должен поддерживать получение токена реестра через входные параметры и внедрение авторизации в `/docker-config/config.json` на лету внутри пода Kaniko через init-контейнер `merge-docker-config` (по аналогии с существующей интеграцией Docker Hub). Это полностью избавляет от необходимости дублировать K8s-секреты по всем неймспейсам кластера.

# Что сделать

1. **Входные параметры в `actions/kaniko-build/action.yml`:**
   - Добавить входной параметр `registry_token` (описание: `'Auth token or password for corporate registry'`, required: false, default: `''`).
   - Добавить входной параметр `registry_username` (описание: `'Username for corporate registry'`, required: false, default: `'thedevsru'`).
   - Добавить входной параметр `registry_server` (описание: `'Server hostname for corporate registry'`, required: false, default: `'registry.thedevs.ru'`).

2. **Корректировка pre-flight проверки в `actions/kaniko-build/action.yml`:**
   - Изменить условие pre-flight проверки секрета: если передан непустой `registry_token`, отсутствие K8s-секрета не является блокирующей ошибкой (выводится информационное сообщение или warning, но не `exit 1`).
   - Фатальная ошибка (`exit 1` при `NotFound`) генерируется только в случае, когда `registry_token` пуст, а указанный `docker_secret` отсутствует в целевом сборочном namespace.

3. **Формирование заголовка авторизации и передача в init-контейнер:**
   - В блоке `run:` шага `Run Kaniko Build` сформировать base64-строку авторизации:
     `REGISTRY_B64=$(printf '%s:%s' "$REGISTRY_USERNAME" "$REGISTRY_TOKEN" | base64 -w0)` (при непустых значениях).
   - Передать `REGISTRY_B64` и `REGISTRY_SERVER` в переменные окружения init-контейнера `merge-docker-config` манифеста пода.
   - В скрипте `merge-docker-config` добавить внедрение блока авторизации для `REGISTRY_SERVER` в `/docker-config/config.json` (через модификацию секции `auths` аналогично существующему блоку `DOCKERHUB_B64`).

4. **Документация:**
   - В `actions/kaniko-build/README.md` описать новые параметры `registry_token`, `registry_username`, `registry_server` и привести пример вызова сборки с передачей секрета из `secrets.REGISTRY_TOKEN`.

# Что уже есть

1. Экшен `actions/kaniko-build/action.yml` на ветке `dev` репозитория `THEDEVS-RU/.github`.
2. Готовый рабочий паттерн передачи креденшелов через env и внедрения в `/docker-config/config.json` внутри init-контейнера `merge-docker-config` (реализован для `DOCKERHUB_USERNAME` и `DOCKERHUB_TOKEN`).
3. Механизм опционального монтирования томов `secret-orig` с фолбэком на `emptyDir`.

# Критерии готовности

1. В `actions/kaniko-build/action.yml` объявлены параметры `registry_token`, `registry_username`, `registry_server`.
2. При передаче `registry_token` init-контейнер `merge-docker-config` добавляет валидный блок авторизации для указанного сервера в `/docker-config/config.json` внутри пода.
3. Pre-flight проверка в `actions/kaniko-build/action.yml` не завершается с кодом 1 при отсутствии K8s-секрета, если передан `registry_token`.
4. Сохранена полная обратная совместимость для пайплайнов, продолжающих передавать K8s-секрет через `docker_secret`.
5. Документация в `actions/kaniko-build/README.md` актуализирована.

# Не трогать

1. Не изменять логику и тесты композитного экшена `actions/deploy-resolve` (`actions/deploy-resolve/action.yml`, `actions/deploy-resolve/resolve.sh`, `tests/test-deploy-resolve.sh`).
2. Не изменять конечный автомат опроса статуса подов, лимиты ресурсов контейнеров, тома кэша (`kaniko-cache`, `cache_pvc`) и таймауты сборки.
3. Не модифицировать корневой `README.md` репозитория `THEDEVS-RU/.github`.
