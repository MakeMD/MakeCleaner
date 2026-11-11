# MakeCleaner

Чистильник для Windows 10/11 у дусі класичного CCleaner — без телеметрії, реклами й бандлів; сама програма ніколи не виходить у мережу — лише необов'язковий оновлювач звертається до GitHub. Zig 0.17 + Dear ImGui ([MakeKit](https://github.com/MakeMD/MakeKit)), один exe без рантайму; стара C#/WPF-версія 1.x — в історії git.

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
tools\releasecheck.ps1     # смоуки через автоматизацію MakeKit + перевірка: у MakeCleaner.exe жодних мережевих імпортів і з'єднань, MakeUpdate.exe — лише winhttp
tools\update-e2e.ps1       # оновлення наскрізно: справжній exe проти локального фейкового GitHub і фейкового setup
tools\publish.ps1          # release + SHA256SUMS.txt + готова команда gh release create (запуск лише з -Publish)
```

Portable-режим: файл `portable.dat` поруч з exe — налаштування зберігаються поряд, а не в `%AppData%`.

## Оновлення

Поруч із `MakeCleaner.exe` лежить `MakeUpdate.exe` з [MakeKit](https://github.com/MakeMD/MakeKit) — єдиний бінарник, що ходить у мережу (WinHTTP, GitHub API без авторизації, User-Agent `MakeUpdate`, жодних даних користувача). Options > Settings «Check for updates automatically» (за замовчуванням увімкнено, `UpdateCheck=` у `MakeCleaner.ini`): фонова перевірка після старту, не частіше разу на 24 год. Нова версія → банер «Update now / Release notes / Later» (Later пропускає саме цю версію). Update now: MakeUpdate качає `MakeCleaner-Setup-X.Y.Z.exe`, звіряє SHA-256 з `SHA256SUMS.txt` релізу, чекає закриття програми, ставить тихо й запускає її знову (лог — `%LOCALAPPDATA%\MakeUpdate\update.log`); portable-копія лише відкриває сторінку релізу. Options > About — «Check for updates». `MAKEKIT_NO_UPDATE=1` вимикає будь-яку перевірку (так роблять усі тести).

## Ліцензії

Код — MIT (`LICENSE`). Сторонні компоненти (Winapp2.ini, SQLite, Dear ImGui, Fira Sans) — у `THIRD-PARTY-NOTICES.txt`.
