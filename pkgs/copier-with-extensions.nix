# copier, plus the Jinja extension loader that templates import by module name.
#
# nixpkgs builds copier as a python application with a closed environment: a
# template's `_jinja_extensions` can only import what copier itself depends on,
# so `copier_templates_extensions.TemplateExtensionLoader` fails however the
# module is installed elsewhere. Extending copier's own dependency list is the
# way to put the loader where copier will find it.
#
# Two packages, because upstream renamed itself. `copier-template-extensions`
# is the real one; `copier-templates-extensions` (plural) is the deprecated
# alias, kept because templates still written against the old module name — the
# frkl python-project-template among them — import it under that spelling.
{
  copier,
  fetchPypi,
  python3Packages,
}:

let
  # Wheels rather than sdists: both are pure python, and the sdists build
  # through pdm-backend with a version hook that is not shipped in them.
  fetchWheel =
    {
      pname,
      version,
      hash,
    }:
    fetchPypi {
      inherit pname version hash;
      format = "wheel";
      dist = "py3";
      python = "py3";
    };

  # Neither package declares its copier dependency here: copier is what pulls
  # these in, and naming it back would close the loop.
  copier-template-extensions = python3Packages.buildPythonPackage rec {
    pname = "copier_template_extensions";
    version = "0.3.3";
    format = "wheel";

    src = fetchWheel {
      inherit pname version;
      hash = "sha256-v2u9662iYTJkDW4RKHI/of9+tZ0AjeB6dUPFHg+ssOo=";
    };

    # jinja2 is the half of the runtime this package really needs; the other
    # half is copier itself, which is exactly the loop this file avoids.
    dependencies = [ python3Packages.jinja2 ];

    # Both checks come back to copier: the wheel declares it as a runtime
    # dependency, and the module imports it. The stock nixpkgs copier answers
    # for that at build time without the override pointing back at itself.
    dontCheckRuntimeDeps = true;
    nativeCheckInputs = [ python3Packages.copier ];

    pythonImportsCheck = [ "copier_template_extensions" ];
  };

  copier-templates-extensions = python3Packages.buildPythonPackage rec {
    pname = "copier_templates_extensions";
    version = "0.3.2";
    format = "wheel";

    src = fetchWheel {
      inherit pname version;
      hash = "sha256-oXfuNPM4irEVKsgmCoG7jnmIlN9iVnxAr8rXtL04f2Q=";
    };

    dependencies = [ copier-template-extensions ];

    nativeCheckInputs = [ python3Packages.copier ];
    pythonImportsCheck = [ "copier_templates_extensions" ];
  };
in

copier.overridePythonAttrs (old: {
  dependencies = old.dependencies ++ [
    copier-template-extensions
    copier-templates-extensions
  ];
})
