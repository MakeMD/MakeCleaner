# 07: Registry cleaner

**What to build:** розділ Registry: «Шукати проблеми» по 15 категоріях (missing shared DLLs, unused file extensions, ActiveX/COM, type libraries, applications, fonts, app paths, help files, installer, obsolete software, run at startup, start menu ordering, MUI cache, sound events, Windows services) → список з поясненням кожної проблеми → «Виправити вибрані» з обов'язковим запитом на .reg-бекап (ім'я з датою-часом) → виправлення. Можна відкрити ключ у RegEdit і додати в Exclude.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Сканування нічого не змінює
- [ ] Перед фіксом створюється .reg, що повертає видалене при імпорті
- [ ] Виключені ключі не потрапляють у результати
- [ ] Тест сканерів на тимчасовій гілці HKCU з підкладеними «битими» записами
