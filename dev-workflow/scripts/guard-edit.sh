#!/usr/bin/env bash
# guard-edit.sh — PreToolUse-хук Claude Code для инструментов работы с файлами (dev-workflow):
# Read, Write, Edit, MultiEdit, NotebookEdit, Grep. Дополняет guard-bash.sh: те же запреты
# не должны обходиться правкой файла вместо команды в терминале.
#
# Правила:
#   hooks    запись в .git/hooks, .git/config, .claude/settings*.json, dev-workflow.conf,
#            скрипты и SKILL.md самого регламента, списки заморозки freeze-*.txt. Всегда блокирует.
#   secrets  чтение и запись .env (кроме .env.example и подобных), .envrc, .netrc, .pgpass,
#            .pypirc, .npmrc, credentials, закрытых ключей id_*: их значения попали бы в контекст.
#   tests    правка или удаление строк в существующем тесте (файл с тестами, который есть в
#            HEAD) и любое изменение файла из списка заморозки. Дописывать новый тест в
#            существующий файл можно, если вставка не содержит пропусков и подавлений.
#            Без jq вставку не отличить от правки: тогда любая запись в такой файл — правка.
#
# Выход 2 — блокировка, текст из stderr получает агент. Правило из списка GUARD_ASK вместо
# блокировки запрашивает подтверждение (permissionDecision "ask"), но только в режимах прав
# default, acceptEdits и plan. Если GUARD_ASK не задан, спрашивает только правило tests.
# Настройки — те же, что у guard-bash.sh (файл dev-workflow.conf и переменные DEV_WORKFLOW_*).
# Шаблон тестов — DEV_WORKFLOW_TEST_PATTERN, как у check-commit.sh.

set -u
input=$(cat)

unquote() { local v=$1; v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}; printf '%s' "$v"; }

cfg_guard="" cfg_allow="" cfg_ask="" ask_set=0
conf="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/dev-workflow.conf"
if [[ -f "$conf" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      GUARD=*)       cfg_guard=$(unquote "${line#GUARD=}") ;;
      GUARD_ALLOW=*) cfg_allow=$(unquote "${line#GUARD_ALLOW=}") ;;
      GUARD_ASK=*)   cfg_ask=$(unquote "${line#GUARD_ASK=}"); ask_set=1 ;;
    esac
  done < "$conf"
fi
guard_mode=${DEV_WORKFLOW_GUARD-$cfg_guard}
allow_list=${DEV_WORKFLOW_GUARD_ALLOW-$cfg_allow}
if [[ -n "${DEV_WORKFLOW_GUARD_ASK+x}" ]]; then ask_list=$DEV_WORKFLOW_GUARD_ASK
elif (( ask_set )); then ask_list=$cfg_ask
else ask_list=tests; fi
case "$guard_mode" in off|OFF|Off|0|false|no) exit 0 ;; esac
allow_list=",${allow_list// /},"
ask_list=",${ask_list// /},"

json_field() {  # упрощённое чтение строкового поля JSON, когда нет jq
  local re v
  re='"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ $input =~ $re ]] || return 1
  v=${BASH_REMATCH[1]}
  v=${v//\\n/$'\n'}; v=${v//\\\"/\"}; v=${v//\\\\/\\}
  printf '%s' "$v"
}
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}; s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

use_jq=0
if [[ -z "${DEV_WORKFLOW_GUARD_NO_JQ:-}" ]] && command -v jq >/dev/null 2>&1 \
   && printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  use_jq=1
fi
jget() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

if (( use_jq )); then
  tool=$(jget .tool_name); cwd=$(jget .cwd); pmode=$(jget .permission_mode)
  file=$(jget '(.tool_input.file_path // .tool_input.notebook_path // .tool_input.path)')
else
  tool=$(json_field tool_name) || tool=""
  cwd=$(json_field cwd) || cwd=""
  pmode=$(json_field permission_mode) || pmode=""
  file=$(json_field file_path || json_field notebook_path || json_field path) || file=""
fi
[[ -n "$file" ]] || exit 0

block() {  # $1 — правило, $2 — что именно
  [[ "$allow_list" == *",$1,"* ]] && return 0
  if [[ "$1" != hooks && "$ask_list" == *",$1,"* ]]; then
    case "$pmode" in
      default|acceptEdits|plan)
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}\n' \
          "$(json_str "dev-workflow [$1]: $2. Подтвердите, только если это изменение с вами согласовано.")"
        exit 0 ;;
    esac
  fi
  printf 'Заблокировано регламентом dev-workflow [%s]: %s.\n' "$1" "$2" >&2
  printf 'Это действие требует согласия пользователя (SKILL.md, инварианты 2, 4, 5). Не ищи обходной путь: опиши пользователю, что и зачем нужно изменить, и дождись решения.\n' >&2
  exit 2
}

case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit) writing=1 ;;
  Read|Grep|Glob|NotebookRead) writing=0 ;;
  *) exit 0 ;;
esac

