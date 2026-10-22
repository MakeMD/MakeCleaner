# 18: Options у WPF

**What to build:** підменю Options: Settings (безпечне видалення 1/3/7/35, опції «старше 24 год» для Temp і Кошика), Include і Exclude (список + Add / Edit / Remove праворуч, ті самі перевірки шляхів), Cookies (два списки «На комп'ютері» / «Зберегти» з кнопками переносу, імпорт/експорт), Schedule (раз / щодня / щотижня / при вході, Create / Remove задачі), About (версія, «no telemetry, no ads, no network access», атрибуція Winapp2).

**Blocked by:** 14

**Status:** ready-for-agent

- [ ] Усі налаштування читаються/пишуться тим самим Settings, що й WinForms-версія — перехід не губить списки
- [ ] Корінь диска / системні папки в Include відхиляються з поясненням
- [ ] guismoke-incexc, guismoke-cookies і GUI-частина autosmoke проходять на WPF exe (Create задачі не натискається)
