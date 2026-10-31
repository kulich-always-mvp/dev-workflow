#!/usr/bin/env bash
# session-reminder.sh — хук SessionStart Claude Code (dev-workflow): после сжатия контекста,
# возобновления или /clear напоминает агенту об активной задаче.
#
# Читает «<основная рабочая копия>/.ai/ACTIVE» (SKILL.md, п. 8) и печатает напоминание; Claude Code
# добавляет вывод хука SessionStart в контекст агента. Нет файла — ничего не печатает.
# Подключение — references/enforcement.md, «Напоминание после сжатия контекста».

set -u
input=$(cat 2>/dev/null || true)

cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
fi
if [[ -z "$cwd" ]]; then
  re='"cwd"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ $input =~ $re ]] && cwd=${BASH_REMATCH[1]//\\\\/\\}
fi
cwd=${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}
[[ -d "$cwd" ]] || exit 0

main=$(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[[ -n "$main" ]] || exit 0
active="$main/.ai/ACTIVE"
[[ -f "$active" ]] || exit 0

line=$(head -n 1 "$active" | tr -d '\r')
[[ -n "$line" ]] || exit 0
slug=${line%% *}

printf 'dev-workflow: активна задача «%s». Прежде чем продолжать, вызови skill dev-workflow и перечитай файлы-якоря в %s/.ai/tasks/%s/ (спецификацию, план, журнал): источник истины — они, а не пересказ диалога.\n' \
  "$line" "$main" "$slug"
exit 0
