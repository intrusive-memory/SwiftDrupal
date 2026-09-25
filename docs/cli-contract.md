# `drupal` CLI contract

The stable, machine-facing surface of the `drupal` binary: output envelope,
exit codes, config schema, and commands. This is the seed of the
tool-shipped agent instructions (requirements item 7 in
[`02-v1-mvp-requirements.md`](requirements/02-v1-mvp-requirements.md)).

Anything listed here is a contract: fields and exit codes are only ever
added, never renumbered or repurposed. Breaking changes bump
`schema_version` (envelope) or `manifest_version` (manifest). Text-mode
output is for people and is **not** part of the contract.

Status: the config commands (`init`, `config`, `validate`,
`describe-commands`) are fully implemented. Every command that needs
containers is wired through the `ContainerRuntime` protocol, whose only
implementation right now fails with `not_implemented` (exit 12).

## Output modes

- **JSON mode** — when stdout is not a TTY, or with `--json`. Every command
  prints exactly **one line** of JSON on stdout: the envelope below. Nothing
  else goes to stdout (exceptions: `logs`, and `exec`/`ssh` in text mode).
- **Text mode** — when stdout is a TTY, or with `--no-json`. Human-readable
  results on stdout; `error:`, `warning:` and `hint:` lines on stderr.

`--json` / `--no-json` are accepted by every command (the last one given
wins). There are no interactive prompts anywhere. The only interactive
command is `ssh`, which refuses to run without a TTY.

## Envelope (`schema_version` 1)

```json
{
  "schema_version": 1,
  "ok": true,
  "command": "validate",
  "data": { "...command-specific...": "..." },
  "warnings": [],
  "error": null
}
```

On failure `ok` is `false`, `data` is `null`, and `error` is an object:

```json
{
  "schema_version": 1,
  "ok": false,
  "command": "validate",
  "data": null,
  "warnings": [],
  "error": {
    "code": "config_invalid",
    "exit_code": 3,
    "message": "/path/.drupal/config.yaml is invalid: line 2, php_version: unsupported php_version '8.0'; expected one of: '8.2', '8.3', '8.4', '8.5'",
    "details": [
      { "path": "php_version", "line": 2, "message": "unsupported php_version '8.0'; expected one of: '8.2', '8.3', '8.4', '8.5'" }
    ],
    "hint": "Fix the file, then run `drupal validate`."
  }
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | int | Envelope schema version. |
| `ok` | bool | `true` iff `error` is `null`. |
| `command` | string | Canonical subcommand name (aliases resolve: `describe` → `status`); `"drupal"` if no subcommand could be identified. |
| `data` | object \| null | Command result; `null` on failure and for commands with no result. |
| `warnings` | string[] | Non-fatal observations (e.g. docroot directory missing). Always present. |
| `error` | object \| null | See below. |
| `error.code` | string | Stable identifier from the exit-code table. Branch on this or the exit code, never on `message`. |
| `error.exit_code` | int | The process exit code. |
| `error.message` | string | One-line human summary. |
| `error.details` | object[] | Every individual problem: `message` always; `path` (dotted config key, e.g. `database.type`, `web_environment[1]`) and `line` (1-based, in the config file) when known — omitted, not `null`, when unknown. |
| `error.hint` | string \| null | Suggested next step. |

Keys are sorted and the line has no embedded newlines, so `jq`, `grep`, or
line-based parsing all work.

## Exit codes

Defined in one place: `ExitStatus` in
`Sources/DrupalKit/Core/ExitStatus.swift`; also emitted by
`describe-commands` as `exit_codes`.

| Code | `error.code` | Meaning |
| --- | --- | --- |
| 0 | `success` | Command succeeded. |
| 1 | `internal_error` | Unexpected internal error (a bug in drupal). |
| 2 | `usage_error` | Invalid flags/arguments (unknown flag, value not in the allowed set), or an impossible combination (`ssh` without a TTY, `export-db` to stdout in JSON mode). |
| 3 | `config_invalid` | The config file (or the config `init`/`config` would write) fails parsing or validation. `error.details` lists every problem. |
| 4 | `project_not_found` | No `.drupal/config.yaml` in the directory or any parent. |
| 5 | `already_exists` | Refused to overwrite a file: `init` over a different config, `export-db` onto an existing file. Pass `--force`. |
| 6 | `platform_unavailable` | Not Apple silicon / macOS 26+, or Containerization unusable. |
| 7 | `container_start_failed` | A container could not be created or started. |
| 8 | `health_timeout` | Containers started but were not healthy within `--timeout`. |
| 9 | `project_not_running` | The command needs a running project (`exec`, `ssh`, `logs`, `import-db`, `export-db`). |
| 10 | `container_operation_failed` | Another runtime operation failed (stop, exec, logs, delete, or the import/export SQL tool exited non-zero). |
| 11 | `io_error` | Reading or writing a local file failed. |
| 12 | `not_implemented` | The command exists in the contract but its runtime is not built yet. |
| 13 | `post_start_failed` | A `post_start` command exited non-zero (containers are left running). |

**`exec` and `ssh` exit with the child process's own exit code** when the
child could be run, as `docker exec` does — so for those two commands a
code in 1–13 may come from the child. In JSON mode, disambiguate with the
envelope: `ok: true` with `data.exit_code` means the child ran and that is
its code; `ok: false` means `drupal` itself failed with `error.code`.

Order of checks when several things are wrong: flag parsing (2) first;
then project lookup (4) and config validation (3); then per-command input
checks (e.g. `import-db --file` unreadable → 11, `export-db` without
`--file` in JSON mode → 2); then the host platform (6); and only then the
runtime (7–10, 12). So an invalid config is reported as 3 even though the
runtime is not implemented yet.

## Config file

Location: **`<project root>/.drupal/config.yaml`**. Commands find it by
walking up from the current directory (or `--project-dir`), as git does
for `.git`. `init` writes it into the current directory (or
`--project-dir`) without walking up.

```yaml
# name: my-site            # optional; default = sanitized directory name
docroot: "web"
php_version: "8.4"
webserver_type: nginx-fpm
database:
  type: mariadb
  version: "11.8"
