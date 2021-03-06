{ config, pkgs, lib, ... } @ args:

with lib;

let
  cfg = config.nixcloud.reverse-proxy;
  stateDir = "/var/lib/nixcloud/reverse-proxy";
  user = "reverse-proxy";
  group = "reverse-proxy";
  mkBasicAuth = authDef: let
    htpasswdFile = pkgs.writeText "basicAuth.htpasswd" (
      concatStringsSep "\n" (mapAttrsToList (user: password: ''
        ${user}:{PLAIN}${password}
      '') authDef)
    );
  in ''
    auth_basic secured;
    auth_basic_user_file ${htpasswdFile};
  '';

in

{
  options = {
    nixcloud.reverse-proxy = {
      enable = mkEnableOption "reverse-proxy";
      httpPort = mkOption {
        type = types.int;
        default = 80;
        description = ''Port where the reverse proxy listens for incoming http requests. Note: This port is added to `networking.allowedTCPPorts`.'';
      };
      httpsPort = mkOption {
        type = types.int;
        default = 443;
        description = ''Port where the reverse proxy listens for incoming https requests. Note: This port is added to  `networking.allowedTCPPorts`'';
      };
      extendEtcHosts = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Write all configured domains into /etc/hosts using networking.extraHosts with ::1 and 127.0.0.1 as host ip. This helps with testing webservices and isn't required in production if DNS was setup correctly and has already propagated.
        ''; # '
      };
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Extend the nginx configuration of the generated nixcloud.reverse-proxy
          configuration file.
        '';
        example = ''
          server {
            listen 80;
            listen [::]:80;
            server_name test.t;
            location /blog {
              rewrite     ^   https://$server_name$request_uri? permanent;
            }
          }
        '';
      };
      configFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          The path to a configuration which can be used instead the generated one. If the `configFile` option is used most other options are completely ignored.
          This option exists because on nixcloud.io we need to generate the configuration file externally since we can't run `nixos-rebuild switch`.
        ''; #'
      };
      extraMappings = mkOption {
        type = types.listOf (types.submodule (import ./options.nix));
        default = [];
        description = ''
          Can be used to append proxy-mappings, created manually, for services not supporting `proxyOptions` in `nixcloud` namespace.
        '';
        example = ''
          [{
            port   = 3333;
            path   = "/tour";
            domain = "nixcloud.io";
            ip = "127.0.0.1";
          }];
        '';
      };
    };
  };

  config = let
    generateNginxConfigFile = allProxyOptions: allNCWDomains: pkgs.writeText "nginx-reverse-proxy.conf" ''
      # this file is auto-generated by nixcloud.reverse-proxy
      # https://github.com/nixcloud/nixcloud-webservices/blob/master/documentation/nixcloud.reverse-proxy.md
      user "reverse-proxy" "reverse-proxy";
      error_log stderr;

      daemon off;

      events {}
      http {
        ${createServerRecords allProxyOptions allNCWDomains}
        ${cfg.extraConfig}
      }
    '';

    # walk through all `nixcloud.webservices` services, collect proxyOptions from enabled services
    # { house = { ... }; music = { ... }; test = { ... }; test1 = { ... }; }
    allNixcloudServicesSet = s: fold (el: con: con // s.${el} ) {} (attrNames s);
    collectedConfigs = allNixcloudServicesSet config.nixcloud.webservices;
    filteredCollectedConfigs = filterAttrs (n: v: v.enable == true) collectedConfigs;
    filteredCollectedConfigsList = fold (el: c: c ++ [ filteredCollectedConfigs.${el}.proxyOptions ]) [] (attrNames filteredCollectedConfigs);

    allProxyOptions = filteredCollectedConfigsList ++ cfg.extraMappings;

    # create a unique list of all domains from nixcloud.reverse-proxy
    allNCWDomains = unique (map (el: el.domain) allProxyOptions);
    
    # a list of unique domains gained from nixcloud.webservices.proxyOption(s) which require a http server record in nginx.conf
    allHttpOnlyProxyOptions = filter (el: (el.http.mode != "off") || (checkWebsockets el.websockets "http") ) allProxyOptions;
    allHttpNCDomains = unique (map (el: el.domain) allHttpOnlyProxyOptions);

    ACMEImpliedDomains = unique (mapAttrsToList (name: value: if (value.domain != null) then value.domain else name) config.security.acme.certs);
    ACMEImpliedDomains_ = unique (mapAttrsToList (name: value: 
      { name = if (value.domain != null) then value.domain else name; value = value.webroot; }) config.security.acme.certs);
  
    allAcmeDomains = builtins.listToAttrs ACMEImpliedDomains_;
    allHttpDomains = unique (ACMEImpliedDomains ++ allHttpNCDomains);
        
    # ACME/TLS details
    #   example value: { "lastlog.de" = "ACME"; "nixcloud.io = "ACME"; }
    #
    # it returns either:
    # - "ACME" if all locations per domain (in proxyOption) have set TLS="ACME" (default)
    # - an assertion on contradicting proxyOptions records
    ACMEsupportSet = fold (el: c:
      if (el.https.mode != "off" && el.TLS != "ACME" && c ? "${el.domain}") then
        let
          a=c.${el.domain};
          b="${el.TLS}";
        in
          if (a == b) then
            c else abort "error: `${a}` != `${b}`! A conflict in `proxyOptions` for for domain ${el.domain}:${toString el.port}${el.path} with a record for the same domain added previously."
      else
        c // { "${el.domain}" = "${el.TLS}"; }
    ) {} allProxyOptions;

    createLocationRecords = mode: filteredProxyOptions:
      lib.concatMapStringsSep "\n" (location: (createLocationRecord mode location)) filteredProxyOptions;

    createLocationRecord = mode: location:
      let
        m = location.${mode}.mode;
        b = location.${mode}.basicAuth;
        r = location.${mode}.record;
        l = builtins.toPath (location.path);
        f = location.${mode}.flags;
      in
        (if (m == "on") then
          ''
            location ${l} {
            ${if r == "" then ''
              ${f}
              proxy_pass http://${location.ip}:${toString location.port}${removeSuffix "/" (toString (builtins.toPath (location.path)))};
            '' else r
            }
              ${if (b != {}) then mkBasicAuth b else ""}
            }
          '' #"
        else if (m == "redirect_to_http" ) then 
          ''
            location ${l} {
              rewrite     ^   http://$server_name$request_uri? permanent;
            }
          ''
        else if (m == "redirect_to_https" ) then
          ''
            location ${l} {
              rewrite     ^   https://$server_name$request_uri? permanent;
            }
          ''
        else if (m == "off") then ""
        else abort "unknown location mode: `${m}`, this should never happen.... but just in case!");

    createWsPaths = mode: filteredProxyOptions:
      lib.concatMapStringsSep "\n" (location: (createWsPaths_ mode location)) filteredProxyOptions;
    
    createWsPaths_ = mode: location:
      lib.concatMapStringsSep "\n" (w: createWsPath mode location location.websockets.${w}) (attrNames location.websockets);

    checkWebsockets = websockets: mode:
      fold (el: container: if (websockets.${el}).${mode}.mode != "off" then true else container) false (attrNames websockets);      
      
    createWsPath = mode: location: websocket:
      let
        b = websocket.${mode}.basicAuth;
        r = websocket.${mode}.record;
        m = websocket.${mode}.mode;
        f = websocket.${mode}.flags;
        ppp = removeSuffix "/" (toString (builtins.toPath (location.path + websocket.subpath)));
      in
        if (m == "on") then
          ''
            location ${ppp} {
            ${if r == "" then ''
              ${f}
              proxy_pass http://${location.ip}:${toString location.port}${ppp};
            '' else r #"
            }
              ${if (b != {}) then mkBasicAuth b else ""}
            }
          ''
        else if (m == "redirect_to_http") then ""
        else if (m == "redirect_to_https") then ""
        else if (m == "off") then ""       
        else abort "unknown location mode: `${m}`, this should never happen.... but just in case!";

    createServerRecords = allProxyOptions: allNCWDomains:
      concatMapStringsSep "\n" (x: x) (createHttpServerRecords allProxyOptions) +
      (concatMapStringsSep "\n" (createHttpsServerRecord allProxyOptions) allNCWDomains);

    # 3. map over these and create server (http/https) records per domain        
    createHttpServerRecords = allProxyOptions: let
      createHttpServerRecord =  domain: let
        filteredProxyOptions = filter (e: e.domain == "${domain}") allProxyOptions;
      in
      ''
        server {
          listen ${toString cfg.httpPort};
          listen [::]:${toString cfg.httpPort};
          
          server_name ${domain};  
          ${optionalString (allAcmeDomains ? "${domain}")
          ''
            # ACME requires this in the http record (will not work over https)
            location /.well-known/acme-challenge {
              root ${allAcmeDomains."${domain}"};
              auth_basic off;
            }
          ''}

          ${createLocationRecords "http" filteredProxyOptions}
          ${createWsPaths "http" filteredProxyOptions}
        } ''; #"  '' ''

    in 
      (map createHttpServerRecord allHttpDomains);

    createHttpsServerRecord = allProxyOptions: domain:
    let
      filteredProxyOptions = filter (e: e.domain == "${domain}") allProxyOptions;
      needsHttps = fold (el: con: if ((el.https.mode != "off") || checkWebsockets el.websockets "https") then true else con) false filteredProxyOptions;
      #ACMEcertList = filter (cert: cert.
    in optionalString (filteredProxyOptions != [] && needsHttps) ''
      server {
        ssl on;
        listen ${toString cfg.httpsPort} ssl;
        listen [::]:${toString cfg.httpsPort} ssl;

        server_name ${domain};

        ${optionalString (ACMEsupportSet.${domain} == "ACME") ''
        ssl_certificate /var/lib/acme/${domain}_ncws/fullchain.pem;
        ssl_certificate_key /var/lib/acme/${domain}_ncws/key.pem;
        ''}
        ${createLocationRecords "https" filteredProxyOptions}
        ${createWsPaths "https" filteredProxyOptions}
      }
    '';
    checkAndFormatNginxConfigfile = (import ../../web/webserver/lib/nginx_check_config.nix {inherit lib pkgs;}).checkAndFormatNginxConfigfile;
    configFile = generateNginxConfigFile allProxyOptions allNCWDomains;

  in mkIf (cfg.enable) {
    networking = {
      extraHosts = if cfg.extendEtcHosts then (concatMapStringsSep "\n" (x: "127.0.0.1 ${x}") allNCWDomains + "\n" + concatMapStringsSep "\n" (x: "::1 ${x}") allNCWDomains) else ""; 
      firewall = {
        allowedTCPPorts = [
          cfg.httpPort
          cfg.httpsPort
        ];
      };
    };
    systemd.services."nixcloud.reverse-proxy" = let
      acmeIsUsed = fold (el: con: (el == "ACME") || con) false (attrValues ACMEsupportSet);
    in {
      description   = "nixcloud reverse-proxy service";
      wantedBy      = [ "multi-user.target" ];
      
      after = if acmeIsUsed then [ "acme-selfsigned-certificates.target" ] else [ "network.target" ];
      wants =  if acmeIsUsed then [ "acme-selfsigned-certificates.target" "acme-certificates.target" ] else [];
      
      stopIfChanged = false;

      preStart = ''
        mkdir -p ${stateDir}/nginx/logs
        mkdir -p ${stateDir}/nginx
        chmod 700 ${stateDir}
        chown -R ${user}:${group} ${stateDir}
      '';
      serviceConfig = {
        ExecStart = "${pkgs.nginx}/bin/nginx -c ${if (cfg.configFile == null) then (checkAndFormatNginxConfigfile {inherit configFile; fileName = "nixcloud.reverse-proxy.conf";}) else cfg.configFile}/nixcloud.reverse-proxy.conf -p ${stateDir}/nginx";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "always";
        RestartSec = "10s";
        StartLimitInterval = "1min";
      };
    };

    users.extraUsers = (singleton
      { name = "${user}";
        group = "${group}";
      });

    users.extraGroups = (singleton
      { name = "${user}";
      });

    security.acme.certs = (fold (el: con: if ((ACMEsupportSet.${el}) != "ACME") then con else con // {
      "${el}_ncws" = {
        # FIXME: inject nixcloud.reverse-proxy user into acme groups (or the othern way round)
        #user = "acme";
        #group = "acme";
        domain = "${el}";
        # FIXME: check if allowKeysForGroup is required
        # allowKeysForGroup = true;
        webroot = "/var/lib/acme/acme-challenges";
        postRun = ''
         systemctl reload nixcloud.reverse-proxy
        '';
        # FIXME systemd.reload = [ "nixcloud.reverse-proxy.service" ];
      };
    }) {} (attrNames ACMEsupportSet));
    nixcloud.tests.wanted = [ ./test.nix ];
  };
}
