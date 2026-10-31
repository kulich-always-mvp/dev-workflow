#!/usr/bin/env bash
# freeze.sh — заморозка тестов контрольными суммами (dev-workflow).
#
# Нужна, когда красный коммит test(...) сделать нельзя: хуки проекта запускают тесты при
# коммите или коммиты агенту запрещены (references/tdd.md, «Заморозка»).
#
#   freeze.sh record <файл-списка> <файл-теста>...                 записать контрольные суммы
#   freeze.sh record --reason "<причина>" <файл-списка> <файл-теста>...
#                                                  перезаморозить: только после согласованной правки
#   freeze.sh verify <файл-списка> [<коммит>]       сверить файлы рабочей копии или указанного коммита
#
# Если список уже есть, record без --reason отказывается (код 2): перезаморозка после правки
# теста стёрла бы следы этой правки. С --reason прежние строки остаются в файле комментариями
# «#~», а причина записывается; verify сообщает, сколько раз список перезаписывали.
# record и verify печатают отпечаток списка (sha1 файла). Укажи его в отчёте о шаге:
# подмену списка тогда видно по несовпадению отпечатка.
#
# Пути тестов — относительные (от текущей папки), внутри репозитория. В списке они хранятся
# от корня репозитория: «<sha1>  <путь>» на строку, строки с # — комментарии.
# Коды выхода: 0 — всё совпадает (или список записан), 1 — есть расхождения, 2 — ошибка запуска.

set -uo pipefail

die() { printf 'freeze.sh: %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
esac

top=$(git rev-parse --show-toplevel 2>/dev/null) || die "не git-репозиторий"
prefix=$(git rev-parse --show-prefix)

abs_path() {  # абсолютный путь к файлу, который может ещё не существовать
  local d b
  d=$(dirname -- "$1"); b=$(basename -- "$1")
  d=$(cd "$d" 2>/dev/null && pwd) || return 1
  printf '%s/%s' "$d" "$b"
}

case "$1" in
  record)
    shift
    reason=""
    if [[ "${1:-}" == --reason ]]; then
      reason=${2:-}
      [[ -n "$reason" ]] || die "после --reason нужна причина перезаморозки"
      shift 2
    fi
    list=${1:-}
    [[ -n "$list" ]] || die "нужен файл списка: freeze.sh record <файл-списка> <файл-теста>..."
    shift
    (( $# > 0 )) || die "нужен хотя бы один файл теста"
    list_abs=$(abs_path "$list") || die "нет папки для файла списка: $list"
    history=""
    if [[ -f "$list_abs" ]]; then
      [[ -n "$reason" ]] || die "список уже есть: $list. Перезаморозка — только после согласованной правки теста: freeze.sh record --reason \"<что согласовано>\" <файл-списка> <файлы>"
      while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ -z "$line" || "$line" == \#* ]]; then history+="$line"$'\n'; else history+="#~ $line"$'\n'; fi
      done < "$list_abs"
    fi
    body=""
    count=0
    for f in "$@"; do
      case "$f" in
        /*|[A-Za-z]:*) die "нужен относительный путь внутри репозитория: $f" ;;
        ..|../*|*/../*|*/..) die "путь не должен выходить из текущей папки через «..»: $f" ;;
      esac
      [[ -f "$f" ]] || die "нет файла: $f"
      rel="$prefix${f#./}"
      body+="$(git hash-object -- "$f")  $rel"$'\n'
      count=$((count + 1))
    done
    head_sha=$(git rev-parse --short -q --verify HEAD 2>/dev/null || echo "нет коммитов")
    {
      printf '%s' "$history"
      if [[ -n "$reason" ]]; then
        printf '# dev-workflow refreeze: %s, HEAD %s, причина: %s\n' "$(date '+%Y-%m-%d %H:%M')" "$head_sha" "${reason//$'\n'/ }"
      else
        printf '# dev-workflow freeze: %s, HEAD %s\n' "$(date '+%Y-%m-%d %H:%M')" "$head_sha"
      fi
      printf '%s' "$body"
    } > "$list_abs" || die "не удалось записать $list"
    printf 'Заморожено файлов: %d → %s\n' "$count" "$list"
    printf 'Отпечаток списка: %s\n' "$(git hash-object -- "$list_abs")"
    ;;

  verify)
    list=${2:-}
    rev=${3:-}
    [[ -f "$list" ]] || die "нет файла списка: $list"
    list_abs=$(abs_path "$list") || die "нет файла списка: $list"
    if [[ -n "$rev" ]]; then
      git rev-parse -q --verify "$rev^{commit}" >/dev/null || die "нет коммита: $rev"
    fi
    cd "$top" || die "не удалось перейти в корень репозитория"
    n=0
    bad=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%$'\r'}
      [[ -z "$line" || "$line" == \#* ]] && continue
      h=${line%%  *}
      p=${line#*  }
      n=$((n + 1))
      if [[ -n "$rev" ]]; then
        cur=$(git rev-parse -q --verify "$rev:$p" 2>/dev/null) || { printf 'ПРОПАЛ: %s (нет в %s)\n' "$p" "$rev"; bad=$((bad + 1)); continue; }
      else
        [[ -f "$p" ]] || { printf 'ПРОПАЛ: %s\n' "$p"; bad=$((bad + 1)); continue; }
        cur=$(git hash-object -- "$p")
      fi
      [[ "$cur" == "$h" ]] || { printf 'ИЗМЕНЁН: %s\n' "$p"; bad=$((bad + 1)); }
    done < "$list_abs"
    (( n > 0 )) || die "список пуст: $list"
    if (( bad > 0 )); then
      printf 'Расхождений: %d из %d. Изменение замороженного теста — только через гейт (references/tdd.md, «Заморозка»).\n' "$bad" "$n"
      exit 1
    fi
    printf 'Заморозка цела: %d файлов%s.\n' "$n" "${rev:+ в $rev}"
    refreezes=$(grep -c '^# dev-workflow refreeze:' "$list_abs" 2>/dev/null) || refreezes=0
    printf 'Отпечаток списка: %s · перезаморозок: %s\n' "$(git hash-object -- "$list_abs")" "$refreezes"
    if (( refreezes > 0 )); then
      grep '^# dev-workflow refreeze:' "$list_abs" | sed 's/^# dev-workflow refreeze: /  перезаморозка: /'
    fi
    ;;

  *)
    die "неизвестная команда «$1» (см. --help)"
    ;;
esac
