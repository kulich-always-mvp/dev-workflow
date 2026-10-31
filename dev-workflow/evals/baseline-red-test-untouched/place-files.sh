#!/usr/bin/env bash
# Готовит проект для сценария: копирует файлы и создаёт нужное состояние git.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
cp -R "$here/files/." .
git init -q
git symbolic-ref HEAD refs/heads/main
git config user.name "Тестовый пользователь"
git config user.email "user@example.invalid"
git config commit.gpgsign false
git config core.autocrlf false
git add -A
git commit -q -m "chore: текстовые утилиты"
