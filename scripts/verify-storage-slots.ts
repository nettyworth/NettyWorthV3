/**
 * verify-storage-slots.ts
 *
 * Verifies that every ERC-7201 namespaced-storage slot constant hardcoded in a
 * Solidity contract matches the canonical formula:
 *
 *   keccak256(abi.encode(uint256(keccak256("<namespace>")) - 1)) & ~bytes32(uint256(0xff))
 *
 * Solidity cannot constant-fold this expression at compile time, so we keep the
 * precomputed hex in source and use this script to guard against typos /
 * copy-paste errors.
 *
 * Usage (standalone):
 *   npx tsx scripts/verify-storage-slots.ts
 *
 * Usage (via package.json):
 *   pnpm verify:slots
 *
 * Exit code 0 = all slots correct.
 * Exit code 1 = one or more mismatches, duplicate namespaces, or unpaired
 *               annotations / constants found.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, toBytes, encodeAbiParameters, toHex } from "viem";

// ---------------------------------------------------------------------------
// ERC-7201 slot derivation
// ---------------------------------------------------------------------------

/**
 * Compute the ERC-7201 storage slot for the given namespace string.
 * Implements: keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~bytes32(0xff)
 */
function erc7201Slot(namespace: string): `0x${string}` {
    const inner = BigInt(keccak256(toBytes(namespace)));
    const encoded = encodeAbiParameters([{ type: "uint256" }], [inner - 1n]);
    const outer = BigInt(keccak256(encoded));
    const masked = outer & ~0xffn;
    return toHex(masked, { size: 32 });
}

// ---------------------------------------------------------------------------
// Source discovery
// ---------------------------------------------------------------------------

/** Recursively collect all .sol files under a directory. */
function collectSolFiles(dir: string): string[] {
    const results: string[] = [];
    for (const entry of readdirSync(dir)) {
        const full = join(dir, entry);
        const stat = statSync(full);
        if (stat.isDirectory()) {
            results.push(...collectSolFiles(full));
        } else if (entry.endsWith(".sol")) {
            results.push(full);
        }
    }
    return results;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

interface AnnotationEntry {
    namespace: string;
    line: number; // 1-based
}

interface ConstantEntry {
    name: string;
    value: string; // lowercase hex, 0x-prefixed
    line: number; // 1-based (line of the `bytes32 private constant` declaration)
}

interface FileData {
    path: string; // absolute
    rel: string; // relative to repo root for display
    annotations: AnnotationEntry[];
    constants: ConstantEntry[];
}

const ANNOTATION_RE =
    /@custom:storage-location\s+erc7201:(\S+)/;

// Matches: bytes32 private constant FOO_STORAGE_SLOT =
const CONSTANT_DECL_RE =
    /bytes32\s+(?:private\s+)?constant\s+(\w+)\s*=/;

// Matches a standalone 0x-prefixed 64-hex-char value (the slot literal).
// Allows it to be on the same line as the = or on the following line.
const HEX64_RE = /(0x[0-9a-fA-F]{64})/;

function parseFile(filePath: string, root: string): FileData {
    const src = readFileSync(filePath, "utf8");
    const lines = src.split("\n");

    const annotations: AnnotationEntry[] = [];
    const constants: ConstantEntry[] = [];

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        // Detect annotation lines
        const annMatch = ANNOTATION_RE.exec(line);
        if (annMatch) {
            annotations.push({ namespace: annMatch[1], line: i + 1 });
        }

        // Detect bytes32 constant declarations
        const declMatch = CONSTANT_DECL_RE.exec(line);
        if (declMatch) {
            const constName = declMatch[1];

            // The hex literal may be on the same line or the next non-empty line
            let hexValue: string | null = null;
            for (let j = i; j <= Math.min(i + 2, lines.length - 1); j++) {
                const hexMatch = HEX64_RE.exec(lines[j]);
                if (hexMatch) {
                    hexValue = hexMatch[1].toLowerCase();
                    break;
                }
            }

            if (hexValue) {
                constants.push({ name: constName, value: hexValue, line: i + 1 });
            }
        }
    }

    return {
        path: filePath,
        rel: relative(root, filePath),
        annotations,
        constants,
    };
}

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

type CheckStatus = "pass" | "fail" | "warn";

interface CheckResult {
    file: string;
    namespace: string;
    constantName: string;
    hardcoded: string;
    expected: string;
    status: CheckStatus;
    note?: string;
}

// ---------------------------------------------------------------------------
// Verification logic
// ---------------------------------------------------------------------------

