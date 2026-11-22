{
  description = "A standalone home on non-NixOS Linux";
  inputs.workstation.url = "path:../..";
  outputs = { workstation, ... }: {
    homeConfigurations.demo = workstation.lib.mkHome ./home.nix;
  };
}
