# 16: Tools у WPF — Uninstall і Startup

**What to build:** у підменю Tools з'являються Uninstall і Startup. Сторінка інструмента = таблиця на всю ширину + колонка однакових кнопок праворуч + «Зберегти в текстовий файл». Uninstall: пошук, Run Uninstaller / Repair / Change / Rename / Delete entry. Startup: вкладки Windows / Scheduled Tasks / Context Menu / Windows Services, Enable / Disable / Delete.

**Blocked by:** 14

**Status:** ready-for-agent

- [ ] Поведінка й запобіжники ті самі, що у WinForms-версії (підтвердження, UAC лише в момент дії, системні служби не видаляються)
- [ ] guismoke-tools проходить на WPF exe (лише читання)
