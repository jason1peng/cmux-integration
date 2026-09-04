#!/usr/bin/env python3
"""Validate a displayed local read-only command without executing it.

The command policy is the single owner for routine supervisor approvals.  It
models the shell boundary before parsing: only standalone ``&&`` may compose
commands, expansion/control syntax is rejected, and each supported command has
an explicit read-only subcommand/option grammar.  Paths are canonicalized
beneath the caller supplied cwd and declared scope, including symlink targets.
Git approvals also pass a bounded non-executing config preflight; configured
external/diff-driver diff, fsmonitor, pager, textconv/filter, hook, and
repository-redirect helpers fail closed instead of running behind an approved
command.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shlex
import sys
from typing import Iterable

POLICY = "routine-command-v2"
SCHEMA_VERSION = 1
MAX_COMMAND_BYTES = 8192
MAX_SEGMENTS = 8

DIRECT_PROGRAMS = {"pwd", "ls", "find", "rg", "grep", "cat", "head", "tail", "sed", "echo", "printf"}
GIT_PROGRAM = "git"
GIT_SUBCOMMANDS = {"status", "diff", "log", "show", "rev-parse", "branch", "ls-files"}

# Explicit per-command option sets.  Unknown options fail closed; there is no
# deny-list fallback that could accidentally admit a newly added write mode.
SIMPLE_OPTIONS = {
    "cat": {"-n", "--number", "-b", "--number-nonblank", "-s", "--squeeze-blank", "-v", "-E", "-T", "-A"},
    "head": {"-q", "--quiet", "-v", "--verbose"},
    "tail": {"-q", "--quiet", "-v", "--verbose"},
}
VALUE_OPTIONS = {
    "head": {"-n", "--lines", "-c", "--bytes"},
    "tail": {"-n", "--lines", "-c", "--bytes"},
    "grep": {"-e", "--regexp", "-m", "--max-count", "--include", "--exclude"},
    "rg": {"-e", "--regexp", "-m", "--max-count", "-g", "--glob"},
}
PATTERN_OPTIONS = {
    "grep": {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-E", "--extended-regexp", "-H", "--with-filename", "-h", "--no-filename", "-I", "--binary-files=without-match", "-w", "--word-regexp", "-x", "--line-regexp", "-q", "--quiet", "--silent"},
    # Hidden/no-ignore traversal can expose credential files under a broad
    # checkout scope; keep routine search on the default visibility boundary
    # and require explicit escalation for those modes.
    "rg": {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-E", "--regexp", "-H", "--with-filename", "-h", "--no-filename", "-I", "--files-with-matches", "-l", "--files-without-match", "--count", "-c", "-w", "--word-regexp", "-x", "--line-regexp", "-q", "--quiet", "--stats"},
}
LS_SHORT_OPTIONS = set("aA1ldhFfrtSUXvigo")
LS_LONG_OPTIONS = {
    "--all", "--almost-all", "--author", "--classify", "--directory",
    "--full-time", "--group-directories-first", "--human-readable", "--inode",
    "--numeric-uid-gid", "--size", "--time-style=full-iso",
}
LS_LONG_PREFIXES = ("--color=", "--format=", "--quoting-style=", "--sort=", "--time=")

GIT_GLOBAL_OPTIONS = {"--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects"}
GIT_OPTIONS = {
    "status": {"--short", "-s", "--porcelain", "--branch", "-b", "--show-stash", "--ahead-behind", "--no-ahead-behind", "--renames", "--no-renames", "--untracked-files", "--ignored", "--column"},
    "diff": {"--stat", "--shortstat", "--numstat", "--name-only", "--name-status", "--check", "--summary", "--raw", "--patch", "-p", "--no-patch", "-s", "--no-ext-diff", "--no-textconv", "--submodule", "--color", "--no-color", "--word-diff", "--minimal", "--merge-base", "--relative", "--ignore-space-change", "--ignore-all-space", "--ignore-space-at-eol", "--ignore-blank-lines"},
    "log": {"-1", "-2", "-3", "--max-count", "-n", "--oneline", "--stat", "--shortstat", "--name-only", "--name-status", "--decorate", "--no-decorate", "--graph", "--all", "--first-parent", "--no-merges", "--reverse", "--patch", "-p", "--no-patch", "--format", "--pretty", "--abbrev-commit", "--date", "--color", "--no-color"},
    # `git show --textconv` may invoke a configured external converter; only
    # the explicit no-textconv form is safe for a non-executing policy gate.
    "show": {"--stat", "--shortstat", "--numstat", "--name-only", "--name-status", "--format", "--pretty", "--oneline", "--patch", "-p", "--no-patch", "--raw", "--color", "--no-color", "--no-textconv", "--submodule"},
    "rev-parse": {"--show-toplevel", "--show-prefix", "--is-inside-work-tree", "--is-inside-git-dir", "--verify", "--quiet", "-q", "--short", "--abbrev-ref", "--symbolic", "--symbolic-full-name", "--show-cdup", "--show-super-prefix"},
    "branch": {"--show-current", "--list", "-l", "--all", "-a", "--remotes", "-r", "--verbose", "-v", "--no-color", "--color", "--contains", "--no-contains", "--merged", "--no-merged", "--sort", "--column"},
    "ls-files": {"--cached", "-c", "--deleted", "-d", "--modified", "-m", "--others", "-o", "--ignored", "-i", "--stage", "-s", "--directory", "--no-empty-directory", "--empty-directory", "--killed", "-k", "--unmerged", "-u", "--exclude-standard", "--full-name", "--error-unmatch", "--eol", "--deduplicate", "--recurse-submodules"},
}

# Options with a separate value.  Values are constrained by the command's
# grammar below; options with a form such as --foo=value are handled there.
GIT_VALUE_OPTIONS = {
    "status": {"--untracked-files", "--ignored", "--column", "--porcelain"},
    "diff": {"--unified", "-U", "--inter-hunk-context", "--diff-algorithm", "--submodule", "--color"},
    "log": {"--max-count", "-n", "--format", "--pretty", "--date", "--decorate", "--color"},
    "show": {"--format", "--pretty", "--color", "--submodule"},
    "branch": {"--contains", "--no-contains", "--merged", "--no-merged", "--sort", "--column", "--color"},
}
# Git spells these values as optional ``--option[=<value>]`` arguments.  A
# following word is therefore an operand, not an implicit value.  Treating it
# as required would hide an out-of-scope status path (for example
# ``git status --column /private/tmp/outside``) from the path validator.
GIT_OPTIONAL_VALUE_OPTIONS = {
    "status": {"--untracked-files", "--ignored", "--column", "--porcelain"},
    "diff": {"--submodule", "--color"},
    "log": {"--decorate", "--color"},
    "show": {"--color", "--submodule"},
    "branch": {"--column", "--color"},
}

SHELL_PUNCTUATION = {";", "|", "||", "&", "<", ">", "(", ")"}
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
INTEGER_RE = re.compile(r"^[+-]?[0-9]+$")
SAFE_SED_SCRIPT_RE = re.compile(r"^(?:[0-9]+(?:,[0-9]+)?|\$|/[^/\r\n]*/)(?:p|!p)?$")
MAX_FIND_DEPTH = 64
SENSITIVE_PATH_COMPONENTS = {
    ".env", ".ssh", ".aws", ".config", ".netrc", ".npmrc", ".pypirc", ".docker", ".kube",
    "credentials", "credential", "secrets", "secret", "token", "tokens", "api-key", "api_key", "apikey",
    "private-key", "private_key", "id_rsa", "id_dsa", "id_ecdsa",
    "id_ed25519", "known_hosts",
}

# Git read commands are still executable programs.  A command-text allowlist
# cannot make a configured helper safe, so the policy performs a bounded,
# non-executing config preflight before approving one.  Values outside these
# explicit disabled spellings are treated as active helpers and rejected.
GIT_CONFIG_MAX_BYTES = 1024 * 1024
GIT_CONFIG_FALSE_VALUES = {"", "false", "no", "off", "0", "none"}
GIT_REPO_OVERRIDE_ENV = {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_GRAFT_FILE", "GIT_REPLACE_REF_BASE", "GIT_NAMESPACE",
    "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
}
GIT_HELPER_ENV = {
    "GIT_EXTERNAL_DIFF", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_PROXY_COMMAND",
    "GIT_ASKPASS", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
}
GIT_CONFIG_SECTION_RE = re.compile(
    r'^\[([A-Za-z0-9][A-Za-z0-9.-]*)(?:\s+"((?:[^"\\]|\\.)*)")?\]$'
)
GIT_CONFIG_KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]*$")


def _config_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
    return value.strip().casefold()


def _read_git_config(path: pathlib.Path) -> tuple[list[tuple[str, str | None, str, str]], str | None]:
    """Read only the small Git config grammar needed for helper detection."""
    try:
        if not path.is_file():
            return [], "git configuration is not a regular readable file"
        if path.stat().st_size > GIT_CONFIG_MAX_BYTES:
            return [], "git configuration is too large to inspect safely"
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return [], "git configuration cannot be inspected safely"
    entries: list[tuple[str, str | None, str, str]] = []
    section: str | None = None
    subsection: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        # Git conventionally indents keys; parse the stripped key/value while
        # rejecting any continuation whose value cannot be represented as a
        # normal bounded key below.
        section_match = GIT_CONFIG_SECTION_RE.fullmatch(line)
        if section_match:
            section = section_match.group(1).casefold()
            subsection = section_match.group(2)
            if subsection is not None:
                subsection = subsection.casefold()
            continue
        if section is None:
            return [], "git configuration has a key outside a section"
        if "=" in line:
            key, value = (part.strip() for part in line.split("=", 1))
        else:
            key, value = line, ""
        if not GIT_CONFIG_KEY_RE.fullmatch(key):
            return [], "git configuration contains an unmodelled key"
        entries.append((section, subsection, key.casefold(), value))
    return entries, None


def _gitdir_config_paths(cwd: pathlib.Path) -> tuple[list[tuple[pathlib.Path, bool]], str | None]:
    """Locate repository/common/worktree config without invoking Git."""
    current = cwd
    while True:
        dotgit = current / ".git"
        try:
            if dotgit.is_dir():
                gitdir = dotgit.resolve(strict=True)
            elif dotgit.is_file():
                lines = dotgit.read_text(encoding="utf-8").splitlines()
                if len(lines) != 1 or not lines[0].casefold().startswith("gitdir:"):
                    return [], "git directory pointer is malformed"
                target = lines[0].split(":", 1)[1].strip()
                if not target:
                    return [], "git directory pointer is empty"
                gitdir = pathlib.Path(target)
                if not gitdir.is_absolute():
                    gitdir = current / gitdir
                gitdir = gitdir.resolve(strict=True)
            else:
                gitdir = None
        except (OSError, UnicodeError, RuntimeError):
            return [], "git directory cannot be inspected safely"
        if gitdir is not None:
            paths: list[tuple[pathlib.Path, bool]] = []
            common_dir = gitdir
            commondir = gitdir / "commondir"
            if commondir.is_file():
                try:
                    relative = commondir.read_text(encoding="utf-8").strip()
                except (OSError, UnicodeError):
                    return [], "git common directory cannot be inspected safely"
                if not relative or any(char in relative for char in ("\n", "\r", "\x00")):
                    return [], "git common directory pointer is malformed"
                try:
                    common_dir = (gitdir / relative).resolve(strict=True)
                except (OSError, RuntimeError):
                    return [], "git common directory cannot be inspected safely"
            paths.append((common_dir / "config", True))
            # Worktree config is optional and only active when Git created it.
            paths.append((gitdir / "config.worktree", False))
            return paths, None
        if current.parent == current:
            break
        current = current.parent
    return [], None


def _git_config_paths(cwd: pathlib.Path) -> tuple[list[tuple[pathlib.Path, bool]], str | None]:
    paths, error = _gitdir_config_paths(cwd)
    if error:
        return [], error

    def configured_path(name: str, default: pathlib.Path | None, *, required: bool = False) -> tuple[pathlib.Path | None, bool, str | None]:
        raw = os.environ.get(name)
        if raw is None:
            return default, required, None
        if raw in {os.devnull, "/dev/null"}:
            return None, False, None
        candidate = pathlib.Path(raw)
        if not candidate.is_absolute():
            return None, False, f"{name} is not an absolute path"
        return candidate, True, None

    nosystem = os.environ.get("GIT_CONFIG_NOSYSTEM", "").casefold() not in {"", "0", "false", "no"}
    if not nosystem:
        system, required, error = configured_path("GIT_CONFIG_SYSTEM", pathlib.Path("/etc/gitconfig"))
        if error:
            return [], error
        if system is not None:
            paths.append((system, required))

    if "GIT_CONFIG_GLOBAL" in os.environ:
        global_path, required, error = configured_path("GIT_CONFIG_GLOBAL", None)
        if error:
            return [], error
        if global_path is not None:
            paths.append((global_path, required))
    else:
        home = os.environ.get("HOME")
        if home:
            home_path = pathlib.Path(home)
            if not home_path.is_absolute():
                return [], "HOME is not an absolute path"
            paths.extend(((home_path / ".gitconfig", False), (home_path / ".config" / "git" / "config", False)))
        xdg = os.environ.get("XDG_CONFIG_HOME")
        if xdg:
            xdg_path = pathlib.Path(xdg)
            if not xdg_path.is_absolute():
                return [], "XDG_CONFIG_HOME is not an absolute path"
            paths.append((xdg_path / "git" / "config", False))

    # Config injected through environment key/value pairs is not safely
    # inspectable here.  Reject it rather than allowing a hidden helper.
    if os.environ.get("GIT_CONFIG_PARAMETERS") or os.environ.get("GIT_CONFIG"):
        return [], "Git configuration environment overrides are not bounded"
    count = os.environ.get("GIT_CONFIG_COUNT")
    if count and count != "0":
        return [], "Git configuration environment overrides are not bounded"
    if any(key.startswith("GIT_CONFIG_KEY_") or key.startswith("GIT_CONFIG_VALUE_") for key in os.environ):
        return [], "Git configuration environment overrides are not bounded"
    return paths, None


def git_execution_boundary_error(cwd: pathlib.Path, subcommand: str, words: list[str]) -> str | None:
    """Reject Git commands whose active config could execute a helper.

    This check never calls Git or the configured helper.  It is intentionally
    conservative: an unreadable/ambiguous config is an escalation, while a
    command with an explicit disabling option may proceed for the matching
    helper class.
    """
    if any(os.environ.get(name) for name in GIT_REPO_OVERRIDE_ENV):
        return "git execution boundary rejects repository environment overrides"
    no_ext_diff = "--no-ext-diff" in words
    no_textconv = "--no-textconv" in words
    no_pager = "--no-pager" in words
    if subcommand in {"diff", "log", "show"} and not no_ext_diff and os.environ.get("GIT_EXTERNAL_DIFF"):
        return "git execution boundary rejects GIT_EXTERNAL_DIFF"
    if subcommand in {"diff", "log", "show"} and not no_textconv and os.environ.get("GIT_TEXTCONV"):
        return "git execution boundary rejects GIT_TEXTCONV"
    if subcommand not in {"rev-parse"} and not no_pager and any(os.environ.get(name) for name in ("GIT_PAGER", "PAGER")):
        return "git execution boundary rejects configured pager environment"
    if any(os.environ.get(name) for name in GIT_HELPER_ENV):
        return "git execution boundary rejects configured Git helper environment"

    config_paths, path_error = _git_config_paths(cwd)
    if path_error:
        return f"git execution boundary rejects uninspectable configuration: {path_error}"
    for path, required in config_paths:
        try:
            exists = path.exists()
        except OSError:
            return "git execution boundary rejects uninspectable configuration"
        if not exists:
            if required:
                return "git execution boundary rejects missing repository configuration"
            continue
        entries, error = _read_git_config(path)
        if error:
            return f"git execution boundary rejects uninspectable configuration: {error}"
        for section, subsection, key, raw_value in entries:
            value = _config_value(raw_value)
            if not value:
                continue
            if section in {"include", "includeif"} and key == "path":
                return "git execution boundary rejects configured Git includes"
            if section == "core" and key == "fsmonitor" and subcommand in {"status", "diff"} and value not in GIT_CONFIG_FALSE_VALUES:
                return "git execution boundary rejects configured core.fsmonitor"
            if section == "diff" and key == "external" and subcommand in {"diff", "log", "show"} and not no_ext_diff:
                return "git execution boundary rejects configured diff.external"
            if section == "diff" and subsection is not None and key == "command" and subcommand in {"diff", "log", "show"}:
                # A diff driver command is selected by repository attributes,
                # so a plain `git diff -- path` can execute it even though the
                # command text contains no helper.  There is no safe command
                # spelling that disables one configured driver selectively;
                # fail closed for every configured driver command.
                return "git execution boundary rejects configured diff driver command"
            if section == "diff" and key == "textconv" and subcommand in {"diff", "log", "show"} and not no_textconv:
                return "git execution boundary rejects configured diff textconv"
            if section == "filter" and key in {"clean", "smudge", "process"} and subcommand in {"diff", "log", "show", "status"}:
                return "git execution boundary rejects configured filter helper"
            if section == "core" and key == "hookspath":
                return "git execution boundary rejects configured hooksPath"
            if section == "core" and key == "pager" and subcommand != "rev-parse" and not no_pager:
                return "git execution boundary rejects configured core.pager"
            if section == "pager" and subcommand != "rev-parse" and not no_pager:
                return "git execution boundary rejects configured pager helper"
    return None


def output(decision: str, category: str, command: str, reason: str, *, segments: int | None = None) -> dict[str, object]:
    value: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "policy": POLICY,
        "decision": decision,
        "category": category,
        "command": command,
        "reason": reason,
    }
    if segments is not None:
        value["segments"] = segments
    return value


def reject(command: str, reason: str, category: str = "ambiguous") -> int:
    print(json.dumps(output("escalate", category, command, reason), separators=(",", ":")))
    return 2


def has_unmodelled_expansion(command: str) -> str | None:
    """Reject syntax the invoked shell could expand before a program sees it.

    This validator deliberately does not attempt to emulate shell expansion.
    Rejecting the complete family (including quoted-looking forms) is safer for
    displayed-command approval than approving a string whose quoting differs
    between shells or TUI transports.
    """
    if any(ord(char) < 0x20 or ord(char) == 0x7f for char in command):
        return "control characters are not allowed"
    if any(char in command for char in ("\n", "\r", "`", "$", "~", "{", "}", "*", "?", "[", "]", "#", "!")):
        return "tilde, brace, glob, comment, command substitution, or interpolation is not modeled"
    return None


def tokenize(command: str) -> tuple[list[list[str]] | None, str | None]:
    if not isinstance(command, str) or not command:
        return None, "command is empty"
    try:
        if len(command.encode("utf-8")) > MAX_COMMAND_BYTES:
            return None, f"command exceeds {MAX_COMMAND_BYTES} bytes"
    except UnicodeEncodeError:
        return None, "command is not valid UTF-8"
    expansion_error = has_unmodelled_expansion(command)
    if expansion_error:
        return None, expansion_error
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except (ValueError, TypeError):
        return None, "command quoting is malformed"
    if not tokens:
        return None, "command is empty"
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token == "&&":
            if not current:
                return None, "empty command in bundle"
            segments.append(current)
            current = []
            continue
        if token in SHELL_PUNCTUATION or "&&" in token:
            return None, "only standalone && may join read-only commands"
        current.append(token)
    if not current:
        return None, "bundle cannot end with &&"
    segments.append(current)
    if len(segments) > MAX_SEGMENTS:
        return None, f"bundle exceeds {MAX_SEGMENTS} commands"
    return segments, None


def normalize_relative(cwd: pathlib.Path, raw: str) -> str | None:
    if not isinstance(raw, str) or not raw or raw == "-":
        return None
    if any(ord(char) < 0x20 or ord(char) == 0x7F or char in {"\u2028", "\u2029"} for char in raw):
        return None
    # Do not ask pathlib to interpret shell-like path syntax or traversal.
    if any(char in raw for char in "~{}*?[]") or "\\" in raw:
        return None
    path = pathlib.PurePath(raw)
    if not os.path.isabs(raw) and ".." in path.parts:
        return None
    candidate = pathlib.Path(raw) if os.path.isabs(raw) else cwd / raw
    try:
        resolved = candidate.resolve(strict=False)
        relative = resolved.relative_to(cwd)
    except (OSError, RuntimeError, ValueError):
        return None
    return relative.as_posix() or "."


def scope_covers_root(cwd: pathlib.Path, scopes: list[str]) -> bool:
    return any(normalize_relative(cwd, scope) == "." for scope in scopes)


def in_scope(cwd: pathlib.Path, scopes: Iterable[str], raw: str) -> bool:
    relative = normalize_relative(cwd, raw)
    if relative is None:
        return False
    for scope in scopes:
        normalized = normalize_relative(cwd, scope)
        if normalized is None:
            continue
        if normalized == "." or relative == normalized or relative.startswith(normalized.rstrip("/") + "/"):
            return True
    return False


def validate_paths(cwd: pathlib.Path, scopes: list[str], paths: Iterable[str]) -> tuple[bool, str | None]:
    for path in paths:
        if not in_scope(cwd, scopes, path):
            return False, f"path is outside the declared scope: {path}"
    return True, None


def parse_option_value(word: str, options: set[str]) -> tuple[str, str | None] | None:
    for option in options:
        if word == option:
            return option, None
        if word.startswith(option + "="):
            return option, word.split("=", 1)[1]
    return None


def validate_numeric(value: str | None, label: str) -> str | None:
    if value is None or not INTEGER_RE.fullmatch(value):
        return f"{label} value is missing or invalid"
    try:
        bounded = abs(int(value)) <= 1000000
    except (OverflowError, ValueError):
        bounded = False
    return None if bounded else f"{label} value is missing or invalid"


def validate_ls(words: list[str], cwd: pathlib.Path, scopes: list[str]) -> str | None:
    paths: list[str] = []
    options_ended = False
    for word in words[1:]:
        if not options_ended and word == "--":
            options_ended = True
            continue
        if not options_ended and word.startswith("--"):
            if word not in LS_LONG_OPTIONS and not any(word.startswith(prefix) and len(word) > len(prefix) for prefix in LS_LONG_PREFIXES):
                return "ls option is outside the bounded read-only allowlist"
            continue
        if not options_ended and word.startswith("-"):
            if word == "-":
                return "stdin is not a bounded path"
            if not word[1:] or not all(char in LS_SHORT_OPTIONS for char in word[1:]):
                return "ls option is outside the bounded read-only allowlist"
            continue
        paths.append(word)
    if not paths:
        return None if scope_covers_root(cwd, scopes) else "ls without a path requires an explicit checkout-wide scope"
    ok, reason = validate_paths(cwd, scopes, paths)
    return reason if not ok else None


def validate_file_reader(words: list[str], cwd: pathlib.Path, scopes: list[str], program: str) -> str | None:
    paths: list[str] = []
    index = 1
    while index < len(words):
        word = words[index]
        if word == "--":
            paths.extend(words[index + 1 :])
            break
        if word == "-" or (program == "tail" and word in {"-f", "--follow", "-F", "--retry"}):
            return "stdin/follow modes are not bounded"
        # head/tail accept the common attached short numeric forms (`-n20`,
        # `-c-1`) as well as the separated forms handled below.
        if program in {"head", "tail"} and len(word) > 2 and word[:2] in {"-n", "-c"}:
            reason = validate_numeric(word[2:], word[:2])
            if reason:
                return reason
            index += 1
            continue
        value_options = VALUE_OPTIONS.get(program, set())
        parsed = parse_option_value(word, value_options)
        if parsed:
            option, value = parsed
            if value is None:
                if index + 1 >= len(words):
                    return f"{option} value is missing"
                value = words[index + 1]
                index += 1
            reason = validate_numeric(value, option)
            if reason:
                return reason
            index += 1
            continue
        if word.startswith("-"):
            if word not in SIMPLE_OPTIONS.get(program, set()):
                return "file-inspection option is outside the read-only allowlist"
            index += 1
            continue
        paths.append(word)
        index += 1
    if not paths:
        return "file-inspection command has no declared path"
    ok, reason = validate_paths(cwd, scopes, paths)
    return reason if not ok else None


def validate_pattern(words: list[str], cwd: pathlib.Path, scopes: list[str], program: str) -> str | None:
    options = PATTERN_OPTIONS[program]
    value_options = VALUE_OPTIONS[program]
    operands: list[str] = []
    pattern_seen = False
    options_ended = False
    index = 1
    while index < len(words):
        word = words[index]
        if not options_ended and word == "--":
            options_ended = True
            index += 1
            continue
        if not options_ended:
            parsed = parse_option_value(word, value_options)
            if parsed:
                option, value = parsed
                if value is None:
                    if index + 1 >= len(words):
                        return "pattern option value is missing"
                    value = words[index + 1]
                    index += 1
                if option in {"-e", "--regexp"}:
                    pattern_seen = True
                elif option in {"-m", "--max-count"}:
                    reason = validate_numeric(value, option)
                    if reason:
                        return reason
                index += 1
                continue
            if word.startswith("--") and any(word.startswith(prefix) for prefix in ("--include=", "--exclude=", "--glob=", "--max-count=")):
                index += 1
                continue
            if word.startswith("-"):
                if word not in options:
                    return "pattern command option is outside the read-only allowlist"
                index += 1
                continue
        if not pattern_seen:
            pattern_seen = True
        else:
            operands.append(word)
        index += 1
    if not pattern_seen:
        return "pattern command has no search pattern"
    if not operands:
        return "pattern command has no declared path"
    ok, reason = validate_paths(cwd, scopes, operands)
    return reason if not ok else None


def validate_find(words: list[str], cwd: pathlib.Path, scopes: list[str]) -> str | None:
    if len(words) < 2:
        return "find has no declared root"
    root = words[1]
    if root == "-" or not in_scope(cwd, scopes, root):
        return "find root is outside the declared scope"
    index = 2
    while index < len(words):
        word = words[index]
        if word in {"-maxdepth", "-mindepth"}:
            if index + 1 >= len(words) or not re.fullmatch(r"[0-9]+", words[index + 1]) or int(words[index + 1]) > MAX_FIND_DEPTH:
                return "find depth must be a bounded non-negative integer"
            index += 2
            continue
        if word in {"-name", "-iname", "-path", "-ipath", "-regex", "-iregex"}:
            if index + 1 >= len(words) or not words[index + 1] or len(words[index + 1]) > 512:
                return "find pattern is missing or too long"
            index += 2
            continue
        if word == "-type":
            if index + 1 >= len(words) or words[index + 1] not in set("bcdflps"):
                return "find type predicate is outside the safe allowlist"
            index += 2
            continue
        if word in {"-print", "-print0", "-depth", "-xdev"}:
            index += 1
            continue
        return "find action/operator is outside the read-only allowlist"
    return None


def validate_sed(words: list[str], cwd: pathlib.Path, scopes: list[str]) -> str | None:
    scripts: list[str] = []
    paths: list[str] = []
    index = 1
    while index < len(words):
        word = words[index]
        if word == "--":
            paths.extend(words[index + 1 :])
            break
        if word in {"-n", "--quiet", "--silent", "-E", "-r", "--regexp-extended"}:
            index += 1
            continue
        if word in {"-e", "--expression"}:
            if index + 1 >= len(words):
                return "sed expression is missing"
            scripts.append(words[index + 1])
            index += 2
            continue
        if word in {"-i", "--in-place", "-f", "--file"} or word.startswith("-i"):
            return "sed write/injected-script options are not allowed"
        if word.startswith("-"):
            return "sed option is outside the read-only allowlist"
        if not scripts:
            scripts.append(word)
        else:
            paths.append(word)
        index += 1
    if not scripts or not all(SAFE_SED_SCRIPT_RE.fullmatch(script) for script in scripts):
        return "sed script is not a bounded print-only expression"
    if not paths:
        return "sed has no declared path"
    ok, reason = validate_paths(cwd, scopes, paths)
    return reason if not ok else None


def git_words(words: list[str]) -> tuple[str | None, list[str], str | None]:
    index = 1
    while index < len(words) and words[index].startswith("-"):
        word = words[index]
        if word in {"-C", "-c", "--config-env"} or word.startswith(("-C", "--git-dir", "--work-tree", "--exec-path", "--config")):
            return None, [], "git global option can change checkout/configuration"
        if word not in GIT_GLOBAL_OPTIONS:
            return None, [], "git global option is outside the read-only allowlist"
        index += 1
    if index >= len(words):
        return None, [], "git subcommand is missing"
    return words[index], words[index + 1 :], None


def option_and_values(args: list[str], subcommand: str) -> tuple[list[str], list[str], str | None]:
    """Split options and operands while enforcing an explicit option grammar."""
    allowed = GIT_OPTIONS[subcommand]
    values = GIT_VALUE_OPTIONS.get(subcommand, set())
    options: list[str] = []
    operands: list[str] = []
    index = 0
    after_separator = False
    while index < len(args):
        word = args[index]
        if not after_separator and word == "--":
            after_separator = True
            index += 1
            continue
        if after_separator:
            operands.append(word)
            index += 1
            continue
        if word.startswith("-"):
            parsed = parse_option_value(word, values)
            if parsed:
                option, value = parsed
                if value is None:
                    if option in GIT_OPTIONAL_VALUE_OPTIONS.get(subcommand, set()):
                        # Optional Git values are only accepted in the
                        # ``--option=value`` spelling. Leave the next word
                        # available for operand/scope validation.
                        options.append(option)
                        index += 1
                        continue
                    if index + 1 >= len(args):
                        return [], [], f"git {subcommand} option value is missing"
                    value = args[index + 1]
                    index += 1
                # Values are intentionally bounded; format strings may not
                # contain controls or expansion syntax (already rejected).
                if not value or len(value) > 512:
                    return [], [], f"git {subcommand} option value is malformed"
                if subcommand == "status" and option == "--porcelain" and value not in {"v1", "v2"}:
                    return [], [], "git status porcelain version is unsupported"
                options.append(option + "=" + value)
                index += 1
                continue
            if word not in allowed:
                return [], [], f"git {subcommand} option is outside the read-only allowlist"
            options.append(word)
            index += 1
            continue
        # A non-option before -- is a ref/revision operand.  It is accepted for
        # diff/log/show/rev-parse only under the subcommand checks below.
        operands.append(word)
        index += 1
    return options, operands, None


def validate_git_path_operands(cwd: pathlib.Path, scopes: list[str], paths: Iterable[str]) -> str | None:
    for path in paths:
        # Git pathspec magic (`:()`, `!`, and `^`) changes the meaning of a
        # path independently of the checkout-relative scope calculation.
        if path.startswith((":", "!", "^")) or ":(" in path:
            return "git pathspec magic is outside the bounded local form"
    ok, path_reason = validate_paths(cwd, scopes, paths)
    return path_reason if not ok else None


def validate_git_revision(value: str) -> bool:
    return bool(
        re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,255}", value)
        and ".." not in value
        and not value.endswith("/")
    )


def validate_git(words: list[str], cwd: pathlib.Path, scopes: list[str]) -> str | None:
    subcommand, args, reason = git_words(words)
    if reason:
        return reason
    if subcommand not in GIT_SUBCOMMANDS:
        return "git subcommand is outside the read-only local allowlist"
    options, operands, reason = option_and_values(args, subcommand)
    if reason:
        return reason
    boundary_reason = git_execution_boundary_error(cwd, subcommand, words)
    if boundary_reason:
        return boundary_reason

    # branch is deliberately list-only.  In particular `--` itself, branch
    # names, -m/-M/-c/-C/-d/-D, --edit-description, and upstream-changing
    # options are never accepted as routine commands.
    if subcommand == "branch":
        if "--" in args or operands:
            return "git branch mutating/name-selecting forms are not routine approval"
        return None

    if subcommand == "status":
        if "--" in args and not operands:
            return "git status requires a declared path after --"
        if operands:
            return validate_git_path_operands(cwd, scopes, operands)
        return None if scope_covers_root(cwd, scopes) else "git status without a path requires an explicit checkout-wide scope"

    if subcommand in {"diff", "log", "show", "ls-files"}:
        # `git diff --check` and `git ls-files` without operands are bounded
        # checkout-wide reads when the caller explicitly declared `.`.  Keep
        # revision-bearing diff/log/show forms path-delimited so an unmodeled
        # revision/path expression cannot escape the scope.
        if "--" not in args:
            if subcommand == "diff" and not operands:
                return None if scope_covers_root(cwd, scopes) else "git diff without a path requires an explicit checkout-wide scope"
            if subcommand == "ls-files":
                if not operands:
                    return None if scope_covers_root(cwd, scopes) else "git ls-files without a path requires an explicit checkout-wide scope"
                return validate_git_path_operands(cwd, scopes, operands)
            return f"git {subcommand} must name declared paths after --"
        separator_index = args.index("--")
        pre_separator = args[:separator_index]
        path_operands = args[separator_index + 1 :]
        if not path_operands:
            return f"git {subcommand} has no declared path"
        _, pre_operands, pre_reason = option_and_values(pre_separator, subcommand)
        if pre_reason:
            return pre_reason
        for operand in pre_operands:
            if not validate_git_revision(operand):
                return f"git {subcommand} revision is outside the bounded local form"
        return validate_git_path_operands(cwd, scopes, path_operands)

    if subcommand == "rev-parse":
        if "--" in args:
            return "git rev-parse does not accept a path separator"
        for operand in operands:
            if not validate_git_revision(operand):
                return "git rev-parse operand is outside the bounded local form"
        return None
    return "git subcommand is outside the read-only local allowlist"


def validate_direct(words: list[str], cwd: pathlib.Path, scopes: list[str]) -> str | None:
    program = words[0]
    if program not in DIRECT_PROGRAMS:
        return "program is outside the read-only local allowlist"
    if ASSIGNMENT_RE.match(program) or "/" in program or program in {"source", "."}:
        return "environment assignments and path-qualified programs are not allowed"
    if program == "pwd":
        return None if all(word in {"-L", "-P"} for word in words[1:]) else "pwd option/operand is outside the safe allowlist"
    if program in {"echo", "printf"}:
        # These are literal separators in a supervisor bundle.  Expansion was
        # already rejected, and no path or side effect is involved.
        return None
    if program == "ls":
        return validate_ls(words, cwd, scopes)
    if program == "find":
        return validate_find(words, cwd, scopes)
    if program in {"grep", "rg"}:
        return validate_pattern(words, cwd, scopes, program)
    if program == "sed":
        return validate_sed(words, cwd, scopes)
    return validate_file_reader(words, cwd, scopes, program)


MUTATING_BRANCH_FORMS = {
    "-m", "-M", "-c", "-C", "-d", "-D", "-f", "-u", "-t",
    "--move", "--copy", "--delete", "--force", "--edit-description",
    "--set-upstream", "--set-upstream-to", "--unset-upstream", "--track", "--no-track", "-u",
}


def branch_form_is_mutating(words: list[str]) -> bool:
    if len(words) < 2 or words[1] != "branch":
        return False
    for word in words[2:]:
        option = word.split("=", 1)[0]
        if option in MUTATING_BRANCH_FORMS:
            return True
    return False


def sensitive_path_token(value: str) -> bool:
    """Identify conventional credential files before a read-only approval."""
    if not isinstance(value, str):
        return False
    candidate = value.split("=", 1)[-1].casefold().replace("\\", "/")
    components = [part for part in candidate.split("/") if part]
    sensitive_prefixes = (
        ".env.", "secret", "credential", "token", "api-key", "api_key", "apikey",
        "private-key", "private_key", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
        "known_hosts",
    )
    return any(
        part in SENSITIVE_PATH_COMPONENTS or any(part.startswith(prefix) for prefix in sensitive_prefixes)
        for part in components
    )


def validate(command: str, cwd: pathlib.Path, scopes: list[str]) -> int:
    if not isinstance(scopes, list) or not scopes:
        return reject(command, "declared scope is missing")
    # Validate every declared scope before dispatching by program.  Commands
    # without path operands (for example ``echo``) must not become a way to
    # smuggle an invalid/out-of-checkout scope through the policy boundary.
    for scope in scopes:
        try:
            valid_scope = (
                isinstance(scope, str)
                and bool(scope)
                and len(scope.encode("utf-8")) <= 512
                and normalize_relative(cwd, scope) is not None
            )
        except UnicodeEncodeError:
            valid_scope = False
        if not valid_scope:
            return reject(command, "declared scope is malformed or outside the canonical cwd")
    parsed, reason = tokenize(command)
    if parsed is None:
        return reject(command, reason or "command is malformed")
    for words in parsed:
        if ASSIGNMENT_RE.match(words[0]):
            return reject(command, "environment assignments are not allowed")
        if any(sensitive_path_token(word) for word in words[1:]):
            return reject(command, "credential-like paths require explicit escalation", "credential")
        error = validate_git(words, cwd, scopes) if words[0] == GIT_PROGRAM else validate_direct(words, cwd, scopes)
        if error:
            if words[0] in {"rm", "mv", "cp", "chmod", "chown", "truncate", "kill"} or (
                words[0] == "git" and ("mutating" in error.casefold() or branch_form_is_mutating(words))
            ):
                category = "destructive"
            elif words[0] in {"curl", "wget", "ssh", "scp", "rsync", "nc", "netcat"}:
                category = "external-network"
            else:
                category = "important" if (
                    "allowlist" in error
                    or "mutating" in error
                    or "execution boundary" in error
                ) else "ambiguous"
            return reject(command, error, category)
    print(json.dumps(output("approve", "routine", command, "authoritative bounded read-only local command policy", segments=len(parsed)), separators=(",", ":")))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("validate", choices=["validate"])
    parser.add_argument("--command", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--scope", action="append", default=[])
    args = parser.parse_args()
    if not isinstance(args.cwd, str) or not os.path.isabs(args.cwd) or os.path.realpath(args.cwd) != args.cwd:
        return reject(args.command, "canonical cwd is missing or not a directory")
    try:
        cwd = pathlib.Path(args.cwd).resolve(strict=True)
    except (OSError, RuntimeError):
        return reject(args.command, "canonical cwd is missing or not a directory")
    if not cwd.is_dir() or not cwd.is_absolute() or str(cwd) != args.cwd:
        return reject(args.command, "canonical cwd is missing or not a directory")
    if not args.scope:
        return reject(args.command, "declared scope is missing")
    return validate(args.command, cwd, args.scope)


if __name__ == "__main__":
    raise SystemExit(main())
