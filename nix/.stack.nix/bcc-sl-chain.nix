{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = {};
    package = {
      specVersion = "1.10";
      identifier = { name = "bcc-sl-chain"; version = "3.2.0"; };
      license = "Apache-2.0";
      copyright = "2021 The-Blockchain-Company";
      maintainer = "hi@serokell.io";
      author = "Serokell";
      homepage = "";
      url = "";
      synopsis = "Bcc SL - transaction processing";
      description = "Bcc SL - transaction processing";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.base)
          (hsPkgs.aeson)
          (hsPkgs.aeson-options)
          (hsPkgs.array)
          (hsPkgs.base16-bytestring)
          (hsPkgs.bytestring)
          (hsPkgs.Cabal)
          (hsPkgs.bcc-crypto)
          (hsPkgs.canonical-json)
          (hsPkgs.bcc-sl-binary)
          (hsPkgs.bcc-sl-core)
          (hsPkgs.bcc-sl-crypto)
          (hsPkgs.bcc-sl-util)
          (hsPkgs.cborg)
          (hsPkgs.cereal)
          (hsPkgs.conduit)
          (hsPkgs.containers)
          (hsPkgs.cryptonite)
          (hsPkgs.data-default)
          (hsPkgs.deepseq)
          (hsPkgs.ekg-core)
          (hsPkgs.ether)
          (hsPkgs.exceptions)
          (hsPkgs.extra)
          (hsPkgs.filepath)
          (hsPkgs.fmt)
          (hsPkgs.formatting)
          (hsPkgs.formatting)
          (hsPkgs.free)
          (hsPkgs.generic-arbitrary)
          (hsPkgs.hashable)
          (hsPkgs.lens)
          (hsPkgs.lrucache)
          (hsPkgs.memory)
          (hsPkgs.mmorph)
          (hsPkgs.mono-traversable)
          (hsPkgs.mtl)
          (hsPkgs.neat-interpolation)
          (hsPkgs.megaparsec)
          (hsPkgs.QuickCheck)
          (hsPkgs.reflection)
          (hsPkgs.safecopy)
          (hsPkgs.safe-exceptions)
          (hsPkgs.serokell-util)
          (hsPkgs.template-haskell)
          (hsPkgs.text)
          (hsPkgs.time)
          (hsPkgs.time-units)
          (hsPkgs.transformers)
          (hsPkgs.universum)
          (hsPkgs.unordered-containers)
          ];
        build-tools = [
          (hsPkgs.buildPackages.cpphs or (pkgs.buildPackages.cpphs))
          ];
        };
      tests = {
        "chain-test" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.aeson)
            (hsPkgs.base16-bytestring)
            (hsPkgs.bytestring)
            (hsPkgs.bcc-crypto)
            (hsPkgs.bcc-sl-binary)
            (hsPkgs.bcc-sl-binary-test)
            (hsPkgs.bcc-sl-core)
            (hsPkgs.bcc-sl-core-test)
            (hsPkgs.bcc-sl-crypto)
            (hsPkgs.bcc-sl-crypto-test)
            (hsPkgs.bcc-sl-chain)
            (hsPkgs.bcc-sl-util)
            (hsPkgs.bcc-sl-util-test)
            (hsPkgs.containers)
            (hsPkgs.cryptonite)
            (hsPkgs.data-default)
            (hsPkgs.fmt)
            (hsPkgs.formatting)
            (hsPkgs.generic-arbitrary)
            (hsPkgs.hedgehog)
            (hsPkgs.hspec)
            (hsPkgs.lens)
            (hsPkgs.mtl)
            (hsPkgs.pvss)
            (hsPkgs.QuickCheck)
            (hsPkgs.random)
            (hsPkgs.serokell-util)
            (hsPkgs.formatting)
            (hsPkgs.time-units)
            (hsPkgs.universum)
            (hsPkgs.unordered-containers)
            (hsPkgs.vector)
            ];
          build-tools = [
            (hsPkgs.buildPackages.hspec-discover or (pkgs.buildPackages.hspec-discover))
            ];
          };
        };
      benchmarks = {
        "block-bench" = {
          depends = [
            (hsPkgs.QuickCheck)
            (hsPkgs.base)
            (hsPkgs.bytestring)
            (hsPkgs.criterion)
            (hsPkgs.bcc-sl-binary)
            (hsPkgs.bcc-sl-chain)
            (hsPkgs.bcc-sl-crypto)
            (hsPkgs.bcc-sl-core)
            (hsPkgs.bcc-sl-core-test)
            (hsPkgs.bcc-sl-crypto-test)
            (hsPkgs.bcc-sl-util-test)
            (hsPkgs.containers)
            (hsPkgs.data-default)
            (hsPkgs.deepseq)
            (hsPkgs.formatting)
            (hsPkgs.generic-arbitrary)
            (hsPkgs.random)
            (hsPkgs.text)
            (hsPkgs.universum)
            (hsPkgs.unordered-containers)
            (hsPkgs.vector)
            ];
          };
        };
      };
    } // rec { src = (pkgs.lib).mkDefault ../.././chain; }