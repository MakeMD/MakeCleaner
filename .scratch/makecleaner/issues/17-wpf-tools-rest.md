# 17: Tools у WPF — Duplicate Finder, Disk Analyzer, Drive Wiper, System Restore

**What to build:** решта інструментів у підменю Tools. Duplicate Finder: форма налаштувань (критерії збігу, ігнор, розміри, папки) → результати з групами, Back, Delete selected. Disk Analyzer: вибір дисків і категорій, власна стовпчикова діаграма за категоріями + список файлів, відкрити папку, зберегти звіт. Drive Wiper: вільне місце / весь диск, кількість проходів, список дисків, попередження для SSD, підтвердження введенням слова, прогрес. System Restore: список точок і Remove (остання заблокована).

**Blocked by:** 14

**Status:** done

- [x] Сканування асинхронні зі скасуванням, UI не зависає (Duplicates / Disk Analyzer: кнопка стає Cancel; лічильник файлів оновлюється таймером 5 разів на секунду, а не на кожен звіт)
- [x] Системний диск неможливо стерти повністю; без введеного слова стирання не стартує (та сама послідовність, що у WinForms: `DriveWiper.CheckErasable` → UAC → діалог із словом ERASE)
- [x] guismoke-dupes і guismoke-wiper проходять на WPF exe (Wiper/Restore — без натискання дій); WinForms-варіанти теж зелені

**Нотатки (done):**
- Файли: `DuplicatesView`, `DiskAnalyzerView`, `DriveWiperView`, `RestoreView` (XAML + code-behind), `ToolsUi.cs` (WPF-близнюк WinForms `ToolsUi`: `Run` — скан-кнопка, що стає Cancel; `ConfirmDelete`, `OpenFolder`, `PickFolder` через `OpenFolderDialog`, `SaveText`, `RequireAdmin` — аналог `ElevatedUi.Require`). У `Theme.xaml` — стиль `ButtonColumn` (колонка кнопок праворуч) і пензель `Danger`. У `MainWindow` — чотири рядки `.Add(...)` для Tools. Core не змінювався.
- Duplicate Finder: два стани однієї сторінки — форма (Search) і результати, згруповані за набором дублікатів (`ListCollectionView` + `GroupStyle`), Select all but first / Delete Selected / Back. До 2000 груп, найбільша втрата першою.
- Disk Analyzer: список категорій і є стовпчиковою діаграмою (смуга пропорційна найбільшій категорії, розмір, кількість, %); клік по категорії фільтрує список файлів (до 5000 найбільших). Кнопки Open Folder / Delete Selected / Save Report рядком під списком, щоб список файлів мав ширину.
- WPF-пастка, яку WinForms ховав: форму читаємо на UI-потоці до `Task.Run` — читання `TextBox.Text` з фонового потоку валило процес.
- Смоуки: `-Wpf` у `guismoke-dupes.ps1` і `guismoke-wiper.ps1`; пункти меню вибираються як TabItem (WinForms) або ListItem (WPF); очікування вікна 20 с; WPF-знімки з префіксом `wpf-`; у wiper-смоуку Options пропускається під `-Wpf` (тікет 18) і чекаємо, поки сторінка Drive Wiper збудується (опит дисків/SSD буває кілька секунд).
- Не перевірено вживу: Delete у Duplicates/Disk Analyzer на справжніх файлах (лише фікстура в смоуці WinForms-шляху раніше), Save Report, Wipe / Entire Drive / Remove точки відновлення (свідомо не натискались), діалог ERASE (модальний — смоук не відкриває), Restart as admin.
- Спостереження: скасування скану займає 0.3–2.3 с — `Scan.Files` у Core перевіряє токен лише на кожному знайденому файлі, тож у великих теках без файлів чекає до наступного (так само у WinForms). Окремий follow-up у Core.
