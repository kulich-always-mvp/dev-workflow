#!/usr/bin/env bash
# guard-bash.sh — PreToolUse-хук Claude Code для инструмента Bash (dev-workflow).
#
# Блокирует команды, которые по регламенту требуют явного согласия пользователя
# (SKILL.md, инвариант 4; references/git-safety.md, «Действия, требующие согласия»).
# Включается сам блоком hooks во frontmatter SKILL.md, когда skill вызван в Claude Code;
# постоянно — через settings.json (references/enforcement.md).
#
# Вход: JSON события PreToolUse в stdin. Выход 2 — блокировка, текст из stderr получает агент.
# Правило из списка GUARD_ASK вместо блокировки выводит запрос подтверждения (JSON
# permissionDecision "ask"), но только в режимах прав default, acceptEdits и plan: в остальных
# (bypassPermissions, dontAsk, auto, неизвестный) спросить некого, и правило блокирует.
# Это страховка от ошибок, а не защита от намеренного обхода: команду, записанную в файл
# и запущенную оттуда, проверка по тексту не увидит.
#
# Проба: команда «true dev-workflow-guard-probe» всегда блокируется с текстом «сторож активен».
# Если она выполнилась, сторож не подключён (SKILL.md, «Сторож»).
#
# Настройки задаёт только пользователь: файл ${CLAUDE_CONFIG_DIR:-~/.claude}/dev-workflow.conf
# (строки КЛЮЧ=значение) или переменные окружения (они главнее файла):
#   GUARD=off                       DEV_WORKFLOW_GUARD               выключить сторожа
#   GUARD_ALLOW=deploy,database     DEV_WORKFLOW_GUARD_ALLOW         не проверять эти правила
#   GUARD_ASK=deploy,branch-delete  DEV_WORKFLOW_GUARD_ASK           спрашивать вместо блокировки
#   PROTECTED_BRANCHES=main master  DEV_WORKFLOW_PROTECTED_BRANCHES  защищённые ветки (пусто — без проверки)
# Правила: hooks, force-push, discard, history, branch-delete, protected-branch, snapshots,
#          system, global-install, remote-script, database, deploy, rm-root, delete-tracked, secrets.
# Правило hooks никогда не спрашивает: обход проверок подтверждением не разрешается.
# После согласия пользователь выполняет заблокированную команду сам, в своём терминале,
# или подтверждает запрос, если правило в GUARD_ASK.

set -u
input=$(cat)

# ---------------------------------------------------------------- настройки

unquote() { local v=$1; v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}; printf '%s' "$v"; }

cfg_guard="" cfg_allow="" cfg_ask="" cfg_branches="main master"
conf="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/dev-workflow.conf"
if [[ -f "$conf" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      GUARD=*)              cfg_guard=$(unquote "${line#GUARD=}") ;;
      GUARD_ALLOW=*)        cfg_allow=$(unquote "${line#GUARD_ALLOW=}") ;;
      GUARD_ASK=*)          cfg_ask=$(unquote "${line#GUARD_ASK=}") ;;
      PROTECTED_BRANCHES=*) cfg_branches=$(unquote "${line#PROTECTED_BRANCHES=}") ;;
    esac
  done < "$conf"
fi
guard_mode=${DEV_WORKFLOW_GUARD-$cfg_guard}
allow_list=${DEV_WORKFLOW_GUARD_ALLOW-$cfg_allow}
protected=${DEV_WORKFLOW_PROTECTED_BRANCHES-$cfg_branches}
ask_list=${DEV_WORKFLOW_GUARD_ASK-$cfg_ask}
case "$guard_mode" in off|OFF|Off|0|false|no) exit 0 ;; esac
allow_list=",${allow_list// /},"
ask_list=",${ask_list// /},"

# ---------------------------------------------------------------- текст команды

