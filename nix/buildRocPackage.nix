
{ pkgs
, roc-cli
, name
, entryPoint
, src
, outputHash
, linker ? ""
, optimize ? true
, ...
}:
# see checks.canBuildRocPackage in /flake.nix for example usage
let
  packageDependencies = pkgs.stdenv.mkDerivation {
    inherit src outputHash;
    name = "roc-dependencies";
    nativeBuildInputs = with pkgs; [ gnutar brotli ripgrep wget cacert ];

    buildPhase = ''
      declare -A visitedUrls

      # function that recursively prefetches roc dependencies
      # so they're available during roc build stage
      function prefetch () {
        local searchPath=$1
        local skipApp=$2 # to skip any example app files in dependencies
        
        # Set default value for skipApp if not provided
        if [ -z "$skipApp" ]; then
          skipApp=false
        fi

        local dependenciesRegexp='https://[^"]*tar.br|https://[^"]*tar.gz'
        
        # If skipApp is true, exclude files containing app declarations
        if [ "$skipApp" = true ]; then
          # Find files containing app declarations
          local appFiles=$(rg -l '^\s*app\s*\[' -IN $searchPath)
          
          # If app files were found, exclude them from search
          if [ -n "$appFiles" ]; then
            local excludeArgs=""
            for file in $appFiles; do
              excludeArgs="$excludeArgs -g !$file"
            done
            local getDependenciesCommand="rg -o '$dependenciesRegexp' -IN $excludeArgs $searchPath"
          else
            local getDependenciesCommand="rg -o '$dependenciesRegexp' -IN $searchPath"
          fi
        else
          local getDependenciesCommand="rg -o '$dependenciesRegexp' -IN $searchPath"
        fi
        
        local depsUrlsList=$(eval "$getDependenciesCommand")

        if [ -z "$depsUrlsList" ]; then
          echo "Executed: $getDependenciesCommand"
          echo "No URLs found in $searchPath"
        fi

        for url in $depsUrlsList; do
          if [[ -n "''${visitedUrls["$url"]^^}" ]]; then
            echo "Skipping already visited URL: $url"
          else
            echo "Prefetching $url"
            visitedUrls["$url"]=1

            local domain=$(echo $url | awk -F '/' '{print $3}')

            local packagePath=$(echo $url | awk -F "$domain/|/[^/]*$" '{print $2}')
            local outputPackagePath="$out/roc/packages/$domain/$packagePath"
            echo "Package path: $outputPackagePath"

            mkdir -p "$outputPackagePath"

            # Download dependency
            if ! (wget -P "$outputPackagePath" "$url" 2>/tmp/wget_error); then
              echo "WARNING: Failed to download $url: $(cat /tmp/wget_error)"
              exit 1
            fi

            # Unpack dependency
            if [[ $url == *.br ]]; then
              brotli -d "$outputPackagePath"/*.tar.br
              tar -xf "$outputPackagePath"/*.tar --one-top-level -C $outputPackagePath
            elif [[ $url == *.gz ]]; then
              tar -xzf "$outputPackagePath"/*.tar.gz --one-top-level -C $outputPackagePath
            fi

            # Delete temporary files
            rm "$outputPackagePath"/*tar*

            # Recursively fetch dependencies of dependencies
            # Pass the skipApp parameter to recursive calls
            prefetch "$outputPackagePath" "$skipApp"
          fi
        done
      }

      prefetch ${src} true

      if [ -d "$out/roc/packages" ]; then
        echo "Successfully prefetched packages:"
        find "$out/roc/packages" -type d -mindepth 3 -maxdepth 3 | sort
      else
        echo "WARNING: No packages were prefetched. This might indicate a problem."
      fi
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };
in
pkgs.stdenv.mkDerivation {
  inherit name src;
  nativeBuildInputs = [ roc-cli ];
  XDG_CACHE_HOME = packageDependencies;

  buildPhase = ''
    roc build ${entryPoint} --output ${name} \
    ${if optimize == true then "--optimize" else ""} \
    ${if linker != "" then "--linker=${linker}" else ""}

    mkdir -p $out/bin
    mv ${name} $out/bin/${name}
  '';
}

