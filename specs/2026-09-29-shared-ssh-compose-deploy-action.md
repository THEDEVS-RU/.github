id: 2026-09-29-shared-ssh-compose-deploy-action
product: global
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

В организации `THEDEVS-RU` развертывание приложений на виртуальные серверы через SSH и Docker Compose в настоящее время реализовано локально в виде экшена `.github/actions/ssh-compose-deploy/action.yml` внутри репозитория `THEDEVS-RU/euromobil-2`. Данная реализация содержит жестко зашитые параметры конкретного продукта:
1. Захардкоженные дефолты путей и сервисов (`/opt/euromobil-2`, `euromobil-2`).
2. Привязка аутентификации исключительно к реестру GitHub Packages (`ghcr.io` / `ghcr_user` / `ghcr_token`), что противоречит принятому платформенному стандарту TheDevs об обязательном использовании единого центрального реестра `registry.thedevs.ru`.
3. Копирование экшена в другие проекты (в частности, в `mobitrack-2`) привело бы к дублированию кода между репозиториями и расхождению логики.

В соответствии с общеплатформенным стандартом TheDevs CI/CD (задачи TD-1659, TD-1660, TD-1661, TD-1662, EMB-37, MOBI2-288) логика развертывания через SSH Compose выносится в единый централизованный composite action в публичном репозитории `THEDEVS-RU/.github` по пути `actions/ssh-compose-deploy/action.yml`. Веткой доставки является `dev`. После слияния action становится доступен всем репозиториям организации через синтаксис `uses: THEDEVS-RU/.github/actions/ssh-compose-deploy@dev`.

Первичным потребителем экшена является проект `euromobil-2` (перевод которого на общий экшен оформляется отдельной задачей), а также проекты платформы, развертываемые на SSH-хостах. В репозитории `mobitrack-2` общий экшен указывается в качестве альтернативного транспорта развертывания на случай появления целевых окружений вне Kubernetes.

# Что сделать

Создать файл `actions/ssh-compose-deploy/action.yml` в репозитории `THEDEVS-RU/.github`.

### Входные параметры (inputs)

- `host`: обязательный (`required: true`), адрес или IP-адрес целевого сервера.
- `port`: необязательный (`required: false`), порт SSH, по умолчанию `'22'`.
- `user`: обязательный (`required: true`), имя пользователя для SSH-подключения.
- `key`: обязательный (`required: true`), приватный ключ SSH.
- `known_hosts`: обязательный (`required: true`), строка known_hosts для защиты от MITM-атак.
- `image`: обязательный (`required: true`), полное имя базового образа (например, `registry.thedevs.ru/thedevs-ru/euromobil-2`).
- `tag`: обязательный (`required: true`), тег развертываемой версии образа.
- `app_dir`: обязательный (`required: true`), путь к целевой директории на удаленном сервере (без захардкоженных продуктовых дефолтов).
- `compose_dir`: обязательный (`required: true`), путь к локальной директории репозитория, содержащей `docker-compose.yml` и `deploy.sh`.
- `service_name`: обязательный (`required: true`), имя сервиса в `docker-compose.yml`.
- `container_name`: обязательный (`required: true`), целевое имя контейнера.
- `registry_url`: необязательный (`required: false`), URL реестра контейнеров, по умолчанию `'registry.thedevs.ru'`.
- `registry_user`: необязательный (`required: false`), имя пользователя для docker login, по умолчанию пустая строка.
- `registry_token`: необязательный (`required: false`), токен/пароль для docker login, по умолчанию пустая строка.

### Выходные параметры (outputs)

- `deployed_image`: полное имя образа фактически запущенного контейнера на сервере (значение `{{.Config.Image}}` из `docker inspect`).

### Реализация шагов экшена

1. **Валидация обязательных параметров**:
   - Проверка непустых значений `host`, `port`, `user`, `key`, `known_hosts`, `image`, `tag`, `app_dir`, `compose_dir`, `service_name`, `container_name`.
2. **Изоляция SSH-ключей**:
   - Создание изолированного временного каталога через `mktemp -d` с обязательным удалением по `trap 'rm -rf ...' EXIT`.
   - Запись ключа и `known_hosts` с правами доступа `0600`.
   - Выполнение команд через `ssh` и `scp` со строгой проверкой хоста (`-o StrictHostKeyChecking=yes -o UserKnownHostsFile=...`).
3. **Подготовка и авторизация**:
   - Создание каталога приложения: `ssh ... "mkdir -p '$APP_DIR'"`.
   - Если переданы непустые `registry_user` и `registry_token`, выполнение авторизации на удаленном сервере:
     `printf '%s' "$TOKEN" | ssh ... "docker login '$REGISTRY_URL' -u '$USER' --password-stdin"`.
4. **Доставка манифестов и запуск**:
   - Копирование `docker-compose.yml` и `deploy.sh` из `$COMPOSE_DIR` в `$APP_DIR` на сервере через `scp`.
   - Выставление прав исполнения и запуск скрипта развертывания:
     `ssh ... "chmod +x '$APP_DIR/deploy.sh' && APP_DIR='$APP_DIR' IMAGE_NAME='$IMAGE' SERVICE_NAME='$SERVICE_NAME' CONTAINER_NAME='$CONTAINER_NAME' '$APP_DIR/deploy.sh' '$TAG' '$IMAGE' '$CONTAINER_NAME' '$SERVICE_NAME'"`.
5. **Верификация развернутого контейнера**:
   - Опрос запущенного контейнера: `docker inspect -f '{{.Config.Image}}' '$CONTAINER_NAME'`.
   - Запись значения в `$GITHUB_OUTPUT` под ключом `deployed_image`.
   - Проверка соответствия запущенного образа ожидаемому тегу `:${TAG}`.

# Что уже есть

- Локальная реализация composite action в `THEDEVS-RU/euromobil-2` (`.github/actions/ssh-compose-deploy/action.yml`), доказавшая работоспособность на стендах с Docker Compose.
- Централизованный экшен сборки `actions/kaniko-build/action.yml` в `THEDEVS-RU/.github` как образец оформления общих экшенов организации.

# Критерии готовности

- В репозитории `THEDEVS-RU/.github` на ветке `dev` создан файл `actions/ssh-compose-deploy/action.yml`.
- Экшен параметризован универсальными входами без специфичных для какого-либо отдельного продукта путей или имен сервисов.
- Экшен поддерживает авторизацию в произвольном Docker-реестре (по умолчанию `registry.thedevs.ru`), не требуя обязательного логина при анонимном доступе.
- Экшен возвращает output `deployed_image` с результатом `docker inspect`.
- Спецификация проходит валидацию скриптом `references/contracts/builder/tools/validate-spec-format.sh specs/2026-09-29-shared-ssh-compose-deploy-action.md`.

# Не трогать

- Действие сборки `actions/kaniko-build/**`.
- Конфигурационные файлы организации в `.github/` и `profile/`.
- Файл `README.md` репозитория.
