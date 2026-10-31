#!/usr/bin/env bash
# Хук проекта: коммит проходит, только если все тесты зелёные.
if command -v python3 >/dev/null 2>&1; then py=python3; else py=python; fi
exec "$py" -m unittest discover -q
