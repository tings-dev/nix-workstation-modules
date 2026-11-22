# Common workstation defaults, selected explicitly by each host.
# Host-specific hardware, disks, networking and stateVersion stay in hosts/.
{ lib, pkgs, ... }:

{
  imports = [
    ./nix.nix
    ./management.nix
    ./features/netbird.nix
  ];

  # These defaults can be overridden by an ordinary host setting.
  time.timeZone = lib.mkDefault "Europe/Berlin";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
  console.keyMap = lib.mkDefault "us";

  # Keep swap independent of the host's disk layout.
  zramSwap.enable = lib.mkDefault true;

  # Enable the client; enrollment remains runtime state.
  services.tailscale.enable = true;

  # Share DNS between LAN, Tailscale and the hardened NetBird client. The
  # resolved module wires NetworkManager and /etc/resolv.conf to its stub;
  # NetBird's module grants its client permission to register DNS via PolicyKit.
  services.resolved.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    # Keep both the graphed overview and the plain terminal process viewer.
    btop
    curl
    git
    htop
    jq
    just
    rsync
    tree
    vim
    wget
  ];
}
