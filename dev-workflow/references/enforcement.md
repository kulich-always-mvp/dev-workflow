# Механические проверки

Правила в тексте со временем ослабевают: длинный контекст, сжатие, усталость от ограничений. Часть инвариантов проверяется автоматически — тогда нарушение блокируется независимо от того, «помнит» ли агент регламент.

Ниже `<SKILL>` — папка skill, например `~/.claude/skills/dev-workflow` или `.claude/skills/dev-workflow`.

| Что | Проверяет | Где работает | Как включается |
|---|---|---|---|
| `scripts/guard-bash.sh` | опасные команды до их запуска: обход хуков, принудительный push, `reset --hard`, откат каталогов, удаление веток, удаление файлов под git и тестов, защищённые ветки, `sudo`, глобальные установки, `curl \| sh`, разрушающие запросы к БД, деплой, автообновление снапшотов, вывод секретов; команды внутри `bash -c`, `python -c`, `node -e` | Claude Code (хук `PreToolUse` для Bash) | **сам**, вместе со skill (п. 1) |
| `scripts/guard-edit.sh` | то же для инструментов работы с файлами: запись в git-хуки, `.git/config`, настройки агента, файлы регламента и списки заморозки; чтение и запись файлов с секретами; правка строк существующих и замороженных тестов (дописывать можно) | Claude Code (хук `PreToolUse` для Read, Write, Edit, MultiEdit, NotebookEdit, Grep) | **сам**, вместе со skill (п. 1а) |
| `scripts/session-reminder.sh` | после сжатия контекста напоминает об активной задаче из `.ai/ACTIVE` | Claude Code (хук `SessionStart`) | вручную в `settings.json` (п. 1б) |
| `scripts/check-commit.sh` | существующие тесты меняются только в коммитах `test` и не вместе с кодом; нет новых подавлений и пропусков; нет коммитов `wip` в истории задачи; предупреждает о правке конфигов проверок | любой агент, человек, CI | вручную перед ревью (обязательно, `references/review-and-close.md`); по желанию — git-хук и CI (пп. 2, 4) |
| `scripts/freeze.sh` | замороженные тесты не изменились (контрольные суммы) | любой агент | когда красный коммит заморозки невозможен (`references/tdd.md`) |
| `scripts/selftest.sh` | сами скрипты: 600+ сценариев | любой bash | `bash <SKILL>/scripts/selftest.sh` → «Итог: N проверок, все прошли» |

Нужен bash (в Windows — Git Bash из Git for Windows) и git; `jq` не обязателен.

## 1. Сторож команд в Claude Code

**Как включается.** Блок `hooks` во frontmatter `SKILL.md` регистрирует `guard-bash.sh` (для Bash) и `guard-edit.sh` (для инструментов работы с файлами) как хуки `PreToolUse`, когда skill вызван, и хуки работают до конца сессии. Скрипты ищутся в `.claude/skills/dev-workflow/` проекта, затем в `~/.claude/skills/dev-workflow/` (или в папке из `CLAUDE_CONFIG_DIR`), затем в `$CLAUDE_PLUGIN_ROOT/skills/dev-workflow/`, если skill установлен плагином. Если skill лежит в другом месте — сделайте туда ссылку или подключите хуки вручную (ниже). Не нашёл скрипт — хук молча пропускает всё.

**Проба.** Чтобы молчаливое отключение было видно, агент в начале задачи выполняет `true dev-workflow-guard-probe`. Сторож всегда блокирует эту команду с текстом «Сторож dev-workflow активен» (даже при `GUARD_ALLOW`, но не при `GUARD=off`). Команда выполнилась — сторож не подключён, и агент пишет в отчёте «Сторож: не активен». Проверить вручную можно так же.

**Что видит агент.** Заблокированная команда не выполняется; агент получает причину вида `Заблокировано регламентом dev-workflow [force-push]: …`. В квадратных скобках — имя правила. Регламент велит не обходить блокировку, а объяснить пользователю, что и зачем нужно выполнить.

**Как выполнить заблокированное после согласия.** Пользователь запускает команду сам, в своём терминале. Если такие команды нужны постоянно (например, деплой в этом проекте — обычное дело), правило отключают в настройках.

