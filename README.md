# lumide_serverpod

[![pub package](https://img.shields.io/pub/v/lumide_serverpod.svg)](https://pub.dev/packages/lumide_serverpod) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Powered by SoFluffy](https://img.shields.io/badge/Powered%20by-SoFluffy-orange)](https://sofluffy.io)

The official [Serverpod](https://serverpod.dev) extension for [Lumide IDE](https://lumide.dev).

## Highlights

- Start and stop servers from Lumide's Run controls, with hot reload on Serverpod 4.
- Debug servers: breakpoints, conditions, logpoints, stepping, variables, and evaluation.
- Generate code when a model or endpoint file is saved.
- Create migrations and repair migrations, and apply pending migrations.
- Check model files (`.spy.yaml`) as you type, and jump between models.
- Run the scripts of a server's `pubspec.yaml`.
- Start and stop Docker services, create projects, and upgrade the CLI.
- Works with workspaces of several folders and several servers.

## Requirements

Lumide 0.24.0 and later.

Install the Serverpod CLI and make sure `serverpod` is on your `PATH`:

```sh
dart pub global activate serverpod_cli
```

Serverpod 4 is recommended. With older versions, servers start with `dart bin/main.dart`: start their database first, such as with **Serverpod: Start Docker Services**.

## Commands

Use the Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`), or click the Serverpod item in the status bar.

| Command | Purpose |
| --- | --- |
| `serverpod.start` / `serverpod.stop` | Start or stop a server |
| `serverpod.debug` | Start a server in the debugger |
| `serverpod.generate` | Run `serverpod generate` |
| `serverpod.createMigration` | Create a migration, an empty one, or a forced one, with an optional tag |
| `serverpod.createRepairMigration` | Create a repair migration against a run mode's database |
| `serverpod.applyMigrations` | Apply pending migrations with the server's maintenance role |
| `serverpod.runScript` | Run a script from `serverpod: scripts:` |
| `serverpod.docker.up` / `serverpod.docker.stop` | Start or stop the Docker Compose services |
| `serverpod.create` | Create a project from a template |
| `serverpod.upgrade` | Upgrade the Serverpod CLI |

Commands act on the server of the file you right-clicked or have open, or ask which one when the workspace has several.

## Running servers

Each server package shows in the Run controls. Serverpod 4 servers start with `serverpod start`, which generates code, starts the database, and reloads the server when files change. Server logs go to a **Serverpod Server** output channel per server.

To change how a server starts, add an entry to `.sofluffy/lumide/launch.json`:

```json
{
  "name": "Staging server",
  "provider": "lumide_serverpod.serverpod",
  "config": {
    "server": "${workspaceFolder}/my_project_server",
    "mode": "staging",
    "applyMigrations": true,
    "serverArgs": ["--role", "monolith"]
  }
}
```

`watch`, `docker`, and `launchFlutterApps` turn `serverpod start` options on or off.

## Debugging

Click **Debug** in the Run controls, or run **Serverpod: Debug Server**, then call an endpoint. Breakpoints stop in endpoints, models, and any server code, and support conditions and logpoints.

On Serverpod 4, the debugger attaches to the VM service `serverpod start` serves. Hot reload keeps working, and when the server restarts, the debugger reconnects and sets your breakpoints again. Code that runs before the debugger attaches, such as `main`, is not stopped in. With older versions, the server waits at its start until your breakpoints are set.

One server is debugged at a time.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `serverpod.generateOnSave` | `true` | Generate code when a model or endpoint file is saved. Skipped while `serverpod start` runs the server, since it generates code itself |
| `serverpod.runMode` | `development` | The run mode servers start in, and migrations apply to |
| `serverpod.applyMigrationsOnStart` | `false` | Apply pending migrations when a server starts |
| `serverpod.launchFlutterApps` | `false` | Let `serverpod start` launch the companion Flutter apps marked `auto_launch` |
| `serverpod.languageServer` | `true` | Check model files with the Serverpod language server |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

The Serverpod logo in `assets/` is Serverpod's, from the [Serverpod repository](https://github.com/serverpod/serverpod/tree/main/misc/logo), and identifies Serverpod in Lumide.

---

Built with ❤️ by [SoFluffy](https://sofluffy.io).

## Happy Coding 🦊
