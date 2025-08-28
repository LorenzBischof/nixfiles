# Important information

- Search for both home-manager and system options, while preferring home-manager. 
- Always prefer options, instead of packages.
- Keep related configuration in separate files. 
- If the content is only related to one host, it should be located under ./hosts, otherwise create a module at ./modules.
- Use `nix flake lock` when adding or removing Flake inputs
- Only update specific flake inputs with `nix flake update <input>` if there is a reason (e.g. changelog suggests a bug was fixed)
- Test changes with `just test` for the laptop or `just test <host>`
- The log of `just test` is printed to stderr. All errors are always located after the first occurence of the 'error:' string. Ignore everything before the first 'error:' string. If there are any errors, suggest a change which might resolve the error and try again. 
- The current Nix configuration can be evaluated with `nix eval`. Example for the nas host and `services.nginx.enable`: `nix eval --json '.#nixosConfigurations.nas.options.services.nginx.enable.definitionsWithLocations'`. This will also print the file where the definition is located, however the file will be located in the Nix store. Ignore the store path prefix to figure out the real file path. Prefer this method instead of manually looking at files.
