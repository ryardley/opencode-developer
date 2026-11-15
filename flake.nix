{
  description = "ralph: work through tk tickets with a sandboxed opencode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    agent-sandbox.url = "github:archie-judd/agent-sandbox.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      agent-sandbox,
      llm-agents,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Domain allowlist for the sandbox's filtering proxy, read from
      # allow-hosts.txt (one host per line, '#' comments). Matched by suffix,
      # so "crates.io" also allows static.crates.io.
      baseAllowedDomains = let
        lib = nixpkgs.lib;
        lines = lib.splitString "\n" (builtins.readFile ./allow-hosts.txt);
        entries = builtins.filter (l: l != "" && !(lib.hasPrefix "#" l)) (map lib.trim lines);
      in builtins.listToAttrs (map (d: {
        name = d;
        value = "*";
      }) entries);
    in
    {
      lib = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sbx = agent-sandbox.lib.${system};

          # tk-tickets (github.com/wedow/ticket), pinned to the same rev the
          # pool-watcher devenv uses.
          ticketSrc = pkgs.fetchFromGitHub {
            owner = "wedow";
            repo = "ticket";
            rev = "194b71a8bbc3771da1ce9f579395937c976bbddc";
            hash = "sha256-S7nA8IiOCYqA6ic1b5MkE7fUCtViUiEUVeJ4HV1re2o=";
          };
          tk = pkgs.writeShellApplication {
            name = "tk";
            runtimeInputs = with pkgs; [
              coreutils
              gnused
              gawk
              gnugrep
              ripgrep
              jq
              git
            ];
            text = ''
              exec ${pkgs.bash}/bin/bash ${ticketSrc}/ticket "$@"
            '';
          };

          # The tk-tickets opencode skill (SKILL.md) bundled with the flake.
          # ralph installs it into each target repo's `.opencode/skills/` so
          # both sandboxed and interactive opencode discover it.
          tkTicketsSkill = pkgs.writeTextFile {
            name = "tk-tickets-skill";
            text = builtins.readFile ./skills/tk-tickets/SKILL.md;
          };

          # opencode v1 (matches the version ralph was built against; the host
          # runs 1.18.29 and uses the v1 config format). Switch to the v2 CLI
          # by using `pkg = pkgs.opencode;` instead.
          mkOpencode = { extraAllowedDomains ? [ ], extraEnv ? { } }:
            let
              sandboxPackages = sbx.commonTools
                ++ (with pkgs; [
                  cargo
                  rustc
                  nodejs_22
                  yarn
                  foundry
                ]);
              # The sandbox's fixed toolchain. The active devenv profile is
              # prepended at launch, so whatever the target repo's devenv
              # installs wins over these.
              sandboxPath = pkgs.lib.makeBinPath (sandboxPackages ++ [ pkgs.bashInteractive ]);
            in
            sbx.mkSandbox {
              pkg = llm-agents.packages.${system}.opencode;
              binName = "opencode";
              outName = "opencode";
              allowedPackages = sandboxPackages;
              # opencode's own state (sessions, db) is left to the masked home:
              # writable and ephemeral, discarded at exit. Nothing on the host is
              # written outside the project directory.
              rwDirs = [ ];
              # The whole store is bound read-only so the devenv profile's
              # binaries and their libraries resolve. This exposes every
              # package in the store, not just the ones on PATH.
              roDirs = [ "$HOME/.config/opencode" "/nix/store" ];
              roFiles = [
                "$HOME/.local/share/opencode/auth.json"
              ];
              env = {
                # opencode's CLI talks to its local background service over
                # loopback; it must bypass the filtering proxy.
                NO_PROXY = "localhost,127.0.0.1,::1";
                OPENCODE_ENABLE_EXA = "1";
                OPENCODE_WEBSEARCH_PROVIDER = "exa";
                # Prepend the active devenv profile (set by `devenv shell`) so
                # the repo's tools are on PATH, then the sandbox's fixed
                # toolchain. The profile is empty when not launched from a
                # devenv shell.
                PATH = "\${DEVENV_PROFILE:+$DEVENV_PROFILE/bin:}${sandboxPath}";
                # The sandbox masks $HOME, so git cannot read the host's global
                # gitconfig and `git commit` would fail with no declared
                # identity. Resolve the identity from the host's git config at
                # launch and pass it in as env vars. The values are shell
                # expressions expanded on the host before the sandbox starts.
                # Override by passing extraEnv or setting user.name/user.email.
                GIT_AUTHOR_NAME = "\"$(git config user.name)\"";
                GIT_AUTHOR_EMAIL = "\"$(git config user.email)\"";
                GIT_COMMITTER_NAME = "\"$(git config user.name)\"";
                GIT_COMMITTER_EMAIL = "\"$(git config user.email)\"";
              } // extraEnv;
              allowedDomains = baseAllowedDomains
                // builtins.listToAttrs (map (d: {
                  name = d;
                  value = "*";
                }) extraAllowedDomains);
            };

          mkRalph = opencode: pkgs.runCommand "ralph" {
            nativeBuildInputs = with pkgs; [ makeWrapper ];
          } ''
            mkdir -p "$out/bin" "$out/share/tk-tickets"
            install -m 0755 ${./ralph.sh} "$out/bin/ralph"
            install -m 0644 ${tkTicketsSkill} "$out/share/tk-tickets/SKILL.md"
            wrapProgram "$out/bin/ralph" \
              --prefix PATH : "${pkgs.lib.makeBinPath (with pkgs; [
                coreutils
                gnused
                gawk
                gnugrep
                git
                tk
                opencode
              ])}"
          '';
        in
        {
          inherit tk tkTicketsSkill mkOpencode mkRalph;
        }
      );
      packages = forAllSystems (
        system:
        let
          lib = self.lib.${system};
          opencode = lib.mkOpencode { };
          ralph = lib.mkRalph opencode;
        in
        {
          inherit (lib) tk;
          tk-tickets-skill = lib.tkTicketsSkill;
          inherit opencode ralph;
          # Raw (unsandboxed) opencode, for debugging.
          opencode-raw = llm-agents.packages.${system}.opencode;
          default = ralph;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.ralph
              self.packages.${system}.tk
              self.packages.${system}.opencode
            ];
            shellHook = ''
              echo "ralph: tk-ticket driver with a sandboxed opencode (v1 via llm-agents.nix)."
              echo "  cd <repo-with-.tickets> && ralph --dry-run"
              echo "  ralph, tk, opencode are on PATH."
            '';
          };
        }
      );
    };
}
