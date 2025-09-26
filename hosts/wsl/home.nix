{
  self,
  config,
  pkgs,
  ...
}:
let
  regula = pkgs.stdenv.mkDerivation {
    name = "regula";
    src = pkgs.fetchzip {
      url = "https://github.com/fugue/regula/releases/download/v3.2.1/regula_3.2.1_Linux_x86_64.tar.gz";
      sha256 = "sha256-fN6ABQnDfhqnRBcBlc6hV4iKtJRvngNPDrBkCXd9k+k=";
      curlOpts = "-k";
      stripRoot = false;
    };
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out/bin
      cp $src/$name $out/bin/$name
      chmod +x $out/bin/$name
    '';
  };
  fregot = pkgs.stdenv.mkDerivation {
    name = "fregot";
    src = pkgs.fetchzip {
      url = "https://github.com/fugue/fregot/releases/download/v0.14.2/fregot-v0.14.2-linux.tar.gz";
      sha256 = "sha256-883R1ocsx98oq73D//8jVQOz/3G8Cw7XxTb5Ugn+yJQ=";
      curlOpts = "-k";
      #stripRoot = false;
    };
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out/bin
      cp $src/$name $out/bin/$name
      chmod +x $out/bin/$name
    '';
  };
in
{
  imports = [
    ../../modules/home/shell
    ../../modules/home/git
  ];

  nixpkgs.config.allowUnfree = true;

  programs = {
    # To start zsh add the following two lines at the bottom of the ~/.bashrc
    #
    # export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive
    # exec zsh
    #
    # Notes about the LOCALE_ARCHIVE export:
    # Unicode characters cannot be printed: https://github.com/starship/starship/issues/290#issuecomment-554315704
    # Fix: https://github.com/ohmyzsh/ohmyzsh/issues/6985#issuecomment-692576751
    zsh = {
      sessionVariables = {
        http_proxy = "http://localhost:8888";
        https_proxy = "http://localhost:8888";
        HTTP_PROXY = "http://localhost:8888";
        HTTPS_PROXY = "http://localhost:8888";
        no_proxy = "localhost,127.0.0.1";
        NO_PROXY = "localhost,127.0.0.1";
      };
    };
    ssh = {
      enable = true;
      addKeysToAgent = "yes";
    };
  };
  # TODO: can we use a yubikey?
  services.ssh-agent.enable = true;

  home = {
    packages = with pkgs; [
      golangci-lint
      kubectl

      #    cue
      #    open-policy-agent
      #    kubebuilder
      #    kind
      #    argocd
      terraform
      #    yq

      #    helmfile
      #    (wrapHelm kubernetes-helm { plugins = [ kubernetes-helmPlugins.helm-diff ]; })
      regula
      fregot
      gitlab-runner
      gotools
      docker-compose
      awscli2
      open-policy-agent
    ];
    # Home Manager needs a bit of information about you and the paths it should
    # manage.
    username = "bischoflo";
    homeDirectory = "/home/bischoflo";

    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    stateVersion = "23.11"; # Please read the comment before changing.
  };

  programs.go.enable = true;

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

}
