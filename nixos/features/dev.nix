# System development capabilities; select home/features/dev.nix separately.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    gcc
    gnumake
  ];

  # Expose the system CA bundle to tools configured to use /etc/ssl/cert.pem.
  environment.etc."ssl/cert.pem" = lib.mkIf config.security.pki.installCACerts {
    source = config.security.pki.caBundle;
  };

  # uv, mise and pyenv all install generic-linux interpreters that ask for
  # /lib64/ld-linux-x86-64.so.2. Without nix-ld that path is a stub whose only
  # job is to print an error, so `uv run` cannot start at all.
  #
  # CPython itself only needs glibc — python-build-standalone links openssl,
  # sqlite and zlib in statically. The list below is for the manylinux wheels
  # that get installed on top and dlopen their dependencies at import time; a
  # missing libstdc++ is the usual first symptom.
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      openssl
      libffi
      bzip2
      xz
      expat
      ncurses
      readline
      sqlite
      libuuid
      libxml2
      glib
      libGL
      fontconfig
      freetype
    ];
  };

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };
}
