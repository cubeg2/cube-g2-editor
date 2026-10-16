#!/usr/bin/env python3
"""
generate_module_db.py
Reads g2ools/nord/g2/modules.py and generates ModuleDatabase.swift

Usage:
    python3 Tools/generate_module_db.py \
        ../reference/g2ools/nord/g2/modules.py \
        > Sources/G2Core/ModuleDatabase.swift
"""

import re
import sys
from pathlib import Path

# --- Color mapping: g2ools name -> Swift enum case ---
COLOR_MAP = {
    "red":            ".audio",
    "blue":           ".control",
    "yellow":         ".logic",
    "blue_red":       ".pitchOrControl",
    "yellow_orange":  ".logicOrControl",
    "orange":         ".logicOrControl",
    "green":          ".control",
    "purple":         ".control",
    "white":          ".control",
}

def swift_string(s):
    return '"' + s.replace('"', '\\"') + '"'

def swift_identifier(s):
    """Convert a Python name to a valid Swift identifier."""
    s = s.replace('-', '_').replace('&', 'And').replace(' ', '_').replace('/', '_')
    if s and s[0].isdigit():
        s = '_' + s
    return s

def parse_modules(src):
    """Parse ModuleType(...) blocks from modules.py source text.
    Returns list of dicts with module data."""

    modules = []

    # Split on ModuleType( boundaries
    blocks = re.split(r'(?=\bModuleType\s*\()', src)

    for block in blocks:
        if not block.strip().startswith('ModuleType'):
            continue

        m = {}

        # id
        match = re.search(r'\bid\s*=\s*(\d+)', block)
        if not match:
            continue
        m['id'] = int(match.group(1))

        # height
        match = re.search(r'\bheight\s*=\s*(\d+)', block)
        m['height'] = int(match.group(1)) if match else 2

        # longnm
        match = re.search(r"\blongnm\s*=\s*'([^']*)'", block)
        m['longName'] = match.group(1) if match else ''

        # shortnm
        match = re.search(r"\bshortnm\s*=\s*'([^']*)'", block)
        m['shortName'] = match.group(1) if match else ''

        # page
        match = re.search(r"\bPageType\s*\(\s*'([^']*)'", block)
        m['page'] = match.group(1) if match else ''

        # inputs
        m['inputs'] = parse_connectors(block, 'InputType')

        # outputs
        m['outputs'] = parse_connectors(block, 'OutputType')

        # param count (just names for now)
        m['params'] = re.findall(r"ParamType\s*\(\s*'([^']*)'", block)

        # mode count
        m['modes'] = re.findall(r"ModeType\s*\(\s*'([^']*)'", block)

        modules.append(m)

    return modules

def parse_connectors(block, kind):
    """Extract InputType or OutputType entries from a module block."""
    connectors = []
    pattern = re.compile(
        r'\b' + kind + r"""\s*\(\s*'([^']*)'\s*,\s*(\w+)\s*,"""
        r"""\s*horiz\s*=\s*(\d+)\s*,\s*vert\s*=\s*(\d+)\s*\)""",
        re.DOTALL
    )
    for match in pattern.finditer(block):
        name, color_raw, horiz, vert = match.groups()
        color = COLOR_MAP.get(color_raw, '.control')
        connectors.append({
            'name':  name,
            'color': color,
            'horiz': int(horiz),
            'vert':  int(vert),
        })
    return connectors

