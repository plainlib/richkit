//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit RichKitRegister;

{$mode objfpc}{$H+}

interface

uses
  Controls, Classes, LResources, SpellChecker;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('Common Controls', [TSpellChecker]);
end;

initialization
  {$I richkit.lrs}

end.
