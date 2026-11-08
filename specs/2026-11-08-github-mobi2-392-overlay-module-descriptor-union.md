id: 2026-11-08-github-mobi2-392-overlay-module-descriptor-union
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high

# Context

This is the fix stage of MOBI2-392, the base task for MOBI2-391. The diagnostics spec (`specs/2026-11-08-github-mobi2-391-addon-tests-overlay-nonentity-diagnostics.md`) was merged to `dev` in PR THEDEVS-RU/.github#39 (4350f36). Its item 4 produced the evidence below.

Evidence: THEDEVS-RU/addon-gssoft run 42462400635, attempt 2 (2026-11-08T09:28Z, uses the action from `@dev`):
- The full EclipseLink-7250 message in `testAddon_limiter` / `LimiterPostgresSmokeTest`, PU [main]: `[class ru.thedevs.entity.notification.NotifyPreference] uses a non-entity [class ru.thedevs.entity.notification.NotifyTenantSubscription] as target entity in the relationship attribute [field subscription]`. Result: 331 tests, 2 failed.
- The overlay-check lines for `limiter` (in `ru/thedevs/limiter/persistence.xml` and `ru/thedevs/persistence.xml`, each with +86 host classes) show every orm.xml target as `listed=true` with consistent roots. Example: `CoreUserEntity.phone -> GpsPhone listed=true root=gpscore-3.0.0.9.jar super=ru.thedevs.entity.CorePhone superRoot=core-3.0.0.98.jar`. `NotifyPreference.subscription` is mapped by annotation (`THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/notification/NotifyPreference.java:50-53`), so no mapping file contains it and no overlay-check line covers it.

Verdict:
- H1 is refuted for GpsPhone/CorePhone: both are listed and loaded from the expected roots.
- H2 is refuted for `NotifyUserContact.phone`: the host orm.xml redirects it and the target is listed.
- Confirmed: the PU class list is skewed (an H3 variant). `NotifyTenantSubscription` is an `@Entity` (`THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/notification/NotifyTenantSubscription.java:26-34`). It was added by TD-2592/TD-2605 (3341bf7 on 2026-10-29T22:20Z, 1bc67d8 on 2026-10-30), after the last green run 40921058131 (2026-10-29T17:24Z).
- The effective descriptor is the last module's `ru/thedevs/limiter/persistence.xml` (`dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38-46`). It is built from one dependency descriptor plus host classes, and neither lists the class:
  - local cache: `limiter-3.0.0.28.jar` `ru/thedevs/limiter/persistence.xml` has 57 classes and no `NotifyTenantSubscription`;
  - `limiter-3.0.0.31.jar` has 59 classes and lists it;
  - `glonasssoft-3.0.0.28.jar` `ru/thedevs/integration/gssoft/persistence.xml` has 143 classes and does not list it.
- The resolved core jar's own descriptor `ru/thedevs/persistence.xml` lists it (`core-3.0.0.97.jar`, line 61). That descriptor is a separate overlay candidate and is never merged into the last-module descriptor.

Root cause: the overlay (`ci-addon-tests.init.gradle:1315-1390`) merges each dependency descriptor only with host classes. It ignores the other Jmix module descriptors resolved on the same dependency roots. A dependency descriptor fixed at publish time therefore goes stale as soon as a library adds an entity, and the single effective PU no longer matches the entity classes on the classpath.

# What to do

### 1. Merge resolved module descriptors into each merged descriptor
In `actions/setup-addon-tests/ci-addon-tests.init.gradle`, overlay task `buildHostPersistenceOverlay_<dep>`, step "3 & 4. Merge candidates" (`:1315`):
- Before the per-candidate loop, collect for each store file name (`persistence.xml`, `<store>-persistence.xml`) the ordered, deduplicated union of `<class>` values over all candidates in `candidatesByRelPath` with that file name. Keep `depRoots` order (`:1231-1281`) and read with `withResourceInputStream`.
- For each merged candidate, add the union classes that the candidate does not already list. Insert them exactly the way host classes are inserted (`:1356-1367`, same `classInsertBeforeTags`), after the host classes.
- Print `[TD-2521] Persistence overlay for '<dep>': <relPath> (+<N> module classes)` when N > 0.
- Do not change mapping files, properties or converters. Keep host precedence as it is.

### 2. Diagnostic for module entities the overlay added
In the overlay-check block (`:1472`), for each class that step 1 added to a merged descriptor, print `[TD-2521] overlay check '<dep>': module entity <class> added to <relPath> from <source relPath>@<root>`. This covers annotation-mapped relationships, which the orm.xml target check cannot see. Wrap the whole overlay-check block in a top-level `try/catch` that prints `::warning::[TD-2521] overlay check failed: <message>`, so that the diagnostic never fails the task.

### 3. Fixture test
In `tests/test-setup-addon-tests.sh` (TD-2521 block, the overlay assertions at `:1268-1283`), add a second dependency-side jar on `addonTestClasspath` with group `ru.thedevs`. Its descriptor has the same file name and lists an entity that neither the dependency's last-module descriptor nor the host descriptor lists. Assert the following:
- the merged descriptor seen by the dependency test classloader contains that entity exactly once;
- the downstream log contains the `(+1 module classes)` line and the `module entity ... added to` line.

All existing assertions must still pass unchanged.

### 4. Documentation
In `AGENTS.md` §2 "Диагностика", document both new lines. Add one sentence saying that `superRoot=missing` is expected for JDK superclasses such as `java.lang.Object`.

### 5. Verification on the consumer
After merge to `dev`, run `gh run rerun 42462400635 -R THEDEVS-RU/addon-gssoft --failed`. Quote the result of "Run addon dependency tests" (`testAddon_limiter` expected green, 331/331) and the `module entity ... NotifyTenantSubscription` line in the handoff. If it is still red with a different cause, escalate to SPEC with the full EclipseLink message.

## Affected files
1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`

# What already exists

- The TD-2521 overlay with candidate discovery over `depRoots` and host-class merge (`ci-addon-tests.init.gradle:1231-1470`).
- The MOBI2-392 overlay-check diagnostic and fixture lines (`ci-addon-tests.init.gradle:1472-1660`, `tests/test-setup-addon-tests.sh:1268-1283`).

## Verified APIs
1. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1231` — `depRoots` (classesDir, then `ru.thedevs` jars of `addonTestClasspath`).
2. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1251` — `candidatesByRelPath` (first root wins per relPath).
3. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1284` — `matchingCandidates` filtered by host store file name.
4. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1356` — host class insertion with `classInsertBeforeTags`.
5. `THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/notification/NotifyTenantSubscription.java:27` — `@Entity(name = "notify_NotifyTenantSubscription")`.
6. `THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/notification/NotifyPreference.java:53` — `private NotifyTenantSubscription subscription`.
7. `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38` — PU descriptor of the last module.

# Acceptance criteria

- The merged descriptor contains every `<class>` from the resolved module descriptors with the same store file name. The new log lines are printed, and existing fixture outputs are unchanged apart from the added classes.
- `tests/test-setup-addon-tests.sh` covers the module-class merge and the diagnostic line. PR CI is green.
- `AGENTS.md` §2 documents the new lines.
- After merge, the rerun of THEDEVS-RU/addon-gssoft run 42462400635 is green on "Run addon dependency tests".

# Out of scope

- Disabling or excluding `testAddon_limiter` or any other dependency suite.
- Republishing addon-limiter or changing library entities.
- MOBI2-391 code (addon-gssoft PR #31).