json_field() {  # $1 — ключ; упрощённое чтение строкового поля JSON, когда нет jq
  local re v
  re='"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ $input =~ $re ]] || return 1
  v=${BASH_REMATCH[1]}
  v=${v//\\n/$'\n'}
  v=${v//\\\"/\"}
  v=${v//\\\\/\\}
  printf '%s' "$v"
}

cmd="" cwd="" pmode=""
use_jq=0
if [[ -z "${DEV_WORKFLOW_GUARD_NO_JQ:-}" ]] && command -v jq >/dev/null 2>&1; then
  use_jq=1
  both=$(printf '%s' "$input" | jq -r '(.cwd // "") + "\u0001" + (.permission_mode // "") + "\u0001" + (.tool_input.command // "")' 2>/dev/null) || both=""
  if [[ "$both" == *$'\001'*$'\001'* ]]; then
    cwd=${both%%$'\001'*}
    both=${both#*$'\001'}
    pmode=${both%%$'\001'*}
    cmd=${both#*$'\001'}
  fi
fi
if [[ -z "$cmd" ]]; then
  cmd=$(json_field command) || cmd=""
  [[ -n "$cwd" ]] || cwd=$(json_field cwd) || cwd=""
  [[ -n "$pmode" ]] || pmode=$(json_field permission_mode) || pmode=""
fi
if [[ -z "$cmd" ]]; then
  # Формат события неизвестен: проверяем весь текст, кавычки считаем границами команд.
  cmd=${input//\"/;}
fi

# Тело heredoc — это данные (текст файла), а не команды; исключение — heredoc, который
# передаётся в shell (bash <<EOF). Строки тела выкидываем, чтобы не блокировать запись
# документации со словами вроде «sudo».
strip_heredocs() {
  local out="" line delim="" keep=0 t tab=$'\t'
  local start_re='(^|[^<])<<-?[[:space:]]*["'"'"']?([A-Za-z_][A-Za-z0-9_]*)["'"'"']?'
  local shell_re='(^|[;&|(]|[[:space:]])(sh|bash|zsh|dash|ksh)([[:space:]]+-[a-zA-Z]+)*[[:space:]]*<<'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$delim" ]]; then
      t=${line#"${line%%[!$tab]*}"}
      if [[ "$t" == "$delim" ]]; then delim=""; continue; fi
      (( keep )) && out+="$line"$'\n'
      continue
    fi
    out+="$line"$'\n'
    if [[ $line =~ $start_re ]]; then
      delim=${BASH_REMATCH[2]}
      keep=0
      [[ $line =~ $shell_re ]] && keep=1
    fi
  done <<< "$1"
  printf '%s' "$out"
}
cmd=$(strip_heredocs "$cmd")
cmd=${cmd//$'\r'/;}
cmd=${cmd//$'\n'/;}
orig=$cmd

# Команды внутри «bash -c "…"», «sh -c '…'», «eval "…"», «pwsh -Command "…"» проверяем
# как отдельные: на месте открывающей кавычки ставим разделитель.
unwrap_re='(^|[^A-Za-z0-9_])((sh|bash|zsh|dash|ksh|pwsh|powershell)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-([A-Za-z]*c[A-Za-z]*|[Cc]ommand)|eval)[[:space:]]+["'"'"']'
rest=$cmd out=""
while [[ $rest =~ $unwrap_re ]]; do
  m=${BASH_REMATCH[0]}
  out+="${rest%%"$m"*}${m%?};"
  rest=${rest#*"$m"}
done
cmd=$out$rest

# Код внутри «python -c "…"», «node -e '…'», «perl -e», «ruby -e», «php -r», «deno eval»:
# строки в нём часто содержат команды shell (os.system("git reset --hard")). К проверке
# добавляем копию команды, где кавычки, скобки и запятые считаются границами команд.
interp_re='(^|[^A-Za-z0-9_])(python[0-9.]*|py|node|deno|bun|perl|ruby|php)(\.exe)?([[:space:]]+-[A-Za-z0-9-]+)*[[:space:]]+(-[A-Za-z]*[ceEr]|--eval|eval)[[:space:]]+["'"'"']'
if [[ $cmd =~ $interp_re ]]; then
  extra=$cmd
  for ch in '"' "'" '(' ')' ',' '[' ']'; do extra=${extra//"$ch"/;}; done
  cmd="$cmd;$extra"
fi

# ---------------------------------------------------------------- проверки

# P — начало простой команды (после разделителя, обёрток и присваиваний переменных);
# G — вызов git до подкоманды; A — «дальше в той же простой команде»; E — конец слова.
P='(^|[;&|({`]|\$\()[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*|env|command|builtin|exec|time|nohup|nice|xargs|then|do|else|!|timeout[[:space:]]+[0-9.]+[smhd]?)[[:space:]]+)*'
G="$P"'([^[:space:];&|]*/)?git(\.exe)?[[:space:]]([^;&|]*[[:space:]])?'
A='([[:space:]][^;&|]*)?[[:space:]]'
E='([[:space:];&|)]|$)'
Q='["'"'"']?'

json_str() {  # строка JSON в кавычках
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}; s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

block() {  # $1 — правило, $2 — что именно
  [[ "$allow_list" == *",$1,"* ]] && return 0
  if [[ "$1" != hooks && "$ask_list" == *",$1,"* ]]; then
    case "$pmode" in
      default|acceptEdits|plan)
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}\n' \
          "$(json_str "dev-workflow [$1]: $2. Подтвердите, только если это действие с вами согласовано.")"
        exit 0 ;;
    esac
  fi
  printf 'Заблокировано регламентом dev-workflow [%s]: %s.\n' "$1" "$2" >&2
  printf 'Это действие требует явного согласия пользователя (SKILL.md, инвариант 4). Не ищи обходной путь: опиши пользователю, что и зачем нужно выполнить, и дождись решения — после согласия он выполнит команду сам.\n' >&2
  exit 2
}
check()  { if [[ $cmd =~ $3 ]]; then block "$1" "$2"; fi; }
checko() { if [[ $orig =~ $3 ]]; then block "$1" "$2"; fi; }
checki() {
  shopt -s nocasematch
  if [[ $cmd =~ $3 ]]; then shopt -u nocasematch; block "$1" "$2"; fi
  shopt -u nocasematch
}

# --- проба: показывает агенту, что сторож подключён (не отключается через GUARD_ALLOW)
probe_re="${P}"'true[[:space:]]+dev-workflow-guard-probe([[:space:];&|)]|$)'
if [[ $cmd =~ $probe_re ]]; then
  printf 'Сторож dev-workflow активен (это проба, а не нарушение).\n' >&2
  exit 2
fi

# --- обход проверок: хуки git и настройки агента
check  hooks "обход git-хуков (--no-verify)" "${G}--no-veri"
check  hooks "обход git-хуков (git commit -n)" "${G}commit${A}-[a-zA-Z]*n[a-zA-Z]*${E}"
# core.hooksPath: блокируется установка и сброс; чтение (git config core.hooksPath, --get) нужно Discovery.
checki hooks "отключение git-хуков (core.hooksPath)" '(^|[^A-Za-z0-9_])git(\.exe)?[[:space:]]([^;&|]*[[:space:]])?-c[[:space:]]*core\.hookspath'
checki hooks "отключение git-хуков (core.hooksPath)" "${G}"'config([[:space:]]+-[^;&|[:space:]]*)*[[:space:]]+(--unset(-all)?|--replace-all|--add|set|unset)[[:space:]]+([^;&|]*[[:space:]])?core\.hookspath'
checki hooks "отключение git-хуков (core.hooksPath)" "${G}"'config([[:space:]]+-[^;&|[:space:]]*)*[[:space:]]+core\.hookspath[[:space:]=]+["'"'"']?[^-[:space:];&|]'
checki hooks "отключение менеджера git-хуков" '(^|[[:space:];&|(])(export[[:space:]]+)?(husky=0|husky_skip_hooks=|lefthook=0|skip=[^[:space:];&|]+[[:space:]]+([^[:space:];&|]*/)?git[[:space:]])'
check  hooks "изменение git-хуков, настроек агента или сторожа" "${P}"'(rm|mv|cp|ln|chmod|truncate|tee|install|sed[[:space:]]+-i[^[:space:]]*|perl[[:space:]]+-p?i[^[:space:]]*)[[:space:]][^;&|]*(\.git/hooks|\.claude/settings[^[:space:];&|]*\.json|dev-workflow\.conf)'
check  hooks "запись в git-хуки, настройки агента или сторожа" '>[[:space:]]*'"$Q"'[^[:space:];&|]*(\.git/hooks/|\.claude/settings[^[:space:];&|]*\.json|dev-workflow\.conf)'
# Скрипты и SKILL.md самого регламента, списки заморозки, .git/config (там живёт core.hooksPath).
# Копировать скрипты skill в репозиторий (cp) можно — это не правка.
GUARDED='(skills/dev-workflow/(scripts/|SKILL\.md)|freeze-[^/[:space:];&|]*\.txt|\.git/config)'
check  hooks "изменение файлов регламента, списка заморозки или .git/config" "${P}"'(rm|mv|truncate|tee|sed[[:space:]]+-i[^[:space:]]*|perl[[:space:]]+-p?i[^[:space:]]*)[[:space:]][^;&|]*'"$GUARDED"
check  hooks "запись в файлы регламента, список заморозки или .git/config" '>[[:space:]]*'"$Q"'[^[:space:];&|]*'"$GUARDED"

# --- принудительный push и удаление на удалённом репозитории
check force-push "принудительный push или удаление на удалённом репозитории" "${G}push${A}"'(--forc[a-z-]*|--mirror|--prune|--delete|-[a-zA-Z]*[fd][a-zA-Z]*)([[:space:]=;&|)]|$)'
check force-push "принудительный push (+ветка)" "${G}push${A}"'\+[^[:space:]]'
check force-push "удаление ветки на удалённом репозитории (:ветка)" "${G}push${A}"':[^[:space:]]'

# --- отбрасывание незакоммиченных изменений
check discard "git reset --hard" "${G}reset${A}--ha"
check discard "git clean -f" "${G}clean${A}"'(-[a-zA-Z]*f|--forc)'
check discard "отбрасывание всех незакоммиченных изменений" "${G}checkout${A}"'(\.|\./|:/|\*|-f|--forc[a-z-]*)([[:space:];&|)]|$)'
check discard "переключение ветки с отбрасыванием изменений" "${G}switch${A}"'(-f|--forc[a-z-]*|--discard-changes)([[:space:];&|)]|$)'
check discard "удаление отложенных изменений (git stash drop/clear)" "${G}stash[[:space:]]+(drop|clear)${E}"
check discard "git worktree remove --force" "${G}worktree[[:space:]]+remove${A}"'(-f|--forc[a-z-]*)([[:space:];&|)]|$)'
restore_all="${G}restore${A}"'(\.|\./|:/|\*)([[:space:];&|)]|$)'
if [[ $cmd =~ $restore_all ]]; then
  staged_only="${G}restore${A}(--staged|-S)${E}"
  worktree_too="${G}restore${A}(--worktree|-W)${E}"
  if ! [[ $cmd =~ $staged_only ]] || [[ $cmd =~ $worktree_too ]]; then
    block discard "отбрасывание всех незакоммиченных изменений (git restore .)"
  fi
fi

# --- переписывание истории
check history "переписывание истории" "${G}(filter-branch|filter-repo)${E}"
check history "удаление журнала ссылок (reflog)" "${G}reflog[[:space:]]+(expire|delete)${E}"
check history "необратимая чистка объектов (gc --prune)" "${G}gc${A}--prune"
check history "удаление ссылки (update-ref -d)" "${G}update-ref${A}-d${E}"

# --- удаление и перенос веток (свои временные parked/… и wip/… — можно)
branch_re="${G}branch${A}"'(-[a-zA-Z]*[DdfF][a-zA-Z]*|--delete|--force)([[:space:];&|)]|$)'
if [[ $cmd =~ $branch_re ]]; then
  seg_re="${G}branch([[:space:]][^;&|]*)?"
  [[ $cmd =~ $seg_re ]]
  seg=${BASH_REMATCH[0]}
  seg=${seg#*branch}
  del=0 force=0 others=""
  set -f
  for tok in $seg; do
    case "$tok" in
      --delete) del=1 ;;
      --force) force=1 ;;
      --*) ;;
      -*) [[ "$tok" == *D* ]] && { del=1; force=1; }
          [[ "$tok" == *d* ]] && del=1
          [[ "$tok" == *f* ]] && force=1 ;;
      *) tok=${tok//\"/}; tok=${tok//\'/}
         case "$tok" in parked/*|wip/*) ;; *) others+=" $tok" ;; esac ;;
    esac
  done
  set +f
  if (( force )) && [[ -n "$others" ]]; then
    if (( del )); then block branch-delete "принудительное удаление веток:$others"
    else block branch-delete "принудительный перенос ветки (git branch -f):$others"; fi
  fi
fi

# --- защищённые ветки
protected_check() {
  [[ "$allow_list" == *",protected-branch,"* ]] && return 0
  local b alt="" re mod bare sw change dir cur
  for b in $protected; do
    [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] || continue
    alt+="${alt:+|}${b//./\\.}"
  done
  [[ -n "$alt" ]] || return 0

  re="${G}push${A}"'([^[:space:]]*:)?(refs/heads/)?('"$alt"')([[:space:];&|)]|$)'
  [[ $cmd =~ $re ]] && block protected-branch "push в защищённую ветку"

  mod="${G}(commit|merge|rebase|cherry-pick|revert|am|pull)${E}"
  bare="${G}"'push(([[:space:]]+-[^[:space:];&|]*)*)([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?(([[:space:]]+-[^[:space:];&|]*)*)[[:space:]]*($|[;&|)])'
  sw="${G}(checkout|switch)[[:space:]]+(${alt})${E}"
  change="${G}(checkout|switch)${E}"
  if [[ $cmd =~ $sw ]] && { [[ $cmd =~ $mod ]] || [[ $cmd =~ $bare ]]; }; then
    block protected-branch "изменение защищённой ветки (переключение на неё и коммит, слияние или push в одной команде)"
  fi
  [[ $cmd =~ $mod ]] || [[ $cmd =~ $bare ]] || return 0
  [[ $cmd =~ $change ]] && return 0   # ветка меняется внутри команды — текущую не проверяем
  dir=${cwd:-$PWD}
  [[ -d "$dir" ]] || return 0
  cur=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 0   # пустой репозиторий: первый коммит допустим
  for b in $protected; do
    [[ "$cur" == "$b" ]] && block protected-branch "коммит, слияние или push в защищённой ветке «$cur»"
  done
  return 0
}
protected_check

# --- снапшоты и эталоны
checki snapshots "автоматическое обновление снапшотов" '(--update-snapshots?|--snapshot-update|--updatesnapshot|--update-golden|--update_golden)([[:space:]=;&|)]|$)'
check  snapshots "автоматическое обновление снапшотов (-u)" "${P}"'(([^[:space:];&|]*/)?(jest|vitest|playwright)|(npx|bunx|pnpm[[:space:]]+exec|pnpm|yarn)[[:space:]]+(jest|vitest|playwright)|(npm|pnpm|yarn|bun)([[:space:]]+run)?[[:space:]]+test)'"${A}"'-u([[:space:];&|)]|$)'
check  snapshots "автоматическое обновление эталонов (go test -update)" "${P}"'go[[:space:]]+test'"${A}"'-update([[:space:]=;&|)]|$)'
check  snapshots "автоматическое принятие снапшотов (cargo insta)" "${P}"'cargo[[:space:]]+insta[[:space:]]+(accept|review)'
checki snapshots "автоматическое обновление снапшотов (переменная окружения)" '(^|[[:space:];&|(])(export[[:space:]]+)?(insta_update=(always|new|unseen|1)|update_expect=1|trybuild=overwrite|update_snapshots?=(1|true|all))'

# --- система
check  system "sudo и повышение прав" "${P}"'(sudo|doas|runas)[[:space:]]'
checki system "постоянные системные настройки Windows" "${P}"'(setx|reg[[:space:]]+(add|delete|import|copy))[[:space:]]'
check  system "изменение профиля shell" '>>?[[:space:]]*'"$Q"'[^[:space:];&|]*(\.bashrc|\.bash_profile|\.zshrc|\.zprofile|\.zshenv|\.profile|config\.fish|_profile\.ps1)'
check  system "изменение профиля shell" "${P}"'(tee|sed[[:space:]]+-i[^[:space:]]*)[[:space:]][^;&|]*(\.bashrc|\.bash_profile|\.zshrc|\.zprofile|\.zshenv|\.profile|config\.fish)'
git_cfg_global="${G}config${A}(--global|--system)${E}"
if [[ $cmd =~ $git_cfg_global ]]; then
  git_cfg_read="${G}config${A}(--get|--get-all|--get-regexp|--list|-l|--show-origin|--show-scope|get|list)${E}"
  [[ $cmd =~ $git_cfg_read ]] || block system "изменение глобальных настроек git (git config --global)"
fi

# --- глобальные установки
INST='(i|install|add|link|uninstall|remove|rm|un|update|up|upgrade)'
check global-install "глобальная установка пакетов" "${P}(npm|pnpm|bun)${A}${INST}${A}(-g|--global)${E}"
check global-install "глобальная установка пакетов" "${P}(npm|pnpm|bun)${A}(-g|--global)${A}${INST}${E}"
check global-install "глобальная установка пакетов (yarn global)" "${P}"'yarn[[:space:]]+global[[:space:]]+(add|remove|upgrade)'
check global-install "установка Python-пакетов вне виртуального окружения" "${P}"'(pip[0-9.]*|python[0-9.]*[[:space:]]+-m[[:space:]]+pip|uv[[:space:]]+pip)[[:space:]]+install'"${A}"'(--user|--break-system-packages)([[:space:];&|)]|$)'
check global-install "глобальная установка программ" "${P}"'(pipx|cargo|gem|go)[[:space:]]+install([[:space:];&|)]|$)'
check global-install "глобальная установка программ" "${P}"'dotnet[[:space:]]+tool[[:space:]]+(install|update|uninstall)'"${A}"'(-g|--global)([[:space:];&|)]|$)'
check global-install "системный менеджер пакетов" "${P}"'(apt|apt-get|aptitude|yum|dnf|zypper|apk|brew|port|choco|winget|scoop|snap|flatpak)[[:space:]]+(install|reinstall|add|remove|uninstall|upgrade|purge)([[:space:];&|)]|$)'
check global-install "системный менеджер пакетов" "${P}"'pacman[[:space:]]+-[SRU]'

# --- выполнение скриптов из сети
checki remote-script "выполнение скрипта из сети" '(curl|wget|iwr|irm|invoke-webrequest|invoke-restmethod)[^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?([^[:space:];&|]*/)?(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|node|perl|ruby|iex|invoke-expression|pwsh|powershell)([[:space:];&|)]|$)'
checko remote-script "выполнение скрипта из сети" '(sh|bash|zsh|dash|ksh|eval)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*["'"'"']?\$\([[:space:]]*(curl|wget)'
checko remote-script "выполнение скрипта из сети" '(source|\.|sh|bash|zsh|dash|ksh)[[:space:]]+<\([[:space:]]*(curl|wget)'
shopt -s nocasematch
ps_re='(iex|invoke-expression)[[:space:]]*\(?[[:space:]]*\(?(iwr|irm|invoke-webrequest|invoke-restmethod|new-object[[:space:]]+(system\.)?net\.webclient)'
if [[ $orig =~ $ps_re ]]; then shopt -u nocasematch; block remote-script "выполнение скрипта из сети (PowerShell)"; fi
shopt -u nocasematch

# --- базы данных
db_client='(^|[^A-Za-z0-9_.-])(psql|mysql|mariadb|sqlite3|sqlcmd|mongo|mongosh|redis-cli|clickhouse-client|cqlsh|duckdb)([^A-Za-z0-9_-]|$)'
db_destroy='(drop[[:space:]]+(table|database|schema|index|view|collection|user|role)|truncate[[:space:]]|flushall|flushdb|dropdatabase\(|\.drop\(\))'
db_delete='delete[[:space:]]+from'
db_where='[[:space:]]where[[:space:]]'
shopt -s nocasematch
if [[ $cmd =~ $db_client ]]; then
  if [[ $cmd =~ $db_destroy ]]; then shopt -u nocasematch; block database "разрушающий запрос к базе данных"; fi
  if [[ $cmd =~ $db_delete ]] && ! [[ $cmd =~ $db_where ]]; then shopt -u nocasematch; block database "DELETE без WHERE"; fi
fi
shopt -u nocasematch
checki database "сброс или пересоздание базы данных" '(prisma[[:space:]]+migrate[[:space:]]+(reset|deploy)|prisma[[:space:]]+db[[:space:]]+push'"${A}"'(--force-reset|--accept-data-loss)|(rails|rake)'"${A}"'db:(drop|reset|purge|schema:load|setup|truncate_all)|artisan'"${A}"'(migrate:(fresh|reset|refresh)|db:wipe)|manage\.py'"${A}"'(flush|sqlflush)([[:space:];&|)]|$)|alembic'"${A}"'downgrade|flyway'"${A}"'clean|liquibase'"${A}"'drop-?all|typeorm'"${A}"'schema:drop|sequelize'"${A}"'db:drop|(^|[;&|[:space:]])dropdb[[:space:]]|mongorestore'"${A}"'--drop)'

# --- публикация и деплой
check deploy "публикация пакета" "${P}(npm|pnpm|yarn|bun)${A}publish${E}"
check deploy "публикация пакета" "${P}"'(cargo|gem|twine|poetry|uv|hatch|flit)[[:space:]]+(publish|push|upload)([[:space:];&|)]|$)'
check deploy "публикация пакета" "${P}"'dotnet[[:space:]]+nuget[[:space:]]+push'
check deploy "публикация образа" "${P}"'docker[[:space:]]+((image[[:space:]]+)?push([[:space:];&|)]|$)|buildx'"${A}"'--push)'
check deploy "изменение репозитория или релиза на GitHub" "${P}"'gh[[:space:]]+(release[[:space:]]+(create|upload|delete|edit)|pr[[:space:]]+merge|repo[[:space:]]+(delete|archive|edit|rename)|secret[[:space:]]+(set|delete|remove)|variable[[:space:]]+(set|delete)|workflow[[:space:]]+(run|enable|disable))'
check deploy "изменение инфраструктуры" "${P}(terraform|tofu)${A}"'(apply|destroy|import|taint|untaint)([[:space:];&|)]|$)'
check deploy "изменение инфраструктуры" "${P}(terraform|tofu)${A}"'state[[:space:]]+(rm|mv|push|replace-provider)'
check deploy "изменение инфраструктуры" "${P}pulumi${A}"'(up|destroy|cancel|refresh)([[:space:];&|)]|$)'
check deploy "изменение кластера Kubernetes" "${P}kubectl${A}"'(apply|create|delete|replace|patch|scale|rollout|drain|cordon|uncordon|taint|edit|set|annotate|label|expose|run|autoscale)([[:space:];&|)]|$)'
check deploy "изменение релиза Helm" "${P}helm${A}"'(install|upgrade|uninstall|delete|rollback)([[:space:];&|)]|$)'
check deploy "деплой" "${P}(vercel|netlify)${A}"'--prod(uction)?([[:space:]=;&|)]|$)'
check deploy "деплой" "${P}(firebase|fly|flyctl|serverless|sls|cdk|eb)${A}"'(deploy|destroy|remove|terminate)([[:space:];&|)]|$)'
check deploy "изменение ресурсов облака" "${P}aws${A}"'(rm|rb|mv|sync|deploy|invoke|delete-[a-z-]+|terminate-[a-z-]+|put-[a-z-]+|update-[a-z-]+|create-[a-z-]+)([[:space:];&|)]|$)'
check deploy "изменение ресурсов облака" "${P}gcloud${A}"'(delete|deploy|create|update|set-iam-policy|add-iam-policy-binding|remove-iam-policy-binding)([[:space:];&|)]|$)'
check deploy "изменение ресурсов облака" "${P}az${A}"'(delete|create|update|deploy|set|purge)([[:space:];&|)]|$)'

# --- удаление корня, домашней папки, проекта или .git
check rm-root "удаление корня диска, домашней папки, проекта или .git" "${P}rm${A}"'(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]][^;&|]*)?[[:space:]]'"$Q"'(/|/\*|~|~/|~/\*|\$HOME|\$\{HOME\}|\.|\./|\./\*|\.\.|\.\./|\.\./\*|\*|([^[:space:];&|"'"'"']*/)?\.git/?|[A-Za-z]:[/\\]?|/[a-z]/?)'"$Q"'([[:space:];&|)]|$)'

# ---------------------------------------------------------------- разбор по простым командам
# Дальше команда делится на простые команды по ; & | и разбирается по словам: так видно,
# какие пути получает rm, find, git restore и программы чтения файлов.

TEST_PATTERN="${DEV_WORKFLOW_TEST_PATTERN:-(^|/)(tests?|__tests__|specs?|testdata|__snapshots__|e2e)/|(^|/)test_[^/]*\.py$|(^|/)conftest\.py$|_test\.(py|go|rb|exs?|dart)$|\.(test|spec|cy)\.[cm]?[jt]sx?$|_spec\.rb$|(Tests?|Spec)\.(java|kt|kts|cs|swift|php|scala)$|\.snap$|\.golden$|\.approved\.}"
SECRET_NAME='^(\.env(\..+)?|\.envrc|\.netrc|_netrc|\.pgpass|\.pypirc|\.npmrc|credentials|id_(rsa|dsa|ecdsa|ed25519))$'
SECRET_OK='^\.env\.(example|sample|template|dist|defaults)$'
SECRET_VAR='\$\{?[A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|PASS|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIALS?)[A-Za-z0-9_]*'

base_dir=${cwd:-$PWD}
in_repo=0
[[ -d "$base_dir" ]] && git -C "$base_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_repo=1

unq() { local t=$1; t=${t//\"/}; t=${t//\'/}; printf '%s' "$t"; }

tracked_under() {  # $1 — папка репозитория, $2 — путь или маска: есть ли там файлы под git
  [[ -n "$(git -C "$1" ls-files -- "$2" 2>/dev/null | head -n 1)" ]]
}
tracked_tests_under() {  # есть ли там тесты, уже закоммиченные в HEAD (существующие тесты)
  local f
  while IFS= read -r f; do
    [[ "$f" =~ $TEST_PATTERN ]] && git -C "$1" cat-file -e "HEAD:$f" 2>/dev/null && return 0
  done < <(git -C "$1" -c core.quotePath=false ls-files --full-name -- "$2" 2>/dev/null)
  return 1
}

simple_cmds=()
IFS=$'\n' read -r -d '' -a simple_cmds < <(printf '%s' "$cmd" | tr ';&|' '\n\n\n'; printf '\0')

set -f
for sc in "${simple_cmds[@]}"; do
  read -r -a w <<< "$sc"
  n=${#w[@]} i=0
  # обёртки и присваивания перед командой
  while (( i < n )); do
    t=$(unq "${w[i]}"); t=${t#\$(}; t=${t#\(}; t=${t#\{}; t=${t#\`}
    case "$t" in
      ""|"!"|then|do|else|command|builtin|exec|time|nohup|nice|xargs|sudo|doas) (( i++ )); continue ;;
      timeout) (( i += 2 )); continue ;;
      [A-Za-z_]*=*) [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && { (( i++ )); continue; } ;;
    esac
    break
  done
  (( i < n )) || continue
  prog=$(unq "${w[i]}"); prog=${prog#\$(}; prog=${prog#\(}; prog=${prog#\{}; prog=${prog##*/}; prog=${prog%.exe}
  args=("${w[@]:i+1}")

  # --- secrets: окружение целиком, файлы с секретами, значения секретных переменных
  if [[ "$allow_list" != *",secrets,"* ]]; then
    if [[ "$prog" == env ]]; then
      rest_cmd=0
      for a in "${args[@]}"; do
        a=$(unq "$a")
        case "$a" in -*|[A-Za-z_]*=*) ;; "") ;; *) rest_cmd=1; break ;; esac
      done
      (( rest_cmd )) || block secrets "вывод всего окружения (env): там бывают токены и пароли"
    fi
    if [[ "$prog" == printenv ]]; then
      if (( ${#args[@]} == 0 )); then block secrets "вывод всего окружения (printenv)"; fi
      for a in "${args[@]}"; do
        a=$(unq "$a")
        shopt -s nocasematch
        if [[ "\$$a" =~ $SECRET_VAR ]]; then shopt -u nocasematch; block secrets "вывод секретной переменной ($a)"; fi
        shopt -u nocasematch
      done
    fi
    if [[ "$prog" == export || "$prog" == declare || "$prog" == typeset ]] && [[ " ${args[*]} " == *" -p "* || " ${args[*]} " == *" -px "* || ${#args[@]} -eq 0 ]]; then
      block secrets "вывод всего окружения ($prog)"
    fi
    if [[ "$prog" == set && ${#args[@]} -eq 0 ]]; then block secrets "вывод всех переменных (set)"; fi
    shopt -s nocasematch
    if [[ "$prog" =~ ^(get-childitem|gci|dir|ls)$ && " ${args[*]} " =~ [[:space:]]\"?env:\"?[[:space:]] ]]; then
      shopt -u nocasematch; block secrets "вывод всего окружения (env:)"
    fi
    shopt -u nocasematch
    case "$prog" in
      cat|bat|batcat|less|more|head|tail|nl|tac|strings|xxd|od|hexdump|base64|type|Get-Content|gc|grep|egrep|fgrep|rg|ag)
        quiet=0
        if [[ "$prog" =~ ^(grep|egrep|fgrep|rg|ag)$ ]]; then
          for a in "${args[@]}"; do [[ "$(unq "$a")" =~ ^-[A-Za-z]*[lLcq][A-Za-z]*$ || "$(unq "$a")" =~ ^--(files-with(out)?-matches|count|quiet)$ ]] && quiet=1; done
        fi
        if (( ! quiet )); then
          for a in "${args[@]}"; do
            a=$(unq "$a"); b=${a##*/}; b=${b##*\\}
            [[ "$a" == -* ]] && continue
            if [[ "$b" =~ $SECRET_NAME ]] && ! [[ "$b" =~ $SECRET_OK ]]; then
              block secrets "чтение файла с секретами ($a). Структуру без значений можно посмотреть так: sed -E 's/=.*/=<скрыто>/' $a"
            fi
          done
        fi ;;
      echo|printf|Write-Output|Write-Host)
        line=" ${args[*]}"
        line=${line//\$\{\#/}
        shopt -s nocasematch
        if [[ "$line" =~ $SECRET_VAR ]] && ! [[ "${BASH_REMATCH[0]}" == *:+* || "$line" =~ \$\{[A-Za-z0-9_]+:\+ ]]; then
          shopt -u nocasematch; block secrets "вывод значения секретной переменной"
        fi
        shopt -u nocasematch ;;
    esac
  fi

  (( in_repo )) || continue

  # --- delete-tracked: рекурсивное удаление файлов под git и удаление существующих тестов
  if [[ "$prog" == rm ]]; then
    rec=0 paths=() dd=0
    for a in "${args[@]}"; do
      a=$(unq "$a")
      if (( ! dd )); then
        case "$a" in
          --) dd=1; continue ;;
          --recursive) rec=1; continue ;;
          --*) continue ;;
          -*) [[ "$a" == *[rR]* ]] && rec=1; continue ;;
        esac
      fi
      [[ -n "$a" ]] && paths+=("$a")
    done
    for p in "${paths[@]}"; do
      if (( rec )) && tracked_under "$base_dir" "$p"; then
        block delete-tracked "рекурсивное удаление файлов под контролем git ($p)"
      fi
      if tracked_tests_under "$base_dir" "$p"; then
        block delete-tracked "удаление существующих тестов ($p)"
      fi
    done
  fi
  if [[ "$prog" == find ]] && [[ " ${args[*]} " =~ [[:space:]](-delete|-exec(dir)?[[:space:]]+(rm|/bin/rm))[[:space:]] ]]; then
    roots=() name=""
    for (( k = 0; k < ${#args[@]}; k++ )); do
      a=$(unq "${args[k]}")
      case "$a" in
        -name|-iname|-path|-ipath) name=$(unq "${args[k+1]:-}"); break ;;
        -*|"("|"!"|"\\(") break ;;
        *) roots+=("$a") ;;
      esac
    done
    (( ${#roots[@]} )) || roots=(.)
    for r in "${roots[@]}"; do
      if [[ -n "$name" ]]; then spec=":(glob)${r%/}/**/$name"; [[ "$r" == . ]] && spec=":(glob)**/$name"
      else spec=$r; fi
      if tracked_under "$base_dir" "$spec"; then
        block delete-tracked "удаление через find файлов под контролем git ($r${name:+, $name})"
      fi
    done
  fi

  # --- git: rm -r, restore и checkout каталогов или масок
  if [[ "$prog" == git ]]; then
    gdir=$base_dir k=0 sub=""
    while (( k < ${#args[@]} )); do
      a=$(unq "${args[k]}")
      case "$a" in
        -C) d=$(unq "${args[k+1]:-}"); [[ "$d" == /* ]] && gdir=$d || gdir="$base_dir/$d"; (( k += 2 )); continue ;;
        -c|--git-dir|--work-tree|--namespace) (( k += 2 )); continue ;;
        -*) (( k++ )); continue ;;
      esac
      sub=$a; (( k++ )); break
    done
    rest_args=("${args[@]:k}")
    case "$sub" in
      rm)
        rec=0 cached=0 paths=() dd=0
        for a in "${rest_args[@]}"; do
          a=$(unq "$a")
          if (( ! dd )); then
            case "$a" in
              --) dd=1; continue ;;
              --cached) cached=1; continue ;;
              -*) [[ "$a" == -r || "$a" == -*r* && "$a" != --* ]] && rec=1; continue ;;
            esac
          fi
          paths+=("$a")
        done
        if (( ! cached )); then
          for p in "${paths[@]}"; do
            (( rec )) && tracked_under "$gdir" "$p" && block delete-tracked "git rm -r файлов под контролем git ($p)"
            tracked_tests_under "$gdir" "$p" && block delete-tracked "удаление существующих тестов (git rm $p)"
          done
        fi ;;
      restore|checkout)
        staged_only=0 worktree=0 paths=() dd=0 skip=0
        for a in "${rest_args[@]}"; do
          a=$(unq "$a")
          if (( skip )); then skip=0; continue; fi
          if (( ! dd )); then
            case "$a" in
              --) dd=1; continue ;;
              --staged|-S) staged_only=1; continue ;;
              --worktree|-W) worktree=1; continue ;;
              -s|--source|-b|-B|--orphan|--conflict) skip=1; continue ;;
              -*) continue ;;
            esac
            [[ "$sub" == checkout ]] && continue   # у checkout пути — только после «--»
          fi
          paths+=("$a")
        done
        (( staged_only && ! worktree )) && continue
        for p in "${paths[@]}"; do
          [[ "$p" == :/* ]] && p=${p#:/}
          if [[ "$p" == *[\*\?\[]* ]] || [[ -n "$p" && -d "$gdir/$p" ]]; then
            block discard "отбрасывание изменений в целом каталоге или по маске (git $sub $p); свои правки откатывай пофайлово"
          fi
        done ;;
    esac
  fi
done
set +f

exit 0
