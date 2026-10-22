# 15: Registry у WPF

**What to build:** екран Registry у WPF-застосунку: зліва чекліст 15 категорій з «вибрати все», справа смуга прогресу і таблиця з колонками Problem | Data | Registry key і чекбоксами рядків; Scan ліворуч, Review selected праворуч. Перед фіксом — запит на .reg-бекап, потім діалог з кроками n/N (назад/вперед, Fix, Fix all selected з підтвердженням, Close). Контекстне меню рядка: вибрати/зняти все або за типом, відкрити в RegEdit, додати в Exclude.

**Blocked by:** 14

**Status:** done

- [x] Сканування нічого не змінює; фікс неможливий без відповіді на питання про бекап (спершу пояснення → OK, потім вибір файлу; Cancel на будь-якому кроці = нічого не змінено; збій запису бекапу = нічого не змінено)
- [x] «Додати в Exclude» пише в той самий спільний список, що й Options (`Custom.AddExclude`, REG-записи)
- [x] regsmoke проходить на WPF exe (лише Scan) — `tools/regsmoke.ps1 -Wpf`; WinForms-варіант теж зелений

**Нотатки (done):**
- `src/MakeCleaner.Wpf/RegistryView.xaml(.cs)` — чекліст категорій (той самий `CheckNode`, що в Cleaner: «All categories» отримує третій стан; ключі `Reg:<категорія>` ті самі, що у WinForms), смуга прогресу того ж вигляду, що в Cleaner (~15 рядків XAML, скопійовано, не виносилось), таблиця з чекбоксом рядка, контекстне меню. Скан іде по одній категорії, тож смуга показує «NN% (x of y)» і Cancel спрацьовує між категоріями й усередині (той самий `CancellationToken` у `RegScanner.Scan`).
- `src/MakeCleaner.Wpf/RegFixDialog.cs` — вікно кроків n/N: `<<` / `>>`, Fix Issue, Fix All Selected (з підтвердженням), Close; виправлені лишаються в обході з позначкою «fixed», невдалі — «failed (need admin?)» і можна повторити.
- Core: `RegFix.Fix` = `WriteBackup` + новий `RegFix.Apply` (сам цикл видалення). Діалог пише бекап усіх вибраних один раз, потім `Apply` поштучно — інакше кожен Fix Issue перезаписував би бекап одним записом. Тест `Backup_once_then_apply_one_by_one`.
- `MainWindow`: один рядок — `new RegistryView(settings)` замість порожньої `SubNavPage("Registry")`.
- Скриншот: `%TEMP%\makecleaner-wpf-registry.png`.
- Не перевірено вживу: діалог бекапу і вікно кроків n/N (модальні; на реальних ключах фікс заборонений, а UIA-сценарію на тестовій гілці немає — логіку покриває тест `RegFix.Apply`), «Open in RegEdit» і «Add to Exclude» з контекстного меню, Cancel посеред скану (скан на цій машині займає ~1 с).
