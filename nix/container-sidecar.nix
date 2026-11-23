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
    # newuidmap/newgidmap. These must be setuid-root so the unprivileged
    # container-runner user can apply the mapping; without them every
    # `podman system service` start fails with
    #   exec: "newuidmap": executable file not found in $PATH
    security.wrappers = {
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
      # Adjust if these overlap another user's subordinate ID range.
      subUidRanges = [ { startUid = 100000; count = 65536; } ];
      subGidRanges = [ { startGid = 100000; count = 65536; } ];
      # Start the user's systemd instance at boot so the API comes up without
      # a login.
      linger = true;
    };

    systemd.user.services.podman-api = {
      description = "Rootless podman API for the opencode sandbox";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        ExecStart = "${pkgs.podman}/bin/podman system service --time=0 tcp://127.0.0.1:${toString cfg.port}";
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
