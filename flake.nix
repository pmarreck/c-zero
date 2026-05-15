{
	description = "C0 - Hierarchical binary data stream format";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		zig-overlay = {
			url = "github:mitchellh/zig-overlay";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = { self, nixpkgs, zig-overlay }:
		let
			pname = "c0";
			version = "0.1.0";
			allSystems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs allSystems;
			zigFor = system: zig-overlay.packages.${system}."0.16.0";

			# Fixed-output derivation hash for Zig dependencies
			# To update: set to "" and run `nix build` — the error will show the correct hash
			zigDepsHash = "sha256-esF+XFqSa2jTWuwS4tzGSlYBdAhAOnFquwOJtJAarls=";

			mkZigDeps = pkgs: zig: let isDarwin = pkgs.stdenv.isDarwin; in pkgs.stdenv.mkDerivation {
				pname = "${pname}-zig-deps";
				inherit version;
				src = self;
				nativeBuildInputs = [ zig pkgs.git pkgs.cacert ]
					++ pkgs.lib.optionals isDarwin [
						pkgs.darwin.cctools
						pkgs.apple-sdk
					];
				outputHashMode = "recursive";
				outputHashAlgo = "sha256";
				outputHash = zigDepsHash;
				buildPhase = ''
					export HOME=$TMPDIR
					export ZIG_GLOBAL_CACHE_DIR=$out
					export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
					export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
					zig build --fetch=all
				'';
				dontInstall = true;
				dontFixup = true;
			};
		in {
			packages = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					zig = zigFor system;
					isDarwin = pkgs.stdenv.isDarwin;
					zigDeps = mkZigDeps pkgs zig;
				in {
					default = pkgs.stdenv.mkDerivation {
						inherit pname version;
						src = self;
						nativeBuildInputs = [ zig ]
							++ pkgs.lib.optionals isDarwin [
								pkgs.darwin.cctools
								pkgs.apple-sdk
							];
						buildPhase = ''
							export HOME="$TMPDIR"
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							mkdir -p $ZIG_GLOBAL_CACHE_DIR
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
							zig build --prefix $out -Doptimize=ReleaseFast
						'';
						dontInstall = true;
						dontFixup = true;
					};
				});

			checks = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					zig = zigFor system;
					isDarwin = pkgs.stdenv.isDarwin;
					zigDeps = mkZigDeps pkgs zig;
				in {
					tests = pkgs.stdenv.mkDerivation {
						pname = "${pname}-tests";
						inherit version;
						src = self;
						nativeBuildInputs = [ zig ]
							++ pkgs.lib.optionals isDarwin [
								pkgs.darwin.cctools
								pkgs.apple-sdk
							];
						buildPhase = ''
							export HOME="$TMPDIR"
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							mkdir -p $ZIG_GLOBAL_CACHE_DIR
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
							timeout 600 zig build test || { echo "Tests failed"; exit 1; }
						'';
						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
						'';
					};
				});

			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					zig = zigFor system;
				in {
					default = pkgs.mkShell {
						packages = [
							zig
							pkgs.git
						];
						shellHook = ''
							unset LD
							unset SDKROOT
							export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
						'';
					};
				});
		};
}
