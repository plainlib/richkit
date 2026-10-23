{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit richkit;

{$warn 5023 off : no warning about unused units}
interface

uses
  RichMemoCellEditor, ClipToHtml, HtmlToRtf, RichMemoHelper, RichSpellChecker, 
  RtfToHtml, SpellUtils, WinSpellChecker, HunSpellChecker, SpellChecker, 
  RichKitRegister, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('RichKitRegister', @RichKitRegister.Register);
end;

initialization
  RegisterPackage('richkit', @Register);
end.
