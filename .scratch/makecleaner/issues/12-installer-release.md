# 12: Інсталятор і реліз

**What to build:** single-file exe + portable zip (з portable.dat) + per-user інсталятор Inno Setup, без бандлів і без автозапуску. About з версією, атрибуцією Winapp2 (CC BY-SA 4.0) і заявою «без телеметрії». Фінальна перевірка: жодних мережевих викликів під час повного прогону всіх функцій.

**Blocked by:** 03, 06, 07, 08, 09, 10, 11

**Status:** done, крім ручної перевірки install/uninstall (див. перший пункт)

- [ ] Інсталятор і деінсталятор не лишають сміття (ключі, задачі, папки) — `.iss` компілюється, але setup.exe не запускався: класифікатор авто-режиму блокує запуск інсталятора. Перевірка — вручну командами зі звіту тікета
- [x] Portable zip працює з флешки без запису поза своєю папкою — перевірено з тимчасової копії розпакованого zip (не з фізичної флешки): 0 нових записів у %AppData%, %LocalAppData%, %TEMP%\.net, HKCU\Software
- [x] Під час прогону всіх функцій від MakeCleaner немає жодного мережевого з'єднання — у межах смоуків (усі 10, включно з /auto) на опублікованому exe: 145 замірів, 0 TCP/UDP. Дії, які смоуки не натискають (Fix у Registry, Drive Wiper, Create/Remove задачі), під опитуванням не запускались

**Нотатки:**
- Версія — лише `<Version>` у csproj; `tools\release.ps1` читає її (`dotnet msbuild -getProperty:Version`) і передає в ISCC, About показує `Application.ProductVersion`.
- `tools\release.ps1` → `dist\publish` (single-file self-contained, стиснений бандл розпаковується в пам'ять; `e_sqlite3.dll` лежить поруч, щоб не самовитягуватись у %TEMP%), `dist\MakeCleaner-<v>-portable.zip`, `dist\MakeCleaner-Setup-<v>.exe`. ISCC шукається як у MakePack.
- Інсталятор: per-user (`PrivilegesRequired=lowest`), ярлик у меню Пуск, ярлик на робочому столі — опційно, без автозапуску. Деінсталятор видаляє задачу `MakeCleaner Auto Clean` (schtasks, тихо, якщо її нема) і питає, чи видаляти `%AppData%\MakeCleaner` (за замовчуванням «Ні»: перевстановлення не повинно губити keep-lists; тихий uninstall їх лишає).
- `tools\releasecheck.ps1` — смоуки на опублікованій portable-копії + опитування мережі + знімок слідів поза папкою. Усі смоуки отримали параметр `-BinDir`.
- Тест «без System.Net.*» тепер обходить MakeCleaner.dll і всі його app-local залежності (Microsoft.Data.Sqlite, SQLitePCLRaw), тобто весь керований набір, що постачається.
- `THIRD-PARTY-NOTICES.txt` (Winapp2 CC BY-SA, .NET MIT, Microsoft.Data.Sqlite MIT, SQLitePCLRaw Apache-2.0, SQLite public domain) лежить поруч з exe.
