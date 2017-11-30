{ stdenv, buildGoPackage, fetchFromGitHub, clang }:

buildGoPackage rec {
  name = "ethsign-${version}";
  version = "0.6.1";

  goPackagePath = "github.com/dapphub/ethsign";
  hardeningDisable = ["fortify"];
  src = ./.;

  extraSrcs = [
    {
      goPackagePath = "github.com/ethereum/go-ethereum";
      src = fetchFromGitHub {
        owner = "ethereum";
        repo = "go-ethereum";
        rev = "v1.7.3";
        sha256 = "1w6rbq2qpjyf2v9mr18yiv2af1h2sgyvgrdk4bd8ixgl3qcd5b11";
      };
    }
    {
      goPackagePath = "gopkg.in/urfave/cli.v1";
      src = fetchFromGitHub {
        owner = "urfave";
        repo = "cli";
        rev = "v1.19.1";
        sha256 = "1ny63c7bfwfrsp7vfkvb4i0xhq4v7yxqnwxa52y4xlfxs4r6v6fg";
      };
    }
  ];

  meta = with stdenv.lib; {
    homepage = http://github.com/dapphub/ethsign;
    description = "Make raw signed Ethereum transactions";
    license = [licenses.gpl3];
  };
}
