# G2Editor — notices and attribution

## Project status

G2Editor is an independent, community-developed editor for the Nord Modular G2.
It is developed on a non-profit, experimental basis for interoperability,
preservation, research, and continued use of existing hardware on modern Apple
operating systems, initially macOS. It is a work in progress and is provided
without warranty; use it at your own risk.

G2Editor is not affiliated with, authorized, sponsored, or endorsed by Clavia
DMI AB or Nord Keyboards. The names Nord, Nord Modular, and Nord Modular G2, and
any associated marks, belong to their respective owners and are used only to
identify the hardware and software with which this project is intended to be
compatible.

## Interface compatibility

The original Nord Modular G2 Editor no longer runs on current Apple Silicon
Macs. G2Editor intentionally recreates its functional organization, module
panels, displays and diagrams — including the DX algorithm diagrams, which many
musicians recognize by their picture — so that existing users can keep working
with the instrument without relearning it.

This statement describes compatibility and usability goals. It does not claim
ownership of, or grant permission to use, third-party trademarks, code, artwork,
panel data, resource data, or other protected materials.

## Project license

Copyright (C) 2026 G2Editor contributors.

Except for third-party material identified below, original G2Editor source code
is licensed under the GNU General Public License, version 3 or, at your option,
any later version (`GPL-3.0-or-later`). The complete license text is in
[`LICENSE`](LICENSE).

This license was selected to accommodate the GPL-2.0-or-later and
GPL-3.0-or-later code on which parts of the implementation are based. It does
not change or replace the licenses and rights that apply to third-party
material.

## Third-party material

- Bruno Verhue's NMG2Editor code and bundled Gen1 panel files are distributed
  under GPL-2.0-or-later. A copy of the license is bundled at
  `Sources/G2Core/Resources/BVerhue-LICENSE.txt`.
- The module panel layouts this editor draws come from those Gen1 panel files:
  192 definitions in `Sources/G2Core/Resources/Modules`, covering 167 modules.
  They are used here under GPL-2.0-or-later. The drawing code in this project
  is its own.
- Portions informed by or ported from g2ools (Matt Gerassimoff) are
  GPL-2.0-or-later.
- Portions informed by or ported from G2-Edit (Chris Turner) are
  GPL-3.0-or-later.
- MatrixSansScreen-Regular is distributed under the SIL Open Font License 1.1;
  its notice is bundled at
  `Sources/G2EditorApp/Resources/MatrixSans-OFL.txt`.
- All eleven `.pch2` test fixtures are unmodified copies of test patches
  published by G2-Edit (GPL-3.0-or-later), pch2csd (MIT) and g2fx
  (BSD 3-Clause). Per-file attribution is in
  [`Tests/G2CoreTests/Fixtures/PROVENANCE.md`](Tests/G2CoreTests/Fixtures/PROVENANCE.md).
- The packaged app (`Tools/build_app.sh`) bundles an unmodified copy of
  libusb 1.0 (https://libusb.info), distributed under LGPL-2.1-or-later. It is
  linked dynamically from `Contents/Frameworks` and can be replaced with another
  build of libusb; its license is bundled at
  `Contents/Resources/Licenses/libusb-COPYING.txt`.