# Путь: обратные слэши Windows → прямые; относительный — от cwd.
path=${file//\\//}
if [[ "$path" != /* && ! "$path" =~ ^[A-Za-z]:/ ]]; then path="${cwd:-$PWD}/$path"; fi
base=${path##*/}

# --- hooks: обход проверок правкой файла
if (( writing )); then
  if [[ "$path" =~ /\.git/hooks/ || "$path" =~ /\.git/config$ || "$path" =~ /\.claude/settings[^/]*\.json$ \
     || "$base" == dev-workflow.conf || "$path" =~ /skills/dev-workflow/(scripts/|SKILL\.md$) \
     || "$base" =~ ^freeze-.*\.txt$ ]]; then
    block hooks "правка git-хуков, .git/config, настроек агента, файлов регламента или списка заморозки ($file)"
  fi
fi

# --- secrets: файлы, значения из которых не должны попадать в контекст
SECRET_NAME='^(\.env(\..+)?|\.envrc|\.netrc|_netrc|\.pgpass|\.pypirc|\.npmrc|credentials|id_(rsa|dsa|ecdsa|ed25519))$'
SECRET_OK='^\.env\.(example|sample|template|dist|defaults)$'
if [[ "$tool" != Glob && "$base" =~ $SECRET_NAME ]] && ! [[ "$base" =~ $SECRET_OK ]]; then
  block secrets "доступ к файлу с секретами ($file). Структуру без значений можно посмотреть командой sed -E 's/=.*/=<скрыто>/' $base"
fi

(( writing )) || exit 0

# --- tests: существующие и замороженные тесты
TEST_PATTERN="${DEV_WORKFLOW_TEST_PATTERN:-(^|/)(tests?|__tests__|specs?|testdata|__snapshots__|e2e)/|(^|/)test_[^/]*\.py$|(^|/)conftest\.py$|_test\.(py|go|rb|exs?|dart)$|\.(test|spec|cy)\.[cm]?[jt]sx?$|_spec\.rb$|(Tests?|Spec)\.(java|kt|kts|cs|swift|php|scala)$|\.snap$|\.golden$|\.approved\.}"
SUPPRESS='(#[[:space:]]*noqa|type:[[:space:]]*ignore|pyright:[[:space:]]*ignore|pylint:[[:space:]]*disable|pragma:[[:space:]]*no[[:space:]]*cover|eslint-disable|biome-ignore|@ts-ignore|@ts-nocheck|@ts-expect-error|istanbul[[:space:]]+ignore|nolint|NOLINT|@SuppressWarnings|rubocop:disable|phpcs:ignore|pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)\(|unittest\.(skip|expectedFailure)|skipTest\(|(it|describe|test|context|suite)\.(skip|only|todo|fixme)\(|(^|[^A-Za-z0-9_])(xit|xdescribe|xtest|fit|fdescribe)\(|t\.Skip|@(Disabled|Ignore)([^A-Za-z0-9_]|$)|#\[ignore\])'

dir=${path%/*}
while [[ -n "$dir" && ! -d "$dir" ]]; do dir=${dir%/*}; done
[[ -n "$dir" ]] || exit 0
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
top=${top//\\//}
rel=${path#"$top"/}
[[ "$rel" != "$path" ]] || exit 0

main=$(git -C "$top" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
main=${main:-$top}
frozen=0
shopt -s nullglob
for list in "$main"/.ai/tasks/*/freeze-*.txt; do
  while IFS= read -r l || [[ -n "$l" ]]; do
    l=${l%$'\r'}
    [[ -z "$l" || "$l" == \#* ]] && continue
    [[ "${l#*  }" == "$rel" ]] && { frozen=1; break 2; }
  done < "$list"
done
shopt -u nullglob
if (( frozen )); then
  block tests "изменение замороженного теста ($rel, список заморозки задачи). Новый тест — в новом файле; правка — через гейт (references/tdd.md, «Заморозка»)"
fi

[[ "$rel" =~ $TEST_PATTERN ]] || exit 0
git -C "$top" cat-file -e "HEAD:$rel" 2>/dev/null || exit 0   # новый файл теста — можно

# Дописывание: каждая правка сохраняет старый текст целиком и только добавляет к нему.
inserted="" pure=0
if (( use_jq )); then
  case "$tool" in
    Edit)
      old=$(jget .tool_input.old_string); new=$(jget .tool_input.new_string)
      if [[ -n "$old" && "$new" == "$old"* ]]; then pure=1; inserted=${new#"$old"}
      elif [[ -n "$old" && "$new" == *"$old" ]]; then pure=1; inserted=${new%"$old"}; fi ;;
    MultiEdit)
      cnt=$(printf '%s' "$input" | jq -r '.tool_input.edits | length' 2>/dev/null) || cnt=0
      pure=1
      for (( e = 0; e < cnt; e++ )); do
        old=$(jget ".tool_input.edits[$e].old_string"); new=$(jget ".tool_input.edits[$e].new_string")
        if [[ -n "$old" && "$new" == "$old"* ]]; then inserted+=${new#"$old"}$'\n'
        elif [[ -n "$old" && "$new" == *"$old" ]]; then inserted+=${new%"$old"}$'\n'
        else pure=0; break; fi
      done
      (( cnt > 0 )) || pure=0 ;;
    Write)
      if [[ -f "$path" ]]; then
        cur=$(cat -- "$path"); new=$(jget .tool_input.content)
        if [[ "$new" == "$cur"* ]]; then pure=1; inserted=${new#"$cur"}; fi
      fi ;;
  esac
fi

EARLY_RETURN=$'(^|\n)[[:space:]]*return[[:space:]]*(\n|$)'
if (( pure )); then
  if [[ "$inserted" =~ $SUPPRESS ]]; then
    block tests "в существующий тест добавляется пропуск или подавление ($rel: ${BASH_REMATCH[0]})"
  fi
  if [[ "$inserted" =~ $EARLY_RETURN ]]; then
    block tests "в существующий тест вставляется досрочный return ($rel)"
  fi
  exit 0
fi
block tests "правка или удаление строк существующего теста ($rel). Тесты, существовавшие на момент Baseline, заморожены: новый тест можно дописать, менять старые — только через гейт (references/tdd.md, «Заморозка»)"
