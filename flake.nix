# The skills as an Agent Plugins package (agent-stacks.org), built here rather than from
# the public agent-pkgs set: a project's stack takes this flake as an input and puts
# `agent-plugin-bead-loop` in its plugins. `planner` is that stack with Claude Code alone,
# for writing beads in a repo that has no stack of its own:
#   nix run github:imkarrer/bead-loop#planner
# The loop itself is installed by install.sh, not by this flake.
{
  description = "bead-loop's skills for writing beads the loop lands, as an agent plugin and a Claude Code stack";

  inputs.agent-pkgs.url = "github:agent-stacks/agent-pkgs";
  inputs.nixpkgs.follows = "agent-pkgs/nixpkgs";

  outputs = { self, nixpkgs, agent-pkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: lib.genAttrs systems (system: f system);
      # Only plugin.json and skills/ go in: the package changes when a skill does, not on
      # every commit to the supervisor.
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [ ./plugin.json ./skills ];
      };
      skills = lib.mapAttrs (name: _: "skills/${name}")
        (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./skills));
    in {
      packages = forAllSystems (system:
        let
          inherit (agent-pkgs.lib.${system}) buildAgentPlugin mkAgentStack;
        in rec {
          # plugin.json at the root is the manifest: its name, version and description.
          agent-plugin-bead-loop = buildAgentPlugin {
            name = "bead-loop";
            version = (lib.importJSON ./plugin.json).version;
            inherit src skills;
            sourceUrl = "https://github.com/imkarrer/bead-loop";
          };
          planner = mkAgentStack {
            name = "bead-loop-planner";
            harness = agent-pkgs.packages.${system}.claude-code;
            plugins = [ agent-plugin-bead-loop ];
          };
          default = agent-plugin-bead-loop;
        });
    };
}
