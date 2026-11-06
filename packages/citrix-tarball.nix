{
  lib,
  stdenvNoCC,
  cacert,
  curl,
  # Name and flat SHA-256 of the tarball to fetch; both describe one release.
  name,
  hash,
}:

# TODO: nixpkgs takes this tarball through `requireFile`, so no fetcher reaches
# it and a build stops until someone puts the file in the store by hand. No
# upstream issue to wait on — requireFile is deliberate there, since the
# download accepts a click-through EULA. Drop this if nixpkgs ever fetches it.
# How the page walk works: docs/citrix-workspace.md.
stdenvNoCC.mkDerivation {
  # requireFile's own name and flat hash, so this lands on upstream's store path.
  inherit name;
  outputHash = hash;
  outputHashAlgo = "sha256";
  outputHashMode = "flat";

  nativeBuildInputs = [ curl ];
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  impureEnvVars = lib.fetchers.proxyImpureEnvVars;

  # Fetch where the result is wanted, as every other fetcher does, but never
  # instead of substituting: 370 MB out of our cache beats 370 MB out of Citrix.
  # Spelled out because `runCommand` would have set allowSubstitutes false.
  preferLocalBuild = true;
  allowSubstitutes = true;

  latestPage = "https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html";
  legacyIndex = "https://www.citrix.com/downloads/workspace-app/legacy-workspace-app-for-linux/";

  buildCommand = builtins.readFile ./citrix-tarball.sh;
}
