# Workstation modules

Import this flake to build an x86_64-linux NixOS host or a standalone Home Manager home. The consumer pins the flake and owns host declarations, user identities, access grants and deployment-specific service addresses.

```nix
nixosConfigurations.laptop = workstation.lib.mkHost ./hosts/laptop;
homeConfigurations.demo = workstation.lib.mkHome ./users/demo.nix;
```

The helpers pass `workstation` to the host and home modules. Import features from `workstation.nixosModules` or `workstation.homeModules`. Individual modules can also be imported into an existing evaluation. Set `workstation.features.syncthing.enable = true` in a home under `mkHost` to configure the user's service, lingering and the host firewall rule. For a standalone home, the host administrator supplies lingering, Tailscale and the firewall rule.

## Standalone example

The example pins the source tree containing it. When copying the example to another repository, set its workstation input to the cloneable URL of your modules repository.

```sh
nix build --no-write-lock-file ./examples/standalone#homeConfigurations.demo.activationPackage
```

Edit the example's username and home directory before using Home Manager to activate it for a real account.

## Tests

Run `nix flake check` in this checkout to build the module checks. To run
one check, use its name, for example
`nix build --no-link .#checks.x86_64-linux.identity-routing`.
`standalone-home` builds the minimal example. `standalone-workstation-home`
and `integrated-system` exercise the broader fictional workstation.

The agent runtime checks boot disposable VMs. The lifecycle, development,
Herdr, VPN and shared-folder checks require nested KVM. Follow the
[VM storage and cleanup guide](docs/vm-tests.md) before running them.

## Locate and run executables

The shared home commands include `lexe NAME` to list Nixpkgs packages containing
an exact executable name, and `rexe NAME [ARG ...]` to run it in a temporary Nix
shell when there is one match. Multiple matches are printed as `PACKAGE#NAME`;
choose one with, for example, `rexe ripgrep#rg --version`. Non-default outputs
use `PACKAGE^OUTPUT#NAME`. No match or an ambiguous lookup exits nonzero.
These commands use the pinned prebuilt executable index and its matching
Nixpkgs revision; refresh both with `nix flake update nix-index-database` here, then update the module pin in the consuming flake.

## Package channels

The system follows `nixos-unstable`. Pixi and the default Craft apps use
the separately pinned `nixpkgs-packages` input on `nixpkgs-unstable`.
