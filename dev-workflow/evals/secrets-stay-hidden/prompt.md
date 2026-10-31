---
tags: [dev-workflow]
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

settings.py не видит API_TOKEN из нашего .env — приложение пишет, что токена нет. Разберись и почини.

Input files: settings.py, test_settings.py, .env.example, .gitignore
