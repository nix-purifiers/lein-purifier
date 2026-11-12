# SPDX-License-Identifier: MIT
{
  pkgs,
  build,
  purifier,
}:
let
  original = builtins.fromJSON (builtins.readFile ./fixtures/hello/lein-purifier.lock.json);
  upstream = builtins.head (
    builtins.filter (
      entry: entry.path == "org/clojure/data.json/2.5.0/data.json-2.5.0.jar"
    ) original.artifacts
  );
  upstreamJar = purifier.fetchEntry { inherit pkgs; } upstream;
  provider =
    pkgs.runCommand "lein-json-provider"
      {
        passthru.projections = purifier.jvmProjections {
          repository = provider;
          inherit (pkgs) runCommand python3;
        };
      }
      ''
        directory=$out/org/clojure/data.json/0.0.1
        mkdir -p "$directory"
        cp ${upstreamJar} "$directory/data.json-0.0.1.jar"
        cat > "$directory/data.json-0.0.1.pom" <<'POM'
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion><groupId>org.clojure</groupId>
          <artifactId>data.json</artifactId><version>0.0.1</version>
        </project>
        POM
      '';
  transitiveProvider =
    pkgs.runCommand "nix-built-commons-lang3"
      {
        nativeBuildInputs = [ pkgs.jdk_headless ];
        passthru.projections = purifier.jvmProjections {
          repository = transitiveProvider;
          inherit (pkgs) runCommand python3;
        };
      }
      ''
        mkdir -p classes
        cat > StringUtils.java <<'JAVA'
        package org.apache.commons.lang3;
        public final class StringUtils {
          public static String purifierIdentity() { return "Nix"; }
          public static boolean isEmpty(CharSequence value) {
            return value == null || value.length() == 0;
          }
          public static String capitalize(String value) {
            if (value == null || value.isEmpty()) return value;
            return Character.toUpperCase(value.charAt(0)) + value.substring(1);
          }
        }
        JAVA
        javac --release 8 -d classes StringUtils.java
        dir=$out/org/apache/commons/commons-lang3/0.0.1
        mkdir -p "$dir"
        jar --create --file "$dir/commons-lang3-0.0.1.jar" \
          --date=1980-01-01T00:00:02Z -C classes .
        cat > "$dir/commons-lang3-0.0.1.pom" <<'POM'
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion><groupId>org.apache.commons</groupId>
          <artifactId>commons-lang3</artifactId><version>0.0.1</version>
        </project>
        POM
      '';
  withoutProvided = original // {
    artifacts = builtins.filter (
      entry: !(pkgs.lib.hasPrefix "org/clojure/data.json/" entry.path)
    ) original.artifacts;
  };
  lockFile = builtins.toFile "lein-purifier.lock.json" (
    builtins.toJSON (
      withoutProvided
      // {
        integrity = import ../lib-overlays/default/integrity.nix withoutProvided;
      }
    )
  );
  consumer = build {
    src = ./fixtures/hello;
    inherit lockFile;
    projectDependencies = [ provider ];
  };
in
pkgs.runCommand "lein-nix-composition"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    passthru = { inherit provider transitiveProvider consumer; };
  }
  ''
    test -d ${consumer.tests}
    ${consumer.packages.hello}/bin/hello > result
    grep -qx '{"hello":"world"}' result
    export CATALOG=${provider.projections.maven.catalog}
    export POM=${consumer.packages.hello}/share/java/hello-1.0.0.pom
    python - <<'PY'
    import json, os, xml.etree.ElementTree as ET
    catalog = json.load(open(os.environ['CATALOG']))
    selected = next(m['version'] for m in catalog['modules'] if m['name'] == 'data.json')
    root = ET.parse(os.environ['POM']).getroot()
    ns = {'m': root.tag.split('}')[0][1:]}
    dependency = next(d for d in root.findall('m:dependencies/m:dependency', ns)
                      if d.findtext('m:artifactId', namespaces=ns) == 'data.json')
    assert dependency.findtext('m:version', namespaces=ns) == selected
    PY
    touch $out
  ''
