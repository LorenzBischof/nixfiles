{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.programs.git;
in
{

  options.my.programs.git.enable = lib.mkEnableOption "git";
  config = lib.mkIf cfg.enable {
    home.file = {
      ".config/git/hooks/post-checkout" = {
        source = ./config/hooks/post-checkout;
        executable = true;
      };
    };
    home.packages = [ pkgs.watchman ];
    programs.jujutsu = {
      enable = true;
      settings = {
        user = {
          name = "LorenzBischof";
          email = "1837725+LorenzBischof@users.noreply.github.com";
        };
        git.private-commits = "description(glob:'wip:*') | description(glob:'private:*')";
        signing = {
          behavior = "own";
          backend = "ssh";
          key = "~/.ssh/id_ed25519_github.com_lorenzbischof_signing.pub";
        };
        colors = {
          commit_id = "bright black";
          author = "bright black";
          timestamp = "bright black";
          "working_copy commit_id" = "bright black";
          "working_copy author" = "bright black";
          "working_copy timestamp" = "bright black";
          "working_copy empty description placeholder" = "bright black";
        };
        ui = {
          diff-editor = ":builtin";
          default-command = "log";
        };
        template-aliases = {
          "format_short_change_id(id)" = "id.shortest(7)";
          "format_short_commit_id(id)" = "id.short(7)";
          "format_short_signature(signature)" = "signature.name()";
          "format_timestamp(timestamp)" = "timestamp.ago()";
        };
        fsmonitor.backend = "watchman";
      };
    };

    programs.git = {
      enable = true;
      settings = {
        core = {
          whitespace = "trailing-space, space-before-tab";
          quotepath = "off"; # https://stackoverflow.com/a/22828826
          # TODO: make sure local git hooks are also executed
          # hooksPath = "~/.config/hooks"; # https://stackoverflow.com/a/71939092
        };
        push = {
          autoSetupRemote = true;
        };
        pull = {
          ff = "only";
        };
        rebase = {
          autosquash = true;
        };
        init = {
          defaultBranch = "main";
        };
        help = {
          autocorrect = true;
        };
      };
      includes = [
        {
          condition = "gitdir:~/git/github.com/lorenzbischof/";
          path = ./config/config_github.com_lorenzbischof;
        }
      ];
    };
  };
}
