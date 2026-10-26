{
  lib,
  stdenv,
  kernel,
  kernelModuleMakeFlags,
  src,
}:

# Vendored instead of using the upstream flake's own nixosModule: upstream
# installs the .ko files with install(1) straight out of the build directory,
# which never runs Kbuild's signing step, so no .ko.cer is produced and
# aggregateModules fails with "cat: ...ko.cer: No such file or directory".
# See NixOS/nixpkgs#575192 - nixpkgs fixes this per-package rather than making
# the aggregator tolerant, so the same fix has to happen here.
stdenv.mkDerivation {
  pname = "asustor-platform-driver";
  version = "0.2-unstable-2025-12-07";

  inherit src;

  hardeningDisable = [
    "pic"
    "format"
  ];
  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = kernelModuleMakeFlags ++ [
    "KERNEL_MODULES=${kernel.dev}/lib/modules/${kernel.modDirVersion}"
  ];

  # The upstream Makefile lists modules_install in .PHONY but never defines a
  # rule for it, so the target has to come from the kernel's own Makefile.
  # Going through it is what signs the modules and emits the .ko.cer files;
  # it also compresses and strips them, which the hand-rolled install did not.
  installTargets = [ "modules_install" ];
  installFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=extra"
  ];

  meta = {
    description = "Kernel modules for ASUSTOR NAS hardware (LEDs, fan and GPIO via IT87)";
    homepage = "https://github.com/mafredri/asustor-platform-driver";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
