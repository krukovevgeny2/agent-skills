#!/usr/bin/env bash
# Ведёт исследование researchFlow: шлюз, спеку, номера и статусы гипотез, worktree опытов, журнал опытов, приёмку, бюджет и коммит итога.
# Файлы исследования живут в основной копии .agentflow/docs/research/<slug>, служебные в .agentflow/.scratch/<slug>.
# Диспетчер и агенты вызывают скрипт вместо ручных команд git. Скрипт можно запускать из любого worktree репозитория.
set -euo pipefail

usage() {
  cat <<'EOF'
Использование:
  research.sh gate [--fix]                    проверить git, автора, соседние навыки и игнор служебных каталогов; печатает «готово»
                                              или по строке на пробел и выходит с кодом 3; --fix дописывает только строки игнора
  research.sh init <slug> [база]              завести каталог исследования, запомнить базу опытов (ветку или коммит, по умолчанию
                                              ветку основной копии) и время старта; печатает путь спеки, повторный вызов только печатает его
  research.sh tick <slug>                     главный шаг диспетчера: заводит опыты на свободные слоты и печатает, что делать дальше,
                                              по строке на действие (см. roles/dispatcher.md)
  research.sh spec <slug>                     проверить поля спеки и приёмку критика: «спека принята» или пробелы с кодом 3
  research.sh agree <slug>                    записать согласие пользователя на принятую спеку: на вопрос, границы, базу, бюджет и критерии
  research.sh accept <slug> spec|report|<NN>  записать приёмку критика: хеш спеки, отчёта или плана, вердикта и журнала гипотезы.
                                              Для гипотезы это и закрытие: снимает worktree и печатает «закрыта: NN <вердикт>: <путь>»,
                                              иначе «<причина> → <роль>» с кодом 3
  research.sh next <slug>                     напечатать номер следующей гипотезы
  research.sh plan <slug> <NN>                закрепить «## План» гипотезы: «закреплён» или «нет плана» с кодом 3;
                                              новый план после start снимает worktree и возвращает гипотезу в planned: опыт идёт заново
  research.sh run <slug> <NN> <команда>       выполнить команду в worktree опыта; в logs/<NN>.log пишет команду, хвост вывода и код выхода,
                                              полный вывод в .agentflow/.scratch/<slug>/out/<NN>.log
  research.sh verdict <slug> <NN>             проверить вердикт до критика: план и журнал не менялись в обход скрипта, вердикт и причина есть;
                                              ставит review (слот свободен) и печатает «на критика», иначе «<причина> → <роль>» с кодом 3
  research.sh hold <slug> <NN>                поставить опыт на паузу до ответа пользователя: статус waiting, слот свободен, worktree остаётся
  research.sh resume <slug> <NN>              снять паузу после ответа пользователя: «нет слота» с кодом 3 или путь worktree
  research.sh reopen <slug> <NN>             вернуть закрытую гипотезу в planned после строки «Сравнивающий: оспорено»
  research.sh reject <slug> <NN> <причина>   снять гипотезу: причина в конец файла, статус rejected, worktree снят
  research.sh empty <slug>                    записать слово «пусто» автора: действует, пока не появилась новая гипотеза или идея
  research.sh status <slug>                   строка на гипотезу и итог: «очередь пуста» или «в работе»
  research.sh budget <slug> [сумма]           без суммы напечатать расход с начала исследования и бюджет, с суммой записать новый бюджет
  research.sh report <slug>                   проверить отчёт: очередь пуста, ссылки на все гипотезы и журналы целы, критерии спеки
                                              в матрице, приёмка критика; печатает «отчёт готов» или пробелы с кодом 3
  research.sh record <slug>                   после «отчёт готов» закоммитить только каталог исследования в текущую ветку основной копии
  research.sh tokens <slug>                   посчитать расход агентов исследования с его начала по транскриптам Claude Code
EOF
}

die() {
  echo "research.sh: $*" >&2
  exit 1
}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Одновременных опытов не больше этого числа, в журнал опыта идёт столько последних строк вывода.
SLOTS=3
TAIL=150

