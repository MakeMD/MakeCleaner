# 19: Прибрати WinForms

**What to build:** WPF-застосунок стає єдиним MakeCleaner.exe: старий WinForms-проєкт видалено, `tools/release.ps1`, інсталятор, `tools/releasecheck.ps1` і всі `tools/*smoke*.ps1` працюють на WPF-збірці. PLAN.md відображає новий стан.

**Blocked by:** 15, 16, 17, 18

**Status:** ready-for-agent

- [ ] У рішенні немає UseWindowsForms
- [ ] Усі тести й смоуки зелені; releasecheck: 0 мережевих з'єднань, 0 слідів поза portable-папкою
- [ ] Розмір і склад dist перевірено (exe, portable zip, setup)
