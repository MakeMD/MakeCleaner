# MakeCleaner — план

Clean-room аналог CCleaner без телеметрії, реклами, бандлів, онлайн-ліцензування і фонових агентів.
Основа — RE-нотатки `re/notes/01-features.md` (що вміє CCleaner 6.41) і `re/notes/02-junk.md` (чого в нас бути не повинно).

## Принципи

1. **Clean-room.** Ліцензія CCleaner забороняє RE і похідні роботи. Беремо лише *що* робить програма (функції, формат правил winapp2 — він публічний і стандарт де-факто). Жодного коду, рядків UI, графіки чи вбудованих INI-баз CCleaner. Правила — з community **Winapp2.ini** (CC BY-SA 4.0, з атрибуцією) + власні, написані з документації Windows.
2. **Нуль мережі.** Збірка не посилається на `System.Net.*` — перевіряється тестом/CI. Ні оновлювача, ні аналітики, ні «Help improve».
3. **Нуль фону.** Ні служб, ні моніторингу, ні Run-ключів. Розклад — лише явно створене користувачем завдання в Task Scheduler, що викликає `MakeCleaner.exe /auto`.
4. **Безпечно за замовчуванням.** Спершу Analyze (dry-run з розмірами), потім Clean. Реєстр — тільки з `.reg`-бекапом. Ризиковані пункти — з попередженням.
5. **Portable-first.** `portable.dat` поруч з exe → налаштування в `MakeCleaner.ini` поруч; інакше `%AppData%\MakeCleaner`.

## Стек

C# .NET 10 WinForms, single-file exe, як MakePack. Залежності: `Microsoft.Data.Sqlite` (cookie keep-list у Chromium/Firefox). Тести — один xUnit-проєкт. Інсталятор — Inno Setup per-user (досвід MakePack).

## Скоуп

| Беремо | Відкладаємо (додати, коли попросиш) | Ніколи |
|---|---|---|
| Custom Clean: Windows (система, Explorer, Edge) + Applications (winapp2) | Browser Plugins (розширення) | Телеметрія, IPM-реклама, апселли/наги |
| Рушій winapp2.ini: Detect/DetectFile/DetectOS/FileKey/RegKey/ExcludeKey | Software Updater через `winget upgrade` | Health Check-«лякалка» з лічильниками |
| Built-ins: Recycle Bin, Temp, Clipboard, DNS cache, thumbnails, event logs | Clean all user profiles | Driver Updater, Performance Optimizer |
| Браузери: Chromium-родина + Firefox; cookie keep-list | Мультимовність (поки укр + англ ресурси) | Smart Cleaning / Active Monitoring |
| Registry cleaner (15 категорій) + `.reg`-бекап + exclude | | Онлайн-ліцензія, trial, автооновлення |
| Tools: Uninstall, Startup, System Restore, Duplicate Finder, Disk Analyzer, Drive Wiper | | Cloud Drive Cleaner |
| Secure delete 1/3/7/35 проходів, Wipe Free Space | | |
| CLI `/auto` + розклад через Task Scheduler | | |

## Архітектура (мінімум)

- `Rules/` — парсер INI-правил (регістронезалежно, нумеровані ключі), розгортання env-змінних, `Detect*`.
- `Engine/` — Analyze → список цілей (файли/ключі/значення + розмір) → Clean. ExcludeKey і Include/Exclude з налаштувань — фільтр на одному шляху. Built-in процедури (`SpecialKey`) — словник `ім'я → делегат`.
- `Registry/` — сканери категорій, `.reg`-експорт перед фіксом.
- `Tools/` — кожен інструмент окремий екран, без спільних абстракцій.
- `UI/` — WinForms: ліве меню (Clean / Registry / Tools / Options), дерево чекбоксів, звіт.

## Етапи

- **M0** Каркас: solution, portable-налаштування, CI-перевірка «без мережі».
- **M1** Рушій winapp2 + перший tracer bullet: одне правило → Analyze → Clean у GUI.
- **M2** Windows-вкладка (власний `winsys`-набір + built-ins), Applications-вкладка з Winapp2.ini.
- **M3** Браузери + cookie keep-list.
- **M4** Registry cleaner.
- **M5** Tools.
- **M6** Secure delete, CLI/розклад, інсталятор, реліз.

## Ризики

- Видалення не того → dry-run, ExcludeKey, захист системних шляхів (корінь диска, `%windir%` без маски), тести на фікстурах у temp.
- Wipe Free Space на SSD шкодить ресурсу → попередження як у оригіналі.
- Winapp2 CC BY-SA → файл правил лежить окремо, з атрибуцією; код MakeCleaner ліцензуємо як хочеш.
