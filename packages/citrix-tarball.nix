{
  lib,
  stdenvNoCC,
  cacert,
  curl,
  version,
  # The SHA-256 the download page publishes beside the file, in nix32 or SRI
  # form — the same hash upstream's `requireFile` pins.
  hash,
}:

# TODO: nixpkgs fetches Citrix Workspace's tarball with `requireFile`, so no
# fetcher reaches it and the build stops at requireFile's message until a human
# has put the file in the store by hand. Nothing about that download needs a
# human, though: Citrix's Linux download pages are plain server-rendered HTML an
# anonymous `curl` gets at 200, and each entry carries its own Akamai-signed URL
# (`?__gda__=exp=…~acl=/*~hmac=…`, good for about an hour) beside the file's
# published SHA-256. A fixed-output derivation is the one kind with network
# access in the sandbox, which is all it takes to do the fetch where every other
# source is fetched. No upstream issue to wait on: requireFile is deliberate
# there, because downloading the file accepts a click-through EULA (see
# docs/citrix-workspace.md). Drop this if nixpkgs ever fetches it itself.
stdenvNoCC.mkDerivation {
  # `requireFile` hashes flat and names its path after the file, so this name
  # and hash land on exactly the store path upstream computes. That is worth
  # keeping: a tarball already in a binary cache, or added by hand with
  # `nix-store --add-fixed sha256`, substitutes for this derivation untouched.
  name = "linuxx64-${version}.tar.gz";

  nativeBuildInputs = [ curl ];

  outputHashAlgo = "sha256";
  outputHashMode = "flat";
  outputHash = hash;

  # The sandbox carries no system trust store, so pass the bundle in.
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  impureEnvVars = lib.fetchers.proxyImpureEnvVars;

  # Fetch where the result is wanted, as every other fetcher does...
  preferLocalBuild = true;
  # ...but never instead of substituting it: 370 MB out of our own cache beats
  # 370 MB out of Citrix. Spelled out because it is the whole reason this is not
  # a `runCommand`, which would have set it false.
  allowSubstitutes = true;

  latestPage = "https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html";
  legacyIndex = "https://www.citrix.com/downloads/workspace-app/legacy-workspace-app-for-linux/";

  buildCommand = builtins.readFile ./citrix-tarball.sh;
}