**Подтверждение вместо блокировки (`GUARD_ASK`).** Для правил из списка `GUARD_ASK` сторож не блокирует, а отвечает Claude Code решением `permissionDecision: "ask"`: пользователь видит обычный запрос разрешения с причиной и подтверждает или отклоняет его прямо в окне Claude Code, без терминала. Это работает только в режимах прав `default`, `acceptEdits` и `plan`. В режимах `bypassPermissions`, `dontAsk`, `auto` и в неинтерактивном запуске спросить некого или подтверждение могло бы пройти без человека, поэтому там правило блокирует, как обычно. Правило `hooks` не спрашивает никогда. По умолчанию `GUARD_ASK` пуст для команд, а у `guard-edit.sh` равен `tests`: правку существующего теста в обычном режиме подтверждает пользователь. Пустое значение `GUARD_ASK=` отключает и это.

**Настройки** задаёт только пользователь — в файле `~/.claude/dev-workflow.conf` (или `$CLAUDE_CONFIG_DIR/dev-workflow.conf`), строки `КЛЮЧ=значение`:

```
# правила, которые не проверять (через запятую)
GUARD_ALLOW=deploy,database
# правила, по которым спрашивать вместо блокировки (только в обычных режимах прав)
GUARD_ASK=branch-delete,deploy,tests
# защищённые ветки (через пробел); пустое значение отключает эту проверку
PROTECTED_BRANCHES=main master develop
# выключить сторожа целиком
# GUARD=off
```

Те же настройки можно задать переменными окружения `DEV_WORKFLOW_GUARD_ALLOW`, `DEV_WORKFLOW_GUARD_ASK`, `DEV_WORKFLOW_PROTECTED_BRANCHES`, `DEV_WORKFLOW_GUARD` — они главнее файла. Настройки общие для обоих сторожей. Файл лежит рядом с настройками Claude Code, а не в проекте: репозиторий не может ослабить сторожа своим файлом, а запись в `~/.claude` Claude Code без подтверждения не разрешает (кроме режима `bypassPermissions`).

| Правило | Что блокирует |
|---|---|
| `hooks` | `--no-verify`, `commit -n`, установку и сброс `core.hooksPath` (чтение разрешено), `HUSKY=0`, правку `.git/hooks`, `.git/config`, настроек агента, файла настроек сторожа, скриптов и `SKILL.md` регламента, списков заморозки `freeze-*.txt` |
| `force-push` | `push --force`/`-f`/`--force-with-lease`, `+ветка`, `:ветка`, `--delete`, `--mirror`, `--prune` |
| `discard` | `reset --hard`, `clean -f`, `checkout .`/`-f`, `restore .`, откат целого каталога или маски (`git restore -- src/`, `git checkout HEAD -- tests/`, `git restore "*.py"`), `switch --discard-changes`, `stash drop`/`clear`, `worktree remove --force` |
| `history` | `filter-branch`/`filter-repo`, `reflog expire`, `gc --prune`, `update-ref -d` |
| `branch-delete` | `branch -D` и `branch -f` для веток, кроме своих `parked/…` и `wip/…` |
| `protected-branch` | коммит, слияние, `rebase`, `cherry-pick`, `pull`, `push` в защищённой ветке и push в неё; первый коммит пустого репозитория разрешён |
| `snapshots` | `-u`/`--update-snapshots` и аналоги в jest, vitest, playwright, pytest, go, insta |
| `system` | `sudo`, `setx`, `reg add`, правку профиля shell, `git config --global` (чтение разрешено) |
| `global-install` | `npm i -g`, `yarn global`, `pip install --user`, `pipx`/`cargo`/`gem`/`go install`, `brew`/`apt`/`winget`/`choco` и т. п. |
| `remote-script` | `curl … \| sh`, `bash -c "$(curl …)"`, `bash <(curl …)`, `iwr … \| iex` |
| `database` | `DROP`/`TRUNCATE`/`DELETE` без `WHERE` через клиент БД, `prisma migrate reset`, `rails db:drop`, `migrate:fresh`, `manage.py flush` и т. п. |
| `deploy` | `npm publish`, `cargo publish`, `docker push`, `gh release create`, `gh pr merge`, `terraform apply`, `kubectl apply`, `helm upgrade`, `vercel --prod`, изменяющие команды `aws`/`gcloud`/`az` |
| `rm-root` | `rm -r` корня диска, домашней папки, текущей папки, `*` или `.git` |
| `delete-tracked` | `rm -r`, `find … -delete`, `git rm -r` каталогов с файлами под git; удаление существующих (закоммиченных) тестов любым из этих способов. Свои новые и неотслеживаемые файлы удалять можно |
| `secrets` | `env` и `printenv` без аргументов, `export -p`, `set`; вывод секретных переменных (`echo $API_TOKEN`); чтение `.env` (кроме `.env.example` и подобных), `.envrc`, `.netrc`, `.pgpass`, `.npmrc`, `credentials`, закрытых ключей командами `cat`, `head`, `grep` и т. п. Разрешено: `grep -q`, `sed`/`cut` с маскировкой, `source .env` |

