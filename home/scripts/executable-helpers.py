"""Find and run exact executable names from the prebuilt nix-index database."""

import os
import subprocess
import sys


def executable_name(value):
    return bool(value) and value not in (".", "..") and not any(
        char.isspace() or char in "/#" for char in value
    )


def packages(name):
    # nix-locate excludes matches known only through dependencies by default.
    result = subprocess.run(
        [
            "nix-locate", "--minimal", "--no-group",
            "--type", "x", "--type", "s", "--whole-name", "--at-root",
            "--", f"/bin/{name}",
        ],
        check=True, stdout=subprocess.PIPE, text=True,
    )
    matches = set()
    for line in result.stdout.splitlines():
        # nix-locate reports attr.output, including non-default outputs.
        attribute, separator, output = line.strip().rpartition(".")
        if not separator or not attribute or not output:
            raise ValueError(f"unexpected nix-locate result: {line!r}")
        matches.add(attribute if output == "out" else f"{attribute}^{output}")
    return sorted(matches)


def main(mode, nixpkgs, args):
    if not args or args[0] in ("-h", "--help"):
        print(
            "usage: lexe NAME" if mode == "lexe"
            else "usage: rexe [PACKAGE#]NAME [ARG ...]",
            file=sys.stdout if args else sys.stderr,
        )
        return 0 if args else 2
    if mode == "lexe" and len(args) != 1:
        raise ValueError("usage: lexe NAME")

    selector, *arguments = args
    if mode == "rexe" and "#" in selector:
        package, name = selector.split("#", 1)
        if not package or any(char.isspace() or char in "/#" for char in package):
            raise ValueError("expected PACKAGE#NAME")
    else:
        package, name = None, selector
    if not executable_name(name):
        raise ValueError("expected an executable name without a path or '#'")

    if package is None:
        matches = packages(name)
        if not matches:
            print(f"{mode}: no packages contain executable {name!r}", file=sys.stderr)
            return 1
        if mode == "lexe":
            print("\n".join(matches))
            return 0
        if len(matches) > 1:
            print("\n".join(f"{match}#{name}" for match in matches))
            return 1
        package = matches[0]

    # Use the requested executable, rather than the package's default program.
    # nix shell provides its sibling commands and preserves the program's exit
    # status, signals, terminal and arguments without installing a profile.
    os.execvp("nix", ["nix", "shell", f"{nixpkgs}#{package}", "--command", name, *arguments])


if __name__ == "__main__":
    mode, nixpkgs, *args = sys.argv[1:]
    try:
        sys.exit(main(mode, nixpkgs, args))
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode if error.returncode > 0 else 1)
    except (OSError, ValueError) as error:
        print(f"{mode}: {error}", file=sys.stderr)
        sys.exit(1)