def emit_swift(modules):
    lines = []

    lines.append("// ModuleDatabase.swift")
    lines.append("// AUTO-GENERATED — do not edit by hand.")
    lines.append("// Source: g2ools/nord/g2/modules.py (Matt Gerassimoff, GPL)")
    lines.append("// Generator: Tools/generate_module_db.py")
    lines.append("")
    lines.append("import Foundation")
    lines.append("")

    # --- Connector color enum ---
    lines.append("public enum ConnectorColor: String {")
    lines.append("    case audio           // red  — audio signal")
    lines.append("    case control         // blue — control signal")
    lines.append("    case logic           // yellow — gate/logic")
    lines.append("    case pitchOrControl  // blue_red")
    lines.append("    case logicOrControl  // yellow_orange")
    lines.append("}")
    lines.append("")

    # --- Connector definition ---
    lines.append("public struct ConnectorDef {")
    lines.append("    public let name:  String")
    lines.append("    public let color: ConnectorColor")
    lines.append("    public let horiz: Int")
    lines.append("    public let vert:  Int")
    lines.append("}")
    lines.append("")

    # --- ModuleDef ---
    lines.append("public struct ModuleDef {")
    lines.append("    public let id:         Int")
    lines.append("    public let shortName:  String")
    lines.append("    public let longName:   String")
    lines.append("    public let page:       String")
    lines.append("    public let height:     Int   // in grid units")
    lines.append("    public let inputs:     [ConnectorDef]")
    lines.append("    public let outputs:    [ConnectorDef]")
    lines.append("    public let paramNames: [String]")
    lines.append("    public let modeNames:  [String]")
    lines.append("}")
    lines.append("")

    # --- ModuleDatabase ---
    lines.append("public enum ModuleDatabase {")
    lines.append("")
    lines.append("    // MARK: - Lookup")
    lines.append("")
    lines.append("    public static func module(id: Int) -> ModuleDef? {")
    lines.append("        return byID[id]")
    lines.append("    }")
    lines.append("")
    lines.append("    public static func module(shortName: String) -> ModuleDef? {")
    lines.append("        return byShortName[shortName.lowercased()]")
    lines.append("    }")
    lines.append("")
    lines.append("    public static let all: [ModuleDef] = buildAll()")
    lines.append("")
    lines.append("    private static let byID: [Int: ModuleDef] = {")
    lines.append("        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })")
    lines.append("    }()")
    lines.append("")
    lines.append("    private static let byShortName: [String: ModuleDef] = {")
    lines.append("        Dictionary(uniqueKeysWithValues: all.map { ($0.shortName.lowercased(), $0) })")
    lines.append("    }()")
    lines.append("")
    lines.append("    // MARK: - Module definitions")
    lines.append("")
    lines.append("    private static func buildAll() -> [ModuleDef] {")
    lines.append("        return [")

    for m in sorted(modules, key=lambda x: x['id']):
        lines.append("            ModuleDef(")
        lines.append(f"                id:         {m['id']},")
        lines.append(f"                shortName:  {swift_string(m['shortName'])},")
        lines.append(f"                longName:   {swift_string(m['longName'])},")
        lines.append(f"                page:       {swift_string(m['page'])},")
        lines.append(f"                height:     {m['height']},")

        # inputs
        if m['inputs']:
            conn_lines = []
            for c in m['inputs']:
                conn_lines.append(
                    f"                    ConnectorDef(name: {swift_string(c['name'])}, "
                    f"color: {c['color']}, horiz: {c['horiz']}, vert: {c['vert']})"
                )
            lines.append("                inputs:     [")
            lines.append(",\n".join(conn_lines) + ",")
            lines.append("                ],")
        else:
            lines.append("                inputs:     [],")

        # outputs
        if m['outputs']:
            conn_lines = []
            for c in m['outputs']:
                conn_lines.append(
                    f"                    ConnectorDef(name: {swift_string(c['name'])}, "
                    f"color: {c['color']}, horiz: {c['horiz']}, vert: {c['vert']})"
                )
            lines.append("                outputs:    [")
            lines.append(",\n".join(conn_lines) + ",")
            lines.append("                ],")
        else:
            lines.append("                outputs:    [],")

        # params
        if m['params']:
            param_str = ", ".join(swift_string(p) for p in m['params'])
            lines.append(f"                paramNames: [{param_str}],")
        else:
            lines.append("                paramNames: [],")

        # modes
        if m['modes']:
            mode_str = ", ".join(swift_string(mo) for mo in m['modes'])
            lines.append(f"                modeNames:  [{mode_str}]")
        else:
            lines.append("                modeNames:  []")

        lines.append("            ),")

    lines.append("        ]")
    lines.append("    }")
    lines.append("}")
    lines.append("")

    return "\n".join(lines)

def main():
    if len(sys.argv) < 2:
        print("Usage: generate_module_db.py <path/to/modules.py>", file=sys.stderr)
        sys.exit(1)

    src_path = Path(sys.argv[1])
    src = src_path.read_text(encoding='utf-8', errors='replace')

    modules = parse_modules(src)

    if not modules:
        print("ERROR: No modules found — check path or format.", file=sys.stderr)
        sys.exit(1)

    print(f"Parsed {len(modules)} modules.", file=sys.stderr)

    swift_code = emit_swift(modules)
    print(swift_code)

if __name__ == '__main__':
    main()
