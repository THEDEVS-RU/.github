id: 2026-09-29-shared-cicd-actions
product: global
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

В рамках перехода платформы TheDevs на единый стандарт CI/CD (задачи TD-1659...TD-1663) сервисы организации (`template-project`, `shield`, `marta`, `thedevslk` и др.) требуют централизованных действий для развёртывания и сборки:
1. Дублирование кода деплоя по SSH: логика подключения по SSH, копирования шаблонов Compose, запуска `deploy.sh` с контролем готовности и отката ранее реализовывалась локально внутри конкретных сервисов (например, `euromobil-2`). Копирование этой логики в каждый проект нарушает принцип DRY и приводит к расхождению реализаций.
2. Дублирование шага определения целевого деплоя: логика выбора между Kubernetes и SSH Compose повторяется в трёх воркфлоу каждого из микросервисов (`build.yml`, `release.yml`, `redeploy.yml`).
3. Скрытая зависимость от `ghcr-secret` в `actions/kaniko-build/action.yml`: параметр `docker_secret` имеет значение по умолчанию `'ghcr-secret'` и безусловно монтирует secret-том `secretName: $SECRET` без флага `optional: true`. При отказе от GitHub Container Registry под Kaniko падает в кластере, если секрет `ghcr-secret` отсутствует в сборочном namespace.

Для решения этих задач в публичном репозитории `THEDEVS-RU/.github` создаются и обновляются централизованные composite actions, доступные всем репозиториям организации на ветке `dev`.

# Что сделать

### 1. Создание composite action `actions/ssh-compose-deploy/action.yml`

Создать централизованный composite action для развёртывания docker-compose приложений по SSH:
- **Inputs:**
  - `host`: обязательный, целевой IP или домен сервера.
  - `port`: необязательный, по умолчанию `'22'`, SSH-порт.
  - `user`: обязательный, имя пользователя SSH (например, из `vars.SSH_USER`).
  - `key`: обязательный, приватный SSH-ключ.
  - `known_hosts`: обязательный, строка SSH known_hosts.
  - `image`: обязательный, базовое имя образа без тега (`registry.thedevs.ru/...`).
  - `tag`: обязательный, тег развёртываемого образа.
  - `app_dir`: обязательный, целевой каталог приложения на сервере (например, `/opt/template-project`).
  - `compose_dir`: необязательный, по умолчанию `'Deployment/compose'`, локальный каталог с `docker-compose.yml`.
  - `service_name`: необязательный, по умолчанию `'app'`, имя сервиса в Compose.
  - `container_name`: необязательный, по умолчанию `'app'`, имя контейнера.
  - `healthcheck_port`: необязательный, по умолчанию `'8080'`, порт проверки жизнеспособности.
  - `healthcheck_path`: необязательный, по умолчанию `'/login'`, HTTP-путь проверки.
  - `healthcheck_timeout`: необязательный, по умолчанию `'300'`, таймаут ожидания готовности в секундах.
- **Outputs:**
  - `deployed_image`: фактическое имя и тег развёрнутого образа из `docker inspect`.
- **Логика выполнения:**
  - Проверка заполненности обязательных входных параметров.
  - Создание временного каталога SSH с правами `0600` для `id_key` и `known_hosts`.
  - Вызов `ssh` с флагами `-o StrictHostKeyChecking=yes` и `-o UserKnownHostsFile`.
  - Создание удалённого каталога `$APP_DIR`.
  - Копирование `docker-compose.yml` из `$COMPOSE_DIR` на удалённый хост.
  - Встроенный в экшен скрипт `deploy.sh` передается и исполняется на удалённом хосте:
    - управляет файлом `.env` с правами `0600`;
    - считывает `PREV_TAG` и `PREV_IMAGE` для отката;
    - выполняет `docker compose pull "$SERVICE"`;
    - обновляет переменные `IMAGE_NAME` и `IMAGE_TAG` в `.env`;
    - выполняет `docker compose up -d --remove-orphans "$SERVICE"`;
    - циклически с шагом 4с опрашивает `http://127.0.0.1:${HEALTHCHECK_PORT}${HEALTHCHECK_PATH}`;
    - при успехе выполняет `docker rmi` для старых образов сервиса кроме текущего и предыдущего;
    - при сбое выводит логи `docker compose logs --tail=200`, производит автоматический откат на `PREV_TAG` при его наличии и завершается с кодом 1.
  - Экшен получает `deployed_image` через `docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME"` и пишет его в `$GITHUB_OUTPUT`.
  - Никакой авторизации в `ghcr.io` не выполняется (образ забирается нодами из `registry.thedevs.ru`).

### 2. Создание composite action `actions/resolve-deploy-target/action.yml`