# Основная копия это родитель общего каталога .git, откуда бы ни вызвали скрипт.
set_root() {
  root=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
  wt="$root/.agentflow/.worktree/research"
  docs="$root/.agentflow/docs/research"
  scratch="$root/.agentflow/.scratch"
}

need_slug() {
  slug=${1:?нужен slug}
  dir="$docs/$slug"
  state="$scratch/$slug"
  [ -f "$dir/spec.md" ] || die "нет исследования $slug, сначала init"
  mkdir -p "$state/plans" "$state/logs" "$state/accepted" "$state/out"
}

hyp_file() {
  local files=("$dir/hypotheses/$1-"*.md)
  [ -e "${files[0]}" ] || die "нет файла гипотезы $1 в $dir/hypotheses/"
  echo "${files[0]}"
}

hyp_numbers() {
  local file name
  for file in "$dir/hypotheses/"[0-9][0-9]-*.md; do
    [ -e "$file" ] || continue
    name=$(basename "$file")
    echo "${name%%-*}"
  done
}

get_status() {
  perl -ne 'if (/^Status:\s*(\S+)/) { print $1; exit }' "$1"
}

set_status() {
  perl -0pi -e 's/^Status:.*$/Status: '"$2"'/m' "$1"
}

# Текст раздела «## <имя>» до следующего заголовка второго уровня.
section() {
  perl -0777 -ne 'print $1 if /^## \Q'"$2"'\E[^\n]*\n(.*?)(?=^## |\z)/ms' "$1"
}

field() {
  perl -ne 'if (/^\Q'"$2"'\E:\s*(.*?)\s*$/) { print $1; exit }' <<<"$1"
}

hash() {
  git -C "$root" hash-object --stdin
}

# Файл без раздела замечаний: строки ролей под ним не меняют принятый текст.
body_hash() {
  perl -0777 -pe 's/^## Comments.*\z//ms' "$1" | hash
}

plan_hash() {
  section "$1" "План" | hash
}

log_file() {
  echo "$dir/logs/$1.log"
}

log_hash() {
  if [ -f "$(log_file "$1")" ]; then hash <"$(log_file "$1")"; else echo нет; fi
}

# Журнал пишет только скрипт: после каждой записи он запоминает хеш, и правка в обход видна.
log_append() {
  cat >>"$(log_file "$1")"
  log_hash "$1" >"$state/logs/$1"
}

hyp_hash() {
  { plan_hash "$2"; section "$2" "Вердикт" | hash; log_hash "$1"; } | hash
}

is_accepted() {
  [ -f "$state/accepted/$1" ] && [ "$(cat "$state/accepted/$1")" = "$2" ]
}

# Согласие пользователя держится только на его решениях: вопрос, границы, база, бюджет и критерии.
# Техническая правка спеки (подготовка, вход) проходит через критика и согласия заново не требует.
decision_hash() {
  local spec name
  spec=$(cat "$dir/spec.md")
  {
    for name in Вопрос Границы База Бюджет; do echo "$name: $(field "$spec" "$name")"; done
    section "$dir/spec.md" "Критерии"
  } | hash
}

agreed() {
  [ -f "$state/agreed" ] && [ "$(cat "$state/agreed")" = "$(decision_hash)" ]
}

need_agreed() {
  agreed || {
    echo "нет согласия"
    exit 3
  }
}

base_sha() {
  awk '{print $2}' "$state/base"
}

limit() {
  if [ -f "$state/budget" ]; then
    cat "$state/budget"
  else
    field "$(cat "$dir/spec.md")" "Бюджет" | tr -d '$ '
  fi
}

token_line() {
  perl "$here/tokens.pl" "$root" "$slug" "$state/tokens.md" "$(cat "$state/started" 2>/dev/null || true)"
}

spent() {
  perl -ne 'if (/\$([0-9.]+)/) { print $1; exit }' <<<"$(token_line 2>/dev/null || true)" | grep . || echo 0
}

over_budget() {
  perl -e 'exit($ARGV[0] >= $ARGV[1] ? 0 : 1)' "$(spent)" "$(limit)"
}

