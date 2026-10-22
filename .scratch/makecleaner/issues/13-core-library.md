# 13: Ядро в окрему бібліотеку без UI

**What to build:** уся логіка MakeCleaner (правила, рушій, спеціальні процедури, браузери, cookies, реєстр, інструменти, налаштування, розклад, /auto) живе в бібліотеці MakeCleaner.Core, яка не посилається на WinForms чи WPF. Нинішній WinForms-застосунок працює як і раніше поверх неї — користувач нічого не помічає. Panel-класи, що зараз сидять в одних файлах з логікою (Startup, Uninstall), і діалоги підтвердження (запит прав адміністратора) переїжджають у UI-проєкт. Тести дивляться на Core.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] Core збирається без UseWindowsForms/UseWPF і без посилань на System.Windows.*
- [x] Тест «без System.Net.*» покриває Core і застосунок
- [x] Усі наявні тести й усі `tools/*smoke*.ps1` зелені на WinForms-застосунку
- [x] `tools/release.ps1` і `tools/releasecheck.ps1` проходять

**Нотатки (done):**
- `src/MakeCleaner.Core` (net10.0-windows, namespace лишився `MakeCleaner`): 17 файлів логіки перенесено через `git mv` + `rules\` (Windows.ini вбудований ресурсом, Winapp2.ini/README копіюються у вихід і publish кожного проєкту, що посилається на Core). Пакет `Microsoft.Data.Sqlite` тепер у Core.
- З UI-файлів у Core винесено логіку, яку тести й майбутній WPF викликають напряму: `DriveWiper` (CheckErasable, IsSsd, Format, WipeDir…) з `DriveWiperPanel`, `RestorePoints` (List, CanRemove, ParseCim, Remove) з `RestorePanel`, `Bytes.Fmt` з `MainForm`, ключ `SecureDelete.SettingKey` з `OptionsPanel`. `StartupPanel`/`UninstallPanel` вирізані в окремі файли застосунку; `Elevated.Require` (MessageBox) → `ElevatedUi.Require` у застосунку.
- Тести посилаються лише на Core; застосунок лише збирається першим (`ReferenceOutputAssembly=false`), його папка передається в тести через `AssemblyMetadata("AppDir")`. Тест «без System.Net» читає посилання через System.Reflection.Metadata (нічого не завантажує) і обходить MakeCleaner.dll → MakeCleaner.Core → Sqlite/SQLitePCLRaw. Новий тест `Core_has_no_ui_framework`: Core без System.Windows.Forms*/PresentationFramework/PresentationCore/WindowsBase/System.Xaml (і самоперевірка, що в застосунку ці посилання видно).
- Смоуки: шлях до `rules\Windows.ini` → `src\MakeCleaner.Core\rules\Windows.ini`. Склад publish не змінився (exe, e_sqlite3.dll, rules\, THIRD-PARTY-NOTICES).
