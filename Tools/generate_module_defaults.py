#!/usr/bin/env python3
"""
generate_module_defaults.py
Reads ModuleDef.xml and generates ModuleDefaultsDatabase.swift

Usage (from G2Editor/):
    python3 Tools/generate_module_defaults.py \
        ../reference/nord_g2_editor/Gen1/Bin/ModuleDef.xml \
        > Sources/G2Core/ModuleDefaultsDatabase.swift
"""

import sys
import xml.etree.ElementTree as ET

def main():
    if len(sys.argv) < 2:
        print("Usage: generate_module_defaults.py <ModuleDef.xml>", file=sys.stderr)
        sys.exit(1)

    tree = ET.parse(sys.argv[1])
    root = tree.getroot()
    # Strip namespace if present
    ns = ""
    if root.tag.startswith("{"):
        ns = root.tag.split("}")[0] + "}"

    def tag(name):
        return f"{ns}{name}"

    entries = []
    for mod in root.findall(tag("ModuleDef")):
        type_el = mod.find(tag("ModuleType"))
        if type_el is None:
            continue
        type_id = int(type_el.text.strip())
        params_el = mod.find(tag("Params"))
        if params_el is None:
            entries.append((type_id, []))
            continue
        defaults = []
        for param in params_el.findall(tag("Param")):
            dv_el = param.find(tag("DefaultValue"))
            defaults.append(int(dv_el.text.strip()) if dv_el is not None else 0)
        entries.append((type_id, defaults))

    entries.sort(key=lambda x: x[0])

    print("// ModuleDefaultsDatabase.swift")
    print("// AUTO-GENERATED — do not edit by hand.")
    print("// Source: reference/nord_g2_editor/Gen1/Bin/ModuleDef.xml")
    print("// Generator: Tools/generate_module_defaults.py")
    print("")
    print("public enum ModuleDefaultsDatabase {")
    print("    /// Default parameter values for each module type (in param order).")
    print("    /// Returns empty array if module has no parameters.")
    print("    public static func defaults(forTypeID id: Int) -> [Int] {")
    print("        return table[id] ?? []")
    print("    }")
    print("")
    print("    // MARK: - Table")
    print("")
    print("    private static let table: [Int: [Int]] = [")
    for type_id, defaults in entries:
        if defaults:
            arr = "[" + ", ".join(str(v) for v in defaults) + "]"
        else:
            arr = "[]"
        print(f"        {type_id}: {arr},")
    print("    ]")
    print("}")

if __name__ == "__main__":
    main()