count_status() {
  local nn n=0
  for nn in $(hyp_numbers); do
    [ "$(get_status "$(hyp_file "$nn")")" = "$1" ] && n=$((n + 1))
  done
  echo "$n"
}

open_hypotheses() {
  local nn
  for nn in $(hyp_numbers); do
    case "$(get_status "$(hyp_file "$nn")")" in
      closed|rejected) ;;
      *) echo "$nn" ;;
    esac
  done
}

open_ideas() {
  grep -E '^- \[ \]' "$dir/ideas.md" 2>/dev/null || true
}

# Слово «пусто» автора действует, пока число гипотез не изменилось и открытых идей нет.
author_empty() {
  [ -f "$state/empty" ] && [ "$(cat "$state/empty")" = "$(hyp_numbers | wc -l | tr -d ' ')" ] && [ -z "$(open_ideas)" ]
}

# Выполняет команду в каталоге и пишет её в журнал опыта: команду, хвост вывода, код выхода. Возвращает код команды.
logged() {
  local nn=$1 path=$2 cmd=$3 out lines code
  out=$(mktemp)
  set +e
  (cd "$path" && bash -c "$cmd") >"$out" 2>&1
  code=$?
  set -e
  { printf '$ %s\n' "$cmd"; cat "$out"; printf 'код выхода: %s\n\n' "$code"; } >>"$state/out/$nn.log"
  lines=$(wc -l <"$out" | tr -d ' ')
  {
    printf '$ %s\n' "$cmd"
    if [ "$lines" -gt "$TAIL" ]; then
      printf '… пропущено строк: %s, полный вывод: %s\n' "$((lines - TAIL))" "${state#"$root"/}/out/$nn.log"
    fi
    tail -n "$TAIL" "$out"
    printf 'код выхода: %s\n\n' "$code"
  } | tee /dev/stderr | log_append "$nn" 2>/dev/null
  rm -f "$out"
  return "$code"
}

# Чего не хватает вердикту гипотезы: печатает «<причина> → <роль>» или ничего.
verdict_gap() {
  local text verdict
  text=$(section "$2" "Вердикт")
  verdict=$(field "$text" "Вердикт")
  if [ "$(cat "$state/plans/$1" 2>/dev/null)" != "$(plan_hash "$2")" ]; then
    echo "план изменён → постановщик"
  elif [ ! -s "$(log_file "$1")" ]; then
    echo "нет журнала опыта → проверяющий"
  elif [ "$(cat "$state/logs/$1" 2>/dev/null)" != "$(log_hash "$1")" ]; then
    echo "журнал изменён в обход run → проверяющий"
  elif ! grep -qxE 'подтверждена|опровергнута|не определена' <<<"$verdict"; then
    echo "нет вердикта → проверяющий"
  elif [ "$verdict" = "не определена" ] && [ -z "$(field "$text" "Причина")" ]; then
    echo "нет причины → проверяющий"
  fi
}

spec_field_gaps() {
  local spec name
  spec=$(cat "$dir/spec.md")
  for name in Вопрос Вход Границы База; do
    [ -n "$(field "$spec" "$name")" ] || echo "нет поля $name"
  done
  field "$spec" "Бюджет" | grep -qE '^\$ ?[0-9]+(\.[0-9]+)?$' || echo "бюджет не в долларах"
  section "$dir/spec.md" "Критерии" | grep -qE '^- .+ — вес [0-9]+' || echo "нет критериев с весом"
}

spec_gaps() {
  spec_field_gaps
  is_accepted spec "$(body_hash "$dir/spec.md")" || echo "нет приёмки критика"
}

