#!/usr/bin/env bash
# Прогоняет research.sh на временном репозитории: шаги скрипта и цепочки tick, которые ведут диспетчера. Агенты не нужны.
set -uo pipefail

R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/researchFlow" && pwd)/research.sh
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rf.XXXX")" && pwd)
CFG=$(mktemp -d "${TMPDIR:-/tmp}/rf-cfg.XXXX")
export CLAUDE_CONFIG_DIR=$CFG
trap 'rm -rf "$T" "$CFG"' EXIT
pass=0 fail=0
ok() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: ждали «$3», получили «$2»"; fi
}
has() {
  if grep -qxF -- "$3" <<<"$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: нет строки «$3» в «$2»"; fi
}

cd "$T" && git init -q -b main . && git config user.name t && git config user.email t@t
echo 'echo 42' >app.sh && git add app.sh && git commit -qm init
D=.agentflow/docs/research/bug
H=$D/hypotheses
W=$T/.agentflow/.worktree/research

hyp() { # номер, текст «Подтвердит»
  cat >"$H/$1-echo.md" <<EOF
Status: draft
Пачка: 1

# $1. Echo печатает 42

Гипотеза: app.sh печатает 42.
Почему: строка в файле.

## Вопросы автору

## План

Запуск: \`bash app.sh\`
Подтвердит: ${2:-вывод 42}
Опровергнет: другой вывод
Нужно: bash

## Вердикт

## Comments
EOF
}
verdict() {
  perl -0pi -e 's/## Вердикт\n/## Вердикт\n\nВердикт: подтверждена\nВывод: logs\/'"$1"'.log\nИтог: 42.\n/' "$H/$1-echo.md"
}

# Шлюз
out=$("$R" gate); ok "gate пробелы" "$?/$(wc -l <<<"$out" | tr -d ' ')" "3/2"
"$R" gate --fix >/dev/null
ok "gate fix" "$("$R" gate)" "готово"

# Спека и приёмка
ok "init" "$("$R" init bug)" "$T/$D/spec.md"
ok "tick без спеки" "$("$R" tick bug)" "спека"
cat >"$D/spec.md" <<'EOF'
Вопрос: почему 42
Вход: текст
Границы: app.sh
База: main
Подготовка: `echo prep > prep.txt`
Бюджет: $5

## Критерии

- Доказательность — вес 3: есть вывод
- Простота — вес 1: строки

## Comments

Критик: принято
EOF
out=$("$R" spec bug); ok "строка критика не приёмка" "$?/$out" "3/нет приёмки критика"
ok "accept spec" "$("$R" accept bug spec)" "принята спека"
ok "spec" "$("$R" spec bug)" "спека принята"
ok "tick согласие" "$("$R" tick bug)" "согласие"
"$R" agree bug >/dev/null
perl -pi -e 's/^Границы: app.sh/Границы: app.sh и всё/' "$D/spec.md"
ok "правка снимает приёмку" "$("$R" tick bug)" "спека"
perl -pi -e 's/^Границы: app.sh и всё/Границы: app.sh/' "$D/spec.md"
ok "возврат правки" "$("$R" tick bug)" "автор"
perl -pi -e 's/^Вход: текст/Вход: текст и лог/' "$D/spec.md"
ok "техническая правка: только критик" "$("$R" tick bug)" "спека"
"$R" accept bug spec >/dev/null
ok "техническая правка без согласия" "$("$R" tick bug)" "автор"
perl -pi -e 's/^- Простота — вес 1/- Простота — вес 2/' "$D/spec.md"
"$R" accept bug spec >/dev/null
ok "правка критериев требует согласия" "$("$R" tick bug)" "согласие"
perl -pi -e 's/^- Простота — вес 2/- Простота — вес 1/' "$D/spec.md"
"$R" accept bug spec >/dev/null

# Гипотеза: план, опыт с подготовкой, журнал
ok "next" "$("$R" next bug)" "01"
hyp 01
ok "tick проработать" "$("$R" tick bug)" "проработать: 01"
ok "plan" "$("$R" plan bug 01)" "закреплён"
ok "tick старт" "$("$R" tick bug)" "проверяющий: 01 $W/bug-01"
ok "подготовка в worktree" "$(cat "$W/bug-01/prep.txt")" "prep"
ok "worktree без ветки" "$(git -C "$W/bug-01" symbolic-ref -q HEAD || echo detached)" "detached"
ok "повторный tick не заводит второй" "$("$R" tick bug)" "проверяющий: 01 $W/bug-01"
ok "run печатает то, что ушло в журнал" "$("$R" run bug 01 bash app.sh | sed -n 2p)" "42"
ok "журнал: подготовка первой" "$(head -1 "$D/logs/01.log")" "\$ echo prep > prep.txt"
echo "подделка" >>"$D/logs/01.log"
out=$("$R" verdict bug 01); ok "журнал в обход run" "$out" "журнал изменён в обход run → проверяющий"
"$R" run bug 01 true >/dev/null 2>&1; ok "run не пишет в подделанный журнал" "$?" "1"
perl -0pi -e 's/подделка\n\z//' "$D/logs/01.log"
ok "verdict без вердикта" "$("$R" verdict bug 01)" "нет вердикта → проверяющий"
verdict 01
ok "verdict" "$("$R" verdict bug 01)" "на критика"
ok "tick критик" "$("$R" tick bug)" "критик: 01"
ok "accept гипотезы" "$("$R" accept bug 01)" "закрыта: 01 подтверждена: $H/01-echo.md"
ok "worktree снят" "$([ -d "$W/bug-01" ] && echo есть || echo нет)" "нет"
perl -pi -e 's/^Итог: 42\./Итог: 43./' "$H/01-echo.md"
has "правка после приёмки" "$("$R" report bug)" "гипотеза 01 изменена после приёмки"
perl -pi -e 's/^Итог: 43\./Итог: 42./' "$H/01-echo.md"

# Длинный вывод: в журнал хвост, полный вывод в .scratch
hyp 02; "$R" plan bug 02 >/dev/null; "$R" tick bug >/dev/null
"$R" run bug 02 seq 1 400 >/dev/null 2>&1
has "хвост журнала" "$(cat "$D/logs/02.log")" "… пропущено строк: 250, полный вывод: .agentflow/.scratch/bug/out/02.log"
ok "полный вывод" "$(grep -cx '[0-9][0-9]*' .agentflow/.scratch/bug/out/02.log)" "400"
verdict 02; "$R" verdict bug 02 >/dev/null; "$R" accept bug 02 >/dev/null

# Идеи и слово «пусто» автора
ok "tick без пусто" "$("$R" tick bug)" "автор"
echo '- [ ] проверить кэш (от критик, гипотеза 01)' >>"$D/ideas.md"
has "tick идеи" "$("$R" tick bug)" "идеи"
"$R" empty bug >/dev/null 2>&1; ok "empty при открытой идее" "$?" "1"
perl -pi -e 's/^- \[ \] (.*)/- [-] $1 — нет кэша/' "$D/ideas.md"
"$R" empty bug >/dev/null
ok "tick сравнение" "$("$R" tick bug)" "сравнение"

# Спор сравнивающего
echo "Сравнивающий: оспорено: проверка" >>"$H/01-echo.md"
ok "reopen" "$("$R" reopen bug 01)" "planned"
ok "tick перепроверка" "$("$R" tick bug)" "проверяющий: 01 $W/bug-01"
"$R" run bug 01 bash app.sh >/dev/null 2>&1; "$R" verdict bug 01 >/dev/null
out=$("$R" accept bug 01); ok "accept после спора" "${out%%:*}" "закрыта"

# Слоты, пауза, перезакрепление
for n in 03 04 05 06; do hyp $n; "$R" plan bug $n >/dev/null; done
out=$("$R" tick bug)
ok "три слота" "$(grep -c '^проверяющий:' <<<"$out")" "3"
"$R" hold bug 03 >/dev/null
out=$("$R" tick bug)
has "пауза освобождает слот" "$out" "проверяющий: 06 $W/bug-06"
has "tick развилка" "$out" "развилка: 03"
ok "resume без слота" "$("$R" resume bug 03)" "нет слота"
perl -pi -e 's/Опровергнет: другой вывод/Опровергнет: пустой вывод/' "$H/04-echo.md"
ok "перезакрепление" "$("$R" plan bug 04)/$(head -1 "$H/04-echo.md")" "закреплён/Status: planned"
ok "worktree 04 снят" "$([ -d "$W/bug-04" ] && echo есть || echo нет)" "нет"
has "журнал отмечает перезапуск" "$(cat "$D/logs/04.log")" "--- план перезакреплён, опыт заново ---"
ok "resume в слот" "$("$R" resume bug 03)" "$W/bug-03"

# Бюджет
echo 0 >.agentflow/.scratch/bug/budget
for n in 03 05 06; do "$R" hold bug $n >/dev/null; done
has "бюджет исчерпан" "$("$R" tick bug)" "бюджет исчерпан: \$0 из \$0"
ok "опыт не заведён" "$(head -1 "$H/04-echo.md")" "Status: planned"
"$R" budget bug 7 >/dev/null
ok "budget продлён" "$("$R" budget bug)" "расход: \$0 из \$7"

# Подготовка красная
for n in 03 04 05 06; do "$R" reject bug $n бюджет >/dev/null; done
ok "reject снимает worktree" "$(ls "$W" | wc -l | tr -d ' ')" "0"
has "причина снятия" "$(cat "$H/05-echo.md")" "Снята: бюджет"
perl -pi -e 's/^Подготовка: .*/Подготовка: `false`/' "$D/spec.md"
"$R" accept bug spec >/dev/null
hyp 07; "$R" plan bug 07 >/dev/null
ok "подготовка красная" "$("$R" tick bug)" "подготовка красная: 07"
ok "worktree 07 снят" "$([ -d "$W/bug-07" ] && echo есть || echo нет)" "нет"
"$R" reject bug 07 подготовка >/dev/null

# Прерванная подготовка: worktree без метки заводится заново
perl -pi -e 's/^Подготовка: .*/Подготовка: `echo prep > prep.txt`/' "$D/spec.md"
"$R" accept bug spec >/dev/null
hyp 08; "$R" plan bug 08 >/dev/null
git -C "$T" worktree add -q --detach "$W/bug-08" HEAD
ok "подготовка после обрыва" "$("$R" tick bug)/$(cat "$W/bug-08/prep.txt" 2>/dev/null)" "проверяющий: 08 $W/bug-08/prep"
"$R" reject bug 08 демо >/dev/null

# Отчёт и коммит
"$R" empty bug >/dev/null
ok "report нет файла" "$("$R" report bug)" "нет report.md"
{
  echo 'Решение: 42.'
  echo
  echo '| Гипотеза | Доказательность | Простота |'
  echo '|---|---|---|'
  for f in "$H"/*.md; do echo "| [$(basename "$f")](hypotheses/$(basename "$f")) | 3 | 1 |"; done
  echo
  echo 'Выводы: [01](logs/01.log), [02](logs/02.log), [битая](hypotheses/99.md)'
  echo
  echo '## Comments'
} >"$D/report.md"
"$R" accept bug report >/dev/null; ok "accept report с битой ссылкой" "$?" "3"
perl -pi -e 's/, \[битая\]\(hypotheses\/99.md\)//' "$D/report.md"
ok "accept report" "$("$R" accept bug report)" "принят отчёт"
ok "tick записать" "$("$R" tick bug)" "записать"
ok "report" "$("$R" report bug)" "отчёт готов"
echo dirty >other.txt
echo '*.log' >>.gitignore
ok "record" "$("$R" record bug | cut -d: -f1)" "записано"
has "журналы в коммите" "$(git ls-files "$D/logs")" "$D/logs/01.log"
ok "коммит только каталог" "$(git show --name-only --format= HEAD | grep -vc "^$D/")" "0"
ok "чужой файл не тронут" "$(git status --porcelain other.txt)" "?? other.txt"

# Расход только с начала исследования
project=$(printf '%s' "$T" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$CFG/projects/$project/s1/subagents"
{
  echo '{"type":"user","timestamp":"2099-01-01T00:00:00Z","message":{"content":"Ты агент роли «проверяющий». '"$T/$H"'/01-echo.md"}}'
  echo '{"type":"assistant","timestamp":"2000-01-01T00:00:00Z","message":{"id":"old","model":"claude-haiku-5-5","usage":{"input_tokens":5000,"output_tokens":1}}}'
  echo '{"type":"assistant","timestamp":"2099-01-01T00:00:01Z","message":{"id":"new","model":"claude-haiku-5-5","usage":{"input_tokens":1000,"output_tokens":1}}}'
} >"$CFG/projects/$project/s1/subagents/agent-a.jsonl"
echo '{"agentType":"researchflow-checker"}' >"$CFG/projects/$project/s1/subagents/agent-a.meta.json"
has "старые записи не считаются" "$("$R" tokens bug | grep -o 'вход [0-9 ]*,' )" "вход 1 000,"

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
