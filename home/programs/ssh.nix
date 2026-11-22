# Shared SSH connections, independent of the local identity mechanism.
{ ... }:

{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    # Read local overrides first: OpenSSH uses the first value it obtains.
    includes = [ "config.d/*" ];
  };

  # Ensure the include directory exists without managing its local entries.
  home.file.".ssh/config.d/.keep".text = "";
}
