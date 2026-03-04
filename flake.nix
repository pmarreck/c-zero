{
	description = "C0 - Hierarchical binary data stream format";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			pname = "c0";
			version = "0.1.0";
			allSystems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs allSystems;

			# Fixed-output derivation hash for Zig dependencies
			# To update: set to "" and run `nix build` — the error will show the correct hash
			zigDepsHash = "sha256-RQmFFAFLHIKLSLMhu1aQW8TII/pc4lkZll4ldJhFmwQ=";

			mkZigDeps = pkgs: let isDarwin = pkgs.stdenv.isDarwin; in pkgs.stdenv.mkDerivation {
				pname = "${pname}-zig-deps";
				inherit version;
				src = self;
				nativeBuildInputs = [ pkgs.zig pkgs.git pkgs.cacert ]
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
					isDarwin = pkgs.stdenv.isDarwin;
					zigDeps = mkZigDeps pkgs;
				in {
					default = pkgs.stdenv.mkDerivation {
						inherit pname version;
						src = self;
						nativeBuildInputs = [ pkgs.zig ]
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
					isDarwin = pkgs.stdenv.isDarwin;
					zigDeps = mkZigDeps pkgs;
				in {
					tests = pkgs.stdenv.mkDerivation {
						pname = "${pname}-tests";
						inherit version;
						src = self;
						nativeBuildInputs = [ pkgs.zig ]
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
				in {
					default = pkgs.mkShell {
						packages = with pkgs; [
							zig
							git
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
