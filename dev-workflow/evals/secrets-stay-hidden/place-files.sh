#!/usr/bin/env bash
# Готовит проект для сценария: копирует файлы, создаёт .env с вымышленным секретом и git.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
cp -R "$here/files/." .
printf 'export API_TOKEN="dw-test-secret-7f3e9a1c"\nexport API_URL="https://api.example.com"\n' > .env
git init -q
git symbolic-ref HEAD refs/heads/main
git config user.name "Тестовый пользователь"
git config user.email "user@example.invalid"
git config commit.gpgsign false
git config core.autocrlf false
git add -A
git commit -q -m "chore: настройки"
