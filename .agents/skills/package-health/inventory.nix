# Audit variant of ../../../.github/app-inventory.nix.
#
# That one emits "<name> <version> (<source>)" strings, because its job is to
# diff two flake.lock revisions. This one emits a JSON object per package,
# because the audit needs `src.drvPath` (to resolve the forge), `meta.position`
# (to tell nixpkgs from other flake inputs, and to recover an attrpath) and
# `source` (service / system / home, for reviewing how the package is used).
#
# Keep the two in step on what they *cover*: enabled services' `.package`,
# `environment.systemPackages`, and per-user `home.packages`.
#
# Used by gather.py as:
#   nix eval --json '<flake>#nixosConfigurations.<host>.config' \
#     --apply "$(cat inventory.nix)"
config:
let
  inherit (builtins)
    attrNames
    concatLists
    filter
    map
    toJSON
    tryEval
    ;

  # Packages without a `version` are wrappers and generated derivations whose
  # version can never change.
  entry =
    source: drv:
    let
      version = drv.version or null;
      srcDrv =
        let
          r = tryEval (toString (drv.src.drvPath or ""));
        in
        if r.success then r.value else "";
      pos =
        let
          r = tryEval (toString ((drv.meta or { }).position or ""));
        in
        if r.success then r.value else "";
    in
    if (drv.type or "") == "derivation" && version != null && version != "" then
      {
        name = drv.pname or drv.name;
        inherit version source;
        src = srcDrv;
        position = pos;
      }
    else
      null;

  # `toJSON` forces deeply, so this is the one place that can catch a package
  # which throws (unfree, broken, wrong platform). Per-field `or` defaults do
  # not help: `tryEval` does not catch missing-attribute errors at all, and it
  # forces only to WHNF, so a throwing value would escape at the comparison.
  safeEntry =
    source: drv:
    let
      r = tryEval (toJSON (entry source drv));
    in
    if r.success then r.value else null;

  fromList = source: list: map (safeEntry source) list;

  # Keyed off the generated units rather than `services`: forcing every
  # `services.*.enable` aborts on renamed-option modules (services.frp does),
  # and `abort` is not catchable with tryEval.
  serviceEntries = map (
    name:
    let
      package = tryEval (config.services.${name}.package or null);
    in
    if package.success && package.value != null then safeEntry "service" package.value else null
  ) (attrNames config.systemd.services);

  hmUsers =
    let
      users = tryEval (config.home-manager.users or { });
    in
    if users.success then users.value else { };

  hmEntries = concatLists (
    map (
      user:
      let
        packages = tryEval (hmUsers.${user}.home.packages or [ ]);
      in
      if packages.success then fromList "home" packages.value else [ ]
    ) (attrNames hmUsers)
  );
in
filter (line: line != null && line != "null") (
  serviceEntries ++ fromList "system" config.environment.systemPackages ++ hmEntries
)
