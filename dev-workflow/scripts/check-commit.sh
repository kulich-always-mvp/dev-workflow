#!/usr/bin/env bash
# check-commit.sh — механическая проверка инварианта «не подгоняй проверки» (dev-workflow).
#
# Режимы:
#   check-commit.sh <файл-сообщения>     как git-хук commit-msg: проверяет индекс (staged)
#   check-commit.sh --range <A>..<B>     проверяет каждый коммит диапазона (кроме merge)
#   check-commit.sh --staged [тип]       проверяет индекс; тип коммита по умолчанию «feat»
#
# Правила:
#   1. Существующие тесты и снапшоты меняются (правка, удаление, переименование, дописывание)
#      только в коммитах типа test и revert. Новые тестовые файлы можно добавлять в любом коммите.
#   2. Коммит test, который меняет или удаляет строки существующих тестов, не трогает
#      существующие нетестовые файлы: согласованная правка теста — отдельным коммитом, без кода.
#      Коммит заморозки (новые тесты и каркас) под это правило не попадает.
#   3. В добавленных строках нет пропусков тестов и подавлений линтера, типов и покрытия.
#   4. Коммит wip (отложенная работа в ветке parked/…) хук пропускает без проверок, но в
#      истории задачи (--range) его быть не должно: правки возвращают через cherry-pick --no-commit.
#   Предупреждения (коммит не блокируют): изменены конфиги тестов, покрытия, линтера или CI;
#   коммит test меняет существующие нетестовые файлы (допустимо только для каркаса).
#
# Настройка через переменные окружения (расширенные регулярные выражения по пути файла):
#   DEV_WORKFLOW_TEST_PATTERN     что считать тестом
#   DEV_WORKFLOW_EXCLUDE          пути, которые не сканируются на подавления
#   DEV_WORKFLOW_ALLOW_SUPPRESS=1 пропустить правило 3 — только с явного согласия пользователя,
#                                 с записью причины в журнал задачи
#
# Ограничение: в режиме хука при git commit --amend видны только новые изменения индекса.
# Перед ревью прогоняйте --range: он проверяет коммиты целиком.
#
# Коды выхода: 0 — нарушений нет, 1 — есть нарушения, 2 — ошибка запуска.

set -uo pipefail

TEST_PATTERN="${DEV_WORKFLOW_TEST_PATTERN:-(^|/)(tests?|__tests__|specs?|testdata|__snapshots__|e2e)/|(^|/)test_[^/]*\.py$|(^|/)conftest\.py$|_test\.(py|go|rb|exs?|dart)$|\.(test|spec|cy)\.[cm]?[jt]sx?$|_spec\.rb$|(Tests?|Spec)\.(java|kt|kts|cs|swift|php|scala)$|\.snap$|\.golden$|\.approved\.}"
EXCLUDE_PATTERN="${DEV_WORKFLOW_EXCLUDE:-(^|/)\.claude/skills/|(^|/)\.agents/skills/|(^|/)(check-commit|selftest)\.sh$|\.(md|mdx|rst|txt)$}"
CONFIG_PATTERN='(^|/)(pytest\.ini|tox\.ini|setup\.cfg|pyproject\.toml|\.coveragerc|\.flake8|\.?mypy\.ini|\.?ruff\.toml|\.?pylintrc|\.golangci\.ya?ml|\.rubocop\.yml|phpunit\.xml(\.dist)?|phpstan\.neon(\.dist)?|karma\.conf\.[jt]s|\.eslintrc(\.[a-z]+)?|\.eslintignore|\.prettierignore|\.nycrc(\.json)?|\.c8rc(\.json)?|\.?codecov\.ya?ml|biome\.jsonc?|tsconfig[^/]*\.json|\.stylelintrc(\.[a-z]+)?|\.pre-commit-config\.yaml|lefthook\.ya?ml|\.gitlab-ci\.yml)$|(^|/)(jest|vitest|eslint|playwright|cypress|stylelint)\.config\.[cm]?[jt]s$|(^|/)\.husky/|(^|/)\.github/workflows/'