web_environment: []        # ["KEY=value", ...]
post_start: []             # ["drush cr", ...]
# nodejs_version: "22"     # optional
```

| Key | Type | Default | Accepted values |
| --- | --- | --- | --- |
| `name` | string | derived (see below) | RFC 1123 label: 1–63 of `a-z 0-9 -`, not starting/ending with `-`. Validated, never rewritten. |
| `docroot` | string | `web` | Relative path inside the project; `""` = the project root. No absolute paths, no `..`. |
| `php_version` | string | `8.4` | `8.2`, `8.3`, `8.4`, `8.5` (the versions preinstalled in `ddev-webserver`). |
| `webserver_type` | string | `nginx-fpm` | `nginx-fpm`, `apache-fpm`. |
| `database.type` | string | `mariadb` | `mariadb` only in v1.0. |
| `database.version` | string | `11.8` | `10.6`, `10.11`, `11.4`, `11.8`. |
| `web_environment` | string[] | `[]` | `KEY=value`; `KEY` is `[A-Za-z_][A-Za-z0-9_]*`, unique. |
| `post_start` | string[] | `[]` | Non-empty shell commands, run in order via `bash -c` in the web container after every `start`/`restart`; the first failure stops the list (exit 13). |
| `nodejs_version` | string | image default | `22`, `22.11`, `22.11.0` style. |

Rules:

- Unknown keys are errors (with a "did you mean" suggestion, or an
  explanation for DDEV-only keys such as `xdebug_enabled` or `hooks`).
- A key with an empty/`null` value means "use the default".
- Versions may be quoted or not (`8.3` and `"8.3"` are the same); `init`
  always writes them quoted.
- All problems are reported at once, each with its key path and line.

Derived, never written:

- **Project name**: `name:` if set, else the project directory's name
  sanitized: diacritics stripped and lowercased; every run of characters
  outside `a-z0-9` becomes one `-`; leading/trailing `-` trimmed;
  truncated to 63 characters. `My Pantheon_Site` → `my-pantheon-site`. A
  directory with no letters or digits (e.g. `___`) is `config_invalid`
  until `name:` is set.
- **Hostname**: `<name>.drupal`; **URL**: `http://<name>.drupal`.
- **Images**: `ddev/ddev-webserver:<tag>` and
  `ddev/ddev-dbserver-mariadb-<version>:<tag>`, pinned to DDEV v1.25.4's
  published tags.

## Commands

Run `drupal describe-commands --json` for the authoritative, generated
list with every flag, its type (`boolean`, `integer`, `number`, `string`,
`enum` with `allowed_values`), default, and description. Summary:

