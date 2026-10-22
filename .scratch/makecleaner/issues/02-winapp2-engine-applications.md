# 02: Повний рушій winapp2 + вкладка Applications

**What to build:** вкладка Applications показує згруповані пункти з community Winapp2.ini лише для програм, що реально є на ПК; Analyze/Clean працює для будь-якого пункту. Рушій підтримує повний публічний синтаксис winapp2: Detect / DetectFile / DetectOS / SpecialDetect (базові браузери), FileKey з RECURSE / REMOVESELF і кількома масками, RegKey (ключ або значення), ExcludeKey (FILE / PATH / REG), Default, Warning; ключі регістронезалежні й нумеровані. Winapp2.ini (CC BY-SA 4.0) лежить окремим файлом з атрибуцією; користувацький winapp2.ini поруч з exe підхоплюється автоматично. Жодних правил з CCleaner.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Секція без виконаного Detect*/DetectOS не показується
- [ ] RECURSE заходить у підпапки, REMOVESELF видаляє й саму папку, без прапорця — лише файли верхнього рівня
- [ ] RegKey видаляє ключ або одне значення; ExcludeKey захищає збіги від видалення
- [ ] Пункт з Warning перед увімкненням питає підтвердження
- [ ] Тести парсера на фікстурах INI (регістр ключів, нумерація, env-змінні, DetectOS min|max)
- [ ] Атрибуція Winapp2 видна в About
