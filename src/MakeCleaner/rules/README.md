# rules/

`Winapp2.ini` is the **Non-CCleaner (base) flavor** of Winapp2.ini by the Winapp2 project,
<https://github.com/MoscaDotTo/Winapp2>, version 260915 (4,068 entries), shipped **unmodified**.

License: [CC BY-SA 4.0](https://github.com/MoscaDotTo/Winapp2/blob/master/License.md).
Attribution: "Winapp2.ini by the Winapp2 project". Changes to this file must stay under CC BY-SA 4.0.
The CC BY-SA license covers only this data file, not the MakeCleaner code.

Why the base flavor and not the CCleaner one: the CCleaner flavor drops entries that CCleaner
already covers with its own built-in cleaners. MakeCleaner has no such built-ins, so the
base flavor gives full coverage, and its `Section=` names are readable group labels.

User rules: put your own `winapp2.ini` next to `MakeCleaner.exe`; entries with the same
name override bundled ones.
