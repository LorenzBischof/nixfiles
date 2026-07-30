{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  requests,
  pycryptodome,
  macaddress,
}:

# Not in nixpkgs. Auto-detects the TP-Link/Archer/Mercusys router model and
# handles its RSA+AES login handshake - see docs/router-debugging.md.
buildPythonPackage rec {
  pname = "tplinkrouterc6u";
  version = "5.26.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-pxGY7J+1BjDBd9ezrWHthC+AEVquM+DvqIaKmop9F9E=";
  };

  build-system = [ setuptools ];

  dependencies = [
    requests
    pycryptodome
    macaddress
  ];

  # No tests shipped in the sdist.
  doCheck = false;

  pythonImportsCheck = [ "tplinkrouterc6u" ];

  meta = {
    description = "Python API client for TP-Link/Mercusys routers (RSA+AES web-login handshake)";
    homepage = "https://github.com/AlexandrErohin/TP-Link-Archer-C6U";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.all;
  };
}
