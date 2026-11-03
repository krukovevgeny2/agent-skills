#!/usr/bin/env bash
# Заводит и снимает worktree фичи и задач agentflow и сливает ветку фичи в ветку, которую подтвердил пользователь.
# В worktree лежит только продуктовый код. Служебные файлы (.agentflow/.scratch) живут в основной копии.
# Диспетчер вызывает скрипт вместо ручных команд git. Скрипт можно запускать из любого worktree репозитория.
set -euo pipefail

usage() {
  cat <<'EOF'
Использование:
  worktree.sh feature <feature-slug> [ветка-старта]
                                              завести ветку feature/<slug> от ветки старта, запомнить ветку старта и завести worktree;
                                              без аргумента ветка старта это ветка, открытая при запуске; повторный вызов только печатает путь
  worktree.sh base <feature-slug>             напечатать ветку старта фичи: её диспетчер называет в вопросе о слиянии
  worktree.sh approve <feature-slug>          записать одобрение нарезки ревьювером: хеш каждого файла задачи без статуса и замечаний
  worktree.sh approved <feature-slug>         печатает «одобрена», либо «не одобрена» с кодом 3, если задача ready-for-agent не совпала с одобрением
  worktree.sh remarks <feature-slug>          проверить, что ревьювер записал новые замечания под «## Comments» спеки: печатает «записаны»,
                                              либо «нет записей» с кодом 3, если раздел пуст или не изменился с прошлого вызова
  worktree.sh task <feature-slug> <NN>        завести ветку task/<slug>-<NN> от ветки фичи и её worktree, поставить статус claimed;
                                              отказывает без одобрения нарезки; повторный вызов продолжает ту же задачу
  worktree.sh sync <feature-slug> <NN>        закоммитить работу задачи промежуточным коммитом и влить кончик ветки фичи. Печатает «готово».
                                              При конфликте оставляет маркеры в дереве, печатает «конфликт» и выходит с кодом 3;
                                              повторный вызов после снятия маркеров завершает слияние
  worktree.sh check <feature-slug> <NN>       запустить в worktree задачи команду из поля «Проверка»: только значение в обратных кавычках, вывод пишет в журнал.
                                              Печатает «зелёная»; при красной печатает «красная», пишет замечание в файл задачи и выходит с кодом 3;
                                              при слове «нет» печатает «пропущено» и выходит с кодом 0;
                                              если поля нет, оно пустое или без команды, печатает «нет команды» и выходит с кодом 4
  worktree.sh supply <feature-slug> <NN> "<текст коммита>"
                                              шаг поставщика: коммит кода в ветке задачи, слияние в ветку фичи, статус resolved в основной копии,
                                              снятие worktree и ветки задачи. При конфликте печатает «конфликт» и выходит с кодом 3, статус не меняется.
                                              Без строки «Ревью кода: готово» под «## Comments» задачи или после красной проверки за ней
                                              печатает «нет ревью», выходит с кодом 3 и ничего не меняет.
                                              У задачи с «Показ: да» затем печатает строку «показ: <путь>»
  worktree.sh return <feature-slug> <NN> [ветка]
                                              снять оставшийся worktree задачи и удалить её ветку, если она слита в ветку фичи, а без неё в названную ветку или ветку старта
  worktree.sh record "<текст коммита>" [путь...]
                                              закоммитить в текущей ветке основной копии только названные файлы, по умолчанию журнал .agentflow/docs/adr
  worktree.sh merge <feature-slug> <ветка> [--journal [запись...]]
                                              слить ветку фичи в ветку, которую подтвердил пользователь; значения по умолчанию нет;
                                              если ветка открыта, там, иначе через временный worktree;
                                              если ветка не текущая в основной копии и там есть записи журнала со времени ответвления фичи,
                                              печатает «журнал» и список, выходит с кодом 3 и ничего не сливает;
                                              повторный вызов с --journal называет записи этой фичи для переноса, пустой список значит ни одной;
                                              затем снять worktree фичи, удалить её ветку, закоммитить журнал и посчитать токены
  worktree.sh tokens <feature-slug>           посчитать токены агентов фичи по транскриптам Claude Code, записать .agentflow/.scratch/<slug>/tokens.md
                                              и напечатать итог одной строкой; без транскриптов печатает «нет данных», отчёт не трогает
Если при запуске ветка не открыта (detached HEAD), ветка старта это главная: origin/HEAD, иначе main, иначе master.
EOF
}

die() {
  echo "worktree.sh: $*" >&2
  exit 1
}

has_branch() {
  git -C "$root" show-ref --verify --quiet "refs/heads/$1"
}

