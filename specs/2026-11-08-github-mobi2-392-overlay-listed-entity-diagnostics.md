id: 2026-11-08-github-mobi2-392-overlay-listed-entity-diagnostics
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

This is the third stage of MOBI2-392, the base task for MOBI2-391. Two earlier stages are already on `dev`:
- PR #39 (4350f36) added the overlay diagnostics.
- PR #40 (6ba19de, spec `specs/2026-11-08-github-mobi2-392-overlay-module-descriptor-union.md`) added the module-class merge.

Evidence after PR #40: THEDEVS-RU/addon-gssoft run 42462400635, attempt 3 (action `THEDEVS-RU/.github@dev` SHA 6ba19de):
- `testAddon_limiter` still fails, 331 tests, 2 failed, with the same message: `[class ru.thedevs.entity.notification.NotifyPreference] uses a non-entity [class ru.thedevs.entity.notification.NotifyTenantSubscription] as target entity in the relationship attribute [field subscription]`.
- The log for `limiter` shows `ru/thedevs/limiter/persistence.xml (+86 host classes)` and `ru/thedevs/persistence.xml (+86 host classes)`, but no `(+N module classes)` line. The module-class merge therefore added nothing. Every `<class>` of every candidate descriptor with the same store file name (including `ru/thedevs/persistence.xml`) was already in the dependency descriptor or the host classes.
- If the candidate `ru/thedevs/persistence.xml` is the copy from the resolved core jar, which lists `NotifyTenantSubscription` (`core-3.0.0.97.jar` line 61), then the class is already listed in the merged `ru/thedevs/limiter/persistence.xml`. In that case the MOBI2-392 stage-2 hypothesis (the class is unlisted) is wrong.

**The cause is not confirmed.** Two hypotheses remain open, and the CI log cannot separate them:
- **H4: the candidate descriptor is a stale copy.** `candidatesByRelPath` keeps the first root per relPath (`ci-addon-tests.init.gradle:1251-1281`, classesDir first). If an earlier root carries an older `ru/thedevs/persistence.xml` without `NotifyTenantSubscription`, the overlay copy shadows the current one and the class stays unlisted.
- **H5: the class is listed but loaded as a non-entity.** The effective descriptor lists the class, but the `NotifyTenantSubscription.class` found first on the `testAddon_limiter` classpath is a different build without `@jakarta.persistence.Entity`, or a different PU descriptor is in effect.

# What to do

### 1. Candidate source line
In `actions/setup-addon-tests/ci-addon-tests.init.gradle`, overlay task `buildHostPersistenceOverlay_<dep>`, after `candidatesByRelPath` is built (`:1281`), print one line per candidate:
`[TD-2521] overlay candidate '<dep>': <relPath> root=<formatClasspathRoot(root)> classes=<N>`
Also print one line per extra copy of the same relPath found in later roots, which are currently ignored:
`[TD-2521] overlay candidate '<dep>': <relPath> shadowed copy root=<root> classes=<N>`

### 2. Merged class list
For each merged descriptor written to the overlay, print its full `<class>` list in a folded group: `::group::[TD-2521] merged '<dep>': <relPath> (<N> classes)`, then one class per line, then `::endgroup::`.

### 3. Entity check for listed classes
In the overlay-check block (`:1522`, inside the existing top-level try/catch), resolve every class listed by each merged descriptor through `resolveClassEntry`. Check whether its class bytes contain one of the constant-pool UTF8 descriptors `Ljakarta/persistence/Entity;`, `Ljakarta/persistence/MappedSuperclass;` or `Ljakarta/persistence/Embeddable;`. When the class is missing or carries none of them, print:
`[TD-2521] overlay check '<dep>': listed class <class> root=<root|missing> entity=<false|missing>`
Also print one positive line per merged descriptor: `[TD-2521] overlay check '<dep>': <relPath> listed=<N> entity-ok=<M>`.

### 4. Fixture test and documentation
- In `tests/test-setup-addon-tests.sh`, assert that the candidate line for `ru/thedevs/itink/persistence.xml` and the `listed=<N> entity-ok=<M>` summary line are printed.
- Assert the `entity=false` line for a fixture class listed in a descriptor but compiled without `@Entity`. The fixture classes are plain Java without JPA annotations, so assert the line count you observe. If the fixture compile classpath lacks the jakarta API, document that every fixture class prints `entity=false`.
- Document all new lines in `AGENTS.md` §2 "Диагностика".

### 5. Evidence and hand-back
After merge to `dev`, run `gh run rerun 42462400635 -R THEDEVS-RU/addon-gssoft --failed`. Collect for `limiter`:
- the candidate lines for `ru/thedevs/persistence.xml` and `ru/thedevs/limiter/persistence.xml`, including any shadowed copies;
- whether the merged `ru/thedevs/limiter/persistence.xml` group lists `ru.thedevs.entity.notification.NotifyTenantSubscription`;
- any `listed class ... NotifyTenantSubscription` line.

Decide between H4 and H5, or record a different cause. Hand back via `next_stage(stage: "SPEC")` with the line `Escalation: impl — root cause evidence for testAddon_limiter NotifyTenantSubscription non-entity`.

## Affected files
1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`

# What already exists

- The candidate discovery and first-root-wins rule (`ci-addon-tests.init.gradle:1231-1290`).
- The module-class merge from PR #40 (`ci-addon-tests.init.gradle:1318-1346`).
- The overlay-check block with `resolveClassEntry`, `formatClasspathRoot` and a top-level try/catch (`ci-addon-tests.init.gradle:1522-1720`).

## Verified APIs
1. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1251` — `candidatesByRelPath` first-root-wins.
2. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1318` — module-class union per store file name.
3. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1522` — overlay consistency diagnostic block.
4. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:96` — `readSuperClassNameFromClassBytes` (constant-pool parser).
5. `THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/notification/NotifyTenantSubscription.java:27` — `@Entity(name = "notify_NotifyTenantSubscription")`.

# Acceptance criteria

- The new candidate, merged-group, entity-check and summary lines are printed. They are diagnostic only: they never fail the task, and the overlay files are byte-identical to before.
- The fixture assertions pass in PR CI, and `AGENTS.md` §2 documents the lines.
- The task returns to SPEC with the `limiter` evidence from the addon-gssoft rerun and the hypothesis it confirms.

# Out of scope

- Any further change to the overlay merge rules before the cause is confirmed.
- Disabling or excluding `testAddon_limiter` or any other dependency suite.
- MOBI2-391 code (addon-gssoft PR #31).
