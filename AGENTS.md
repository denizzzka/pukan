# AGENTS.md

## Comments Policy

- The project language is English.
- Keep comments short: max two lines.
- Add a comment ONLY if the code cannot be understood without it.
- Do NOT restate values, names, or constants already defined in the documented entity.
  - Bad: `// timeout = 30` above `const TIMEOUT = 30`.
  - Reason: when the value changes, the comment goes stale and misleads.
- Never duplicate identifiers, default values, ranges, or type info already visible in the signature or declaration.
- Prefer self-documenting code (clear names, small functions) over explanatory comments.
- If a comment is needed, explain WHY, not WHAT.

## Editing Existing Comments

- Do not leave partially translated or mixed-language comments behind.
- If the comment becomes unnecessary after refactoring, delete it instead of rewriting.

## D language-specific code features
- Use whenever possible: templates, ranges, compile-time evaluation, conditional compilation.
- The colon in imports should be placed on the left side: "import std.algorithm: min, max, sort, map;".
- Don't forget that floating-point types are initialized to NaN by default.
- Write idiomatically.
