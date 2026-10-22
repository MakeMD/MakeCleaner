# 13: Ядро в окрему бібліотеку без UI

**What to build:** уся логіка MakeCleaner (правила, рушій, спеціальні процедури, браузери, cookies, реєстр, інструменти, налаштування, розклад, /auto) живе в бібліотеці MakeCleaner.Core, яка не посилається на WinForms чи WPF. Нинішній WinForms-застосунок працює як і раніше поверх неї — користувач нічого не помічає. Panel-класи, що зараз сидять в одних файлах з логікою (Startup, Uninstall), і діалоги підтвердження (запит прав адміністратора) переїжджають у UI-проєкт. Тести дивляться на Core.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Core збирається без UseWindowsForms/UseWPF і без посилань на System.Windows.*
- [ ] Тест «без System.Net.*» покриває Core і застосунок
- [ ] Усі наявні тести й усі `tools/*smoke*.ps1` зелені на WinForms-застосунку
- [ ] `tools/release.ps1` і `tools/releasecheck.ps1` проходять
