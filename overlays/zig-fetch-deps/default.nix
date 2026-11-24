# Gives zig_0_16, which herdr builds with, the retrying fetchDeps from
# ./fetcher.nix. fetchDeps is passthru, so zig itself is unchanged. A package
# that moves to another Zig version needs that version added here.
final: prev: {
  zig_0_16 = prev.zig_0_16.overrideAttrs (
    finalAttrs: old: {
      passthru = old.passthru // {
        fetchDeps = final.callPackage ./fetcher.nix { zig = finalAttrs.finalPackage; };
      };
    }
  );
}
