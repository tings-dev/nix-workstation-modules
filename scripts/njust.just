# Update and commit flake inputs, then activate this host
update:
    nix flake update
    git diff --quiet HEAD -- flake.lock || git commit --only -m "chore(nix): update flake inputs" -- flake.lock
    @switchCommand@

# Activate this host using the current checkout and pinned inputs
switch:
    @switchCommand@

# Show prepared-update status using the configuration checkout's task
update-status host="":
    just --justfile ./justfile update-status "{{ host }}"

# Activate the prepared system using the configuration checkout's task
apply host="":
    just --justfile ./justfile apply "{{ host }}"