report_field_gaps() {
  local report="$dir/report.md" nn file name target
  [ -z "$(open_hypotheses)" ] || echo "есть незакрытые гипотезы"
  [ -z "$(open_ideas)" ] || echo "есть открытые идеи"
  for nn in $(hyp_numbers); do
    file=$(hyp_file "$nn")
    if [ "$(get_status "$file")" = closed ] && ! is_accepted "$nn" "$(hyp_hash "$nn" "$file")"; then
      echo "гипотеза $nn изменена после приёмки"
    fi
  done
  [ -f "$report" ] || { echo "нет report.md"; return; }
  for nn in $(hyp_numbers); do
    file=$(hyp_file "$nn")
    name=$(basename "$file")
    grep -qF "](hypotheses/$name)" "$report" || echo "нет ссылки на hypotheses/$name"
    if [ "$(get_status "$file")" = closed ]; then
      grep -qF "](logs/$nn.log)" "$report" || echo "нет ссылки на logs/$nn.log"
    fi
  done
  while IFS= read -r target; do
    [ -e "$dir/${target%%#*}" ] || echo "битая ссылка $target"
  done < <(perl -ne 'print "$1\n" while /\]\(([^)\s]+)\)/g' "$report" | grep -vE '^(https?:|mailto:|#)' || true)
  while IFS= read -r name; do
    grep -qF -- "$name" "$report" || echo "критерия «$name» нет в отчёте"
  done < <(section "$dir/spec.md" "Критерии" | perl -ne 'print "$1\n" if /^- (.+?) — вес [0-9]+/')
}

report_gaps() {
  report_field_gaps
  if [ -f "$dir/report.md" ] && ! is_accepted report "$(body_hash "$dir/report.md")"; then
    echo "нет приёмки критика"
  fi
}

drop_worktree() {
  local path="$wt/$slug-$1"
  if [ -d "$path" ]; then git -C "$root" worktree remove --force "$path"; fi
  rm -f "$state/prepared/$1"
}

