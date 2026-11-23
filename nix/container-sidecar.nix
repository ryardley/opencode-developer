# A dedicated-user rootless podman API for the opencode sandbox.
#
# Import this module only on the VMs that need it. It enables the sidecar on
# import, like a plain `docker.nix` module.
#
# The sandbox never gets the host's Docker socket. Instead, this module runs a
# rootless podman API as a separate user (`container-runner`) on 127.0.0.1, and
# the sandbox reaches it over TCP via `allowedHostPorts`. The runner cannot read
# the main user's home, so SSH keys and other secrets stay out of reach even
# when the agent's compose file asks for `--userns=host` or `-v /:/host`.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.containerSidecar;
in
{
  options.services.containerSidecar = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 2375;
      description = ''
        TCP port on 127.0.0.1 for the podman API. The sandbox must be built
        with the same port in `mkOpencode { containerSidecar = { port = ...; }; }`.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "container-runner";
      description = "Dedicated user that runs the podman API.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "container-runner";
      description = "Group for the dedicated user.";
    };

    workspaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/home/you/projects" ];
      description = ''
        Directories to grant the runner read/write access to, so compose bind
        mounts and build contexts work. Applied with ACLs at activation. For a
        repo created after activation, run the same `setfacl` from the repo's
        devenv `enterShell` instead.
      '';
    };
  };

  config = {
    environment.systemPackages = [
      pkgs.podman
      pkgs.shadow
      pkgs.slirp4netns
      pkgs.fuse-overlayfs
    ];

    # Rootless podman maps the runner's subuid/subgid ranges via
    # newuidmap/newgidmap. NixOS's shadow module (enabled by default) already
    # provides these wrappers with file capabilities, so only add setuid
    # fallbacks when shadow is disabled. Defining both setuid and capabilities
    # for the same wrapper fails the security.wrappers assertion:
    #   setuid/setgid and capabilities are mutually exclusive.
    security.wrappers = lib.mkIf (!config.security.shadow.enable) {
      newuidmap = {
        owner = "root";
        group = "root";
        setuid = true;
        source = "${pkgs.shadow}/bin/newuidmap";
      };
      newgidmap = {
        owner = "root";
        group = "root";
        setuid = true;
        source = "${pkgs.shadow}/bin/newgidmap";
      };
    };

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/${cfg.user}";
      createHome = true;
      # Let NixOS allocate a non-overlapping range. A hardcoded 100000 collides
      # with the auto-allocated range the host's normal user also receives.
      autoSubUidGidRange = true;
      # Start the user's systemd instance at boot so the API comes up without
      # a login.
      linger = true;
    };

    # The rootless API needs a signature policy to pull and run images. Podman
    # checks the runner's own config first, so scope the policy to the runner's
    # home and leave the host's podman policy untouched. Public test images are
    # unsigned, so accept them without verification.
    systemd.tmpfiles.rules = [
      "d /var/lib/${cfg.user}/.config 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/${cfg.user}/.config/containers 0755 ${cfg.user} ${cfg.group} -"
      "L+ /var/lib/${cfg.user}/.config/containers/policy.json - - - - ${pkgs.writeText "container-runner-policy.json" (builtins.toJSON { default = [ { type = "insecureAcceptAnything"; } ]; })}"
      # Pre-create the rootless storage graph so the first `podman` run does not
      # race creating it (and crash-loop) on a fresh boot.
      "d /var/lib/${cfg.user}/.local 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/${cfg.user}/.local/share 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/${cfg.user}/.local/share/containers 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/${cfg.user}/.local/share/containers/storage 0755 ${cfg.user} ${cfg.group} -"
    ];

    systemd.user.services.podman-api = {
      description = "Rootless podman API for the opencode sandbox";
      wantedBy = [ "default.target" ];
      unitConfig = {
        ConditionUser = cfg.user;
        # Retry until the port is free instead of giving up after the default
        # 5 starts in 10s. A boot-time race for the port (or a slow user
        # manager) must not leave the sidecar permanently failed, which would
        # surface in the sandbox as a bare "connection refused".
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        # Log what, if anything, already holds the port before each start, so a
        # future flap is diagnosable from the journal rather than a bare
        # "address already in use". Non-fatal: the bind below still decides.
        ExecStartPre = "${pkgs.bash}/bin/bash -c '${pkgs.iproute2}/bin/ss -ltn 2>/dev/null | grep -F 127.0.0.1:${toString cfg.port} || true'";
        # Rootless podman does one-time setup (storage graph, network) on its
        # first invocation. If that setup fails, `podman system service` exits
        # 125 and the sidecar crash-loops until someone runs podman by hand.
        # Initialize it here, in the main process, so a fresh boot waits for
        # init to succeed before binding. Doing it in ExecStart (not
        # ExecStartPre) means Restart=on-failure applies if init keeps failing.
        ExecStart = "${pkgs.bash}/bin/bash -c 'i=0; until ${pkgs.podman}/bin/podman info >/dev/null 2>&1; do i=$((i+1)); if [ $i -ge 60 ]; then echo \"podman init failed after 60s\" >&2; exit 1; fi; ${pkgs.coreutils}/bin/sleep 1; done; exec ${pkgs.podman}/bin/podman system service --time=0 tcp://127.0.0.1:${toString cfg.port}'";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    system.activationScripts.containerSidecarAcls = lib.mkIf (cfg.workspaces != [ ]) ''
      ${lib.concatMapStringsSep "\n" (dir: ''
        if [ -d "${dir}" ]; then
          ${pkgs.acl}/bin/setfacl -R -m u:${cfg.user}:rwX "${dir}" || true
          ${pkgs.acl}/bin/setfacl -R -d -m u:${cfg.user}:rwX "${dir}" || true
        fi
      '') cfg.workspaces}
    '';
  };
}
