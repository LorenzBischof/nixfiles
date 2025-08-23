# Important information

- Search for both home-manager and system options, while preferring home-manager. 
- Always prefer options, instead of packages.
- Keep related configuration in separate files. 
- If the content is only related to one host, it should be located under ./hosts, otherwise create a module at ./modules.
- Use `nix flake lock` when adding or removing Flake inputs
- Only update specific flake inputs with `nix flake update <input>` if there is a reason (e.g. changelog suggests a bug was fixed)
- Test changes with `just test` for the laptop or `just test <host>`
