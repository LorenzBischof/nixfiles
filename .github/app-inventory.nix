# Flat inventory of the applications a host config names, with their versions.
#
# Evaluating this against two flake.lock revisions and diffing the result shows
# which applications an input bump actually moved — without realising a closure,
# so it needs no binary cache and downloads nothing. It deliberately covers only
# packages the configuration names (enabled services, system packages, per-user
# home-manager packages), not their transitive library dependencies.
#
# Used as: nix eval --json '<flake>#nixosConfigurations.<host>.config' \
#            --apply 'import ./.github/app-inventory.nix'
config:
let
  inherit (builtins)
    attrNames
    concatLists
    filter
    listToAttrs
    map
    tryEval
    ;

  # Packages without a `version` are wrappers and generated derivations whose
  # version can never change; dropping them keeps the diff to real applications.
  entry =
    source: drv:
    let
      version = drv.version or null;
    in
    if (drv.type or "") == "derivation" && version != null && version != "" then
      "${drv.pname or drv.name} ${version} (${source})"
    else
      null;

  fromList = source: list: map (entry source) list;

  # Keyed off the generated units rather than `services`: forcing every
  # `services.*.enable` aborts on renamed-option modules (services.frp does),
  # and `abort` is not catchable with tryEval.
  serviceEntries = map (
    name:
    let
      package = tryEval (config.services.${name}.package or null);
    in
    if package.success && package.value != null then entry "service" package.value else null
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

  entries = filter (line: line != null) (
    serviceEntries ++ fromList "system" config.environment.systemPackages ++ hmEntries
  );
in
# attrNames sorts and deduplicates, which is what makes the diff line up.
attrNames (
  listToAttrs (
    map (line: {
      name = line;
      value = null;
    }) entries
  )
)