| Command | Does | `data` on success |
| --- | --- | --- |
| `init` | Create `.drupal/config.yaml` from defaults + field flags. Same flags again → unchanged, exit 0. Different existing file → exit 5 unless `--force`. | `{action: created\|overwritten\|unchanged, project: <resolved>}` |
| `config` | No field flags: print the resolved config. With field flags: rewrite the file with those fields changed (file comments are not preserved). | `<resolved>`, or `{action: updated\|unchanged, project: <resolved>}` |
| `validate` | Validate and print the resolved config. | `<resolved>` |
| `start` | Start web + db (idempotent), wait `--timeout` seconds (default 120) for health, run `post_start`. | `{project, status, post_start: [{command, exit_code}]}` |
| `stop` | Stop both containers, keeping them and the data (idempotent). | `{project, status}` |
| `restart` | `stop` then `start`. | as `start` |
| `status` (alias `describe`) | Resolved config plus container state. | `{project: <resolved>, status}` |
| `delete` | Remove containers and the database volume (`--keep-data` keeps it). Never touches project files. No prompt; idempotent. | `{project, kept_data}` |
| `exec [--service web\|db] <command...>` | Run a command in a container. | `{service, command, exit_code, stdout, stderr}` (output captured in JSON mode) |
| `ssh [--service web\|db]` | Interactive `bash -l`. TTY only. | — |
| `logs [--service ...] [-f] [--tail N]` | Merged web+db log stream. | `{lines}` (final line) |
| `import-db [--file path]` | Drop, recreate, and load the database from a plain `.sql` file or piped stdin. | `{database, source}` |
| `export-db [--file path] [--force]` | `mysqldump` to a file (or stdout in text mode). | `{database, destination}` |
| `describe-commands` | The command manifest. | the manifest |

Global options on every command: `--json` / `--no-json`, `--project-dir
<path>`.

`<resolved>` is the resolved project:

```json
{
  "name": "my-pantheon-site",
  "name_source": "directory",
  "hostname": "my-pantheon-site.drupal",
  "url": "http://my-pantheon-site.drupal",
  "root": "/Users/me/Sites/my-pantheon-site",
  "config_file": "/Users/me/Sites/my-pantheon-site/.drupal/config.yaml",
  "docroot_path": "/Users/me/Sites/my-pantheon-site/web",
  "config": {
    "name": null, "docroot": "web", "php_version": "8.4",
    "webserver_type": "nginx-fpm",
    "database": {"type": "mariadb", "version": "11.8"},
    "web_environment": [], "post_start": [], "nodejs_version": null
  },
  "defaults_applied": [],
  "images": {"web": "ddev/ddev-webserver:…", "db": "ddev/ddev-dbserver-mariadb-11.8:…"}
}
```

`status` is `{state: running|stopped|partial|absent, services: [{service:
web|db, state: running|stopped|absent, image, ip_address}]}`.

### `logs` in JSON mode

One object per log line, then one final envelope line — the only line with
an `ok` key:

```
{"message":"GET / 200","service":"web","stream":"stdout","timestamp":"2026-09-25T12:00:00.123Z"}
{"message":"ready for connections","service":"db","stream":"stderr","timestamp":"2026-09-25T12:00:01.004Z"}
{"command":"logs","data":{"lines":2},"error":null,"ok":true,"schema_version":1,"warnings":[]}
```

Lines are in timestamp order (arrival order once following). With
`--follow` the stream runs until interrupted and has no final envelope. On
failure the final line is an error envelope.

## Manifest (`manifest_version` 1)

`drupal describe-commands --json` → envelope whose `data` is:

```json
{
  "manifest_version": 1,
  "envelope_schema_version": 1,
  "tool": "drupal",
  "version": "0.1.0-dev",
  "output_default": "…",
  "global_options": [ <argument> ],
  "commands": [
    {"name": "start", "aliases": [], "abstract": "…", "discussion": "…",
     "arguments": [ <argument> ]}
  ],
  "exit_codes": [{"code": 0, "name": "success", "description": "…"}]
}
```

`<argument>` is `{name, kind: flag|option|positional, flags, type,
allowed_values?, repeating, required, default?, value_name?,
description}`. It is generated from the ArgumentParser command tree, not
maintained by hand.

## Common workflows

```bash
# New project in the current directory, then check what will happen
drupal init --php-version 8.3 --json
drupal validate --json

# Bring it up and run Drupal tooling
drupal start --json
drupal exec composer install
drupal exec drush site:install -y

# Database
drupal import-db --file dump.sql --json
drupal export-db --file backup.sql --json

# Logs, as JSON lines
drupal logs --json --tail 100
```
