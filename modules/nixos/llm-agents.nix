# shared-nixpkgs builds llm-agents from our nixpkgs, so our overlays (the
# retrying Zig fetcher) apply to it.
{ inputs, ... }:
{
  nixpkgs.overlays = [
    inputs.llm-agents.overlays.shared-nixpkgs
    (import ../../overlays/zig-fetch-deps)
  ];
}