# Заводит worktree опыта на коммите базы и выполняет подготовку из спеки. Печатает путь или «подготовка красная».
start_one() {
  local nn=$1 file path prep
  file=$(hyp_file "$nn")
  path="$wt/$slug-$nn"
  # Метка ставится только после подготовки: прерванная подготовка начинается заново в новом worktree.
  if [ -d "$path" ] && [ ! -f "$state/prepared/$nn" ]; then
    git -C "$root" worktree remove --force "$path"
  fi
  if [ ! -d "$path" ]; then
    rm -f "$state/prepared/$nn"
    mkdir -p "$wt"
    git -C "$root" worktree add -q --detach "$path" "$(base_sha)"
    prep=$(field "$(cat "$dir/spec.md")" "Подготовка" | sed 's/^`//; s/`$//')
    if [ -n "$prep" ] && [ "$prep" != нет ]; then
      if ! logged "$nn" "$path" "$prep" 2>/dev/null; then
        git -C "$root" worktree remove --force "$path"
        echo "подготовка красная: $nn"
        return 3
      fi
    fi
    mkdir -p "$state/prepared"
    touch "$state/prepared/$nn"
  fi
  set_status "$file" running
  echo "$path"
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
  gate)
    command -v git >/dev/null || die "нет git в PATH"
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo "нет репозитория git"
      exit 3
    fi
    set_root
    gaps=()
    [ -n "$(git -C "$root" config user.name || true)" ] || gaps+=("нет user.name")
    [ -n "$(git -C "$root" config user.email || true)" ] || gaps+=("нет user.email")
    git -C "$root" rev-parse --verify -q HEAD >/dev/null || gaps+=("нет ни одного коммита")
    for skill in grill-me grilling; do
      [ -f "$here/../$skill/SKILL.md" ] || gaps+=("нет навыка $skill рядом с researchFlow")
    done
    common=$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd)
    if ! git -C "$root" check-ignore -q --no-index .agentflow/.worktree/x; then
      if [ "${1:-}" = --fix ]; then echo ".agentflow/.worktree/" >>"$root/.gitignore"; else gaps+=("не игнорируется .agentflow/.worktree/: строка в .gitignore"); fi
    fi
    if ! git -C "$root" check-ignore -q --no-index .agentflow/.scratch/x; then
      if [ "${1:-}" = --fix ]; then
        mkdir -p "$common/info"
        echo ".agentflow/.scratch/" >>"$common/info/exclude"
      else
        gaps+=("не игнорируется .agentflow/.scratch/: строка в .git/info/exclude")
      fi
    fi
    if [ "${#gaps[@]}" -gt 0 ]; then
      printf '%s\n' "${gaps[@]}"
      exit 3
    fi
    echo "готово"
    ;;

  init)
    set_root
    slug=${1:?нужен slug}
    dir="$docs/$slug"
    state="$scratch/$slug"
    if [ ! -f "$dir/spec.md" ]; then
      base=${2:-$(git -C "$root" symbolic-ref --quiet --short HEAD || git -C "$root" rev-parse HEAD)}
      sha=$(git -C "$root" rev-parse --verify -q "$base^{commit}") || die "нет ветки или коммита $base"
      mkdir -p "$dir/hypotheses" "$dir/logs" "$state"
      echo "$base $sha" >"$state/base"
      # Время старта в UTC: расход считается только с него, а не со всей сессии диспетчера.
      date -u +%Y-%m-%dT%H:%M:%S >"$state/started"
      printf 'Вопрос:\nВход:\nГраницы:\nБаза: %s (%s)\nПодготовка: нет\nБюджет: $\n\n## Критерии\n\n## Comments\n' "$base" "$sha" >"$dir/spec.md"
      printf '# Идеи\n\n' >"$dir/ideas.md"
    fi
    echo "$dir/spec.md"
    ;;

  tick)
    set_root
    need_slug "${1:-}"
    if ! is_accepted spec "$(body_hash "$dir/spec.md")"; then
      echo "спека"
      exit 0
    fi
    if ! agreed; then
      echo "согласие"
      exit 0
    fi
    actions=()
    drafts=()
    for nn in $(hyp_numbers); do
      file=$(hyp_file "$nn")
      case "$(get_status "$file")" in
        draft) drafts+=("$nn") ;;
        running) actions+=("проверяющий: $nn $wt/$slug-$nn") ;;
        review) actions+=("критик: $nn") ;;
        waiting) actions+=("развилка: $nn") ;;
      esac
    done
    [ "${#drafts[@]}" -gt 0 ] && actions+=("проработать: ${drafts[*]}")
    budget_out=0
    for nn in $(hyp_numbers); do
      file=$(hyp_file "$nn")
      [ "$(get_status "$file")" = planned ] || continue
      [ "$(cat "$state/plans/$nn" 2>/dev/null)" = "$(plan_hash "$file")" ] || { actions+=("план изменён: $nn"); continue; }
      [ "$(count_status running)" -lt "$SLOTS" ] || break
      if [ "$budget_out" = 0 ] && over_budget; then budget_out=1; fi
      [ "$budget_out" = 0 ] || break
      if path=$(start_one "$nn"); then
        actions+=("проверяющий: $nn $path")
      else
        actions+=("$path")
      fi
    done
    [ "$budget_out" = 1 ] && actions+=("бюджет исчерпан: \$$(spent) из \$$(limit)")
    [ -n "$(open_ideas)" ] && actions+=("идеи")
    if [ -z "$(open_hypotheses)" ] && [ -z "$(open_ideas)" ]; then
      if ! author_empty; then
        actions+=("автор")
      elif [ -f "$dir/report.md" ] && is_accepted report "$(body_hash "$dir/report.md")"; then
        actions+=("записать")
      else
        actions+=("сравнение")
      fi
    fi
    [ "${#actions[@]}" -gt 0 ] || actions=("ждать")
    printf '%s\n' "${actions[@]}"
    ;;

  spec)
    set_root
    need_slug "${1:-}"
    gaps=$(spec_gaps)
    if [ -n "$gaps" ]; then
      echo "$gaps"
      exit 3
    fi
    echo "спека принята"
    ;;

  agree)
    set_root
    need_slug "${1:-}"
    [ -z "$(spec_gaps)" ] || die "спека не принята, сначала spec"
    decision_hash >"$state/agreed"
    echo "согласие записано"
    ;;

  accept)
    set_root
    need_slug "${1:-}"
    what=${2:?нужно spec, report или номер гипотезы}
    case "$what" in
      spec)
        gaps=$(spec_field_gaps)
        [ -z "$gaps" ] || { echo "$gaps"; exit 3; }
        body_hash "$dir/spec.md" >"$state/accepted/spec"
        echo "принята спека"
        ;;
      report)
        gaps=$(report_field_gaps)
        [ -z "$gaps" ] || { echo "$gaps"; exit 3; }
        body_hash "$dir/report.md" >"$state/accepted/report"
        echo "принят отчёт"
        ;;
      *)
        nn=$what
        file=$(hyp_file "$nn")
        [ "$(get_status "$file")" = review ] || die "гипотеза $nn не в статусе review, сначала verdict"
        reason=$(verdict_gap "$nn" "$file")
        if [ -n "$reason" ]; then
          echo "$reason"
          exit 3
        fi
        hyp_hash "$nn" "$file" >"$state/accepted/$nn"
        drop_worktree "$nn"
        set_status "$file" closed
        echo "закрыта: $nn $(field "$(section "$file" "Вердикт")" "Вердикт"): ${file#"$root"/}"
        ;;
    esac
    ;;

  next)
    set_root
    need_slug "${1:-}"
    last=$(hyp_numbers | tail -n 1)
    printf '%02d\n' $((10#${last:-00} + 1))
    ;;

  plan)
    set_root
    need_slug "${1:-}"
    need_agreed
    nn=${2:?нужен номер гипотезы}
    file=$(hyp_file "$nn")
    status=$(get_status "$file")
    case "$status" in
      draft|planned|running|review|waiting) ;;
      *) die "гипотеза $nn в статусе $status, план не закрепляется" ;;
    esac
    plan=$(section "$file" "План")
    for name in Запуск Подтвердит Опровергнет; do
      if [ -z "$(field "$plan" "$name")" ]; then
        echo "нет плана"
        exit 3
      fi
    done
    new=$(plan_hash "$file")
    # Новый план после начала опыта: прежний вывод уже виден, поэтому опыт идёт заново.
    case "$status" in
      running|review|waiting)
        if [ "$(cat "$state/plans/$nn" 2>/dev/null)" != "$new" ]; then
          drop_worktree "$nn"
          printf -- '--- план перезакреплён, опыт заново ---\n\n' | log_append "$nn"
          status=planned
          set_status "$file" planned
        fi
        ;;
    esac
    echo "$new" >"$state/plans/$nn"
    [ "$status" = draft ] && set_status "$file" planned
    echo "закреплён"
    ;;

  run)
    set_root
    need_slug "${1:-}"
    nn=${2:?нужен номер гипотезы}
    shift 2
    [ $# -gt 0 ] || die "нужна команда"
    file=$(hyp_file "$nn")
    path="$wt/$slug-$nn"
    case "$(get_status "$file")" in
      running|review) [ -d "$path" ] || die "у гипотезы $nn нет worktree, сначала tick" ;;
      *) die "у гипотезы $nn нет идущего опыта" ;;
    esac
    # Журнал, изменённый в обход скрипта, дальше не дополняется: verdict всё равно его не примет.
    if [ -f "$(log_file "$nn")" ] && [ "$(cat "$state/logs/$nn" 2>/dev/null)" != "$(log_hash "$nn")" ]; then
      die "журнал logs/$nn.log изменён в обход run"
    fi
    code=0
    logged "$nn" "$path" "$*" 2>&1 || code=$?
    exit "$code"
    ;;

  verdict)
    set_root
    need_slug "${1:-}"
    nn=${2:?нужен номер гипотезы}
    file=$(hyp_file "$nn")
    case "$(get_status "$file")" in
      running|review) ;;
      *) die "гипотеза $nn не в опыте" ;;
    esac
    reason=$(verdict_gap "$nn" "$file")
    if [ -n "$reason" ]; then
      echo "$reason"
      exit 3
    fi
    # Гипотеза на критике слот не занимает: tick считает только running.
    set_status "$file" review
    echo "на критика"
    ;;

  hold)
    set_root
    need_slug "${1:-}"
    nn=${2:?нужен номер гипотезы}
    file=$(hyp_file "$nn")
    case "$(get_status "$file")" in
      running|review) set_status "$file" waiting ;;
      waiting) ;;
      *) die "гипотеза $nn не в опыте" ;;
    esac
    echo "ждёт"
    ;;

  resume)
    set_root
    need_slug "${1:-}"
    nn=${2:?нужен номер гипотезы}
    file=$(hyp_file "$nn")
    [ "$(get_status "$file")" = waiting ] || die "гипотеза $nn не ждёт"
    if [ "$(count_status running)" -ge "$SLOTS" ]; then
      echo "нет слота"
      exit 3
    fi
    start_one "$nn"
    ;;

  reopen)
    set_root
    need_slug "${1:-}"
    nn=${2:?нужен номер гипотезы}
    file=$(hyp_file "$nn")
    [ "$(get_status "$file")" = closed ] || die "гипотеза $nn не закрыта"
    last=$(section "$file" Comments | grep -E '^Критик: (принято|замечание)|^Сравнивающий: оспорено' | tail -n 1 || true)
    case "$last" in
      "Сравнивающий: оспорено"*) ;;
      *) die "нет строки «Сравнивающий: оспорено» после последней строки критика" ;;
    esac
    rm -f "$state/accepted/$nn"
    printf -- '--- перепроверка ---\n\n' | log_append "$nn"
    set_status "$file" planned
    echo "planned"
    ;;

  reject)
    set_root
    need_slug "${1:-}"
    nn=${2:?нужен номер гипотезы}
    shift 2
    [ $# -gt 0 ] || die "нужна причина"
    file=$(hyp_file "$nn")
    [ "$(get_status "$file")" != closed ] || die "гипотеза $nn уже закрыта"
    drop_worktree "$nn"
    printf '%s\n' "Снята: $*" >>"$file"
    set_status "$file" rejected
    echo "снята: $nn"
    ;;

  empty)
    set_root
    need_slug "${1:-}"
    [ -z "$(open_ideas)" ] || die "в ideas.md есть открытые строки"
    hyp_numbers | wc -l | tr -d ' ' >"$state/empty"
    echo "записано"
    ;;

  status)
    set_root
    need_slug "${1:-}"
    for nn in $(hyp_numbers); do
      file=$(hyp_file "$nn")
      echo "$nn $(get_status "$file") $(field "$(section "$file" "Вердикт")" "Вердикт")"
    done
    if [ -z "$(hyp_numbers)" ]; then
      echo "гипотез нет"
    elif [ -z "$(open_hypotheses)" ] && [ -z "$(open_ideas)" ]; then
      echo "очередь пуста"
    else
      echo "в работе"
    fi
    ;;

  budget)
    set_root
    need_slug "${1:-}"
    if [ -n "${2:-}" ]; then
      [[ "${2#\$}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "сумма в долларах: число"
      echo "${2#\$}" >"$state/budget"
      echo "бюджет: \$${2#\$}"
    else
      echo "расход: \$$(spent) из \$$(limit)"
    fi
    ;;

  report)
    set_root
    need_slug "${1:-}"
    gaps=$(report_gaps)
    if [ -n "$gaps" ]; then
      echo "$gaps"
      exit 3
    fi
    echo "отчёт готов"
    ;;

  record)
    set_root
    need_slug "${1:-}"
    [ -z "$(report_gaps)" ] || die "отчёт не готов, сначала report"
    rel=${dir#"$root"/}
    for path in "$wt/$slug-"*; do
      [ -d "$path" ] && git -C "$root" worktree remove --force "$path"
    done
    # Журналы опытов могут попасть под игнор проекта (*.log), а отчёт на них ссылается.
    git -C "$root" add -f -- "$rel"
    if git -C "$root" diff --cached --quiet -- "$rel"; then
      echo "нечего записывать"
      exit 0
    fi
    git -C "$root" commit -q -m "docs: исследование $slug" -- "$rel"
    echo "записано: $(git -C "$root" rev-parse --short HEAD)"
    ;;

  tokens)
    set_root
    need_slug "${1:-}"
    token_line
    ;;

  *)
    usage
    exit 1
    ;;
esac
