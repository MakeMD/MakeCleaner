# 16: Tools у WPF — Uninstall і Startup

**What to build:** у підменю Tools з'являються Uninstall і Startup. Сторінка інструмента = таблиця на всю ширину + колонка однакових кнопок праворуч + «Зберегти в текстовий файл». Uninstall: пошук, Run Uninstaller / Repair / Change / Rename / Delete entry. Startup: вкладки Windows / Scheduled Tasks / Context Menu / Windows Services, Enable / Disable / Delete.

**Blocked by:** 14

**Status:** done (без Rename — див. нотатки)

- [x] Поведінка й запобіжники ті самі, що у WinForms-версії (підтвердження, UAC лише в момент дії, системні служби не видаляються) — ті самі виклики Core (`Uninstall.*`, `Startup.*`), ті самі діалоги підтвердження і правила ввімкнення кнопок
- [x] guismoke-tools проходить на WPF exe (лише читання): `tools/guismoke-tools.ps1 -Wpf` → Uninstall 212, Windows 28, Scheduled Tasks 10, Context Menu 41, Windows Services 314 — ті самі цифри, що у WinForms-варіанті

**Нотатки (done):**
- `UninstallView` (пошук + лічильник «N programs», таблиця Program / Publisher / Installed On / Size / Version) і `StartupView` (чотири вкладки, таблиця Enabled / Name / Location / Command). Праворуч колонка кнопок — стиль `ToolColumn` у `Theme.xaml`; «Save to text file» (поточна вкладка/відфільтрований список, заголовок + рядки через Tab) і діалоги підтвердження — `ToolsUi.cs` у WPF-проєкті.
- У `MainWindow` — лише блок `new SubNavPage("Tools").Add("Uninstall", …).Add("Startup", …)`.
- Rename у WinForms-версії не було і Core його не має — не додавав (поведінка-еталон = WinForms).
- Пастка: перша сторінка підменю будується ще в конструкторі `MainWindow` (до запуску dispatcher), тож `await` з конструктора сторінки продовжується не на UI-потоці й тихо падає. Завантаження стартує з `Loaded` (один раз).
- Списки не віртуалізуються (≈300 рядків максимум) — UI Automation бачить усі рядки, смоук рахує як у WinForms.
- Не перевірено вживу: кнопки дій (Run Uninstaller / Repair / Change / Delete entry, Enable / Disable / Delete) і діалог «Save to text file» — смоук лише читає.