NW='(^|[^A-Za-z0-9_])'
SUPPRESS_PATTERN="#[[:space:]]*noqa|#[[:space:]]*type:[[:space:]]*ignore|#[[:space:]]*pyright:[[:space:]]*ignore|mypy:[[:space:]]*ignore-errors|pylint:[[:space:]]*disable|#[[:space:]]*nosec|pragma:[[:space:]]*no[[:space:]]*(cover|branch)"
SUPPRESS_PATTERN+="|eslint-disable|oxlint-disable|biome-ignore|deno-lint-ignore|stylelint-disable|@ts-ignore|@ts-nocheck|@ts-expect-error|istanbul[[:space:]]+ignore|c8[[:space:]]+ignore"
SUPPRESS_PATTERN+="|//[[:space:]]*nolint|NOLINT|lint:ignore|@SuppressWarnings|@Suppress\(|@SuppressLint|SuppressMessage|#pragma[[:space:]]+warning[[:space:]]+disable|diagnostic[[:space:]]+ignored|ReSharper[[:space:]]+disable|#!?\[allow\("
SUPPRESS_PATTERN+="|rubocop:disable|standard:disable|phpcs:(ignore|disable)|@phpstan-ignore|@psalm-suppress|swiftlint:disable|shellcheck[[:space:]]+disable|hadolint[[:space:]]+ignore|tflint-ignore|checkov:skip|noinspection"
SUPPRESS_PATTERN+="|pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)\(|unittest\.(skip|expectedFailure)|skipTest\("
SUPPRESS_PATTERN+="|${NW}(it|describe|test|context|suite)\.(skip|only|todo|fixme)\(|${NW}(xit|xdescribe|xcontext|xtest|fit|fdescribe)\(|${NW}t\.(Skip(Now|f)?|skip)\("
SUPPRESS_PATTERN+="|@(Disabled|Ignore)([^A-Za-z0-9_]|$)|#\[ignore\]|\[Ignore\]|\[(Fact|Theory)\(Skip"

violations=0
warnings=0
MODE=""

err()  { printf 'НАРУШЕНИЕ: %s\n' "$*" >&2; violations=$((violations + 1)); }
warn() { printf 'Предупреждение: %s\n' "$*" >&2; warnings=$((warnings + 1)); }

# Пути с кириллицей и пробелами git по умолчанию экранирует; выключаем это для разбора.
g() { git -c core.quotePath=false "$@"; }
# Фиксированный формат diff, независимо от настроек пользователя (noprefix, внешние diff, textconv).
DIFF_OPTS=(-U0 --no-color --no-ext-diff --no-textconv -M --src-prefix=a/ --dst-prefix=b/)

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

commit_type() {
  # Тип Conventional Commits из первой строки; «revert» для Revert-коммитов.
  local subject="$1"
  if [[ "$subject" =~ ^[Rr]evert ]]; then echo "revert"; return; fi
  if [[ "$subject" =~ ^([A-Za-z]+)(\([^\)]*\))?!?: ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'  # совместимо с bash 3.2 (macOS)
  else
    echo "unknown"
  fi
}

is_test() { [[ -n "$1" && "$1" =~ $TEST_PATTERN ]]; }

join_lines() { printf '%s' "$1" | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }'; }

# Разбор unified diff (-U0). Печатает строки:
#   R<TAB>путь          — в файле удалены или изменены строки
#   H<TAB>путь<TAB>текст — в добавленной строке найдено подавление или пропуск проверки
# Заголовки файлов распознаются только между «diff --git» и первым «@@», поэтому строки
# содержимого вида «-- комментарий» или «++i» разбор не ломают.
parse_diff() {
  PAT="$SUPPRESS_PATTERN" EXC="$EXCLUDE_PATTERN" SKIPSUP="${DEV_WORKFLOW_ALLOW_SUPPRESS:-0}" awk '
    /^diff --git / { hdr = 1; path = ""; next }
    hdr && /^\+\+\+ / {
      p = substr($0, 5); sub(/\t$/, "", p)
      if (p == "/dev/null") p = ""; else sub(/^b\//, "", p)
      path = p; next
    }
    hdr && /^@@/ { hdr = 0; next }
    hdr { next }
    /^@@/ { next }
    /^-/ {
      if (path != "" && !(path in removed)) { removed[path] = 1; print "R\t" path }
      next
    }
    /^\+/ {
      if (ENVIRON["SKIPSUP"] == "1" || path == "" || path ~ ENVIRON["EXC"]) next
      line = substr($0, 2)
      if (line ~ ENVIRON["PAT"]) {
        gsub(/^[ \t]+/, "", line)
        if (length(line) > 120) line = substr(line, 1, 117) "..."
        print "H\t" path "\t" line
      }
    }'
}

# $1 — метка (коммит или «индекс»), $2 — тип коммита, $3 — вывод --name-status, $4 — diff.
check_change() {
  local label="$1" ctype="$2" name_status="$3" diff="$4"
  local parsed removed status p1 p2 p is_t
  local test_changed="" nontest_changed=""

  # Правило 4: отложенная работа (wip) — временный коммит вне истории задачи.
  if [[ "$ctype" == "wip" ]]; then
    [[ "$MODE" == "range" ]] && err "$label: коммит wip в истории задачи — отложенные правки возвращают через git cherry-pick --no-commit parked/…, а не коммитом или слиянием"
    return 0
  fi

  parsed=$(printf '%s\n' "$diff" | parse_diff)
  removed=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "R" { print $2 }')

  while IFS=$'\t' read -r status p1 p2; do
    [[ -z "${status:-}" ]] && continue

    for p in "$p1" "${p2:-}"; do
      [[ -n "$p" && "$p" =~ $CONFIG_PATTERN ]] && warn "$label: изменён конфиг проверок — убедитесь, что ничего не ослаблено: $p"
    done

    is_t=0
    if is_test "$p1" || is_test "${p2:-}"; then is_t=1; fi

    case "$status" in
      A*|C*) continue ;;  # новый файл (в том числе копия) — не правка существующего
    esac

    if (( is_t )); then
      # Правило 1: существующий тест меняется только в коммитах test и revert.
      if [[ "$ctype" != "test" && "$ctype" != "revert" ]]; then
        err "$label: существующий тест изменён в коммите типа «$ctype» (нужен отдельный коммит test(...)): $status ${p2:-$p1}"
        continue
      fi
      # Для правила 2: правка по существу — удаление, переименование или изменённые строки.
      case "$status" in
        M*) if printf '%s\n' "$removed" | grep -Fxq -- "$p1"; then test_changed+="$p1"$'\n'; fi ;;
        *)  test_changed+="${p2:-$p1}"$'\n' ;;
      esac
    else
      nontest_changed+="${p2:-$p1}"$'\n'
    fi
  done <<< "$name_status"

  # Правило 2: в коммите test правка существующих тестов не смешивается с кодом.
  if [[ "$ctype" == "test" && -n "$nontest_changed" ]]; then
    if [[ -n "$test_changed" ]]; then
      err "$label: коммит test меняет существующие тесты ($(join_lines "$test_changed")) и одновременно нетестовые файлы ($(join_lines "$nontest_changed")). Согласованная правка теста — отдельным коммитом, без кода."
    else
      warn "$label: коммит test меняет существующие нетестовые файлы — допустимо только для каркаса (заглушек): $(join_lines "$nontest_changed")"
    fi
  fi

  # Правило 3: подавления и пропуски в добавленных строках.
  local hits h
  hits=$(printf '%s\n' "$parsed" | awk '/^H\t/ { sub(/^H\t/, ""); i = index($0, "\t"); print substr($0, 1, i - 1) ": " substr($0, i + 1) }')
  if [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      [[ -n "$h" ]] && err "$label: добавлено подавление или пропуск проверки — $h"
    done <<< "$hits"
  fi
}

