id: 2026-09-29-shared-ssh-compose-deploy-action
product: global
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

В организации `THEDEVS-RU` развертывание приложений на выделенных виртуальных машинах и серверах без Kubernetes выполняется через Docker Compose по протоколу SSH. Исторически реализация этого механизма существовала исключительно в виде локального action репозитория `euromobil-2` (`.github/actions/ssh-compose-deploy/action.yml`), содержащего жестко зашитые дефолтные значения параметров целевого проекта (`app_dir: /opt/euromobil-2`, `service_name: euromobil-2`, `container_name: euromobil-2`).

При стандартизации CI/CD конвейера в проекте `marta` (задача `TD-1662`) возникла необходимость развертывания по SSH на изолированных стендах. Дублирование кода экшена в репозиторий `marta` нарушает принцип единого центра платформенных переиспользуемых действий организации, где уже успешно размещен общий экшен сборки `actions/kaniko-build/action.yml` (`THEDEVS-RU/.github@dev`).

Для обеспечения переиспользуемости, надежности и изоляции ключей создается единый централизованный composite action в репозитории `THEDEVS-RU/.github` по пути `actions/ssh-compose-deploy/action.yml` с веткой доставки `dev`.

# Что сделать

- Создать файл `actions/ssh-compose-deploy/action.yml` в репозитории `THEDEVS-RU/.github`.

### Входные параметры (inputs)
Экшен объявляется универсальным и не содержит продуктовых дефолтов:
- `host` (`required: true`): IP-адрес или сетевое имя целевого сервера;
- `port` (`required: true`): SSH-порт для подключения (обычно `22` или `2299`);
- `user` (`required: true`): пользователь ОС для SSH-соединения (например, `dreizer`);
- `key` (`required: true`): закрытый ключ SSH (ed25519/rsa);
- `known_hosts` (`required: true`): строка отпечатка хоста `known_hosts` для строгой валидации TLS/SSH;
- `image` (`required: true`): базовое имя Docker-образа без тега (например, `registry.thedevs.ru/thedevs-ru/marta`);
- `tag` (`required: true`): тег развертываемого образа;
- `app_dir` (`required: true`): абсолютный путь к рабочей директории на сервере (обязательный вход без дефолта);
- `service_name` (`required: true`): имя службы в `docker-compose.yml` (обязательный вход без дефолта);
- `container_name` (`required: true`): имя запускаемого контейнера (обязательный вход без дефолта);
- `compose_dir` (`required: false`, `default: 'Deployment'`): относительный путь к локальному каталогу репозитория, содержащему `docker-compose.yml` и `deploy.sh`;
- `ghcr_user` (`required: false`, `default: ''`): имя пользователя для аутентификации при заборе из GHCR;
- `ghcr_token` (`required: false`, `default: ''`): токен доступа при заборе из GHCR.

### Выходные параметры (outputs)
- `deployed_image`: проверенный тег фактически запущенного контейнера, полученный через `docker inspect`.

### Логика выполнения (runs)
1. **Валидация параметров**:
   - Строгая проверка на непустоту всех обязательных входов: `host`, `port`, `user`, `key`, `known_hosts`, `image`, `tag`, `app_dir`, `service_name`, `container_name`. При пустом значении любого из них шаг завершается с ошибкой `exit 1`.
2. **Изоляция SSH-ключей**:
   - Создание изолированного временного каталога через `mktemp -d`;
   - Сохранение закрытого ключа в `id_key` с правами `0600`;
   - Сохранение `known_hosts` с правами `0600`;
   - Настройка вызова `ssh` и `scp` с флагами `-o StrictHostKeyChecking=yes -o UserKnownHostsFile=... -i ... -p ...`;
   - Установка `trap 'rm -rf "$TMP_SSH_DIR"' EXIT` для гарантированной очистки приватного ключа с раннера.
3. **Подготовка директории и аутентификация**:
   - Создание каталога `app_dir` на целевом хосте: `mkdir -p "$APP_DIR"`;
   - Выполнение `docker login ghcr.io` только если `image` начинается с `ghcr.io/` и передан непустой `ghcr_token`. Для внутренних реестров `registry.thedevs.ru` аутентификация в экшене не требуется.
4. **Синхронизация и выполнение деплоя**:
   - Копирование `docker-compose.yml` и `deploy.sh` из `$COMPOSE_DIR` в `$APP_DIR/` по `scp`;
   - Установка прав на исполнение `chmod +x "$APP_DIR/deploy.sh"`;
   - Запуск скрипта деплоя:
     `APP_DIR="$APP_DIR" IMAGE_NAME="$IMAGE" SERVICE_NAME="$SERVICE_NAME" CONTAINER_NAME="$CONTAINER_NAME" "$APP_DIR/deploy.sh" "$TAG" "$IMAGE" "$CONTAINER_NAME" "$SERVICE_NAME"`;
5. **Верификация результата**:
   - Чтение фактически запущенного образа: `DEPLOYED_IMAGE=$(ssh ... "docker inspect -f '{{.Config.Image}}' '$CONTAINER_NAME'")`;
   - Передача значения в `steps.deploy.outputs.deployed_image` и `GITHUB_OUTPUT`.

# Что уже есть

- Проверенный прототип действия в репозитории `THEDEVS-RU/euromobil-2:.github/actions/ssh-compose-deploy/action.yml`.
- Централизованный публичный репозиторий `THEDEVS-RU/.github` с рабочей веткой `dev`, доступный всем воркфлоу организации через `uses: THEDEVS-RU/.github/actions/...@dev`.

# Критерии готовности

- В репозитории `THEDEVS-RU/.github` на ветке `dev` создан файл `actions/ssh-compose-deploy/action.yml`.
- Все специфичные для проектов дефолты (`euromobil-2`) устранены, параметры `app_dir`, `service_name`, `container_name` объявлены обязательными (`required: true`).
- Реализована строгая валидация обязательных параметров с немедленным выходом при отсутствии значений.
- Создание временного каталога и очистка закрытых ключей гарантируются через `trap ... EXIT`.
- Спецификация проходит валидацию скриптом `references/contracts/builder/tools/validate-spec-format.sh`.

# Не трогать

- Файл `actions/kaniko-build/action.yml` и его функциональность.
- Шаблоны issues и документацию в `THEDEVS-RU/.github`.
- Репозиторий `euromobil-2` (перевод `euromobil-2` на централизованный экшен оформляется отдельной задачей).
