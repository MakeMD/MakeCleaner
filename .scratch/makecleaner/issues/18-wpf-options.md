# 18: Options у WPF

**What to build:** підменю Options: Settings (безпечне видалення 1/3/7/35, опції «старше 24 год» для Temp і Кошика), Include і Exclude (список + Add / Edit / Remove праворуч, ті самі перевірки шляхів), Cookies (два списки «На комп'ютері» / «Зберегти» з кнопками переносу, імпорт/експорт), Schedule (раз / щодня / щотижня / при вході, Create / Remove задачі), About (версія, «no telemetry, no ads, no network access», атрибуція Winapp2).

**Blocked by:** 14

**Status:** done

- [x] Усі налаштування читаються/пишуться тим самим Settings, що й WinForms-версія — перехід не губить списки (ті самі ключі: `SecureDeletePasses`, `TempOlderThan24h`, `RecycleBinOlderThan24h`, `Include*`, `Exclude*`, `KeepCookie*`; перевірено смоуком incexc на обох exe і рестартом)
- [x] Корінь диска / системні папки в Include відхиляються з поясненням (той самий `Custom.Reject`)
- [x] guismoke-incexc, guismoke-cookies і GUI-частина autosmoke проходять на WPF exe (Create задачі не натискається)

**Нотатки (done):**
- `src/MakeCleaner.Wpf/OptionsPages.cs` — один файл, сторінка = метод (як у WinForms `OptionsPanel`), підменю через `SubNavPage.Add`. AutomationId ті самі, що у WinForms. Сторінки в ScrollViewer; рядки контролів — WrapPanel (переносяться, а не обрізаються на вузькому вікні).
- About: текст в одному місці (`OptionsPages.AboutText`) — і сторінка Options > About, і діалог з футера.
- Відмінності від WinForms: Include «Edit» не додавав (у WinForms теж лише Add/Remove); вік — TextBox з перевіркою цілого числа замість NumericUpDown; час розкладу — TextBox `yyyy-MM-dd HH:mm` з перевіркою формату замість DateTimePicker; Browse — системний `OpenFolderDialog`.
- Exclude перечитує список, коли сторінка стає видимою (Cleaner > контекстне меню і Registry пишуть туди ж). Cookies сканує браузери при першому відкритті сторінки.
- Смоуки `guismoke-incexc.ps1`, `guismoke-cookies.ps1`, `autosmoke.ps1` отримали `-Wpf` (дефолт — WinForms); `Tab` вибирає і TabItem (WinForms), і ListItem (плитка меню / рядок підменю WPF); підсторінки Options обираються лише з `-Wpf`; очікування вікна 20 с.
- Спільні файли: `MainWindow.xaml.cs` — 2 рядки (`OptionsPages.Build(settings)` замість порожнього `SubNavPage("Options")`, About бере `OptionsPages.AboutText`). `SubNavPage`, `Theme.xaml`, Core — без змін.
- Не перевірено вживу: кнопки Create/Remove задачі (зареєстрували б справжню задачу), Import/Export і Browse (модальні системні діалоги), Run Cleaner у cookies-смоуку (на машині запущений справжній Chrome — смоук зупиняється після Analyze; рядкове видалення покрите юніт-тестом).