Команды внутри `bash -c`, `eval`, а также строки внутри `python -c`, `node -e`, `perl -e`, `ruby -e`, `php -r` проверяются как отдельные: `python -c "os.system('git reset --hard')"` блокируется. Команда в списочной форме (`subprocess.run(["git", "reset", "--hard"])`) или записанная в файл и запущенная оттуда — нет: это граница проверки по тексту (п. 5).

**Подключить на постоянно** (сторож работает, даже если skill не вызывался) — в `~/.claude/settings.json` или `.claude/settings.json` проекта:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "timeout": 15, "command": "bash \"$HOME/.claude/skills/dev-workflow/scripts/guard-bash.sh\"" }
        ]
      },
      {
        "matcher": "Read|Write|Edit|MultiEdit|NotebookEdit|Grep",
        "hooks": [
          { "type": "command", "timeout": 15, "command": "bash \"$HOME/.claude/skills/dev-workflow/scripts/guard-edit.sh\"" }
        ]
      }
    ]
  }
}
```

Для skill внутри проекта путь: `bash \"$CLAUDE_PROJECT_DIR/.claude/skills/dev-workflow/scripts/guard-bash.sh\"` (и так же для `guard-edit.sh`). Проверить, что хуки подключены, — команда `/hooks` в Claude Code или проба `true dev-workflow-guard-probe`. Если сторож подключён и так, и через skill, он просто сработает дважды.

**Запреты Claude Code как второй слой** (там же, в `settings.json`):

```json
{
  "permissions": {
    "deny": [
      "Bash(git push --force *)", "Bash(git reset --hard *)", "Bash(sudo *)",
      "Read(./.env)", "Read(./.env.*)", "Read(./**/.env)"
    ]
  }
}
```

Если запрет на чтение `.env.*` мешает читать `.env.example`, добавьте `"Read(./.env.example)"` в `permissions.allow`.

Такие правила срабатывают и внутри составных команд (`cd x && sudo …`) и после присваиваний переменных, но не видят вариантов вроде `git -C . push --force` — поэтому основной слой здесь сторож.

**Windows.** Claude Code запускает хуки через Git Bash; без Git Bash он работает через PowerShell, и сторож для Bash не срабатывает. Скрипты должны храниться с переводами строк LF: в папке skill для этого лежит `.gitattributes` (`*.sh text eol=lf`). Если skill попал в git-репозиторий с `core.autocrlf=true` без этого файла, bash упадёт с ошибкой `$'\r': command not found`.

**Загрузка skill в claude.ai.** Проверка skill при загрузке в веб-версию claude.ai знает только стандартные поля frontmatter. Перед такой загрузкой удалите блок `hooks` из `SKILL.md`. Claude Code и Codex этот блок понимают или игнорируют.

## 1а. Сторож файлов (`guard-edit.sh`)

Хук на инструменты Read, Write, Edit, MultiEdit, NotebookEdit и Grep. Закрывает обход `guard-bash.sh` правкой файла вместо команды. Правила:

| Правило | Что блокирует |
|---|---|
| `hooks` | запись в `.git/hooks/`, `.git/config`, `.claude/settings*.json`, `dev-workflow.conf`, скрипты и `SKILL.md` регламента (`skills/dev-workflow/`), списки заморозки `freeze-*.txt`. Всегда блокирует |
| `secrets` | чтение, поиск и запись `.env` (кроме `.env.example`, `.sample`, `.template`, `.dist`, `.defaults`), `.envrc`, `.netrc`, `.pgpass`, `.pypirc`, `.npmrc`, `credentials`, `id_rsa` и других закрытых ключей |
| `tests` | правку и удаление строк в существующем тесте — файле по шаблону тестов, который уже есть в `HEAD`; любое изменение файла из списка заморозки `$MAIN/.ai/tasks/*/freeze-*.txt`. Дописывать новый тест в существующий файл можно, если вставка не содержит пропусков, подавлений и досрочного `return`. Новые файлы тестов — без ограничений |

Различать дописывание и правку сторож умеет только с `jq`: без него любая запись в существующий тест считается правкой. Шаблон тестов — тот же, что у `check-commit.sh` (`DEV_WORKFLOW_TEST_PATTERN`).

Почему тесты по `HEAD`: тесты Baseline и тесты, закоммиченные при заморозке (`test(...)`), уже в истории, а свои новые тесты до заморозки — ещё нет, их можно править (`references/tdd.md`). В worktree воркера `HEAD` содержит тесты фазы 0, поэтому они защищены и там.

