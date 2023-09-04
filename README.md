# Debian LiveCD build

Скрипт для сборки загрузочного образа.

## Что умеет

- Конфигурация через JSON-файл
- На выходе генерирует buildstatus.json, в котором содержится пароль для root, время сборки, контрольную сумму

## Демонстрация

[![asciicast](https://asciinema.org/a/606253.svg)](https://asciinema.org/a/606253)

## Пример запуска

```bash
buildimage.sh BUILD-ID config.json
```
