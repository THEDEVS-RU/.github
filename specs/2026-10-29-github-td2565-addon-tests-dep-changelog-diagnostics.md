---
id: 2026-10-29-github-td2565-addon-tests-dep-changelog-diagnostics
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high
---

# Контекст

TD-2565: `testAddon_chats` в `THEDEVS-RU/addon-core-ai` PR #246 (run 40783996903) падает на `8-business-role-6` («column business_role_id already exists»). Расследование показало, что харнесс TD-2533 ведёт себя по замыслу, а дефект — в тестовом changelog'е зависимости chats (самописный changeSet `add-business-role-id-to-core-user` дублирует DDL core под другим id; исправление — отдельная спека `2026-10-29-chats-td2565-test-changelog-real-business-role` в `THEDEVS-RU/addon-chats`). Гипотеза постановки «core включается дважды» опровергнута: повторное вхождение `1-init-entities.xml` дубль-фильтр пропустил, миграция упала только на changeSet с иным идентификатором.

Причина искалась выводом, потому что лог харнесса не называет changelog зависимости: строка `[TD-2533] aggregate-changelog for 'chats': dep changelog position=first, module changelogs=…` (`actions/setup-addon-tests/ci-addon-tests.init.gradle:1003`) показывает позицию, но не путь файла зависимости и хоста. Эта спека делает следующий такой сбой диагностируемым по одному логу и фиксирует в документации контракт тестового changelog'а зависимости. Поведение агрегата, порядок включений и флаги Liquibase **не меняются**.

# Что сделать

## 1. Лог агрегата

В `actions/setup-addon-tests/ci-addon-tests.init.gradle` в строке `println "[TD-2533] aggregate-changelog for '${baseModule}': …"` (внутри `unpackTask.doLast`, строка 1003) добавить после `dep changelog position=${depPosition}` фрагмент `, dep changelog path=${normDepChangelog ?: 'none'}, dep changelog included=${depIncluded}, host changelog=${normHostChangelog ?: 'none'}`, где `depIncluded` — `true`, если changelog зависимости фактически записан в агрегат (`depChangelog != null` и либо `depMatchesModule`, либо `!hostAlreadyIncludesDep`), иначе `false` (в этом случае `position=first` печатается, но файл не пишется, строки 985-989); остальной текст строки (`, module changelogs=…`) сохранить. Переменные `normDepChangelog`, `normHostChangelog`, `depMatchesModule`, `hostAlreadyIncludesDep` уже объявлены в том же блоке (строки 955, 966-969); `depIncluded` вычисляется там же, до `println`. Префикс `[TD-2533] aggregate-changelog for '<dep>': dep changelog position=<…>` остаётся прежним, чтобы существующие проверки теста не ломались.

## 2. Контрактный тест

В `tests/test-setup-addon-tests.sh` рядом с существующей проверкой строки `[TD-2533] aggregate-changelog for 'itink'` (строка 1134) добавить проверку наличия во `$DOWNSTREAM_LOG` фрагментов `dep changelog path=ru/thedevs/itink/liquibase/changelog.xml` и `dep changelog included=true` (значение совпадает с `main.liquibase.change-log` фикстуры, строка 308, и с проверкой на строке 861). Формат сообщения об ошибке — как у соседних проверок.

## 3. Документация

В `AGENTS.md`, раздел «Схема БД testAddon: changelog транзитивных модулей (TD-2533)» (строка 101):

