# 19: Прибрати WinForms

**What to build:** WPF-застосунок стає єдиним MakeCleaner.exe: старий WinForms-проєкт видалено, `tools/release.ps1`, інсталятор, `tools/releasecheck.ps1` і всі `tools/*smoke*.ps1` працюють на WPF-збірці. PLAN.md відображає новий стан.

**Blocked by:** 15, 16, 17, 18

**Status:** done (install/uninstall setup.exe — вручну, див. нотатки)

- [x] У рішенні немає UseWindowsForms (у `src` лише `MakeCleaner.Core` + WPF `MakeCleaner`; тест `Core_has_no_ui_framework` і далі перевіряє Core)
- [x] Усі тести й смоуки зелені; releasecheck: 0 мережевих з'єднань, 0 слідів поза portable-папкою (11 смоуків на опублікованій копії, 129 замірів мережі)
- [x] Розмір і склад dist перевірено (exe 58,55 МБ, portable zip 57,96 МБ, setup 57,2 МБ; поруч з exe — `e_sqlite3.dll` і нативні DLL WPF `*_cor3.dll`)

**Нотатки (done):**
- WinForms-проєкт `src/MakeCleaner` видалено; WPF-проєкт переїхав з `src/MakeCleaner.Wpf` на його місце (`git mv`, історія збережена), `MakeCleaner.csproj`, exe `MakeCleaner.exe` (без AssemblyName). Pack-URI теми: `/MakeCleaner;component/Theme.xaml`.
- `MakeCleaner.Wpf.exe` і перемикач `-Wpf` зі смоуків, згадані в нотатках 14–18, більше не існують: один шлях, `src\MakeCleaner\bin\...\MakeCleaner.exe`. `guismoke-wpf.ps1` перейменовано на `guismoke-cleaner.ps1`; releasecheck його більше не пропускає. Гілки TabItem лишились лише там, де у WPF справді вкладки (Cleaner: Windows/Browsers/Applications; Startup).
- `guismoke-wiper.ps1` знову перевіряє Options > Settings (`secureDelete`): у WPF вибір читається через SelectionPattern (нередагований ComboBox не має ValuePattern).
- Publish: WPF без самовитягування кладе поруч з exe `wpfgfx_cor3.dll`, `PresentationNative_cor3.dll`, `PenImc_cor3.dll`, `vcruntime140_cor3.dll`, `D3DCompiler_47_cor3.dll` (exe 49,5 → 58,5 МБ). `release.ps1` перевіряє їх наявність; інсталятор бере весь `dist\publish\*`. `THIRD-PARTY-NOTICES` — WPF замість Windows Forms.
- Нестабільний тест «ExtractPath_is_conservative» насправді був гонкою в `Dispose`: `RegistryTests`/`CustomTests`/`ToolsTests` ділили `HKCU\Software\MakeCleanerTest` і видаляли його «якщо порожній», поки паралельний клас створював там гілку → `InvalidOperationException` (або `UnauthorizedAccessException` зсередини .NET) з `Dispose` валив тест, що саме завершувався. Тепер кожен клас має власну гілку `HKCU\Software\MakeCleanerTest-*-<guid>`. До: 3 падіння з 26 прогонів; після: 0 з 31.
- Не перевірено: встановлення/видалення setup.exe (класифікатор авто-режиму блокує /VERYSILENT — вручну); вікно на моніторі з іншим DPI.
