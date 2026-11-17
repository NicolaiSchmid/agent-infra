# Agent skills owned by agent-infra, linked into Claude Code and Codex for the
# agent user on atlas (home-manager comes from dotfiles-nix home.nix).
{lib, ...}: let
  skills = ["youtube-transcript"];
  link = dir:
    lib.listToAttrs (map (name: {
        name = "${dir}/${name}";
        value.source = ../skills + "/${name}";
      })
      skills);
in {
  home-manager.users.nicolai.home.file = link ".claude/skills" // link ".codex/skills";
}