1. В подраздел «Диагностика» (строка 133) обновить формат строки лога: `[TD-2533] aggregate-changelog for '<dep>': dep changelog position=<first|topological>, dep changelog path=<path|none>, dep changelog included=<true|false>, host changelog=<path|none>, module changelogs=<paths>`.
2. В подраздел «Контракт модуля» (строка 128) добавить пункт «Тестовый changelog зависимости»: если `main.liquibase.change-log` зависимости не совпадает с changelog какого-либо модуля, он применяется в `testAddon_<dep>` **первым**, до полных changelog'ов модулей (в т.ч. core). Поэтому он не должен содержать собственных changeSet'ов, воспроизводящих DDL upstream-модулей под другим id/author (пример дефекта — TD-2565: `add-business-role-id-to-core-user` против `8-business-role-6`); вместо этого он включает настоящие файлы upstream (`<include file="…/008-business-role.xml"/>`), у которых совпадают путь (в т.ч. `logicalFilePath`) и id, и повторное вхождение пропускает дубль-фильтр. Допустимы собственные changeSet'ы с тестовыми данными, не пересекающиеся со схемой модулей.
   Второе правило: поскольку тестовый changelog применяется первым, он не может опираться на `<property>`, объявленные в changelog'ах модулей, идущих позже (например, `offsetDateTime.type` объявлен только в `io/jmix/email/liquibase/changelog.xml`, `dep-sources/io.jmix.email/jmix-email-3.0.0@local:…:35`). Свойства, нужные включённым upstream-файлам, он объявляет сам до первого `include` (как `THEDEVS-RU/addon-core-ai@dev:coreai/src/test/resources/ru/thedevs/coreai/liquibase/test-changelog.xml:28`).
   Примеры нарушения первого правила: шим `add-business-role-id-to-core-user` в `addon-chats` (TD-2565, спека `2026-10-29-chats-td2565-test-changelog-real-business-role`) и заглушки `0-create-core-secret-table` в `addon-yandex-metrika` и `addon-yandex-webmaster` (спеки `2026-10-29-metrika-td2565-test-changelog-real-core-secret` и `2026-10-29-webmaster-td2565-test-changelog-real-core-secret`, ветки `arch/<id>` соответствующих репозиториев; это отдельные follow-up, в приёмку TD-2565 не входят).
3. В подраздел «Компромиссы и риски» добавить: дубль-фильтр отождествляет только changeSet'ы с совпадающими путём, id и author; конфликтующий DDL с иной идентичностью не отсекается и проявляется как ошибка миграции в `testAddon_*`.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:966-967` — `normDepChangelog`, `normHostChangelog` (результат `normalizeLiquibasePath`, строка 205).
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:983-1003` — `depPosition`, порядок записи агрегата и текущая строка лога.
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:1134,1182` — существующие проверки строк `[TD-2533]` в `$DOWNSTREAM_LOG`.
- `THEDEVS-RU/.github@dev:AGENTS.md:101-140` — подраздел TD-2533.
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:955-969` — `hostAlreadyIncludesDep`, `depMatchesModule`.
- `dep-sources/io.jmix.email/jmix-email-3.0.0@local:io/jmix/email/liquibase/changelog.xml:35` — единственное определение `offsetDateTime.type` в Jmix 3.0.0.
- `THEDEVS-RU/addon-core@dev:core/src/main/resources/ru/thedevs/liquibase/changelog/2026/03/008-business-role.xml:7` — `logicalFilePath` (пример для документации).

# Что уже есть

- Дубль-фильтр `liquibase.allowDuplicatedChangesetIdentifiers=true` и топологический порядок TD-2533 — сохраняются без изменений.
- Логи `[TD-2533] testAddon_<dep>: liquibase.allowDuplicatedChangesetIdentifiers=true` и `[TD-2526]`, `[TD-2544]` — без изменений.

# Критерии готовности

1. Строка `[TD-2533] aggregate-changelog for '<dep>'` содержит `dep changelog path=`, `dep changelog included=` и `host changelog=` и сохраняет прежний префикс и хвост `module changelogs=…`.
2. Контрактный тест содержит проверки `dep changelog path=ru/thedevs/itink/liquibase/changelog.xml` и `dep changelog included=true`; прочие проверки не изменены.
3. `AGENTS.md` описывает новый формат лога и оба правила контракта тестового changelog'а зависимости, перечисленные в разделе 3.
4. Состав и порядок `<include>` в генерируемом `aggregate-changelog.xml` не изменились.

# Не трогать

- Порядок включений, `depMatchesModule`, `hostAlreadyIncludesDep`, обнаружение модулей и системные свойства Liquibase.
- Тестовые changelog'и зависимостей в других репозиториях (исправление chats — отдельная спека).
- Логику TD-2521, TD-2526, TD-2544.
