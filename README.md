# pim: Azure PIM from the terminal

`pim` lists the Azure resource roles you are eligible for through Privileged Identity Management (PIM), shows which ones are active, and lets you activate or deactivate them from the terminal. It works on its own, and it integrates with [herdr](https://herdr.dev): a popup picker on a key, the active roles and time left in the status bar, and notifications before an activation expires.

```
 PIM   42 roles · ● 1 active                              updated just now
 › orders dev
   ROLE         SCOPE                SUBSCRIPTION        EXPIRES
 ▌   ● Contributor  rg-orders-dev        Contoso-NonProd     7h12m
     ○ Contributor  rg-orders-devtest    Contoso-NonProd
 ↑↓ move · tab select · enter activate · ^d deactivate · ^r refresh · esc quit
```

- **Fast:** cached data renders instantly while a background refresh fetches current state. The four Azure lists are fetched in parallel.
- **Respects your PIM policies:** each role's maximum duration, justification requirement and approval requirement are read from its policy. Azure still validates every request.
- **Safe by default:** a filter that matches several roles never activates them unless you pass `--all`. Tokens are never stored, and output is sanitized.
- **Single binary:** no runtime to install. The only external tool is the Azure CLI.

## Requirements

- [Azure CLI](https://aka.ms/azure-cli), signed in with `az login`. `pim` asks it for an access token to Azure Resource Manager.
- Optional: [herdr](https://herdr.dev) 0.9.1 or later, for the popup, status bar and notifications.
- Only to build from source: [Zig](https://ziglang.org) **0.16.0**.

## Install

### From source

```sh
git clone <this repository> herdr-pim && cd herdr-pim

# Zig 0.16.0: pinned in mise.toml, so with mise:
mise trust && mise install
# ...or install Zig 0.16.0 another way (brew install zig, ziglang.org/download)

zig build -Doptimize=ReleaseSafe install --prefix ~/.local    # installs ~/.local/bin/pim
pim version
```

The first build downloads [libvaxis](https://github.com/rockorager/libvaxis) (the terminal UI library) and its dependencies from GitHub. They are pinned to a commit and verified by hash. Building takes under a minute.

### From a prebuilt binary

Builds can be cross-compiled for other platforms from any machine with Zig:

```sh
zig build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=aarch64-macos --prefix out/mac-arm64
zig build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=x86_64-macos --prefix out/mac-x64
zig build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=x86_64-linux-musl --prefix out/linux-x64
```

`-Dstrip=true` drops debug information, which keeps the Linux binaries small (a few MB instead of about 10 MB).

Put the binary somewhere on your `PATH`, for example `~/.local/bin/pim`. macOS quarantines files received through a browser, Teams or Slack. Clear that once:

```sh
xattr -d com.apple.quarantine ~/.local/bin/pim
```

## Getting started

```sh
az login
pim ls                      # all eligible roles and their state
pim                         # interactive picker (in a terminal)
pim up rg-orders-dev -d 2h -j "Investigating failed deployment"
pim down rg-orders-dev
```

### Commands

| Command | What it does |
|---|---|
| `pim [pick] [FILTER...] [-d DURATION]` | Interactive picker. The default in a terminal; `FILTER` pre-fills the search. |
| `pim ls [FILTER...] [--json] [--refresh \| --cached]` | Table (or JSON) of eligible roles. The default when output is not a terminal. |
| `pim up FILTER... [-d D] [-j TEXT] [--all] [--no-wait]` | Activate. Waits until Azure has applied the change, up to 2 minutes. |
| `pim down (FILTER... \| --all) [--no-wait]` | Deactivate. Azure allows this 5 minutes after activation at the earliest. |
| `pim status [--notify] [--max-age S]` | One line for status bars, e.g. `PIM 2 · 3h05m`. Prints nothing when nothing is active. |

How filters and options work:
- `FILTER` terms match the scope, subscription or role name, case-insensitively, and all terms must match.
- An exact scope name wins over partial matches.
- Durations look like `8h`, `90m`, `1h30m` or `PT8H`. The default is 8 hours, shortened to the role's policy maximum.
- A justification is prompted for when a policy requires one and `-j` is not given.
- Exit codes: `0` success, `1` failure, `2` usage error.

Run `pim help` for every option.

### Picker keys

| Key | Action |
|---|---|
| type | filter (space separates terms) |
| ↑ ↓, ctrl-p ctrl-n, PgUp PgDn, Home End | move |
| tab, shift-tab | select or deselect several roles |
| enter | activate the selected roles (or the current one): opens a form for duration and justification |
| ctrl-d | deactivate the selected or current active roles (asks for confirmation) |
| ctrl-r | refresh from Azure |
| ctrl-w, ctrl-u | delete a word, clear the input |
| esc | clear the filter, then the selection, then quit (closes the form) |
| ctrl-c | quit |

## herdr integration

Add to `~/.config/herdr/config.toml`, adjusting the path to wherever `pim` is installed:

```toml
[ui]
tab_bar_right = [
  { type = "command", command = "~/.local/bin/pim status --notify", interval_seconds = 15, timeout_seconds = 20 },
  # ...your other entries
]

[[keys.command]]
key = "prefix+a"
type = "popup"
command = "~/.local/bin/pim pick"
width = "80%"
height = "70%"
```

Then check and reload: `herdr config check && herdr server reload-config`.

What you get:
- **`prefix+a`** opens the picker as a popup. `prefix+p` is herdr's default for previous tab, so pick a free key if you change it.
- **Status bar:** shows `PIM <active> · <time left on the soonest expiry>`, plus `◐<n>` for requests that are still pending. It reads the local cache and refreshes from Azure at most every 5 minutes (`--max-age`). Time left is computed locally, so it is always current.
- **Notifications** (`--notify`), each sent once:
  - 15 minutes before an activation expires;
  - when it has expired;
  - when a pending request becomes active.

## How it works, privacy and security

- **Network:** `pim` talks only to `https://management.azure.com` (the ARM PIM APIs, version `2020-10-01`). Tokens come from `az account get-access-token`, with Azure CLI telemetry turned off for those calls (`AZURE_CORE_COLLECT_TELEMETRY=false`).
- **Tokens:** kept in memory only, never written to disk or logs. Redirects are not followed, and pagination links pointing anywhere other than `management.azure.com` are refused, so a token can never be sent to another host.
- **Cache:** the state directory holds `snapshot.json` (roles, scopes, end times) and `alerts.json` (notifications already sent). Files are written atomically with mode `0600`, in a `0700` directory.
- **Display:** names returned by Azure are stripped of control characters before they are shown, so they cannot inject terminal escape sequences.
- **What it does in Azure:** only self-activation and self-deactivation requests (`roleAssignmentScheduleRequests`, `SelfActivate`/`SelfDeactivate`) for your own principal, which is read from your token. Azure enforces every PIM policy.

## Configuration

| Variable | Effect |
|---|---|
| `PIM_STATE_DIR` | Cache directory. Default: `$XDG_STATE_HOME/pim`, else `~/.local/state/pim` (`%LOCALAPPDATA%\pim` on Windows). |
| `NO_COLOR` | Disables colors in table output. |
| `HERDR_BIN_PATH` | herdr binary used for notifications (set by herdr; otherwise `herdr` on `PATH`). |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not get an Azure token` | Run `az login`. The message includes the first line of `az`'s own error. |
| `the Azure CLI (az) was not found` | Install the Azure CLI and make sure it is on `PATH`. In herdr, commands run through `/bin/sh -lc`, so your login `PATH` applies. |
| `needs a stronger sign-in (MFA / Conditional Access)` | Run `az logout`, then `az login`, completing MFA, and retry. |
| `rejected by the PIM policy: ...ExpirationRule` | The duration exceeds the policy; use a shorter `-d`. |
| `Azure only allows deactivation 5 minutes after activation` | Wait, then retry `pim down`. |
| Status bar entry empty | Nothing is active, or the command failed. Run `pim status --refresh` in a terminal to see why. |
| No notifications | Run `pim status --notify` inside a herdr pane and check stderr. Make sure `herdr notification show test` works. |
| `the picker needs a terminal` | `pim pick` needs an interactive terminal; use `pim ls` in scripts. |

## Limitations

- Covers **Azure resource roles** (resource groups, subscriptions, resources) only. Entra ID directory roles and PIM for Groups are not supported.
- Policies that require a **ticket number** are not supported; activate those in the Azure portal.
- **Windows** builds compile but are untested (for example, starting `az.cmd`).

## Development

```sh
zig build test --summary all     # unit tests (no network access)
zig build fmt                    # formatting check
zig build run -- ls --cached     # run from source
```

The code follows a ports-and-adapters layout, and `src/main.zig` is the only place where everything is wired together:

| Directory | Contents |
|---|---|
| `src/domain/` | Pure logic: time and duration parsing, ARM scopes, joining roles, selection, status line, notification decisions. |
| `src/adapters/` | Outside world: Azure CLI tokens, ARM client and data shapes (tested against recorded responses in `adapters/arm/testdata`), JSON state store, herdr notifier. |
| `src/app/` | Use cases: session (lazy, thread-safe token), snapshot cache and refresh, activation and deactivation, notifications. |
| `src/present/` | Messages and error explanations shared by the CLI and the picker; output sanitizing. |
| `src/cli/` | Argument parsing, commands, table and JSON output. |
| `src/tui/` | Picker: pure state machine (`model.zig`), keymap, view, and the event loop with background tasks (`app.zig`). |
| `src/platform/` | Per-user directories and log muting. |

Conventions:
- Explicit allocators, with an arena per command or background task.
- Explicit error sets with `Diagnostics` out-parameters for user-facing context.
- No network access in tests.
- Every bug fix comes with a regression test.
