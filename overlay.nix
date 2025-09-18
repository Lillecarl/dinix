_: pkgs:
let
  lib = pkgs.lib;
in{
  # Derivation that writes multiple files
  writeMultipleFiles =
    name: files:
    let
      fileList = pkgs.lib.mapAttrsToList (path: file: {
        inherit path;
        content = file.content or file;
        mode = if file.executable or false then "755" else file.mode or "644";
      }) files;

      # Create attribute names for passAsFile
      passAsFileAttrs = builtins.listToAttrs (
        pkgs.lib.imap0 (i: file: {
          name = "file${toString i}";
          value = file.content;
        }) fileList
      );

      passAsFileNames = builtins.attrNames passAsFileAttrs;

      commands = pkgs.lib.imap0 (i: file: ''
        mkdir -p $out/$(dirname "${file.path}")
        cp "$file${toString i}Path" $out/${file.path}
        chmod ${file.mode} $out/${file.path}
      '') fileList;

    in
    pkgs.runCommand name (
      passAsFileAttrs
      // {
        passAsFile = passAsFileNames;
      }
    ) (builtins.concatStringsSep "\n" commands);

  # Write execline script
  writeExeclineBin =
    name: script:
    pkgs.writeScriptBin name # execline
      ''
        #! ${lib.getExe' pkgs.execline "execlineb"}
        ${script}
      '';
}