Создать централизованный composite action для динамического определения целевого типа развёртывания:
- **Inputs:**
  - `deploy_config_k8s`: строка K8s kubeconfig (секрет `DEPLOY_CONFIG_K8S || secrets.KUBE_CONFIG`).
  - `ssh_host`: хост сервера SSH (`vars.SSH_HOST`).
  - `ssh_user`: пользователь SSH (`vars.SSH_USER`).
  - `ssh_key`: приватный SSH-ключ (`secrets.SSH_PRIVATE_KEY || secrets.SSH_KEY`).
  - `ssh_known_hosts`: хост-ключ SSH (`secrets.SSH_KNOWN_HOSTS`).
- **Outputs:**
  - `target`: `'k8s'` или `'ssh'`.
  - `is_k8s`: `'true'` или `'false'`.
  - `is_ssh`: `'true'` или `'false'`.
- **Логика выполнения:**
  - Если вход `deploy_config_k8s` не пуст:
    - установить `target='k8s'`, `is_k8s='true'`, `is_ssh='false'`;
    - вывести информационное сообщение `Selected deployment target: Kubernetes`.
  - Если вход `deploy_config_k8s` пуст:
    - проверить наличие параметров SSH:
      - проверить обязательные переменные: `ssh_host`, `ssh_user`, `ssh_key`, `ssh_known_hosts`;
      - если присутствуют все 4 параметра:
        - установить `target='ssh'`, `is_k8s='false'`, `is_ssh='true'`;
        - вывести информационное сообщение `Selected deployment target: SSH Compose`;
      - если задана хотя бы одна SSH переменная, но отсутствуют остальные:
        - сформировать список пропущенных параметров и прервать выполнение с кодом 1 (`::error::Incomplete SSH configuration: missing <list>`);
      - если не задан ни K8s-секрет, ни один из SSH-параметров:
        - прервать выполнение с кодом 1 (`::error::Neither Kubernetes (DEPLOY_CONFIG_K8S) nor SSH (SSH_HOST, SSH_USER, SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS) configuration is provided`).

### 3. Модификация `actions/kaniko-build/action.yml`

1. **Изменение входного параметра `docker_secret`:**
   - Изменить `default: 'ghcr-secret'` на `default: ''`.
2. **Условное монтирование тома секрета в под Kaniko:**
   - В шаблоне создания пода `APPLY_OUT`:
     - Если переменная `$SECRET` не пуста:
       - секция тома формируется как:
         ```yaml
         - name: secret-orig
           secret:
             secretName: $SECRET
             optional: true
         ```
     - Если переменная `$SECRET` пуста (по умолчанию):
       - том `secret-orig` создается как `emptyDir: {}`:
         ```yaml
         - name: secret-orig
           emptyDir: {}
         ```
   - В init-контейнере `merge-docker-config`:
     - Строка `cp /secret-orig/.dockerconfigjson /docker-config/config.json 2>/dev/null || echo '{"auths":{}}' > /docker-config/config.json` при пустом томе штатно формирует базовый `{"auths":{}}`.
     - При передаче `dockerhub_username` и `dockerhub_token` в конфигурационный файл добавляется авторизация Docker Hub.
   - Под Kaniko больше не падает из-за отсутствия `ghcr-secret` в namespace сборки при пуше в `registry.thedevs.ru`.

# Что уже есть

- Базовый сборочный action `actions/kaniko-build/action.yml` с поддержкой таймаутов, кэширования и бэкоффа.
- Проверенный сценарий деплоя SSH из `euromobil-2` (`Deployment/old/deploy.sh`).
- Публичный репозиторий `THEDEVS-RU/.github` с рабочей веткой `dev`.

# Критерии готовности

- В репозитории `THEDEVS-RU/.github` на ветке `dev` созданы:
  - `actions/ssh-compose-deploy/action.yml`
  - `actions/resolve-deploy-target/action.yml`
- В `actions/kaniko-build/action.yml`:
  - вход `docker_secret` имеет значение по умолчанию пустую строку `default: ''`;
  - при пустом значении `docker_secret` том `secret-orig` создаётся как `emptyDir: {}`;
  - при указанном значении `docker_secret` в манифесте тома выставляется `optional: true`.
- В `actions/resolve-deploy-target/action.yml` реализована строгая валидация SSH параметров по AND с подробным перечислением недостающих ключей при неполной настройке.
- В `actions/ssh-compose-deploy/action.yml` параметризованы `healthcheck_port`, `healthcheck_path`, `healthcheck_timeout` и исключена авторизация в `ghcr.io`.
- Спецификация успешно проходит валидацию `validate-spec-format.sh`.

# Не трогать

- Файлы `profile/README.md`, `README.md`, `.github/ISSUE_TEMPLATE/`.
- Существующие параметры кэширования и логику повторов в `actions/kaniko-build/action.yml`.