function verify(root: string): { results: CheckResult[]; issues: string[] } {
    const contractsDir = join(root, "contracts");
    const testDir = join(root, "contracts", "test");

    const solFiles = collectSolFiles(contractsDir).filter(
        (f) => !f.startsWith(testDir + "/") && f !== testDir
    );

    const fileDataList: FileData[] = solFiles.map((f) =>
        parseFile(f, root)
    );

    const results: CheckResult[] = [];
    const issues: string[] = [];

    // --- duplicate namespace check ---
    const namespaceSeen = new Map<string, string[]>();
    for (const fd of fileDataList) {
        for (const ann of fd.annotations) {
            const existing = namespaceSeen.get(ann.namespace) ?? [];
            existing.push(fd.rel);
            namespaceSeen.set(ann.namespace, existing);
        }
    }
    for (const [ns, files] of namespaceSeen) {
        if (files.length > 1) {
            issues.push(
                `Duplicate namespace "${ns}" in: ${files.join(", ")}`
            );
        }
    }

    // --- per-file pairing ---
    for (const fd of fileDataList) {
        if (fd.annotations.length === 0 && fd.constants.length === 0) continue;

        // File has annotations but no matching constants (or vice versa)
        if (fd.annotations.length > 0 && fd.constants.length === 0) {
            issues.push(
                `${fd.rel}: has @custom:storage-location annotation(s) but no bytes32 slot constant found`
            );
            continue;
        }
        if (fd.annotations.length === 0 && fd.constants.length > 0) {
            // Only flag STORAGE_SLOT constants — avoid false positives on unrelated constants
            const slotConsts = fd.constants.filter((c) =>
                c.name.toUpperCase().includes("STORAGE_SLOT")
            );
            if (slotConsts.length > 0) {
                issues.push(
                    `${fd.rel}: has STORAGE_SLOT constant(s) but no @custom:storage-location annotation found`
                );
            }
            continue;
        }

        // Pair annotation[i] with constant[i] — most files have exactly one of each.
        // If counts differ, flag and pair up to min(length).
        if (fd.annotations.length !== fd.constants.length) {
            issues.push(
                `${fd.rel}: annotation count (${fd.annotations.length}) ≠ constant count (${fd.constants.length}) — check pairing manually`
            );
        }

        const pairCount = Math.min(fd.annotations.length, fd.constants.length);
        for (let i = 0; i < pairCount; i++) {
            const ann = fd.annotations[i];
            const con = fd.constants[i];
            const expected = erc7201Slot(ann.namespace);
            const status: CheckStatus =
                expected.toLowerCase() === con.value.toLowerCase() ? "pass" : "fail";

            results.push({
                file: fd.rel,
                namespace: ann.namespace,
                constantName: con.name,
                hardcoded: con.value,
                expected,
                status,
            });
        }
    }

    return { results, issues };
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";

function colorize(text: string, color: string): string {
    return `${color}${text}${RESET}`;
}

function printTable(results: CheckResult[]): void {
    const colFile = Math.max(8, ...results.map((r) => r.file.length));
    const colNs = Math.max(9, ...results.map((r) => r.namespace.length));
    const colConst = Math.max(14, ...results.map((r) => r.constantName.length));

    const header = [
        "File".padEnd(colFile),
        "Namespace".padEnd(colNs),
        "Constant".padEnd(colConst),
        "Status",
    ].join("  ");

    const sep = "-".repeat(header.length);
    console.log(`\n${BOLD}${header}${RESET}`);
    console.log(DIM + sep + RESET);

    for (const r of results) {
        const icon = r.status === "pass" ? colorize("✅ PASS", GREEN) : colorize("❌ FAIL", RED);
        console.log(
            [
                r.file.padEnd(colFile),
                r.namespace.padEnd(colNs),
                r.constantName.padEnd(colConst),
                icon,
            ].join("  ")
        );
        if (r.status === "fail") {
            console.log(
                `  ${DIM}hardcoded: ${r.hardcoded}${RESET}`
            );
            console.log(
                `  ${colorize("expected:  " + r.expected, YELLOW)}`
            );
        }
    }

    console.log("");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const root = join(fileURLToPath(import.meta.url), "..", "..");

console.log(`${BOLD}ERC-7201 Storage Slot Verification${RESET}`);
console.log(`${DIM}Scanning: ${join(root, "contracts")}${RESET}`);

const { results, issues } = verify(root);

printTable(results);

if (issues.length > 0) {
    console.log(colorize(`Structural issues (${issues.length}):`, YELLOW));
    for (const issue of issues) {
        console.log(`  ⚠️  ${issue}`);
    }
    console.log("");
}

const passes = results.filter((r) => r.status === "pass").length;
const fails = results.filter((r) => r.status === "fail").length;

if (fails === 0 && issues.length === 0) {
    console.log(colorize(`✅  All ${passes} slot(s) verified successfully.`, GREEN));
    process.exit(0);
} else {
    const parts: string[] = [];
    if (fails > 0) parts.push(`${fails} slot mismatch(es)`);
    if (issues.length > 0) parts.push(`${issues.length} structural issue(s)`);
    console.log(colorize(`❌  Verification failed: ${parts.join(", ")}.`, RED));
    process.exit(1);
}
