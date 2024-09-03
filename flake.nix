{
  description = "A scrollable-tiling Wayland compositor.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    crate2nix.url = "github:nix-community/crate2nix";

    niri-unstable.url = "github:YaLTeR/niri";
    niri-unstable.flake = false;

    niri-stable.url = "github:YaLTeR/niri/v0.1.8";
    niri-stable.flake = false;

    xwayland-satellite.url = "github:Supreeeme/xwayland-satellite";
    xwayland-satellite.flake = false;
  };

  outputs = inputs @ {
    self,
    flake-parts,
    crate2nix,
    nixpkgs,
    nixpkgs-stable,
    ...
  }: let
    call = nixpkgs.lib.flip import {
      inherit inputs kdl docs binds settings;
      inherit (nixpkgs) lib;
    };
    kdl = call ./kdl.nix;
    binds = call ./parse-binds.nix;
    docs = call ./generate-docs.nix;
    settings = call ./settings.nix;
    stylix-module = call ./stylix.nix;

    stable-revs = import ./refs.nix;

    date = {
      year = builtins.substring 0 4;
      month = builtins.substring 4 2;
      day = builtins.substring 6 2;
      hour = builtins.substring 8 2;
      minute = builtins.substring 10 2;
      second = builtins.substring 12 2;
    };

    fmt-date = raw: "${date.year raw}-${date.month raw}-${date.day raw}";
    fmt-time = raw: "${date.hour raw}:${date.minute raw}:${date.second raw}";

    version-string = orig: version-string orig.version;

    version-string' = orig-ver: src:
      if stable-revs ? ${src.rev}
      then "stable ${orig-ver}"
      else "unstable ${fmt-date src.lastModifiedDate} (commit ${src.rev})";

    package-version = orig: package-version' orig.version;

    package-version' = orig-ver: src:
      if stable-revs ? ${src.rev}
      then orig-ver
      else "${orig-ver}-unstable-${src.shortRev}";

    make-niri = nixpkgs.lib.makeOverridable ({
      src,
      pkgs,
      patches ? [],
    }: let
      tools = crate2nix.tools.${pkgs.stdenv.system};
      manifest = tools.generatedCargoNix {
        inherit src;
        name = "niri";
      };
      workspace = import manifest {
        inherit pkgs;
        buildRustCrateForPkgs = pkgs:
          pkgs.buildRustCrate.override {
            defaultCrateOverrides =
              pkgs.defaultCrateOverrides
              // (with pkgs; {
                # Q: Why do we need to override these?
                #    (nixpkgs)/(niri's dev flake) doesn't do this!
                #
                # A: crate2nix builds each crate in a separate derivation.
                #    This is to avoid building the same crate multiple times.
                #    Ultimately, that speeds up the build.
                #    But it also means that each crate has separate build inputs.
                #
                #    Many popular crates have "default overrides" in nixpkgs.
                #    But it doesn't cover all crates niri depends on.
                #    So we need to fix those last few ourselves.
                #
                #    (nixpkgs)/(niri's dev flake) uses `cargo` to build.
                #    And this builds all crates in the same derivation.
                #    That's why they don't override individual crates.
                libspa-sys = lib.const {
                  nativeBuildInputs = [pkg-config rustPlatform.bindgenHook];
                  buildInputs = [pipewire];
                };

                libspa = lib.const {
                  nativeBuildInputs = [pkg-config];
                  buildInputs = [pipewire];
                };

                pipewire-sys = lib.const {
                  nativeBuildInputs = [pkg-config rustPlatform.bindgenHook];
                  buildInputs = [pipewire];
                };

                gobject-sys = lib.const {
                  nativeBuildInputs = [pkg-config glib];
                };

                gio-sys = lib.const {
                  nativeBuildInputs = [pkg-config glib];
                };

                # For all niri crates, the hash of the source is different in CI than on my system.
                # KiaraGrouwstra reports identical hash to my system, so it really is only in CI.
                #
                # We suspect it might be due to the fact that CI uses a different version of nix.
                # But that shouldn't matter, because the hash is not derived from the nix version used!
                # It might also be some symptom of import-from-derivation, but i don't care to investigate.
                #
                # Ultimately, the solution looks stupid, but it does work:
                # Just override `src` attr to be the correct path based on the `src` argument.
                # This causes them to be predictable and based on the flake inputs, which is what we want.
                #
                # Everything builds the same way without this. But the hash is different.
                # And for binary caching to work, the hash must be identical.
                #
                # ---
                #
                # I'm also overriding the version.
                # This is unrelated to reproducibility, but looks similarly weird to src
                # The reason for overriding the version is:
                #
                # For stable: follow nix convention `X.Y.Z` instead of `vX.Y.Z`
                #
                # For unstable: include the date and commit hash;
                # => otherwise tools like `nix profile diff-closures` will miss differences in the niri version
                #    and might show an empty diff, even when niri version (commit) changes
                niri-ipc = attrs: {
                  src = "${src}/niri-ipc";
                  version = package-version attrs src;
                };

                niri-config = attrs: {
                  src = "${src}/niri-config";
                  version = package-version attrs src;
                  postPatch = "substituteInPlace src/lib.rs --replace ../.. ${src}";
                };

                niri = attrs: {
                  src = "${src}";
                  version = package-version attrs src;

                  inherit patches;

                  postPatch =
                    "substituteInPlace src/utils/mod.rs --replace "
                    + nixpkgs.lib.escapeShellArgs [
                      ''pub fn version() -> String {''
                      ''
                        #[allow(unreachable_code)]
                        pub fn version() -> String {
                          return "${version-string attrs src}".into();
                      ''
                    ];
                  buildInputs = [libxkbcommon libinput mesa libglvnd wayland pixman ];

                  # we want backtraces to be readable
                  dontStrip = true;

                  extraRustcOpts = [
                    "-C link-arg=-Wl,--push-state,--no-as-needed"
                    "-C link-arg=-lEGL"
                    "-C link-arg=-lwayland-client"
                    "-C link-arg=-Wl,--pop-state"

                    "-C debuginfo=line-tables-only"

                    # "/source/" is not very readable. "./" is better, and it matches default behaviour of cargo.
                    "--remap-path-prefix $NIX_BUILD_TOP/source=./"
                  ];

                  passthru.providedSessions = ["niri"];

                  postInstall = ''
                    mkdir -p $out/share/systemd/user
                    mkdir -p $out/share/wayland-sessions
                    mkdir -p $out/share/xdg-desktop-portal

                    cp ${src}/resources/niri-session $out/bin/niri-session
                    cp ${src}/resources/niri.service $out/share/systemd/user/niri.service
                    cp ${src}/resources/niri-shutdown.target $out/share/systemd/user/niri-shutdown.target
                    cp ${src}/resources/niri.desktop $out/share/wayland-sessions/niri.desktop
                    cp ${src}/resources/niri-portals.conf $out/share/xdg-desktop-portal/niri-portals.conf
                  '';

                  postFixup = "substituteInPlace $out/share/systemd/user/niri.service --replace /usr $out";
                };
              });
          };
      };
    in
      workspace.workspaceMembers.niri.build
      // {
        binds = abort "<package>.binds has been removed. use config.lib.niri.actions instead. it works even when using niri from nixpkgs.";
        inherit workspace;
      });

    make-niri' = nixpkgs.lib.makeOverridable ({
      src,
      pkgs,
      patches ? [],
      rustPlatform ? pkgs.rustPlatform,
      pkg-config ? pkgs.pkg-config,
      wayland ? pkgs.wayland,
      systemdLibs ? pkgs.systemdLibs,
      pipewire ? pkgs.pipewire,
      mesa ? pkgs.mesa,
      libglvnd ? pkgs.libglvnd,
      seatd ? pkgs.seatd,
      libinput ? pkgs.libinput,
      libxkbcommon ? pkgs.libxkbcommon,
      pango ? pkgs.pango,
      libdisplay-info ? pkgs.libdisplay-info,
    }: let
      manifest = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
      workspace-version = manifest.workspace.package.version;
    in
      rustPlatform.buildRustPackage {
        pname = "niri";
        version = package-version' workspace-version src;
        inherit src patches;
        cargoLock = {
          lockFile = "${src}/Cargo.lock";
          allowBuiltinFetchGit = true;
        };
        nativeBuildInputs = [
          pkg-config
          rustPlatform.bindgenHook
        ];

        buildInputs = [
          wayland
          systemdLibs
          pipewire
          mesa
          libglvnd
          seatd
          libdisplay-info 
          libinput
          libxkbcommon
          pango
        ];

        passthru.providedSessions = ["niri"];

        # we want backtraces to be readable
        dontStrip = true;

        RUSTFLAGS = [
          "-C link-arg=-Wl,--push-state,--no-as-needed"
          "-C link-arg=-lEGL"
          "-C link-arg=-lwayland-client"
          "-C link-arg=-Wl,--pop-state"

          "-C debuginfo=line-tables-only"

          # "/source/" is not very readable. "./" is better, and it matches default behaviour of cargo.
          "--remap-path-prefix $NIX_BUILD_TOP/source=./"
        ];

        postPatch = ''
          substituteInPlace src/utils/mod.rs --replace ${nixpkgs.lib.escapeShellArgs [
            ''pub fn version() -> String {''
            ''
              #[allow(unreachable_code)]
              pub fn version() -> String {
                return "${version-string' workspace-version src}".into();
            ''
          ]}
        '';

        postInstall = ''
          install -Dm0755 resources/niri-session -t $out/bin
          install -Dm0644 resources/niri.desktop -t $out/share/wayland-sessions
          install -Dm0644 resources/niri-portals.conf -t $out/share/xdg-desktop-portal
          install -Dm0644 resources/niri{-shutdown.target,.service} -t $out/share/systemd/user
        '';

        postFixup = ''
          substituteInPlace $out/share/systemd/user/niri.service --replace-fail /usr/bin $out/bin
        '';

        meta = with nixpkgs.lib; {
          description = "Scrollable-tiling Wayland compositor";
          homepage = "https://github.com/YaLTeR/niri";
          license = licenses.gpl3Only;
          maintainers = with maintainers; [sodiboo];
          mainProgram = "niri";
          platforms = platforms.linux;
        };
      });

    validated-config-for = pkgs: package: config:
      pkgs.runCommand "config.kdl" {
        inherit config;
        passAsFile = ["config"];
        buildInputs = [package];
      } ''
        niri validate -c $configPath
        cp $configPath $out
      '';

    package-set = {
      niri-stable = pkgs:
        make-niri' {
          inherit pkgs;
          src = inputs.niri-stable;
          patches = [];
        };
      niri-unstable = pkgs:
        make-niri' {
          inherit pkgs;
          src = inputs.niri-unstable;
        };
      xwayland-satellite = pkgs: let
        tools = crate2nix.tools.${pkgs.stdenv.system};
        manifest = tools.generatedCargoNix {
          src = inputs.xwayland-satellite;
          name = "xwayland-satellite";
        };
        workspace = import manifest {
          inherit pkgs;
          buildRustCrateForPkgs = pkgs:
            pkgs.buildRustCrate.override {
              defaultCrateOverrides =
                pkgs.defaultCrateOverrides
                // (with pkgs; {
                  xcb-util-cursor-sys = attrs: {
                    nativeBuildInputs = [pkg-config rustPlatform.bindgenHook];
                    buildInputs = [xcb-util-cursor];
                  };
                  xwayland-satellite = attrs: {
                    version = "${attrs.version}-${inputs.xwayland-satellite.shortRev}";

                    buildInputs = [makeWrapper];

                    postInstall = ''
                      wrapProgram $out/bin/xwayland-satellite \
                        --prefix PATH : "${lib.makeBinPath [xwayland]}"
                    '';
                  };
                });
            };
        };
      in
        workspace.workspaceMembers.xwayland-satellite.build;
    };
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux"];
      perSystem = {
        self',
        inputs',
        config,
        system,
        ...
      }: {
        packages =
          nixpkgs.lib.concatMapAttrs (name: make-for: {
            "${name}" = make-for inputs'.nixpkgs.legacyPackages;
            "${name}-for-nixos-stable" = make-for inputs'.nixpkgs-stable.legacyPackages;
          })
          package-set;

        apps = {
          niri-stable = {
            type = "app";
            program = "${self'.packages.niri-stable}/bin/niri";
          };
          niri-unstable = {
            type = "app";
            program = "${self'.packages.niri-unstable}/bin/niri";
          };

          default = self'.apps.niri-stable;
        };

        checks = let
          test-nixos-for = nixpkgs: modules:
            (nixpkgs.lib.nixosSystem {
              inherit system;
              modules =
                [
                  {
                    # This doesn't need to be a bootable system. It just needs to build.
                    system.stateVersion = "23.11";
                    fileSystems."/".fsType = "ext4";
                    fileSystems."/".device = "/dev/sda1";
                    boot.loader.systemd-boot.enable = true;
                  }
                ]
                ++ modules;
            })
            .config
            .system
            .build
            .toplevel;
        in {
          empty-config-valid-stable = let
            eval = nixpkgs.lib.evalModules {
              modules = [
                settings.module
                {
                  config.programs.niri.settings = {};
                }
              ];
            };
          in
            validated-config-for inputs'.nixpkgs.legacyPackages self'.packages.niri-stable eval.config.programs.niri.finalConfig;

          nixos-unstable = test-nixos-for nixpkgs [
            self.nixosModules.niri
            {
              programs.niri.enable = true;
            }
          ];

          nixos-stable = test-nixos-for nixpkgs-stable [
            self.nixosModules.niri
            {
              programs.niri.enable = true;
            }
          ];
        };

        devShells.default = inputs'.nixpkgs.legacyPackages.mkShell {
          packages = with inputs'.nixpkgs.legacyPackages; [
            just
            fish
            fd
            entr
            moreutils
          ];

          shellHook = ''
            just hook 2>/dev/null
          '';
        };

        formatter = inputs'.nixpkgs.legacyPackages.alejandra;
      };

      flake = {
        overlays.niri = with nixpkgs.lib; final: prev: mapAttrs (const (flip id final)) package-set;
        lib = {
          inherit kdl;
          internal = {
            inherit package-set make-niri validated-config-for;
            docs-markdown = docs.make-docs (settings.fake-docs {inherit fmt-date fmt-time;});
            settings-module = settings.module;
          };
        };
        homeModules.stylix = stylix-module;
        homeModules.config = {
          config,
          pkgs,
          ...
        }:
          with nixpkgs.lib; let
            cfg = config.programs.niri;
          in {
            imports = [
              settings.module
            ];

            options.programs.niri = {
              package = mkOption {
                type = types.package;
                default = package-set.niri-stable pkgs;
              };
            };

            config.lib.niri = {
              actions = mergeAttrsList (map ({
                name,
                fn,
                ...
              }: {
                ${name} = fn;
              }) (binds cfg.package.src));
            };

            config.xdg.configFile.niri-config = {
              enable = cfg.finalConfig != null;
              target = "niri/config.kdl";
              source = validated-config-for pkgs cfg.package cfg.finalConfig;
            };
          };
        nixosModules.niri = {
          config,
          options,
          pkgs,
          ...
        }: let
          cfg = config.programs.niri;
        in
          with nixpkgs.lib; {
            options.programs.niri = {
              enable = mkEnableOption "niri";
              package = mkOption {
                type = types.package;
                default = package-set.niri-stable pkgs;
              };
            };

            options.niri-flake.cache.enable = mkOption {
              type = types.bool;
              default = true;
            };

            config = mkMerge [
              (mkIf config.niri-flake.cache.enable {
                nix.settings = {
                  substituters = ["https://niri.cachix.org"];
                  trusted-public-keys = ["niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="];
                };
              })
              {
                environment.systemPackages = [pkgs.xdg-utils];
                xdg = {
                  autostart.enable = mkDefault true;
                  menus.enable = mkDefault true;
                  mime.enable = mkDefault true;
                  icons.enable = mkDefault true;
                };
              }
              (mkIf cfg.enable {
                services =
                  if nixpkgs.lib.strings.versionAtLeast config.system.nixos.release "24.05"
                  then {
                    displayManager.sessionPackages = [cfg.package];
                  }
                  else {
                    xserver.displayManager.sessionPackages = [cfg.package];
                  };
                hardware =
                  if nixpkgs.lib.strings.versionAtLeast config.system.nixos.release "24.11"
                  then {
                    graphics.enable = mkDefault true;
                  }
                  else {
                    opengl.enable = mkDefault true;
                  };
              })
              (mkIf cfg.enable {
                environment.systemPackages = [cfg.package];
                xdg.portal = {
                  enable = true;
                  extraPortals = with pkgs; [xdg-desktop-portal-gnome  xdg-desktop-portal-gtk];
                  configPackages = [cfg.package];
                };

                security.polkit.enable = true;
                services.gnome.gnome-keyring.enable = true;
                systemd.user.services.niri-flake-polkit = {
                  description = "PolicyKit Authentication Agent provided by niri-flake";
                  wantedBy = ["niri.service"];
                  wants = ["graphical-session.target"];
                  after = ["graphical-session.target"];
                  serviceConfig = {
                    Type = "simple";
                    ExecStart = "${pkgs.libsForQt5.polkit-kde-agent}/libexec/polkit-kde-authentication-agent-1";
                    Restart = "on-failure";
                    RestartSec = 1;
                    TimeoutStopSec = 10;
                  };
                };

                security.pam.services.swaylock = {};
                programs.dconf.enable = mkDefault true;
                fonts.enableDefaultPackages = mkDefault true;
              })
              (optionalAttrs (options ? home-manager) {
                home-manager.sharedModules =
                  [
                    self.homeModules.config
                    {programs.niri.package = mkForce cfg.package;}
                  ]
                  ++ optionals (options ? stylix) [self.homeModules.stylix];
              })
            ];
          };
        homeModules.niri = {
          config,
          pkgs,
          ...
        }:
          with nixpkgs.lib; let
            cfg = config.programs.niri;
          in {
            imports = [
              self.homeModules.config
            ];
            options.programs.niri = {
              enable = mkEnableOption "niri";
            };

            config = mkIf cfg.enable {
              home.packages = [cfg.package];
              services.gnome-keyring.enable = true;
              xdg.portal = {
                enable = true;
                extraPortals = with pkgs; [xdg-desktop-portal-gnome xdg-desktop-portal-gtk];
                configPackages = [cfg.package];
              };
            };
          };
      };
    };
}