main_branch() {
  local name
  name=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  name=${name#origin/}
  for name in "$name" main master; do
    if [ -n "$name" ] && has_branch "$name"; then
      echo "$name"
      return
    fi
  done
  die "нет главной ветки, передай её имя аргументом"
}

# Ветка, открытая там, откуда запущен поток. Из worktree фичи и задач смотрим основную копию.
start_branch() {
  local top name
  top=$(git rev-parse --show-toplevel)
  case "$top" in
    */.agentflow/.worktree/*) top=$root ;;
  esac
  name=$(git -C "$top" symbolic-ref --quiet --short HEAD || true)
  if [ -n "$name" ]; then
    echo "$name"
  else
    main_branch
  fi
}

# Ветка старта записана при заведении фичи. У фичи, начатой без записи, это главная.
base_branch() {
  if [ -f "$scratch/$1/base" ]; then
    cat "$scratch/$1/base"
  else
    main_branch
  fi
}

issue_file() {
  local files=("$scratch/$1/issues/$2-"*.md)
  [ -e "${files[0]}" ] || die "нет файла задачи $2 в $scratch/$1/issues/"
  echo "${files[0]}"
}

issue_status() {
  perl -ne 'if (/^\*{0,2}Status:\*{0,2}\s*(\S+)/) { print $1; exit }' "$1"
}

set_status() {
  perl -0pi -e 's/^\*{0,2}Status:\*{0,2}.*$/Status: '"$2"'/m' "$1"
}

# Хеш задачи не зависит от статуса, суффикса и замечаний: они меняются по ходу работы.
issue_key() {
  local name
  name=$(basename "$1" .md)
  echo "${name%_need_approve}"
}

issue_hash() {
  perl -0777 -pe 's/^## Comments.*\z//ms; s/^\*{0,2}Status:.*\n//m; s/\s+\z/\n/' "$1" | git -C "$root" hash-object --stdin
}

issue_approved() {
  local list="$scratch/$1/approved"
  [ -f "$list" ] && grep -qxF "$(issue_hash "$2") $(issue_key "$2")" "$list"
}

remove_task() {
  local branch="task/$1-$2" dir="$wt/task/$1-$2"
  # git branch -d сверяет с HEAD основной копии, поэтому вхождение проверяем сами.
  git -C "$root" merge-base --is-ancestor "$branch" "$3" || die "ветка $branch не слита в $3"
  if [ -d "$dir" ]; then git -C "$root" worktree remove "$dir"; fi
  git -C "$root" branch -q -D "$branch"
}

# Коммитит только названные пути: чужие файлы и индекс основной копии не затрагиваются.
record_files() {
  local msg=$1
  shift
  if [ -z "$(git -C "$root" status --porcelain -- "$@")" ]; then
    echo "нечего записывать"
    return
  fi
  git -C "$root" add -- "$@"
  git -C "$root" commit -q -m "$msg" -- "$@"
  echo "записано"
}

# Записи журнала в основной копии со времени ответвления фичи. Чьи они, скрипт не знает: это может быть и другая фича.
journal_candidates() {
  {
    git -C "$root" -c core.quotePath=false diff --name-only --diff-filter=d "$1" -- .agentflow/docs/adr
    git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard -- .agentflow/docs/adr
  } | sort -u
}

# Копирует названные записи журнала в ветку слияния. Файл с тем же именем и другим содержимым не перезаписывается.
carry_journal() {
  local dest=$1 msg=$2 file added=()
  shift 2
  for file in "$@"; do
    if [ ! -e "$dest/$file" ]; then
      mkdir -p "$(dirname "$dest/$file")"
      cp "$root/$file" "$dest/$file"
      added+=("$file")
    elif ! cmp -s "$root/$file" "$dest/$file"; then
      echo "worktree.sh: запись журнала не перенесена, в ветке слияния другой файл с тем же именем: $file" >&2
    fi
  done
  [ "${#added[@]}" -gt 0 ] || return 0
  git -C "$dest" add -- "${added[@]}"
  git -C "$dest" commit -q -m "$msg" -- "${added[@]}"
}

# Служебные файлы .agentflow и строка .agentflow/.worktree/ в .gitignore, дописанная шлюзом, чужой правкой не считаются.
foreign_changes() {
  local dirty added
  dirty=$(git -C "$1" status --porcelain | grep -vE '^.. "?\.agentflow/' || true)
  case "$dirty" in
    " M .gitignore")
      added=$(git -C "$1" diff -U0 -- .gitignore | grep -E '^[-+][^-+]' || true)
      [ "$added" = "+.agentflow/.worktree/" ] && dirty=""
      ;;
    "?? .gitignore")
      [ "$(cat "$1/.gitignore")" = ".agentflow/.worktree/" ] && dirty=""
      ;;
  esac
  printf '%s' "$dirty"
}

token_report() {
  perl "$(dirname "${BASH_SOURCE[0]}")/tokens.pl" "$root" "$1" "$scratch/$1/tokens.md"
}

# Основная копия это родитель общего каталога .git, откуда бы ни вызвали скрипт.
root=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
wt="$root/.agentflow/.worktree"
scratch="$root/.agentflow/.scratch"
cmd=${1:-}

case "$cmd" in
  feature)
    slug=${2:?нужен feature-slug}
    dir="$wt/feature/$slug"
    if [ -e "$dir" ]; then
      echo "$dir"
      exit 0
    fi
    if ! has_branch "feature/$slug"; then
      base=${3:-$(start_branch)}
      has_branch "$base" || die "нет ветки $base"
      git -C "$root" branch "feature/$slug" "$base"
      mkdir -p "$scratch/$slug"
      echo "$base" >"$scratch/$slug/base"
    fi
    mkdir -p "$(dirname "$dir")"
    git -C "$root" worktree add "$dir" "feature/$slug"
    ;;

  base)
    slug=${2:?нужен feature-slug}
    base_branch "$slug"
    ;;

  approve)
    slug=${2:?нужен feature-slug}
    files=("$scratch/$slug/issues/"*.md)
    [ -e "${files[0]}" ] || die "нет файлов задач в $scratch/$slug/issues/"
    for file in "${files[@]}"; do
      case "$file" in
        *_need_approve.md) die "открыта развилка, нарезку нельзя одобрить: $file" ;;
      esac
      echo "$(issue_hash "$file") $(issue_key "$file")"
    done >"$scratch/$slug/approved"
    echo "одобрена"
    ;;

  approved)
    slug=${2:?нужен feature-slug}
    for file in "$scratch/$slug/issues/"*.md; do
      [ "$(issue_status "$file")" = "ready-for-agent" ] || continue
      if ! issue_approved "$slug" "$file"; then
        echo "не одобрена"
        exit 3
      fi
    done
    echo "одобрена"
    ;;

  remarks)
    slug=${2:?нужен feature-slug}
    spec="$scratch/$slug/spec.md"
    [ -f "$spec" ] || die "нет спеки: $spec"
    # Сравнивается весь раздел: новые замечания это его изменение, а не простое наличие.
    text=$(perl -0777 -ne 'print $1 if /^## Comments[^\n]*\n(.*)\z/ms' "$spec")
    sum=$(printf '%s' "$text" | git -C "$root" hash-object --stdin)
    if [ -z "${text//[[:space:]]/}" ] || [ "$sum" = "$(cat "$scratch/$slug/remarks" 2>/dev/null || true)" ]; then
      echo "нет записей"
      exit 3
    fi
    echo "$sum" >"$scratch/$slug/remarks"
    echo "записаны"
    ;;

  task)
    slug=${2:?нужен feature-slug}
    nn=${3:?нужен номер задачи NN}
    branch="task/$slug-$nn"
    dir="$wt/task/$slug-$nn"
    has_branch "feature/$slug" || die "нет ветки feature/$slug, сначала: worktree.sh feature $slug"

    issue=$(issue_file "$slug" "$nn")
    case "$issue" in
      *_need_approve.md) die "задача ждёт решения человека: $issue" ;;
    esac
    status=$(issue_status "$issue")
    case "$status" in
      ready-for-agent)
        issue_approved "$slug" "$issue" || die "нарезка не одобрена или файл изменился после одобрения: $issue"
        ;;
      claimed) ;;
      *) die "статус «$status» не даёт начать задачу: $issue" ;;
    esac

    if [ ! -e "$dir" ]; then
      has_branch "$branch" || git -C "$root" branch "$branch" "feature/$slug"
      mkdir -p "$(dirname "$dir")"
      git -C "$root" worktree add "$dir" "$branch"
    fi
    set_status "$issue" claimed
    echo "$dir"
    echo "файл задачи и спека: $scratch/$slug/ (в worktree не копируются)"
    ;;

  sync)
    slug=${2:?нужен feature-slug}
    nn=${3:?нужен номер задачи NN}
    dir="$wt/task/$slug-$nn"
    [ -d "$dir" ] || die "нет worktree задачи: $dir"
    has_branch "feature/$slug" || die "нет ветки feature/$slug"

    # Незавершённое слияние: кодер снял конфликт, маркеры проверяем сами, а не верим слову.
    # Смотрим все файлы слияния: после git add файл с маркерами уже не числится неслитым.
    if git -C "$dir" rev-parse -q --verify MERGE_HEAD >/dev/null; then
      markers=$(git -C "$dir" diff --name-only -z HEAD | (cd "$dir" && xargs -0 grep -lE '^(<<<<<<<|>>>>>>>) ' 2>/dev/null) || true)
      if [ -n "$markers" ]; then
        echo "конфликт"
        exit 3
      fi
      git -C "$dir" add -A
      git -C "$dir" commit -q --no-edit
    else
      git -C "$dir" add -A
      if ! git -C "$dir" diff --cached --quiet; then
        git -C "$dir" commit -q -m "wip: task/$slug-$nn"
      fi
      if ! git -C "$dir" merge -q --no-edit "feature/$slug"; then
        echo "конфликт"
        exit 3
      fi
    fi
    echo "готово"
    ;;

  check)
    slug=${2:?нужен feature-slug}
    nn=${3:?нужен номер задачи NN}
    dir="$wt/task/$slug-$nn"
    [ -d "$dir" ] || die "нет worktree задачи: $dir"
    issue=$(issue_file "$slug" "$nn")

    value=$(perl -ne 'if (/^\*{0,2}Проверка:\*{0,2}\s*(.*?)\s*$/) { print $1; exit }' "$issue")
    # Командой считается только значение в обратных кавычках: любой другой текст не запускается.
    command_pattern='^`(.+)`[.]?$'
    if [[ "$value" =~ $command_pattern ]]; then
      check=${BASH_REMATCH[1]}
    else
      word=$(printf '%s' "$value" | perl -CSD -pe '$_ = lc; s/\P{L}//g')
      if [ "$word" = "нет" ]; then
        echo "пропущено"
        exit 0
      fi
      echo "нет команды"
      exit 4
    fi

    # Вывод проверки остаётся в журнале: в контекст диспетчера идёт одно слово.
    log="$scratch/$slug/check-$nn.log"
    if (cd "$dir" && bash -c "$check") >"$log" 2>&1; then
      echo "зелёная"
    else
      grep -q '^## Comments' "$issue" || printf '\n## Comments\n' >>"$issue"
      printf '\n- Проверка `%s` красная, вывод: %s\n' "$check" "$log" >>"$issue"
      echo "красная"
      exit 3
    fi
    ;;

  supply)
    slug=${2:?нужен feature-slug}
    nn=${3:?нужен номер задачи NN}
    msg=${4:?нужен текст коммита}
    dir="$wt/task/$slug-$nn"
    fdir="$wt/feature/$slug"
    [ -d "$dir" ] || die "нет worktree задачи: $dir"
    [ -d "$fdir" ] || die "нет worktree фичи: $fdir"
    issue=$(issue_file "$slug" "$nn")

    # Запись ревью должна быть последней: красная проверка после неё значит, что код менялся без ревьювера.
    last=$(sed -n '/^## Comments/,$p' "$issue" | grep -E '^Ревью кода: готово$|^- Проверка .* красная, вывод:' | tail -n 1 || true)
    if [ "$last" != "Ревью кода: готово" ]; then
      echo "нет ревью"
      exit 3
    fi

    git -C "$dir" add -A
    if ! git -C "$dir" diff --cached --quiet; then
      git -C "$dir" commit -q -m "$msg"
    fi
    # Работу обычно уже закоммитил sync как wip, поэтому текст задачи идёт в заголовок слияния.
    if ! git -C "$fdir" merge --no-ff -m "$msg" -m "merge: task/$slug-$nn в feature/$slug" "task/$slug-$nn"; then
      git -C "$fdir" merge --abort || true
      echo "конфликт"
      exit 3
    fi
    # Статус пишется только после слияния и только в основной копии: в коммит ветки задачи служебные файлы не попадают.
    set_status "$issue" resolved
    remove_task "$slug" "$nn" "feature/$slug"
    echo "готово"
    show=$(perl -ne 'if (/^\*{0,2}Показ:\*{0,2}\s*(\S+)/) { print $1; exit }' "$issue")
    if [ "$show" = "да" ]; then echo "показ: $fdir"; fi
    ;;

  return)
    slug=${2:?нужен feature-slug}
    nn=${3:?нужен номер задачи NN}
    has_branch "task/$slug-$nn" || die "нет ветки task/$slug-$nn"
    # После слияния фичи её ветки уже нет: тогда ветка задачи должна входить в ветку, куда слита фича.
    base="feature/$slug"
    has_branch "$base" || base=${4:-$(base_branch "$slug")}
    remove_task "$slug" "$nn" "$base"
    ;;

  record)
    msg=${2:?нужен текст коммита}
    shift 2
    [ "$#" -gt 0 ] || set -- .agentflow/docs/adr
    record_files "$msg" "$@"
    ;;

  merge)
    slug=${2:?нужен feature-slug}
    # Значения по умолчанию нет намеренно: ветку называет пользователь в ответе на вопрос о слиянии.
    target=${3:?нужна ветка, которую подтвердил пользователь}
    shift 3
    decided=0
    journal=()
    if [ "${1:-}" = "--journal" ]; then
      decided=1
      shift
      journal=("$@")
    elif [ "$#" -gt 0 ]; then
      die "лишние аргументы: $*"
    fi
    has_branch "feature/$slug" || die "нет ветки feature/$slug"
    has_branch "$target" || die "нет ветки $target"
    fdir="$wt/feature/$slug"
    dir="$wt/feature-merge"
    [ -e "$dir" ] && die "временный worktree уже есть: $dir"

    for task in "$wt/task/$slug-"[0-9]*; do
      [ -e "$task" ] && die "задача ещё не закрыта, слияние не начато: $task"
    done

    if [ -d "$fdir" ] && [ -n "$(git -C "$fdir" status --porcelain)" ]; then
      die "в worktree фичи незакоммиченные файлы, слияние не начато: $fdir"
    fi

    # Журнал пишется в основной копии. Если фича идёт в другую ветку, какие записи её, решает диспетчер: до решения слияние не начинается.
    current=$(git -C "$root" symbolic-ref --quiet --short HEAD || true)
    if [ "$current" = "$target" ]; then
      journal=()
    else
      candidates=$(journal_candidates "$(git -C "$root" merge-base HEAD "feature/$slug")")
      if [ -n "$candidates" ] && [ "$decided" = 0 ]; then
        echo "журнал"
        echo "$candidates"
        exit 3
      fi
      if [ "${#journal[@]}" -gt 0 ]; then
        for file in "${journal[@]}"; do
          grep -qxF -- "$file" <<<"$candidates" || die "не запись журнала со времени ответвления фичи: $file"
        done
      fi
    fi

    # Если ветка уже открыта в каком-то worktree, сливаем там, не переключая ветки. Иначе берём временный worktree.
    open=$(git -C "$root" worktree list --porcelain | awk -v ref="branch refs/heads/$target" '/^worktree /{p=substr($0,10)} $0==ref{print p}')
    temp=0
    if [ -n "$open" ]; then
      dir="$open"
      foreign=$(foreign_changes "$dir")
      if [ -n "$foreign" ]; then
        echo "worktree.sh: в $dir чужие незакоммиченные файлы, слияние не начато:" >&2
        echo "$foreign" >&2
        exit 1
      fi
    else
      git -C "$root" worktree add "$dir" "$target"
      temp=1
    fi

    if ! git -C "$dir" merge --no-ff -m "merge: feature/$slug в $target" "feature/$slug"; then
      git -C "$dir" merge --abort || true
      if [ "$temp" = 1 ]; then git -C "$root" worktree remove --force "$dir"; fi
      die "конфликт при слиянии feature/$slug в $target, слияние отменено"
    fi
    if [ "${#journal[@]}" -gt 0 ]; then
      carry_journal "$dir" "docs: журнал решений фичи $slug" "${journal[@]}" || echo "worktree.sh: журнал не перенесён в $target, записи остались в основной копии" >&2
    fi
    if [ "$temp" = 1 ]; then git -C "$root" worktree remove --force "$dir"; fi
    # Ветка фичи слита: снимаем её worktree и удаляем ветку. Основная копия может стоять на другой ветке, поэтому -D после проверки.
    if [ -d "$fdir" ]; then git -C "$root" worktree remove "$fdir"; fi
    git -C "$root" merge-base --is-ancestor "feature/$slug" "$target" || die "ветка feature/$slug не вошла в $target"
    git -C "$root" branch -D "feature/$slug"
    # Слияние уже прошло, поэтому сбой записи журнала только сообщается.
    record_files "docs: журнал решений фичи $slug" .agentflow/docs/adr || echo "worktree.sh: журнал не закоммичен, запусти record" >&2
    token_report "$slug" || echo "worktree.sh: токены не посчитаны, запусти tokens" >&2
    ;;

  tokens)
    slug=${2:?нужен feature-slug}
    [ -d "$scratch/$slug" ] || die "нет каталога фичи: $scratch/$slug"
    token_report "$slug"
    ;;

  *)
    usage
    exit 1
    ;;
esac