## 1б. Напоминание после сжатия контекста

После сжатия контекста агент может не заметить, что ведёт задачу по регламенту. Хук `SessionStart` печатает напоминание, если в основной копии есть `.ai/ACTIVE` (SKILL.md, п. 8); Claude Code добавляет этот вывод в контекст. В `settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "compact|resume",
        "hooks": [
          { "type": "command", "timeout": 10, "command": "bash \"$HOME/.claude/skills/dev-workflow/scripts/session-reminder.sh\"" }
        ]
      }
    ]
  }
}
```

Во frontmatter `SKILL.md` этот хук не добавлен: поддержку `SessionStart` в хуках skill мы не проверяли.

## 2. Git-хук `commit-msg`

Работает для Claude Code, Codex и людей одинаково, потому что срабатывает на сам `git commit`. Установка — постоянная конфигурация, поэтому только с согласия пользователя. Сторож не даёт агенту писать в `.git/hooks`: команду установки выполняет пользователь.

Только у себя (файл не попадает в репозиторий):

```bash
cp <SKILL>/scripts/check-commit.sh .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg      # в Windows не нужно
```

Для команды — положите копию скрипта в репозиторий (например, `tools/check-commit.sh`) и сошлитесь на неё. Путь к `~/.claude/skills` у коллег и в CI другой, поэтому на него ссылаться нельзя.

husky (`.husky/commit-msg`):

```bash
bash tools/check-commit.sh "$1"
```

pre-commit (`.pre-commit-config.yaml`), затем `pre-commit install --hook-type commit-msg`:

```yaml
repos:
  - repo: local
    hooks:
      - id: dev-workflow
        name: dev-workflow commit check
        entry: bash tools/check-commit.sh
        language: system
        stages: [commit-msg]
```

lefthook (`lefthook.yml`):

```yaml
commit-msg:
  commands:
    dev-workflow:
      run: bash tools/check-commit.sh {1}
```

Ручная проверка диапазона (перед ревью — обязательно):

```bash
bash <SKILL>/scripts/check-commit.sh --range origin/main..HEAD
```

Настройка — переменные окружения (описаны в заголовке скрипта): `DEV_WORKFLOW_TEST_PATTERN` — что считать тестами, `DEV_WORKFLOW_EXCLUDE` — что не сканировать на подавления. Если у проекта необычная раскладка тестов, запиши шаблон в `.ai/PROJECT.md`.

`DEV_WORKFLOW_ALLOW_SUPPRESS=1` отключает проверку подавлений. Использовать только с явного согласия пользователя на конкретное подавление, с записью причины в журнал задачи.

## 3. Codex

Сторож — это хук Claude Code; Codex блок `hooks` из frontmatter игнорирует. В Codex используйте git-хук из п. 2, `check-commit.sh --range` перед ревью и собственные настройки Codex для песочницы и подтверждения команд (sandbox и approval policy): запрещайте сеть и запись вне репозитория, если задача этого не требует.

## 4. CI

Добавьте в пайплайн запроса на слияние (нужна полная история: в GitHub Actions — `fetch-depth: 0` у `actions/checkout`):

```bash
bash tools/check-commit.sh --range "origin/${BASE_BRANCH:-main}..HEAD"
```

Так нарушения видны, даже если локальные хуки не установлены или были обойдены.

## 5. Ограничения

- Сторож проверяет текст команды. Команду, записанную в файл и запущенную оттуда, он не увидит; редкие формы записи тоже могут проскочить. Это страховка от ошибок, а не защита от намеренного обхода — поэтому есть ещё `check-commit.sh --range` и независимое ревью.
- Пути для `delete-tracked` и `discard` сторож проверяет относительно папки, в которой запущена команда; `cd другая && rm -r …` внутри одной команды он оценивает по исходной папке.
- `guard-edit.sh` не видит, что делает программа, которую запускают через Bash (скрипт, переписывающий тест). Это ловят `check-commit.sh` и ревью.
- Перезаморозку после правки теста видно в списке (`freeze.sh verify` сообщает число перезаморозок), но удаление всей папки задачи вместе со списком сторож не запрещает: оно нужно при архивации. Поэтому отпечаток списка записывается в отчёт о шаге сразу при заморозке.
- Ложное срабатывание возможно, когда опасная команда встречается внутри текста, например в сообщении коммита. Перефразируйте текст или выполните команду сами.
- `check-commit.sh` доверяет типу коммита из сообщения. Смешанные коммиты `test` он ловит, но содержательную подгонку внутри нового теста видит только ревью.
