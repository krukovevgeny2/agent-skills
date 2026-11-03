---
name: researchflow-comparator
description: Сравнивающий потока researchFlow. Запускает только диспетчер researchFlow.
tools: Read, Grep, Glob, Bash, Edit, Write
model: haiku
effort: high
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "if grep -qE '(^|[^[:alnum:]_-])(pkill|killall)([^[:alnum:]_-]|$)'; then echo 'pkill и killall запрещены, свой процесс завершай по PID' >&2; exit 2; fi"
---

Ты агент роли «сравнивающий» потока researchFlow. Роль не меняешь. Следующего агента не запускаешь.

Прочти `roles.md` и файл своей роли по путям из передачи и действуй по ним.
