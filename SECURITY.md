# Security

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** on this repository (Security → Report a vulnerability) rather than a public issue. You should hear back within a week.

## Threat model

tongs is built for one specific risk: **an AI agent that you run on your own Mac leaking a credential into its transcript.** A transcript is re-sent to the model provider on every turn, stored on disk, and sometimes shared. Once a value is in it, it can't be taken back out.

It is not a defense against malware already running as your user, or against an agent that is actively trying to steal secrets. It narrows the accidental paths and makes the deliberate ones visible.

### What tongs does

| Mechanism | Protects against |
|---|---|
| Values are entered in a native panel (`tongs request`), never in the chat | The human pasting a key into the transcript |
| `tongs run` injects values as environment variables, never as arguments | Values in the process table and shell history |
| Output scrubbing of the raw value, its URL-encoded form, and Base64 at all three byte alignments | Accidental echoes: `curl -v` headers (including Basic auth), stack traces, libraries logging their config |
| Keychain item ACLs trust only the tongs binary that created them | Other programs, including an agent calling `security find-generic-password -w`, read silently: macOS asks for the login password instead |
| PreToolUse guard hook (Claude Code, Codex) | Agents reaching around tongs to read the Keychain or its database files |
| Touch ID approval per agent × project × secret, valid 12 hours | Silent first use of a secret in a new place |
| Approvals are HMAC-signed with a key held in the Keychain | An agent forging approvals by editing `grants.json` (it can delete them, which only restricts it) |
| Activity log of every request/run (names, project, command, exit code) | Use you didn't notice at the time |

### What it does not do

- **A command that transforms the value before printing it bypasses scrubbing**, e.g. `sh -c 'echo "$X" | rev'`. So does a command that writes the value to a file. The Touch ID prompt shows the command, but once approved, other commands in the same project don't prompt again for 12 hours.
- **`tongs run` runs outside the agent's sandbox.** The Codex rules installed by `tongs setup codex` make Codex ask before each `tongs run`, and that prompt is the real gate. Don't change it to `allow` unless you trust every command the agent might wrap.
- **Agent identification is best effort.** It comes from the process tree and environment variables, and is used for display and approval grouping only. A process tongs can't identify is treated as "Terminal" and still needs approval.
- **Local, same-user attackers are out of scope.** They can read the clipboard while you paste, inject input, or attach to processes.
- **Builds from source are ad-hoc signed.** Each rebuild is a new identity to the Keychain, so you will be asked to re-allow access. Approving a binary you didn't build yourself gives it your secrets.
