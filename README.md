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
| `/nix/store` | read-only (so the devenv profile's binaries and libraries resolve) |
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
- The toolchain on PATH inside the sandbox is the active devenv profile
  (whatever the target repo's `devenv.nix` installs) followed by
  `commonTools` + cargo, rustc, nodejs_22, yarn, foundry.

### devenv in the sandbox

When you launch from inside a devenv shell, the sandbox prepends
`$DEVENV_PROFILE/bin` to `PATH`, so whatever the target repo's `devenv.nix`
installs is available to opencode. The whole nix store is bound read-only so
those binaries and their libraries resolve. This is a deliberate relaxation:
the agent can read and execute every package in the store, not just the ones
on `PATH`. It does not expose the nix daemon, so the agent cannot build or
change daemon settings. Launch from a plain shell and only the fixed
toolchain above is available.

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
    od.mkArchive
    od.mkInstallSkills
    od.mkKillRalph
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

`ralph`, `tk`, `install-skills`, and the sandboxed `opencode` are on PATH inside the shell.

Env (same as before): `RALPH_MAX_ATTEMPTS` (3), `RALPH_MAX_ITERATIONS` (100),
`RALPH_MODEL`, `RALPH_AGENT`.

### Archiving closed tickets

`archive` deletes closed tk tickets: every `.tickets/<id>.md` whose frontmatter
has `status: closed` is `git rm`'d and committed, so it stops showing up in
`tk closed` / `tk show` while git history keeps it. Open and in-progress
tickets are untouched.

```sh
archive --dry-run   # list what would be removed
archive             # git rm closed tickets and commit
```

It requires a clean working tree (the `.ralph/` log dir is ignored) and writes
its log to `.ralph/archive-<timestamp>.log`. Override the commit message with
`ARCHIVE_COMMIT_MESSAGE`.

### Stopping a run

`kill-ralph` stops a running ralph loop. It finds the ralph process and every
descendant (the `timeout`/`opencode run` children for the current attempt),
sends `SIGTERM`, and escalates to `SIGKILL` for anything still alive after a
grace period. The ticket being worked on is left `in_progress`, so re-running
`ralph <id>` picks it back up.

```sh
kill-ralph --dry-run   # list the processes that would be killed
kill-ralph             # SIGTERM, then SIGKILL after 10s
kill-ralph --force     # SIGKILL immediately
```

Set `KILL_RALPH_GRACE` to change the seconds to wait before `SIGKILL`.

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

## Running compose for tests (container sidecar)

The sandbox never gets the host's Docker socket. To let the agent write its own
compose file and run a test against it, run a **dedicated-user rootless podman
API** on the host and point the sandbox at it over TCP. The runner cannot read
your home, so SSH keys and other secrets stay out of reach even when the
agent's compose file asks for `--userns=host` or `-v /:/host`.

### Host: enable the sidecar (NixOS)

Add the flake as an input to the VM's NixOS config and import
`nixosModules.containerSidecar` on the VMs that need it. The module enables the
sidecar on import, so only VMs that import it get it:

```nix
{
  inputs.opencode-developer.url = "github:ryardley/opencode-developer";

  outputs = { self, nixpkgs, opencode-developer, ... }: {
    nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
      modules = [
        opencode-developer.nixosModules.containerSidecar
        { services.containerSidecar.port = 2375; }
      ];
    };
  };
}
```

This creates a `container-runner` user (subuid/subgid, home `0700`, lingering)
and a `podman-api` user service listening on `127.0.0.1:2375`. The existing
rootful Docker is untouched, and the runner is not in the `docker` group.

### Target repo: point the sandbox at it

```nix
{ pkgs, inputs, ... }:

let
  od = inputs.opencode-developer.lib.${pkgs.system};
  opencode = od.mkOpencode {
    containerSidecar = { port = 2375; };
  };
in
{
  packages = [
    (od.mkRalph opencode)
    od.tk
  ];
}
```

`containerSidecar` is opt-in. When set, `mkOpencode` adds `podman` and
`podman-compose` to the sandbox, sets `CONTAINER_HOST=tcp://127.0.0.1:<port>`,
and allows that port through `allowedHostPorts`. When it is `null` (the
default), the sandbox has no container tooling and no open port — so a host
without the sidecar does not get a broken `podman` that fails with
`connection refused`.

Grant the runner access to the repo so compose bind mounts and build contexts
work. In the repo's `devenv.nix`:

```nix
{
  packages = [ pkgs.acl ];
  enterShell = ''
    setfacl -R -m u:container-runner:rwX .
    setfacl -R -d -m u:container-runner:rwX .
  '';
}
```

Add a runtime check so a missing sidecar is obvious:

```sh
curl -fsS http://127.0.0.1:2375/_ping >/dev/null 2>&1 \
  || echo "warning: container sidecar not reachable on 127.0.0.1:2375"
```

### What the agent can do

The agent writes `compose.test.yml` in the repo and runs:

```sh
podman-compose -f compose.test.yml up -d --wait
# run the test, e.g. cargo test
podman-compose -f compose.test.yml down -v
```

If the test runs in the sandbox (not as a compose service), add the service
ports to `allowedHostPorts` too. If it runs as a compose service
(`podman-compose run --rm tests`), only the API port is needed.

### Security and limits

- The runner is a separate user. `--userns=host` gives a container the
  *runner's* identity, not yours; `-v /:/host` sees the runner's view, not your
  home. `~/.ssh` stays unreadable.
- The host's `/var/run/docker.sock` is never bound into the sandbox.
- The API is unauthenticated and bound to `127.0.0.1`. On a single-user VM that
  is fine; on a shared host, firewall the port to your uid.
- Rootless podman's `--network=host` gives the host network namespace, so a
  container can reach VM services. The VM is the boundary; if you need network
  containment, use rootless Docker (whose `--network=host` is slirp4netns) or a
  private netns.
- The agent has root *inside* the runner's user namespace. That is the point,
  and it is disposable.

## Bundled opencode skills

The flake ships two opencode skills:

- `tk-tickets` (source: `skills/tk-tickets/SKILL.md`) — the tk ticket system.
- `podman` (source: `skills/podman/SKILL.md`) — how to run a compose stack
  through the container sidecar.

Each non-dry-run `ralph` invocation syncs both into the target repo's
`.opencode/skills/<name>/SKILL.md` (overwriting any drift) and commits them if
new, so both the sandboxed opencode runs and interactive opencode in that repo
discover them via project skills. If a file already matches, nothing is
written.

To install them without starting a ralph loop, use `install-skills` (also
`./install-skills.sh` from a checkout):

```sh
install-skills              # all skills into this repo, committed
install-skills tk-tickets   # just one skill
install-skills --global     # host-global (~/.config/opencode/skills)
install-skills --dry-run    # preview
```

Verify discovery in a target repo with:

```sh
opencode debug skill   # should list tk-tickets and podman
```

Both are also exposed as `self.packages.<system>.tk-tickets-skill` /
`podman-skill` and `self.lib.<system>.tkTicketsSkill` / `podmanSkill` for
manual installs (e.g. copy a `SKILL.md` into `~/.config/opencode/skills/` for a
host-global install).

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
- **Git identity**: the sandbox masks `$HOME`, so git cannot read the host's
  global gitconfig and `git commit` would fail ("no git identity declared").
  `mkOpencode` passes the host's identity in via `GIT_AUTHOR_*` /
  `GIT_COMMITTER_*`, resolved from the host's git config at launch. Override
  with `extraEnv` or a repo-local `user.name`/`user.email` in the target repo.
- **Allowlist**: add domains via `extraAllowedDomains` in your `devenv.nix`;
  see [Whitelisting domains](#whitelisting-domains) and
  [Following the proxy to see failures](#following-the-proxy-to-see-failures).
- **devenv access**: `mkOpencode` binds `/nix/store` read-only and prepends
  `$DEVENV_PROFILE/bin` to `PATH`, so the target repo's devenv tools are
  available. The whole store is readable and executable, not just the tools
  on `PATH`; the nix daemon is not exposed.
- **Requirements**: nix with flakes; on Linux, bwrap needs user namespaces
  (default on NixOS; Ubuntu 24.04 needs the `bwrap-userns-restrict` profile).
