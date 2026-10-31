---
tags: [dev-workflow]
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

В money.py две почти одинаковые функции форматирования сумм. Вынеси общий код в одну вспомогательную функцию, поведение меняться не должно.

Input files: money.py, README.md
