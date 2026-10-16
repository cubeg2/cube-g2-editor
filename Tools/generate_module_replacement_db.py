#!/usr/bin/env python3
"""Turn the replacement role specification into Swift.

Inputs, and there are only two:

  Tools/module-replacement-roles.txt   families and roles, written in the module
                                       and port names a user reads off the panel
  Sources/G2Core/ModuleDatabase.swift  the project's own module definitions,
                                       which decide what each name resolves to

Everything the generator emits is looked up in those two files, so a renamed or
reordered port fails loudly here instead of quietly sending a cable to the wrong
socket. Behaviour is pinned from the outside by the golden baseline in
Tests/G2CoreTests/Fixtures/module-replacement-baseline.txt.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "Tools/module-replacement-roles.txt"
MODULES = ROOT / "Sources/G2Core/ModuleDatabase.swift"
OUTPUT = ROOT / "Sources/G2Core/ModuleReplacementData.swift"

# A module the replacement families still list although the project's own module
# database does not define it. Kept so the family keeps its shape; nothing can
# resolve a port on it.
UNKNOWN_PREFIX = "module"

MODULE_RE = re.compile(
    r'ModuleDef\(\s*id:\s*(\d+),\s*(?://[^\n]*\n\s*)*shortName:\s*"([^"]+)",\s*longName:\s*"[^"]+"(.*?)\n            \),',
    re.S,
)
PORT_NAME_RE = re.compile(r'name:\s*"([^"]+)"')


class Module:
    def __init__(self, ident: int, short: str, inputs: list[str],
                 outputs: list[str], params: list[str]) -> None:
        self.id = ident
        self.short = short
        self.ports = {"in": inputs, "out": outputs, "knob": params}

    def index(self, kind: str, name: str) -> int:
        names = self.ports[kind]
        try:
            return names.index(name)
        except ValueError:
            raise SystemExit(
                f"{self.short} has no {kind} called {name!r}; it has {names}"
            ) from None


def read_modules() -> dict[str, Module]:
    text = MODULES.read_text(encoding="utf-8")
    modules: dict[str, Module] = {}
    for match in MODULE_RE.finditer(text):
        body = match.group(3)

        def names(key: str) -> list[str]:
            block = re.search(key + r":\s*\[(.*?)\n                \]", body, re.S)
            return PORT_NAME_RE.findall(block.group(1)) if block else []

        params = re.search(r"paramNames:\s*\[(.*?)\]", body, re.S)
        module = Module(
            int(match.group(1)),
            match.group(2),
            names("inputs"),
            names("outputs"),
            re.findall(r'"([^"]*)"', params.group(1)) if params else [],
        )
        if module.short in modules:
            raise SystemExit(f"two modules share the short name {module.short!r}")
        modules[module.short] = module
    if not modules:
        raise SystemExit(f"no module definitions found in {MODULES}")
    return modules


class Family:
    def __init__(self, name: str) -> None:
        self.name = name
        self.members: list[int] = []
        self.roles: dict[str, list[list[list[int]]]] = {"knob": [], "in": [], "out": []}


def placeholder(name: str) -> int | None:
    """`module150` -> 150, for a family member the module database does not define."""
    tail = name[len(UNKNOWN_PREFIX):]
    return int(tail) if name.startswith(UNKNOWN_PREFIX) and tail.isdigit() else None


def resolve(token: str, kind: str, modules: dict[str, Module]) -> list[int]:
    """`OscA.Pitch` or `Mix4-1S.In1L+Lev1` -> the descriptor the Swift table holds."""
    module_name, _, rest = token.partition(".")
    if not rest:
        raise SystemExit(f"{token!r} is not a Module.Port reference")
    module = modules.get(module_name)
    if module is None:
        # An undefined member can only be written positionally, as `moduleN.in0`.
        ident = placeholder(module_name)
        if ident is None:
            raise SystemExit(f"unknown module {module_name!r} in {token!r}")
        match = re.fullmatch(r"(in|out|knob)(\d+)", rest)
        if match is None or match.group(1) != kind:
            raise SystemExit(
                f"{module_name} has no port names, so {token!r} must be written "
                f"positionally, for example {module_name}.{kind}0"
            )
        descriptor = [ident, int(match.group(2))]
        return descriptor + [255, 255] if kind == "in" else descriptor
    port, *attached = rest.split("+")
    descriptor = [module.id, module.index(kind, port)]
    if kind == "in":
        # 255 is the table's "nothing attached" marker for the two knob slots.
        for slot in range(2):
            if slot < len(attached):
                descriptor.append(module.index("knob", attached[slot]))
            else:
                descriptor.append(255)
    elif attached:
        raise SystemExit(f"only input roles may attach a knob, not {token!r}")
    return descriptor


def read_spec(modules: dict[str, Module]) -> list[Family]:
    families: list[Family] = []
    current: Family | None = None
    unknown: dict[str, int] = {}

    for number, raw in enumerate(SPEC.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip() if raw.lstrip().startswith("#") else raw.strip()
        if not line:
            continue
        keyword, _, rest = line.partition(" ")
        rest = rest.strip()
        try:
            if keyword == "family":
                current = Family(rest)
                families.append(current)
            elif current is None:
                raise SystemExit(f"{keyword!r} appears before any family")
            elif keyword == "members":
                for name in rest.split():
                    if name.startswith(UNKNOWN_PREFIX) and name[len(UNKNOWN_PREFIX):].isdigit():
                        ident = int(name[len(UNKNOWN_PREFIX):])
                        unknown[name] = ident
                        current.members.append(ident)
                    else:
                        module = modules.get(name)
                        if module is None:
                            raise SystemExit(f"unknown module {name!r}")
                        current.members.append(module.id)
            elif keyword in ("knob", "in", "out"):
                _, _, entries = rest.partition(":")
                role = [resolve(token, keyword, modules) for token in entries.split()]
                if not role:
                    raise SystemExit("role has no entries")
                for descriptor in role:
                    if descriptor[0] not in current.members:
                        raise SystemExit(
                            f"{descriptor[0]} is not a member of family {current.name!r}"
                        )
                current.roles[keyword].append(role)
            else:
                raise SystemExit(f"unexpected keyword {keyword!r}")
        except SystemExit as error:
            raise SystemExit(f"{SPEC.name}:{number}: {error}") from None
    return families


def swift_array(values: list[int]) -> str:
    return "[" + ", ".join(str(value) for value in values) + "]"


def render(families: list[Family]) -> str:
    lines = [
        "// ModuleReplacementData.swift",
        "//",
        "// Which modules may stand in for one another, and what carries across when",
        "// one is swapped for another: cables keep their meaning, knob values keep",
        "// theirs. The intent is that a patch written years ago on the original",
        "// hardware editor still behaves the same way here, on current Apple Silicon",
        "// machines, rather than losing its wiring on the first edit. That is the whole",
        "// reason this table exists.",
        "//",
        "// Every entry states behaviour a user can observe: which stand-ins the",
        "// replacement menu offers, and which socket a cable ends up in afterwards.",
        "// It is written in the port names printed on the panels, so an entry can be",
        "// checked against a running editor rather than taken on trust.",
        "//",
        "// GENERATED - edit Tools/module-replacement-roles.txt instead, then run",
        "// Tools/generate_module_replacement_db.py. That specification is written in",
        "// module and port names; the numbers below are only those names resolved",
        "// through Sources/G2Core/ModuleDatabase.swift, whose own definitions come",
        "// from the g2ools project.",
        "//",
        "// Behaviour is pinned by the golden baseline in",
        "// Tests/G2CoreTests/Fixtures/module-replacement-baseline.txt.",
        "// Runtime status: ACTIVE only for module-type replacement.",
        "",
        "extension ModuleReplacementDatabase {",
        "    static let rawGroups: [ModuleReplacementRawGroup] = [",
    ]
    for family in families:
        lines.append("        ModuleReplacementRawGroup(")
        lines.append(f'            name: "{family.name}",')
        lines.append(f"            modules: {swift_array(family.members)},")
        for keyword, label in (("knob", "parameterGroups"),
                               ("in", "inputGroups"),
                               ("out", "outputGroups")):
            lines.append(f"            {label}: [")
            for role in family.roles[keyword]:
                descriptors = ", ".join(swift_array(item) for item in role)
                lines.append(f"                [{descriptors}],")
            lines.append("            ]," if label != "outputGroups" else "            ]")
        lines.append("        ),")
    lines.extend(["    ]", "}", ""])
    return "\n".join(lines)


def main() -> None:
    modules = read_modules()
    families = read_spec(modules)
    if not families:
        raise SystemExit(f"{SPEC} declares no families")
    for family in families:
        if len(family.members) < 2:
            raise SystemExit(f"family {family.name!r} needs at least two members")
    OUTPUT.write_text(render(families), encoding="utf-8")
    roles = sum(len(role) for family in families for role in family.roles.values())
    print(
        f"wrote {OUTPUT.relative_to(ROOT)}: "
        f"{len(families)} families, {roles} roles, "
        f"{sum(len(f.members) for f in families)} member slots"
    )


if __name__ == "__main__":
    sys.exit(main())