finish() {
  if (( violations > 0 )); then
    printf '\nНайдено нарушений: %d. %s См. инвариант 2 в SKILL.md и references/enforcement.md.\n' "$violations" "${FINISH_NOTE:-Коммит отклонён.}" >&2
    exit 1
  fi
  (( warnings > 0 )) && printf 'Предупреждений: %d (коммит не блокируется).\n' "$warnings" >&2
  exit 0
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || { echo "check-commit.sh: не git-репозиторий" >&2; exit 2; }

case "$1" in
  --range)
    MODE=range
    range="${2:-}"
    if [[ "$range" != *..* ]]; then
      echo "Использование: $0 --range <A>..<B> (например, origin/main..HEAD)" >&2
      exit 2
    fi
    commits=$(git rev-list --no-merges --reverse "$range") || exit 2
    for c in $commits; do
      subject=$(git log -1 --format=%s "$c")
      ctype=$(commit_type "$subject")
      short=$(git rev-parse --short "$c")
      ns=$(g diff-tree --root --no-commit-id -r -M --name-status "$c")
      df=$(g show --format= "${DIFF_OPTS[@]}" "$c")
      check_change "$short «$subject»" "$ctype" "$ns" "$df"
    done
    FINISH_NOTE="Исправьте коммиты диапазона до слияния."
    finish
    ;;
  --staged)
    MODE=staged
    ctype="${2:-feat}"
    check_change "индекс" "$ctype" "$(g diff --cached -M --name-status)" "$(g diff --cached "${DIFF_OPTS[@]}")"
    FINISH_NOTE="Индекс содержит нарушения."
    finish
    ;;
  -*)
    echo "check-commit.sh: неизвестный режим $1 (см. --help)" >&2
    exit 2
    ;;
  *)
    MODE=hook
    msg_file="$1"
    [[ -f "$msg_file" ]] || { echo "check-commit.sh: нет файла сообщения $msg_file" >&2; exit 2; }
    # Слияния не проверяем: их содержимое проверяется в исходных коммитах.
    if [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then exit 0; fi
    subject=$(grep -v '^#' "$msg_file" | sed '/^[[:space:]]*$/d' | head -n 1)
    ctype=$(commit_type "$subject")
    check_change "индекс" "$ctype" "$(g diff --cached -M --name-status)" "$(g diff --cached "${DIFF_OPTS[@]}")"
    finish
    ;;
esac
