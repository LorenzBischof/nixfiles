{
  lib,
  stdenvNoCC,
  cacert,
  curl,
  version,
  # The SHA-256 Citrix lists next to the download, in any form nix accepts.
  hash,
}:

# TODO: nixpkgs takes this tarball through `requireFile`, deliberately, since
# downloading it accepts Citrix's click-through EULA; there is no upstream issue.
# This fetches it from Citrix's download pages instead, onto the same store path
# requireFile computes. Drop it if nixpkgs ever fetches the tarball itself.
stdenvNoCC.mkDerivation {
  name = "linuxx64-${version}.tar.gz";
  outputHash = hash;
  outputHashAlgo = "sha256";
  outputHashMode = "flat";

  nativeBuildInputs = [ curl ];
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  impureEnvVars = lib.fetchers.proxyImpureEnvVars;
  preferLocalBuild = true;

  buildCommand = builtins.readFile ./citrix-tarball.sh;
}
