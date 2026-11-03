#!/usr/bin/env bash
# Заводит игрушечный репозиторий с багом для пробного прогона /researchFlow: research-demo.sh <каталог>.
# Баг с двумя причинами, чтобы гипотез было несколько: потеря последней строки без перевода строки и целочисленное деление.
set -euo pipefail

target=${1:?нужен каталог для репозитория}
[ ! -e "$target" ] || { echo "research-demo.sh: $target уже есть" >&2; exit 1; }
mkdir -p "$target"
cd "$target"
git init -q -b main .

cat >avg.sh <<'EOF'
#!/usr/bin/env bash
# Печатает среднее чисел из файла, по одному на строку.
sum=0
n=0
while read -r x; do
  sum=$((sum + x))
  n=$((n + 1))
done <"$1"
echo $((sum / n))
EOF
printf '2\n3' >data.txt
cat >test.sh <<'EOF'
#!/usr/bin/env bash
# Среднее 2 и 3 должно быть 2.5.
got=$(bash avg.sh data.txt)
[ "$got" = "2.5" ] && echo ok || { echo "ждали 2.5, получили $got"; exit 1; }
EOF
cat >AGENTS.md <<'EOF'
# Правила

Проверка: `bash test.sh`.
EOF
git add -A
git -c user.name=demo -c user.email=demo@example.com commit -qm "init: среднее чисел"
echo "$PWD"
echo "Откройте этот каталог в новой сессии и запустите /researchFlow с входом: «test.sh красный: среднее 2 и 3 выходит 2, а не 2.5»."
