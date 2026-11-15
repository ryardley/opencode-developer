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
- Network egress is allowed only for the hosts in `allow-hosts.txt` plus any
  `extraAllowedDomains` you pass to `mkOpencode`, routed through a filtering
  proxy (`HTTP_PROXY`/`HTTPS_PROXY` set, `NO_PROXY` for loopback so opencode's
  local service works). The allowlist is cooperative: it restricts anything
  that honors the proxy env (opencode, curl, git, cargo, npm), not a hard
  kernel boundary.
- The toolchain on PATH inside the sandbox is `commonTools` + cargo, rustc,
  nodejs_22, yarn, foundry — enough to build/test this kind of project.

## Usage

Add this flake as an input in `devenv.yaml`:

```yaml
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
  opencode-developer:
    url: github:ryardley/opencode-developer
```

Then add ralph to `devenv.nix`:

```nix
{ pkgs, inputs, ... }:

let
  od = inputs.opencode-developer.lib.${pkgs.system};
  opencode = od.mkOpencode { };
in
{
  packages = [
    (od.mkRalph opencode)
    od.tk
  ];
}
```

Then run it from the target repo (it operates on the *current* repo via
`git rev-parse --show-toplevel`):

```sh
devenv shell

ralph --dry-run   # plan only
ralph             # all ready tickets
ralph pw-4hz9     # one ticket
```

`ralph`, `tk`, and the sandboxed `opencode` are on PATH inside the shell.

Env (same as before): `RALPH_MAX_ATTEMPTS` (3), `RALPH_MAX_ITERATIONS` (100),
`RALPH_MODEL`, `RALPH_AGENT`.

### Whitelisting domains

When ralph runs from a devenv, the sandbox only mounts the target repo, so
this repo and its `allow-hosts.txt` are not visible. Add domains in the target
repo's `devenv.nix` by passing them to `mkOpencode`:

```nix
{ pkgs, inputs, ... }:

let
  od = inputs.opencode-developer.lib.${pkgs.system};
  opencode = od.mkOpencode {
    extraAllowedDomains = [
      "api.example.com"
      "example.org"
    ];
  };
in
{
  packages = [
    (od.mkRalph opencode)
    od.tk
  ];
}
```

`extraAllowedDomains` takes **hosts, not URLs**: strip the scheme, port, and
path. Matching is by suffix, so `example.com` also allows `api.example.com`
and `static.example.com`. Hosts must be ASCII; write an internationalized
domain in punycode (`xn--...`).

Re-enter the devenv to rebuild the wrapper:

```sh
exit
devenv shell
```

`extraAllowedDomains` allows every HTTP method. For method or path rules,
extend `allowedDomains` in this repo's `flake.nix` (the base list) or pass a
custom `mkOpencode` from a fork.

### Following the proxy to see failures

Every launch writes a session directory under `$XDG_STATE_HOME/agent-sandbox`
(default `~/.local/state/agent-sandbox`). The filtering proxy logs there, on
the host, so you can watch it from a second terminal while ralph runs:

```sh
tail -f "$(ls -dt ~/.local/state/agent-sandbox/* | head -1)/proxy.log"
```

Each `opencode run` is its own launch, so the newest directory is the current
attempt. Lines look like:

```
2026-11-15T10:24:31Z allowed: GET api.github.com/graphql
2026-11-15T10:24:32Z blocked: GET api.example.com/v1/things (domain not allowed)
```

`allowed` is logged once per method/host/path; `blocked` is logged on every
request, with the reason `domain not allowed`, `path not allowed`, or
`method not allowed`. Query strings are omitted. Add the blocked host to
`extraAllowedDomains` in your `devenv.nix`, re-enter the shell, and re-run.

`launch.log` in the same directory records the config the wrapper received,
warnings, and the sandbox's exit status. The newest 25 session directories are
kept. Only traffic that honors `HTTP_PROXY`/`HTTPS_PROXY` is filtered
(opencode, curl, git, cargo, npm); loopback is in `NO_PROXY` so opencode's
local service works.

## Bundled tk-tickets skill

The flake ships the `tk-tickets` opencode skill (source:
`skills/tk-tickets/SKILL.md`). Each non-dry-run `ralph` invocation syncs it
into the target repo's `.opencode/skills/tk-tickets/SKILL.md` (overwriting any
drift) and commits it if new, so both the sandboxed opencode runs and
interactive opencode in that repo discover it via project skills. If the file
already matches, nothing is written.

Verify discovery in a target repo with:

```sh
opencode debug skill   # should list tk-tickets
```

`tk-tickets` is also exposed as `self.packages.<system>.tk-tickets-skill` and
`self.lib.<system>.tkTicketsSkill` for manual installs (e.g. copy its
`SKILL.md` into `~/.config/opencode/skills/` for a host-global install).

Note: opencode only discovers project skills under `.opencode/skill/` or
`.opencode/skills/` — a file at `.opencode/tk-ticket/SKILL.md` (or any
non-`skill(s)` directory) is silently ignored. If your repo has such a file,
move it before running ralph (it also fails ralph's clean-tree check).

## Notes

- **opencode is v1** (via `numtide/llm-agents.nix#opencode`), matching the
  host install (`1.18.29`) and the v1 config format ralph was written for.
  To use the v2 CLI instead, change `pkg = pkgs.opencode;` in `flake.nix`
  (v2 reads a different config schema, so existing `opencode.jsonc` may not
  carry over).
- **Auth** comes from the host `~/.local/share/opencode/auth.json`, mounted
  read-only. Tokens that need refreshing will expire; re-run opencode on the
  host to refresh, or pass keys via `env`/`injectedCredentials`.
- **Allowlist**: add domains via `extraAllowedDomains` in your `devenv.nix`;
  see [Whitelisting domains](#whitelisting-domains) and
  [Following the proxy to see failures](#following-the-proxy-to-see-failures).
- **Requirements**: nix with flakes; on Linux, bwrap needs user namespaces
  (default on NixOS; Ubuntu 24.04 needs the `bwrap-userns-restrict` profile).
