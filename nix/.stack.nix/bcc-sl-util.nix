{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = {};
    package = {
      specVersion = "1.10";
      identifier = { name = "bcc-sl-util"; version = "3.2.0"; };
      license = "Apache-2.0";
      copyright = "2021 The-Blockchain-Company";
      maintainer = "support@bcccoin.io";
      author = "TBCO";
      homepage = "https://github.com/The-Blockchain-Company/bcc-sl";
      url = "";
      synopsis = "Bcc SL - general utilities";
      description = "This package contains utility functions not specific\nto Bcc SL which extend 3rd party libraries or implement\nsomething from scratch.";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.aeson)
          (hsPkgs.auto-update)
          (hsPkgs.base)
          (hsPkgs.canonical-json)
          (hsPkgs.cborg)
          (hsPkgs.cereal)
          (hsPkgs.containers)
          (hsPkgs.concurrent-extra)
          (hsPkgs.contravariant)
          (hsPkgs.cryptonite)
          (hsPkgs.deepseq)
          (hsPkgs.directory)
          (hsPkgs.ether)
          (hsPkgs.exceptions)
          (hsPkgs.file-embed)
          (hsPkgs.filepath)
          (hsPkgs.formatting)
          (hsPkgs.hashable)
          (hsPkgs.katip)
          (hsPkgs.lens)
          (hsPkgs.lrucache)
          (hsPkgs.megaparsec)
          (hsPkgs.mmorph)
          (hsPkgs.monad-control)
          (hsPkgs.mtl)
          (hsPkgs.optparse-applicative)
          (hsPkgs.process)
          (hsPkgs.reflection)
          (hsPkgs.resourcet)
          (hsPkgs.safe-exceptions)
          (hsPkgs.serokell-util)
          (hsPkgs.stm)
          (hsPkgs.tagged)
          (hsPkgs.template-haskell)
          (hsPkgs.text)
          (hsPkgs.time)
          (hsPkgs.time-units)
          (hsPkgs.transformers)
          (hsPkgs.transformers-base)
          (hsPkgs.transformers-lift)
          (hsPkgs.universum)
          (hsPkgs.unliftio-core)
          (hsPkgs.unordered-containers)
          (hsPkgs.yaml)
          ];
        build-tools = [
          (hsPkgs.buildPackages.cpphs or (pkgs.buildPackages.cpphs))
          ];
        };
      tests = {
        "util-test" = {
          depends = [
            (hsPkgs.aeson)
            (hsPkgs.aeson-pretty)
            (hsPkgs.base)
            (hsPkgs.bytestring)
            (hsPkgs.async)
            (hsPkgs.canonical-json)
            (hsPkgs.bcc-sl-util)
            (hsPkgs.cereal)
            (hsPkgs.directory)
            (hsPkgs.file-embed)
            (hsPkgs.filepath)
            (hsPkgs.formatting)
            (hsPkgs.hedgehog)
            (hsPkgs.hspec)
            (hsPkgs.pretty-show)
            (hsPkgs.QuickCheck)
            (hsPkgs.quickcheck-instances)
            (hsPkgs.safecopy)
            (hsPkgs.stm)
            (hsPkgs.template-haskell)
            (hsPkgs.text)
            (hsPkgs.time)
            (hsPkgs.time-units)
            (hsPkgs.universum)
            (hsPkgs.unordered-containers)
            (hsPkgs.yaml)
            ];
          build-tools = [
            (hsPkgs.buildPackages.hspec-discover or (pkgs.buildPackages.hspec-discover))
            (hsPkgs.buildPackages.cpphs or (pkgs.buildPackages.cpphs))
            ];
          };
        };
      };
    } // rec { src = (pkgs.lib).mkDefault ../.././util; }