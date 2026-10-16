# Test fixture provenance

All `.pch2` fixtures in this directory are unmodified copies of test patches
published by three open-source projects. Each file was verified byte-identical
(SHA-256) to its upstream original on 2026-09-02. They are kept in this
repository so the test suite does not depend on external paths (commit
`90ad26dd`).

None of these patches were authored by the G2Editor project.

| Fixture | Upstream project | Upstream path | License |
|---|---|---|---|
| `DelayLevel.pch2` | G2-Edit (Chris Turner) | `PatchTestFiles/DelayLevel.pch2` | GPL-3.0-or-later |
| `EnvFx.pch2` | G2-Edit (Chris Turner) | `PatchTestFiles/EnvFx.pch2` | GPL-3.0-or-later |
| `LogicMidi.pch2` | G2-Edit (Chris Turner) | `PatchTestFiles/LogicMidi.pch2` | GPL-3.0-or-later |
| `RndFilter.pch2` | G2-Edit (Chris Turner) | `PatchTestFiles/RndFilter.pch2` | GPL-3.0-or-later |
| `SwitchSeqNote.pch2` | G2-Edit (Chris Turner) | `PatchTestFiles/SwitchSeqNote.pch2` | GPL-3.0-or-later |
| `ioosc.pch2` | G2-Edit (Chris Turner) | `PatchTestFiles/ioosc.pch2` | GPL-3.0-or-later |
| `manyOSCA.pch2` | pch2csd | `tests/resources/manyOSCA.pch2` | MIT |
| `test_3osc.pch2` | pch2csd | `tests/resources/test_3osc.pch2` | MIT |
| `test_all_modules_1.pch2` | pch2csd | `tests/resources/test_all_modules_1.pch2` | MIT |
| `test_all_modules_2.pch2` | pch2csd | `tests/resources/test_all_modules_2.pch2` | MIT |
| `simplesynth001-20240802.pch2` | g2fx (Stuart Popejoy, 2024) | `data/simplesynth001-20240802.pch2` | BSD 3-Clause |

All three licenses permit redistribution with attribution and are compatible
with this project's `GPL-3.0-or-later`. License texts are recorded in the
provenance inventory of the companion documentation repository.

The patches themselves are Nord Modular G2 patch data written with the original
Clavia editor (`Info=BUILD 266` / `BUILD 320` in their headers). They are used
here only as parser and round-trip test input.
