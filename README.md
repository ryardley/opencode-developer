# opencode-developer

Work through tk-tickets one at a time with a **sandboxed** opencode.

For each ready (non-epic) ticket, `ralph` runs `opencode run` once to
implement it and once to verify it (the verifier must end with
`VERDICT: PASS`), then `tk close`s the ticket and commits `feat: <title>`.
On a failed verification it retries with the verifier's reason fed back, up
to `RALPH_MAX_ATTEMPTS` (default 3), then stops. Logs go to `.ralph/logs/`.

The whole thing is a Nix flake so it runs anywhere with nix: `tk` and
`opencode` are provided, and opencode runs inside a sandbox.

## The sandbox

opencode is wrapped with [agent-sandbox.nix](https://github.com/archie-judd/agent-sandbox.nix)
(`bwrap` on Linux, Seatbelt on macOS). Inside the sandbox it sees **only**:

| Path | Access |
|---|---|
| the directory you launch from (`$PWD`) | read-write |
| `~/.config/opencode` | read-only |
| `~/.local/share/opencode/auth.json`, `~/.cache/opencode/models.json` | read-only |
| synthetic `$HOME`, `/tmp`, `/run` | writable, ephemeral (discarded on exit) |
| everything else (other projects, keys, dotfiles, `/usr`…) | invisible |

- opencode's own state (sessions, db) is written to the ephemeral home and
  discarded each run; nothing on the host is written outside the project.
- Network egress is allowed only for the hosts in `allow-hosts.txt`, routed
  through a filtering proxy (`HTTP_PROXY`/`HTTPS_PROXY` set, `NO_PROXY` for
  loopback so opencode's local service works). The allowlist is cooperative:
  it restricts anything that honors the proxy env (opencode, curl, git,
  cargo, npm), not a hard kernel boundary.
- The toolchain on PATH inside the sandbox is `commonTools` + cargo, rustc,
  nodejs_22, yarn, foundry — enough to build/test this kind of project.

## Usage

Run it from the repo whose `.tickets` you want to work through (it operates
on the *current* repo via `git rev-parse --show-toplevel`):

```sh
# from any target repo with tk tickets (e.g. pool-watcher):
nix run path:/path/to/ralph#ralph -- --dry-run   # plan only
nix run path:/path/to/ralph#ralph                # all ready tickets
nix run path:/path/to/ralph#ralph -- pw-4hz9     # one ticket

# or drop into a shell with ralph, tk, and the sandboxed opencode:
nix develop /path/to/ralph
```

Once this directory is its own git repo, the plain forms work from inside it:
`nix run .#ralph -- --dry-run`.

Env (same as before): `RALPH_MAX_ATTEMPTS` (3), `RALPH_MAX_ITERATIONS` (100),
`RALPH_MODEL`, `RALPH_AGENT`.

## Notes

- **opencode is v1** (via `numtide/llm-agents.nix#opencode`), matching the
  host install (`1.18.29`) and the v1 config format ralph was written for.
  To use the v2 CLI instead, change `pkg = pkgs.opencode;` in `flake.nix`
  (v2 reads a different config schema, so existing `opencode.jsonc` may not
  carry over).
- **Auth** comes from the host `~/.local/share/opencode/auth.json`, mounted
  read-only. Tokens that need refreshing will expire; re-run opencode on the
  host to refresh, or pass keys via `env`/`injectedCredentials`.
- **Allowlist**: edit `allow-hosts.txt` and rebuild. To see what got blocked,
  `tail -f ~/.local/state/agent-sandbox/*/proxy.log`.
- **Requirements**: nix with flakes; on Linux, bwrap needs user namespaces
  (default on NixOS; Ubuntu 24.04 needs the `bwrap-userns-restrict` profile).
