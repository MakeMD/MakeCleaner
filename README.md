# MakeCleaner

Чистильник для Windows 10/11 у дусі класичного CCleaner — без телеметрії, реклами, бандлів і мережі. Zig 0.17 + Dear ImGui ([MakeKit](https://github.com/MakeMD/MakeKit)), один exe без рантайму; стара C#/WPF-версія лежить у `legacy/`.

- **Cleaner:** правила Windows (`rules\Windows.ini`), браузери (Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Arc, Firefox; список cookies, які лишаються) і програми за [Winapp2.ini](https://github.com/MoscaDotTo/Winapp2) (CC BY-SA 4.0). Безпечне видалення 1/3/7/35 проходів, очищення вільного місця.
- **Registry:** 15 категорій перевірок, перед виправленням — `.reg`-бекап.
- **Tools:** програми (видалення), автозапуск, дублікати, аналіз диска, затирання диска, точки відновлення.
- **Options:** включення/виключення, cookies, розклад (`MakeCleaner.exe /auto [/shutdown]` через Планувальник завдань).

## Збірка

Потрібні Zig 0.17.1 у `%LOCALAPPDATA%\Programs\zig\0.17.1\` і сусідня тека `..\MakeKit` (`git clone https://github.com/MakeMD/MakeKit`).

```powershell
zig build                  # zig-out\bin\MakeCleaner.exe + rules\
zig build test             # юніт-тести
tools\release.ps1          # ReleaseSafe exe, portable zip, інсталятор (Inno Setup 6)
tools\releasecheck.ps1     # смоуки через автоматизацію MakeKit + перевірка: жодних мережевих імпортів і з'єднань
```

Portable-режим: файл `portable.dat` поруч з exe — налаштування зберігаються поряд, а не в `%AppData%`.

## Ліцензії

Код — MIT (`LICENSE`). Сторонні компоненти (Winapp2.ini, SQLite, Dear ImGui, Fira Sans) — у `THIRD-PARTY-NOTICES.txt`.
