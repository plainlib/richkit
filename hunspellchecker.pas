//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit HunSpellChecker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Math, StrUtils, LazUTF8;

type
  TStringArray = array of string;
  TFlagArray = array of string;
  TIntegerArray = array of integer;

  TSpellError = record
    Offset: integer;
    Length: integer;
    Message: string;
    Replacements: array of string;
    Color: TColor;
  end;
  PSpellError = ^TSpellError;
  TSpellErrorArray = array of TSpellError;

  TSuffixRule = record
    Strip: string;
    Add: string;
    Condition: string;
  end;

  TPrefixRule = record
    Strip: string;
    Add: string;
    Condition: string;
  end;

  TAffixGroup = record
    Suffixes: array of TSuffixRule;
    Prefixes: array of TPrefixRule;
    CrossProduct: boolean;
  end;

  TAffixEntry = record
    Flag: string;
    Group: TAffixGroup;
  end;

  TAffixList = array of TAffixEntry;

  TWordEntry = record
    word: string;
    Flags: TFlagArray;
  end;

  TWeightedSuggestion = record
    S: string;
    Dist: integer;
  end;
  TWeightedSuggestionArray = array of TWeightedSuggestion;

  THunSpellChecker = class
  private
    FWords: array of TWordEntry;
    FWordCount: integer;
    FHashTable: array of integer;
    FHashSize: integer;
    FHashMask: integer;
    FSuffixRules: TAffixList;
    FPrefixRules: TAffixList;
    FActiveFlags: TFlagArray;
    FAllWords: array of string;
    FAllWordsFlags: array of TFlagArray;
    FAllWordsLower: array of string;
    FAllWordsFirstChar: array of string;
    FLengthBuckets: array of TIntegerArray;
    FIconvFrom: array of string;
    FIconvTo: array of string;
    FWordCharsCodes: array of cardinal;
    FNoSuggestFlag: string;
    FNeedAffixFlag: string;
    FPseudoRootFlag: string;
    FCircumfixFlag: string;
    FForbiddenWordFlag: string;
    FCompoundMin: integer;
    FOnlyInCompoundFlag: string;
    FCompoundRules: array of string;
    FREPFrom: array of string;
    FREPTo: array of string;
    FMAPGroups: array of string;
    FSuggestCache: TStringList;
    FFlagMode: string; // ASCII, UTF-8, long, num
    FAFCount: integer;
    FAAliases: array of TFlagArray;
    FBreakPatterns: TStringList;
    FCompoundFlag: string;
    FCompoundBegin: string;
    FCompoundMiddle: string;
    FCompoundEnd: string;
    FCompoundPermitFlag: string;
    FCompoundForbidFlag: string;
    FTryChars: string;             // TRY string from AFF
    FKeyGroups: TStringList;       // KEY groups separated by '|'
    procedure LoadAFFFromStream(Stream: TStream);
    procedure LoadDICFromStream(Stream: TStream);
    function LoadAFF(const FileName: string): boolean;
    function LoadDIC(const FileName: string): boolean;
    procedure AddSuffixRule(const Flag: string; const Strip, Add, Condition: string; CrossProduct: boolean);
    procedure AddPrefixRule(const Flag: string; const Strip, Add, Condition: string; CrossProduct: boolean);
    function MatchesCondition(const Condition, word: string; IsPrefix: boolean): boolean;
    function TryApplySuffixes(const word: string; const Flags: TFlagArray): boolean;
    function TryApplyPrefixes(const word: string; const Flags: TFlagArray): boolean;
    function TryApplyCrossProduct(const word: string; const Flags: TFlagArray): boolean;
    function TryApplyAffixes(const word: string; const Flags: TFlagArray): boolean;
    function GetWordFlags(const word: string): TFlagArray;
    procedure HashAdd(const word: string; const Flags: TFlagArray);
    function HashFind(const word: string; out Index: integer): boolean;
    function FNV1aHash(const S: string): cardinal;
    procedure Rehash;
    function IsWordChar(Ch: pchar; CharLen: integer): boolean;
    procedure BuildAllWordsArray;
    function ApplyIconv(const S: string): string;
    function MatchesCompoundRule(const word, Rule: string): boolean;
    function IsCompoundNumber(const word: string): boolean;
    function IsNoSuggestWord(const Flags: TFlagArray): boolean;
    function IsForbiddenWord(const Flags: TFlagArray): boolean;
    function HasFlag(const Flags: TFlagArray; const Flag: string): boolean;
    procedure AddWeightedSuggestion(var Suggestions: TWeightedSuggestionArray; const Candidate: string; Dist: integer);
    procedure GenerateAndAddAffixForms(var Suggestions: TWeightedSuggestionArray; const BaseWord: string;
      const Flags: TFlagArray; const TargetWordLower: string);
    function FindAffixGroup(const List: TAffixList; const Flag: string; out Index: integer): boolean;
    procedure AddAffixGroup(var List: TAffixList; const Flag: string; const Group: TAffixGroup);
    function FlagInArray(const Arr: TFlagArray; const Flag: string): boolean;
    function StripComment(const S: string): string;
    procedure ExpandAliases(var Flags: TFlagArray);
    function CharInClass(const Ch: widechar; const ClassStr: widestring): boolean;
    function ApplyREP(const word, From, Replacement: string): TStringArray;
    function CheckWordInternal(const word: string; AllowBreak: boolean): boolean;
    function TryBreakWord(const word: string): boolean;
    function TryCompoundWord(const word: string): boolean;
    procedure GenerateTryKeyCandidates(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
    procedure ProcessREPandMAP(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
    function LevenshteinDistanceLimited(const S1, S2: string; MaxDist: integer): integer;
    procedure ProcessDictionaryScan(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
    function CompareWeighted(const A, B: TWeightedSuggestion): integer;
    procedure SortWeightedSuggestions(var Arr: TWeightedSuggestionArray);
    function AdjustCase(const Source, S: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    function LoadFromStream(AFFStream, DICStream: TStream): boolean;
    function LoadFromFiles(const AFFFileName, DICFileName: string): boolean;
    function CheckWord(const word: string): boolean;
    function CheckText(const Text: string): TSpellErrorArray;
    function Suggest(const word: string): TStringArray;
  end;

// Returns an ordered list of possible Hunspell dictionary file names (without extension)
// for a given BCP-47 language code, e.g. 'en', 'en-GB', 'pt', 'pt-BR', 'be', 'sr-Latn'.
// The list is ordered by priority: most specific/preferred first.
function HunspellDictionaryCandidates(const Lang: string): TStringArray;

implementation

function HunspellDictionaryCandidates(const Lang: string): TStringArray;
var
  s, norm, base, preferred: string;
  i: integer;
  list: TStringList;
begin
  Result := nil;
  s := Trim(Lang);
  if s = '' then Exit;

  // Normalize: replace '-' with '_' and keep allowed characters
  norm := '';
  for i := 1 to Length(s) do
  begin
    if s[i] = '-' then
      norm := norm + '_'
    else if (s[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) then
      norm := norm + s[i];
  end;

  list := TStringList.Create;
  try
    list.Duplicates := dupIgnore;
    list.Sorted := False;

    // Exact normalized form
    list.Add(norm);

    // If has region/script part, add base language
    if Pos('_', norm) > 0 then
    begin
      base := Copy(norm, 1, Pos('_', norm) - 1);
      list.Add(base);
    end;

    // Preferred mapping for short two-letter codes
    if Length(norm) = 2 then
    begin
      case LowerCase(norm) of
        'en': preferred := 'en_US';
        'pt': preferred := 'pt_BR';
        'zh': preferred := 'zh_CN';
        'ar': preferred := 'ar';
        'he': preferred := 'he_IL';
        'el': preferred := 'el_GR';
        'ja': preferred := 'ja_JP';
        'ko': preferred := 'ko_KR';
        'hi': preferred := 'hi_IN';
        'vi': preferred := 'vi_VN';
        'uk': preferred := 'uk_UA';
        'cs': preferred := 'cs_CZ';
        'da': preferred := 'da_DK';
        'fi': preferred := 'fi_FI';
        'nb': preferred := 'nb_NO';
        'no': preferred := 'nb_NO';
        'fa': preferred := 'fa_IR';
        'ms': preferred := 'ms_MY';
        'bn': preferred := 'bn_BD';
        'ta': preferred := 'ta_IN';
        'te': preferred := 'te_IN';
        'mr': preferred := 'mr_IN';
        'sw': preferred := 'sw_TZ';
        'km': preferred := 'km_KH';
        'lo': preferred := 'lo_LA';
        'ne': preferred := 'ne_NP';
        'si': preferred := 'si_LK';
        'ka': preferred := 'ka_GE';
        'hy': preferred := 'hy_AM';
        'kk': preferred := 'kk_KZ';
        'az': preferred := 'az_Latn_AZ';
        'sq': preferred := 'sq_AL';
        'be': preferred := 'be_BY';
        'ru': preferred := 'ru_RU';
        'de': preferred := 'de_DE';
        'fr': preferred := 'fr';
        'es': preferred := 'es_ES';
        'it': preferred := 'it_IT';
        'pl': preferred := 'pl_PL';
        'tr': preferred := 'tr_TR';
        'nl': preferred := 'nl_NL';
        'sv': preferred := 'sv_SE';
        'lt': preferred := 'lt';
        'is': preferred := 'is';
        'ca': preferred := 'ca';
        'sr': preferred := 'sr';
        'gl': preferred := 'gl_ES';
        else
          preferred := norm;
      end;

      if preferred <> norm then
      begin
        list.Insert(0, preferred);
        // Add special variants
        if preferred = 'fa_IR' then
          list.Add('fa-IR');
        if preferred = 'be_BY' then
          list.Add('be-official');
        if preferred = 'ca' then
          list.Add('ca-valencia');
        if preferred = 'sr' then
          list.Add('sr-Latn');
        if preferred = 'de_DE' then
          list.Add('de_DE_frami');
        if preferred = 'en_US' then
          list.Add('en');
      end;
    end
    else if (Length(norm) > 2) and (Pos('_', norm) > 0) then
    begin
      // Add hyphenated and suffixed variants for known cases
      if norm = 'fa_IR' then
        list.Add('fa-IR');
      if norm = 'be_BY' then
        list.Add('be-official');
      if norm = 'ca_ES' then
        list.Add('ca');
      if norm = 'ca_ES_valencia' then
        list.Add('ca-valencia');
      if norm = 'de_DE' then
        list.Add('de_DE_frami');
      if norm = 'de_AT' then
        list.Add('de_AT_frami');
      if norm = 'de_CH' then
        list.Add('de_CH_frami');
      if norm = 'sr_Latn' then
        list.Add('sr-Latn');
      if norm = 'pt_PT' then
        list.Add('pt');
    end;

    // If original input contained hyphen, add it as candidate
    if Pos('-', s) > 0 then
      list.Add(s);

    // Remove empty strings
    for i := list.Count - 1 downto 0 do
      if list[i] = '' then list.Delete(i);

    SetLength(Result, list.Count);
    for i := 0 to list.Count - 1 do
      Result[i] := list[i];
  finally
    list.Free;
  end;
end;

procedure SplitBySpaces(const S: string; Fields: TStringList);
var
  i, Start: integer;
begin
  Fields.Clear;
  i := 1;
  while i <= Length(S) do
  begin
    while (i <= Length(S)) and (S[i] in [' ', #9]) do Inc(i);
    if i > Length(S) then Break;
    Start := i;
    while (i <= Length(S)) and not (S[i] in [' ', #9]) do Inc(i);
    Fields.Add(Copy(S, Start, i - Start));
  end;
end;

function LevenshteinDistance(const S1, S2: string): integer;
var
  Wide1, Wide2: widestring;
  Len1, Len2, i, j: integer;
  D: array of array of integer;
begin
  D := nil;
  Wide1 := UTF8Decode(S1);
  Wide2 := UTF8Decode(S2);
  Len1 := Length(Wide1);
  Len2 := Length(Wide2);
  SetLength(D, Len1 + 1, Len2 + 1);
  for i := 0 to Len1 do D[i, 0] := i;
  for j := 0 to Len2 do D[0, j] := j;
  for i := 1 to Len1 do
    for j := 1 to Len2 do
    begin
      if Wide1[i] = Wide2[j] then
        D[i, j] := D[i - 1, j - 1]
      else
        D[i, j] := Min(Min(D[i - 1, j] + 1, D[i, j - 1] + 1), D[i - 1, j - 1] + 1);
    end;
  Result := D[Len1, Len2];
end;

function UTF8StartsStr(const SubStr, S: string): boolean;
begin
  Result := (UTF8Length(S) >= UTF8Length(SubStr)) and (UTF8Copy(S, 1, UTF8Length(SubStr)) = SubStr);
end;

function UTF8EndsStr(const SubStr, S: string): boolean;
var
  LenS, LenSub: integer;
begin
  LenS := UTF8Length(S);
  LenSub := UTF8Length(SubStr);
  Result := (LenS >= LenSub) and (UTF8Copy(S, LenS - LenSub + 1, LenSub) = SubStr);
end;

function THunSpellChecker.StripComment(const S: string): string;
var
  posHash: integer;
begin
  posHash := Pos('#', S);
  if posHash > 0 then
    Result := Copy(S, 1, posHash - 1)
  else
    Result := S;
end;

function THunSpellChecker.CharInClass(const Ch: widechar; const ClassStr: widestring): boolean;
var
  i: integer;
  RangeStart, RangeEnd: widechar;
begin
  i := 1;
  while i <= Length(ClassStr) do
  begin
    if (i + 2 <= Length(ClassStr)) and (ClassStr[i + 1] = '-') then
    begin
      // Range like a-z
      RangeStart := ClassStr[i];
      RangeEnd := ClassStr[i + 2];
      if (Ch >= RangeStart) and (Ch <= RangeEnd) then
        Exit(True);
      Inc(i, 3);
    end
    else
    begin
      if Ch = ClassStr[i] then
        Exit(True);
      Inc(i);
    end;
  end;
  Result := False;
end;

procedure THunSpellChecker.ExpandAliases(var Flags: TFlagArray);
var
  i, j, idx: integer;
  newFlags: TFlagArray = ();
begin
  if FAFCount = 0 then Exit;
  SetLength(newFlags, 0);
  for i := 0 to High(Flags) do
  begin
    // Try to convert numeric flag to alias
    if TryStrToInt(Flags[i], idx) and (idx >= 1) and (idx <= FAFCount) then
    begin
      for j := 0 to High(FAAliases[idx - 1]) do
      begin
        SetLength(newFlags, Length(newFlags) + 1);
        newFlags[High(newFlags)] := FAAliases[idx - 1][j];
      end;
    end
    else
    begin
      SetLength(newFlags, Length(newFlags) + 1);
      newFlags[High(newFlags)] := Flags[i];
    end;
  end;
  Flags := newFlags;
end;

function THunSpellChecker.ApplyREP(const word, From, Replacement: string): TStringArray;
var
  posStart, posEnd: integer;
  candidate: string;
begin
  Result := nil;
  if From = '' then Exit;
  if From[1] = '^' then
  begin
    // Pattern anchored at start
    if UTF8StartsStr(Copy(From, 2, MaxInt), word) then
    begin
      candidate := Replacement + UTF8Copy(word, UTF8Length(Copy(From, 2, MaxInt)) + 1, MaxInt);
      candidate := StringReplace(candidate, '_', ' ', [rfReplaceAll]); // Replace '_' with space
      SetLength(Result, 1);
      Result[0] := candidate;
    end;
  end
  else if From[Length(From)] = '$' then
  begin
    // Pattern anchored at end
    if UTF8EndsStr(Copy(From, 1, Length(From) - 1), word) then
    begin
      candidate := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(Copy(From, 1, Length(From) - 1))) + Replacement;
      candidate := StringReplace(candidate, '_', ' ', [rfReplaceAll]);
      SetLength(Result, 1);
      Result[0] := candidate;
    end;
  end
  else
  begin
    // Unanchored - find first occurrence
    posStart := UTF8Pos(From, word);
    if posStart > 0 then
    begin
      posEnd := posStart + UTF8Length(From) - 1;
      candidate := UTF8Copy(word, 1, posStart - 1) + Replacement + UTF8Copy(word, posEnd + 1, MaxInt);
      candidate := StringReplace(candidate, '_', ' ', [rfReplaceAll]);
      SetLength(Result, 1);
      Result[0] := candidate;
    end;
  end;
end;

function THunSpellChecker.CheckWordInternal(const word: string; AllowBreak: boolean): boolean;
var
  idx: integer;
  CleanWord: string;
  LowerWord: string;
  Flags: TFlagArray;
  EmptyFlags: TFlagArray = ();
begin
  SetLength(EmptyFlags, 0);
  CleanWord := ApplyIconv(word);
  if HashFind(CleanWord, idx) then
  begin
    Flags := FWords[idx].Flags;
    if IsForbiddenWord(Flags) then Exit(False);
    if (FOnlyInCompoundFlag <> '') and HasFlag(Flags, FOnlyInCompoundFlag) then
    begin
      // Word is only allowed in compound, try to see if it's part of a compound via BREAK later
      // but here we just consider it invalid standalone
      Exit(False);
    end;
    // If word has NEEDAFFIX or PSEUDOROOT, it is valid only with affixes
    if ((FNeedAffixFlag <> '') and HasFlag(Flags, FNeedAffixFlag)) or ((FPseudoRootFlag <> '') and
      HasFlag(Flags, FPseudoRootFlag)) then
    begin
      if TryApplyAffixes(CleanWord, Flags) then Exit(True);
      if TryApplyCrossProduct(CleanWord, Flags) then Exit(True);
      Exit(False);
    end;
    // Otherwise word is valid as is
    Exit(True);
  end;
  if IsCompoundNumber(CleanWord) then Exit(True);

  // Try lower-case version
  LowerWord := UTF8LowerCase(CleanWord);
  if LowerWord <> CleanWord then
  begin
    if HashFind(LowerWord, idx) then
    begin
      Flags := FWords[idx].Flags;
      if not IsForbiddenWord(Flags) and not ((FOnlyInCompoundFlag <> '') and HasFlag(Flags, FOnlyInCompoundFlag)) and
        not ((FNeedAffixFlag <> '') and HasFlag(Flags, FNeedAffixFlag)) and not ((FPseudoRootFlag <> '') and
        HasFlag(Flags, FPseudoRootFlag)) then
        Exit(True);
      if ((FNeedAffixFlag <> '') and HasFlag(Flags, FNeedAffixFlag)) or ((FPseudoRootFlag <> '') and
        HasFlag(Flags, FPseudoRootFlag)) then
      begin
        if TryApplyAffixes(LowerWord, Flags) then Exit(True);
        if TryApplyCrossProduct(LowerWord, Flags) then Exit(True);
      end;
    end;
    if TryApplyAffixes(LowerWord, EmptyFlags) then Exit(True);
    if TryApplyCrossProduct(LowerWord, EmptyFlags) then Exit(True);
  end;

  // Try affixes on original word
  if TryApplyAffixes(CleanWord, EmptyFlags) then Exit(True);
  if TryApplyCrossProduct(CleanWord, EmptyFlags) then Exit(True);

  // Try breaking the word according to BREAK patterns (if allowed)
  if AllowBreak and (FBreakPatterns.Count > 0) then
  begin
    if TryBreakWord(CleanWord) then Exit(True);
  end;

  // Try compound word if COMPOUNDFLAG is defined
  if FCompoundFlag <> '' then
  begin
    if TryCompoundWord(CleanWord) then Exit(True);
  end;

  Result := False;
end;

function THunSpellChecker.TryBreakWord(const word: string): boolean;
var
  i, pos: integer;
  pattern, searchStr: string;
  leftPart, rightPart: string;
begin
  Result := False;
  for i := 0 to FBreakPatterns.Count - 1 do
  begin
    pattern := FBreakPatterns[i];
    // Extract search string without anchors
    searchStr := pattern;
    if (Length(searchStr) > 0) and (searchStr[1] = '^') then
      Delete(searchStr, 1, 1);
    if (Length(searchStr) > 0) and (searchStr[Length(searchStr)] = '$') then
      Delete(searchStr, Length(searchStr), 1);

    if searchStr = '' then Continue;

    if (Length(pattern) > 0) and (pattern[1] = '^') then
    begin
      // Must match at start
      if UTF8StartsStr(searchStr, word) then
      begin
        rightPart := UTF8Copy(word, UTF8Length(searchStr) + 1, MaxInt);
        // Do not check empty left part
        if rightPart <> '' then
          if CheckWordInternal(rightPart, False) then
            Exit(True);
      end;
    end
    else if (Length(pattern) > 0) and (pattern[Length(pattern)] = '$') then
    begin
      // Must match at end
      if UTF8EndsStr(searchStr, word) then
      begin
        leftPart := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(searchStr));
        // Do not check empty right part
        if leftPart <> '' then
          if CheckWordInternal(leftPart, False) then
            Exit(True);
      end;
    end
    else
    begin
      // Match anywhere
      pos := UTF8Pos(searchStr, word);
      while pos > 0 do
      begin
        leftPart := UTF8Copy(word, 1, pos - 1);
        rightPart := UTF8Copy(word, pos + UTF8Length(searchStr), MaxInt);
        if (leftPart <> '') and (rightPart <> '') then
        begin
          if CheckWordInternal(leftPart, False) and CheckWordInternal(rightPart, False) then
            Exit(True);
        end;
        pos := UTF8Pos(searchStr, word, pos + 1); // search next occurrence
      end;
    end;
  end;
end;

function THunSpellChecker.TryCompoundWord(const word: string): boolean;
var
  i, idx: integer;
  leftPart, rightPart: string;
  leftFlags, rightFlags: TFlagArray;
  lenWord: integer;
  Rule: string;
  j: integer;
  LeftFlag, RightFlag: string;
begin
  Result := False;
  if word = '' then Exit;
  lenWord := UTF8Length(word);

  // If COMPOUNDRULE defined, use them for validation
  if Length(FCompoundRules) > 0 then
  begin
    for j := 0 to High(FCompoundRules) do
    begin
      Rule := FCompoundRules[j];
      // Currently support only rules with two parts separated by '*'
      // Examples: A*B, A*B*C (use first two parts)
      i := Pos('*', Rule);
      if i = 0 then Continue;
      LeftFlag := Copy(Rule, 1, i - 1);
      RightFlag := Copy(Rule, i + 1, MaxInt);
      // Remove possible additional '*' and following flags (e.g., A*B*C -> B)
      i := Pos('*', RightFlag);
      if i > 0 then
        RightFlag := Copy(RightFlag, 1, i - 1);

      // Try to split word into two parts according to rule
      for i := 1 to lenWord - 1 do
      begin
        leftPart := UTF8Copy(word, 1, i);
        rightPart := UTF8Copy(word, i + 1, MaxInt);
        if not HashFind(leftPart, idx) then
        begin
          if not TryApplyAffixes(leftPart, nil) then
            Continue;
          // Need to refresh flags if affix applied? GetWordFlags only works for exact dictionary words
          // so we better require direct dictionary presence for now.
          // For safety, skip if not found directly.
          if not HashFind(leftPart, idx) then
            Continue;
        end;
        leftFlags := FWords[idx].Flags;
        if IsForbiddenWord(leftFlags) then Continue;
        if not HasFlag(leftFlags, LeftFlag) then Continue;

        if not HashFind(rightPart, idx) then
        begin
          if not TryApplyAffixes(rightPart, nil) then
            Continue;
          if not HashFind(rightPart, idx) then
            Continue;
        end;
        rightFlags := FWords[idx].Flags;
        if IsForbiddenWord(rightFlags) then Continue;
        if not HasFlag(rightFlags, RightFlag) then Continue;

        Result := True;
        Exit;
      end;
    end;
    // If no rule matched, fall through to old method? No, compound rules are authoritative.
    Exit;
  end
  else
  begin
    // Old logic when no COMPOUNDRULE
    for i := 1 to lenWord - 1 do
    begin
      leftPart := UTF8Copy(word, 1, i);
      rightPart := UTF8Copy(word, i + 1, MaxInt);
      if not HashFind(leftPart, idx) then
      begin
        if not TryApplyAffixes(leftPart, nil) then
          Continue;
        if not HashFind(leftPart, idx) then
          Continue;
      end;
      leftFlags := FWords[idx].Flags;
      if IsForbiddenWord(leftFlags) then Continue;

      if not HashFind(rightPart, idx) then
      begin
        if not TryApplyAffixes(rightPart, nil) then
          Continue;
        if not HashFind(rightPart, idx) then
          Continue;
      end;
      rightFlags := FWords[idx].Flags;
      if IsForbiddenWord(rightFlags) then Continue;

      if FCompoundFlag <> '' then
      begin
        if not HasFlag(leftFlags, FCompoundFlag) and not HasFlag(leftFlags, FCompoundBegin) and not
          HasFlag(leftFlags, FCompoundMiddle) then
          Continue;
        if not HasFlag(rightFlags, FCompoundFlag) and not HasFlag(rightFlags, FCompoundEnd) and not
          HasFlag(rightFlags, FCompoundMiddle) then
          Continue;
        if (i = 1) and (FCompoundBegin <> '') and (not HasFlag(leftFlags, FCompoundBegin)) then
          Continue;
        if (i = lenWord - 1) and (FCompoundEnd <> '') and (not HasFlag(rightFlags, FCompoundEnd)) then
          Continue;
      end;
      Result := True;
      Exit;
    end;
  end;
end;

function THunSpellChecker.CheckWord(const word: string): boolean;
begin
  Result := CheckWordInternal(word, True);
end;

function THunSpellChecker.HasFlag(const Flags: TFlagArray; const Flag: string): boolean;
var
  i: integer;
begin
  Result := False;
  for i := 0 to High(Flags) do
    if Flags[i] = Flag then Exit(True);
end;

function THunSpellChecker.FlagInArray(const Arr: TFlagArray; const Flag: string): boolean;
begin
  Result := HasFlag(Arr, Flag);
end;

constructor THunSpellChecker.Create;
begin
  inherited;
  FWordCount := 0;
  FHashSize := 65536;
  FHashMask := FHashSize - 1;
  SetLength(FHashTable, FHashSize);
  FillDWord(FHashTable[0], FHashSize, $FFFFFFFF);
  SetLength(FWords, 0);
  SetLength(FAllWords, 0);
  SetLength(FAllWordsFlags, 0);
  SetLength(FAllWordsLower, 0);
  SetLength(FAllWordsFirstChar, 0);
  SetLength(FLengthBuckets, 0);
  SetLength(FActiveFlags, 0);
  SetLength(FSuffixRules, 0);
  SetLength(FPrefixRules, 0);
  FFlagMode := 'ASCII';
  SetLength(FIconvFrom, 0);
  SetLength(FIconvTo, 0);
  SetLength(FWordCharsCodes, 0);
  SetLength(FREPFrom, 0);
  SetLength(FREPTo, 0);
  SetLength(FMAPGroups, 0);
  SetLength(FCompoundRules, 0);
  FNoSuggestFlag := '';
  FNeedAffixFlag := '';
  FPseudoRootFlag := '';
  FCircumfixFlag := '';
  FForbiddenWordFlag := '';
  FOnlyInCompoundFlag := '';
  FCompoundMin := 0;
  FAFCount := 0;
  SetLength(FAAliases, 0);
  FBreakPatterns := TStringList.Create;
  FCompoundFlag := '';
  FCompoundBegin := '';
  FCompoundMiddle := '';
  FCompoundEnd := '';
  FCompoundPermitFlag := '';
  FCompoundForbidFlag := '';
  FSuggestCache := TStringList.Create;
  FSuggestCache.Sorted := True;
  FSuggestCache.Duplicates := dupIgnore;
  FTryChars := '';
  FKeyGroups := TStringList.Create;
end;

destructor THunSpellChecker.Destroy;
begin
  SetLength(FWords, 0);
  SetLength(FHashTable, 0);
  SetLength(FAllWords, 0);
  SetLength(FAllWordsFlags, 0);
  SetLength(FAllWordsLower, 0);
  SetLength(FAllWordsFirstChar, 0);
  SetLength(FLengthBuckets, 0);
  SetLength(FIconvFrom, 0);
  SetLength(FIconvTo, 0);
  SetLength(FWordCharsCodes, 0);
  SetLength(FREPFrom, 0);
  SetLength(FREPTo, 0);
  SetLength(FMAPGroups, 0);
  SetLength(FCompoundRules, 0);
  SetLength(FSuffixRules, 0);
  SetLength(FPrefixRules, 0);
  SetLength(FActiveFlags, 0);
  SetLength(FAAliases, 0);
  FBreakPatterns.Free;
  FSuggestCache.Free;
  FKeyGroups.Free;
  inherited;
end;

function THunSpellChecker.FNV1aHash(const S: string): cardinal;
var
  i: integer;
begin
  Result := 2166136261;
  for i := 1 to Length(S) do
  begin
    Result := Result xor Ord(S[i]);
    Result := Result * 16777619;
  end;
end;

procedure THunSpellChecker.Rehash;
var
  oldWords: array of TWordEntry;
  oldCount: integer;
  i: integer;
begin
  oldWords := FWords;
  oldCount := FWordCount;

  FHashSize := FHashSize * 2;
  FHashMask := FHashSize - 1;
  SetLength(FHashTable, FHashSize);
  FillDWord(FHashTable[0], FHashSize, $FFFFFFFF);
  SetLength(FWords, 0);

  FWordCount := 0;
  for i := 0 to oldCount - 1 do
    HashAdd(oldWords[i].word, oldWords[i].Flags);

  SetLength(oldWords, 0);
end;

procedure THunSpellChecker.HashAdd(const word: string; const Flags: TFlagArray);
var
  hash, idx: cardinal;
  existingFlags: TFlagArray;
  i, j: integer;
  flagExists: boolean;
begin
  if (FWordCount + 1) * 10 > FHashSize * 7 then
    Rehash;

  hash := FNV1aHash(word) and FHashMask;
  idx := hash;
  while FHashTable[idx] <> -1 do
  begin
    if FWords[FHashTable[idx]].word = word then
    begin
      // Merge flags
      existingFlags := FWords[FHashTable[idx]].Flags;
      for i := 0 to High(Flags) do
      begin
        flagExists := False;
        for j := 0 to High(existingFlags) do
          if existingFlags[j] = Flags[i] then
          begin
            flagExists := True;
            Break;
          end;
        if not flagExists then
        begin
          SetLength(existingFlags, Length(existingFlags) + 1);
          existingFlags[High(existingFlags)] := Flags[i];
        end;
      end;
      FWords[FHashTable[idx]].Flags := existingFlags;
      Exit;
    end;
    idx := (idx + 1) and FHashMask;
  end;

  if FWordCount = Length(FWords) then
    SetLength(FWords, FWordCount + 1024);
  FWords[FWordCount].word := word;
  SetLength(FWords[FWordCount].Flags, Length(Flags));
  for i := 0 to High(Flags) do
    FWords[FWordCount].Flags[i] := Flags[i];
  FHashTable[idx] := FWordCount;
  Inc(FWordCount);
end;

function THunSpellChecker.HashFind(const word: string; out Index: integer): boolean;
var
  hash, idx: cardinal;
begin
  if FHashSize = 0 then Exit(False);
  hash := FNV1aHash(word) and FHashMask;
  idx := hash;
  while FHashTable[idx] <> -1 do
  begin
    if FWords[FHashTable[idx]].word = word then
    begin
      Index := FHashTable[idx];
      Exit(True);
    end;
    idx := (idx + 1) and FHashMask;
  end;
  Result := False;
end;

function THunSpellChecker.LoadFromStream(AFFStream, DICStream: TStream): boolean;
begin
  Result := False;
  try
    // Reset dictionary-dependent state so the same checker can load another dictionary.
    FWordCount := 0;
    SetLength(FWords, 0);
    SetLength(FAllWords, 0);
    SetLength(FAllWordsFlags, 0);
    SetLength(FAllWordsLower, 0);
    SetLength(FAllWordsFirstChar, 0);
    SetLength(FLengthBuckets, 0);
    SetLength(FSuffixRules, 0);
    SetLength(FPrefixRules, 0);
    SetLength(FActiveFlags, 0);
    SetLength(FIconvFrom, 0);
    SetLength(FIconvTo, 0);
    SetLength(FWordCharsCodes, 0);
    SetLength(FCompoundRules, 0);
    SetLength(FREPFrom, 0);
    SetLength(FREPTo, 0);
    SetLength(FAAliases, 0);
    FBreakPatterns.Clear;
    FKeyGroups.Clear;
    FSuggestCache.Clear;
    FFlagMode := 'ASCII';
    FNoSuggestFlag := '';
    FNeedAffixFlag := '';
    FPseudoRootFlag := '';
    FCircumfixFlag := '';
    FForbiddenWordFlag := '';
    FOnlyInCompoundFlag := '';
    FCompoundMin := 0;
    FAFCount := 0;
    FCompoundFlag := '';
    FCompoundBegin := '';
    FCompoundMiddle := '';
    FCompoundEnd := '';
    FCompoundPermitFlag := '';
    FCompoundForbidFlag := '';
    FTryChars := '';

    FillDWord(FHashTable[0], FHashSize, $FFFFFFFF);

    LoadAFFFromStream(AFFStream);
    LoadDICFromStream(DICStream);
    BuildAllWordsArray;
    Result := True;
  except
    // On error, reset to empty dictionary
    FWordCount := 0;
    SetLength(FWords, 0);
    SetLength(FAllWords, 0);
    SetLength(FAllWordsFlags, 0);
    SetLength(FAllWordsLower, 0);
    SetLength(FAllWordsFirstChar, 0);
    SetLength(FLengthBuckets, 0);
    SetLength(FSuffixRules, 0);
    SetLength(FPrefixRules, 0);
    SetLength(FActiveFlags, 0);
    SetLength(FIconvFrom, 0);
    SetLength(FIconvTo, 0);
    SetLength(FWordCharsCodes, 0);
    SetLength(FCompoundRules, 0);
    SetLength(FREPFrom, 0);
    SetLength(FREPTo, 0);
    SetLength(FAAliases, 0);
    FBreakPatterns.Clear;
    FKeyGroups.Clear;
    FSuggestCache.Clear;
    FFlagMode := 'ASCII';
    FNoSuggestFlag := '';
    FNeedAffixFlag := '';
    FPseudoRootFlag := '';
    FCircumfixFlag := '';
    FForbiddenWordFlag := '';
    FOnlyInCompoundFlag := '';
    FCompoundMin := 0;
    FAFCount := 0;
    FCompoundFlag := '';
    FCompoundBegin := '';
    FCompoundMiddle := '';
    FCompoundEnd := '';
    FCompoundPermitFlag := '';
    FCompoundForbidFlag := '';
    FTryChars := '';
    FillDWord(FHashTable[0], FHashSize, $FFFFFFFF);
    Result := False;
  end;
end;

function THunSpellChecker.LoadFromFiles(const AFFFileName, DICFileName: string): boolean;
var
  AFFStream: TFileStream = nil;
  DICStream: TFileStream = nil;
begin
  Result := False;
  if not FileExists(AFFFileName) or not FileExists(DICFileName) then
    Exit;
  try
    AFFStream := TFileStream.Create(AFFFileName, fmOpenRead or fmShareDenyWrite);
    try
      DICStream := TFileStream.Create(DICFileName, fmOpenRead or fmShareDenyWrite);
      try
        Result := LoadFromStream(AFFStream, DICStream);
      finally
        DICStream.Free;
      end;
    finally
      AFFStream.Free;
    end;
  except
    Result := False;
  end;
end;

procedure THunSpellChecker.LoadAFFFromStream(Stream: TStream);
var
  Lines: TStringList = nil;
  Parts: TStringList = nil;
  LineIdx: integer = 0;
  Line: string = '';
  Flag: string = '';
  CrossProduct: boolean = False;
  Count: integer = 0;
  i: integer = 0;
  j: integer = 0;
  Strip: string = '';
  Add: string = '';
  Condition: string = '';
  WordCharsStr: string = '';
  CodePoint: cardinal = 0;
  ChPtr: pchar = nil;
  CharLen: integer = 0;
  KeyStr: string = '';
begin
  Lines := TStringList.Create;
  Parts := TStringList.Create;
  try
    Lines.LoadFromStream(Stream);
    while LineIdx < Lines.Count do
    begin
      Line := StripComment(Lines[LineIdx]);
      Line := Trim(Line);
      Inc(LineIdx);
      if Line = '' then Continue;
      SplitBySpaces(Line, Parts);
      if Parts.Count = 0 then Continue;
      if Parts[0] = 'FLAG' then
      begin
        if Parts.Count >= 2 then
          FFlagMode := UpperCase(Parts[1]);
      end
      else if Parts[0] = 'AF' then
      begin
        if Parts.Count >= 2 then
        begin
          FAFCount := StrToIntDef(Parts[1], 0);
          SetLength(FAAliases, FAFCount);
          i := 0;
          while i < FAFCount do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if (Parts.Count > 0) and (Parts[0] = 'AF') then
              Parts.Delete(0);
            SetLength(FAAliases[i], Parts.Count);
            for j := 0 to Parts.Count - 1 do
              FAAliases[i][j] := Parts[j];
            Inc(i);
          end;
        end;
      end
      else if Parts[0] = 'BREAK' then
      begin
        if Parts.Count >= 2 then
        begin
          Count := StrToIntDef(Parts[1], 0);
          i := 0;
          while i < Count do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if (Parts.Count > 0) and (Parts[0] = 'BREAK') then
              Parts.Delete(0);
            if Parts.Count > 0 then
              FBreakPatterns.Add(Parts[0]);
            Inc(i);
          end;
        end;
      end
      else if Parts[0] = 'COMPOUNDFLAG' then
      begin
        if Parts.Count >= 2 then FCompoundFlag := Parts[1];
      end
      else if Parts[0] = 'COMPOUNDBEGIN' then
      begin
        if Parts.Count >= 2 then FCompoundBegin := Parts[1];
      end
      else if Parts[0] = 'COMPOUNDMIDDLE' then
      begin
        if Parts.Count >= 2 then FCompoundMiddle := Parts[1];
      end
      else if Parts[0] = 'COMPOUNDEND' then
      begin
        if Parts.Count >= 2 then FCompoundEnd := Parts[1];
      end
      else if Parts[0] = 'COMPOUNDPERMITFLAG' then
      begin
        if Parts.Count >= 2 then FCompoundPermitFlag := Parts[1];
      end
      else if Parts[0] = 'COMPOUNDFORBIDFLAG' then
      begin
        if Parts.Count >= 2 then FCompoundForbidFlag := Parts[1];
      end
      else if Parts[0] = 'ONLYINCOMPOUND' then
      begin
        if Parts.Count >= 2 then FOnlyInCompoundFlag := Parts[1];
      end
      else if Parts[0] = 'COMPOUNDMIN' then
      begin
        if Parts.Count >= 2 then FCompoundMin := StrToIntDef(Parts[1], 0);
      end
      else if Parts[0] = 'COMPOUNDRULE' then
      begin
        if Parts.Count >= 2 then
        begin
          Count := StrToIntDef(Parts[1], 0);
          i := 0;
          while i < Count do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if Parts.Count >= 2 then
            begin
              SetLength(FCompoundRules, Length(FCompoundRules) + 1);
              FCompoundRules[High(FCompoundRules)] := Parts[1];
              Inc(i);
            end;
          end;
        end;
      end
      else if Parts[0] = 'SFX' then
      begin
        if Parts.Count >= 4 then
        begin
          Flag := Parts[1];
          CrossProduct := (Parts[2] = 'Y');
          Count := StrToIntDef(Parts[3], 0);
          i := 0;
          while i < Count do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if Parts.Count >= 5 then
            begin
              Strip := Parts[2];
              Add := Parts[3];
              Condition := Parts[4];
              if Strip = '0' then Strip := '';
              if Add = '0' then Add := '';
              AddSuffixRule(Flag, Strip, Add, Condition, CrossProduct);
              Inc(i);
            end;
          end;
        end;
      end
      else if Parts[0] = 'PFX' then
      begin
        if Parts.Count >= 4 then
        begin
          Flag := Parts[1];
          CrossProduct := (Parts[2] = 'Y');
          Count := StrToIntDef(Parts[3], 0);
          i := 0;
          while i < Count do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if Parts.Count >= 5 then
            begin
              Strip := Parts[2];
              Add := Parts[3];
              Condition := Parts[4];
              if Strip = '0' then Strip := '';
              if Add = '0' then Add := '';
              AddPrefixRule(Flag, Strip, Add, Condition, CrossProduct);
              Inc(i);
            end;
          end;
        end;
      end
      else if Parts[0] = 'ICONV' then
      begin
        if Parts.Count >= 2 then
        begin
          Count := StrToIntDef(Parts[1], 0);
          i := 0;
          while i < Count do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if (Parts.Count > 0) and (Parts[0] = 'ICONV') then
              Parts.Delete(0);
            if Parts.Count >= 2 then
            begin
              SetLength(FIconvFrom, Length(FIconvFrom) + 1);
              SetLength(FIconvTo, Length(FIconvTo) + 1);
              FIconvFrom[High(FIconvFrom)] := Parts[0];
              FIconvTo[High(FIconvTo)] := Parts[1];
              Inc(i);
            end;
          end;
        end;
      end
      else if Parts[0] = 'WORDCHARS' then
      begin
        WordCharsStr := '';
        for j := 1 to Parts.Count - 1 do
          WordCharsStr := WordCharsStr + Parts[j];
        ChPtr := PChar(WordCharsStr);
        while ChPtr^ <> #0 do
        begin
          {$NOTES OFF}
          CharLen := UTF8CodepointSize(ChPtr);
          {$NOTES ON}
          if CharLen = 1 then
            CodePoint := Ord(ChPtr^)
          else if CharLen = 2 then
            CodePoint := ((Ord(ChPtr^) and $1F) shl 6) or (Ord((ChPtr + 1)^) and $3F)
          else if CharLen = 3 then
            CodePoint := ((Ord(ChPtr^) and $0F) shl 12) or ((Ord((ChPtr + 1)^) and $3F) shl 6) or (Ord((ChPtr + 2)^) and $3F)
          else if CharLen = 4 then
            CodePoint := ((Ord(ChPtr^) and $07) shl 18) or ((Ord((ChPtr + 1)^) and $3F) shl 12) or
              ((Ord((ChPtr + 2)^) and $3F) shl 6) or (Ord((ChPtr + 3)^) and $3F)
          else
            CodePoint := 0;
          SetLength(FWordCharsCodes, Length(FWordCharsCodes) + 1);
          FWordCharsCodes[High(FWordCharsCodes)] := CodePoint;
          Inc(ChPtr, CharLen);
        end;
      end
      else if Parts[0] = 'NOSUGGEST' then
      begin
        if Parts.Count >= 2 then
          FNoSuggestFlag := Parts[1];
      end
      else if Parts[0] = 'NEEDAFFIX' then
      begin
        if Parts.Count >= 2 then
          FNeedAffixFlag := Parts[1];
      end
      else if Parts[0] = 'PSEUDOROOT' then
      begin
        if Parts.Count >= 2 then
          FPseudoRootFlag := Parts[1];
      end
      else if Parts[0] = 'CIRCUMFIX' then
      begin
        if Parts.Count >= 2 then
          FCircumfixFlag := Parts[1];
      end
      else if Parts[0] = 'FORBIDDENWORD' then
      begin
        if Parts.Count >= 2 then
          FForbiddenWordFlag := Parts[1];
      end
      else if Parts[0] = 'REP' then
      begin
        if Parts.Count >= 2 then
        begin
          Count := StrToIntDef(Parts[1], 0);
          i := 0;
          while i < Count do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if (Parts.Count > 0) and (Parts[0] = 'REP') then
              Parts.Delete(0);
            if Parts.Count >= 2 then
            begin
              SetLength(FREPFrom, Length(FREPFrom) + 1);
              SetLength(FREPTo, Length(FREPTo) + 1);
              FREPFrom[High(FREPFrom)] := Parts[0];
              FREPTo[High(FREPTo)] := Parts[1];
              Inc(i);
            end;
          end;
        end;
      end
      else if Parts[0] = 'MAP' then
      begin
        if Parts.Count >= 2 then
        begin
          Count := StrToIntDef(Parts[1], 0);
          i := 0;
          while i < Count do
          begin
            if LineIdx >= Lines.Count then Break;
            Line := StripComment(Lines[LineIdx]);
            Line := Trim(Line);
            Inc(LineIdx);
            if Line = '' then Continue;
            SplitBySpaces(Line, Parts);
            if (Parts.Count > 0) and (Parts[0] = 'MAP') then
              Parts.Delete(0);
            if Parts.Count >= 1 then
            begin
              SetLength(FMAPGroups, Length(FMAPGroups) + 1);
              FMAPGroups[High(FMAPGroups)] := Parts[0];
              Inc(i);
            end;
          end;
        end;
      end
      else if Parts[0] = 'TRY' then
      begin
        FTryChars := '';
        for j := 1 to Parts.Count - 1 do
          FTryChars := FTryChars + Parts[j];
      end
      else if Parts[0] = 'KEY' then
      begin
        KeyStr := '';
        for j := 1 to Parts.Count - 1 do
          KeyStr := KeyStr + Parts[j];
        FKeyGroups.Clear;
        FKeyGroups.Delimiter := '|';
        FKeyGroups.StrictDelimiter := True;
        FKeyGroups.DelimitedText := KeyStr;
      end;
    end;
  finally
    Lines.Free;
    Parts.Free;
  end;
end;

procedure THunSpellChecker.LoadDICFromStream(Stream: TStream);
var
  Lines: TStringList = nil;
  TempList: TStringList = nil;
  LineIdx: integer = 0;
  Line: string = '';
  word: string = '';
  FlagsStr: string = '';
  SlashPos: integer = 0;
  FlagsArr: TFlagArray = nil;
  i: integer = 0;
  j: integer = 0;
  s: string = '';
begin
  Lines := TStringList.Create;
  TempList := TStringList.Create;
  try
    Lines.LoadFromStream(Stream);
    // Skip the first line (word count), removing BOM if present
    if Lines.Count > 0 then
    begin
      Line := Lines[0];
      if (Length(Line) > 0) and (Ord(Line[1]) = $EF) then
        Delete(Line, 1, 3);
      // Line is ignored, but we do not process it as a dictionary entry
    end;
    LineIdx := 1;
    while LineIdx < Lines.Count do
    begin
      Line := Trim(Lines[LineIdx]);
      Inc(LineIdx);
      if Line = '' then Continue;
      SlashPos := Pos('/', Line);
      if SlashPos > 0 then
      begin
        word := Copy(Line, 1, SlashPos - 1);
        FlagsStr := Trim(Copy(Line, SlashPos + 1, MaxInt));
      end
      else
      begin
        word := Line;
        FlagsStr := '';
      end;
      word := ApplyIconv(word);

      SetLength(FlagsArr, 0);
      if FlagsStr <> '' then
      begin
        case FFlagMode of
          'ASCII':
          begin
            SetLength(FlagsArr, Length(FlagsStr));
            for j := 1 to Length(FlagsStr) do
              FlagsArr[j - 1] := FlagsStr[j];
          end;
          'UTF-8':
          begin
            s := FlagsStr;
            i := 0;
            while s <> '' do
            begin
              SetLength(FlagsArr, i + 1);
              FlagsArr[i] := UTF8Copy(s, 1, 1);
              UTF8Delete(s, 1, 1);
              Inc(i);
            end;
          end;
          'LONG':
          begin
            FlagsStr := StringReplace(FlagsStr, ',', ' ', [rfReplaceAll]);
            SplitBySpaces(FlagsStr, TempList);
            SetLength(FlagsArr, TempList.Count);
            for j := 0 to TempList.Count - 1 do
              FlagsArr[j] := TempList[j];
          end;
          'NUM':
          begin
            FlagsStr := StringReplace(FlagsStr, ',', ' ', [rfReplaceAll]);
            SplitBySpaces(FlagsStr, TempList);
            SetLength(FlagsArr, TempList.Count);
            for j := 0 to TempList.Count - 1 do
              FlagsArr[j] := TempList[j];
          end;
        end;
        ExpandAliases(FlagsArr);
      end;
      HashAdd(word, FlagsArr);
    end;
  finally
    Lines.Free;
    TempList.Free;
  end;
end;

function THunSpellChecker.LoadAFF(const FileName: string): boolean;
var
  Stream: TFileStream = nil;
begin
  Result := False;
  if not FileExists(FileName) then Exit;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      LoadAFFFromStream(Stream);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

function THunSpellChecker.LoadDIC(const FileName: string): boolean;
var
  Stream: TFileStream = nil;
begin
  Result := False;
  if not FileExists(FileName) then Exit;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      LoadDICFromStream(Stream);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

function THunSpellChecker.FindAffixGroup(const List: TAffixList; const Flag: string; out Index: integer): boolean;
var
  i: integer;
begin
  for i := 0 to High(List) do
    if List[i].Flag = Flag then
    begin
      Index := i;
      Exit(True);
    end;
  Result := False;
end;

procedure THunSpellChecker.AddAffixGroup(var List: TAffixList; const Flag: string; const Group: TAffixGroup);
var
  idx: integer;
begin
  if FindAffixGroup(List, Flag, idx) then
    List[idx].Group := Group
  else
  begin
    SetLength(List, Length(List) + 1);
    List[High(List)].Flag := Flag;
    List[High(List)].Group := Group;
  end;
end;

procedure THunSpellChecker.AddSuffixRule(const Flag: string; const Strip, Add, Condition: string; CrossProduct: boolean);
var
  Group: TAffixGroup;
  Rule: TSuffixRule;
  idx: integer;
begin
  if not FindAffixGroup(FSuffixRules, Flag, idx) then
  begin
    Group.CrossProduct := CrossProduct;
    SetLength(Group.Suffixes, 0);
    SetLength(Group.Prefixes, 0);
    AddAffixGroup(FSuffixRules, Flag, Group);
    if not FlagInArray(FActiveFlags, Flag) then
    begin
      SetLength(FActiveFlags, Length(FActiveFlags) + 1);
      FActiveFlags[High(FActiveFlags)] := Flag;
    end;
  end
  else
    Group := FSuffixRules[idx].Group;

  Rule.Strip := Strip;
  Rule.Add := Add;
  Rule.Condition := Condition;
  SetLength(Group.Suffixes, Length(Group.Suffixes) + 1);
  Group.Suffixes[High(Group.Suffixes)] := Rule;
  AddAffixGroup(FSuffixRules, Flag, Group);
end;

procedure THunSpellChecker.AddPrefixRule(const Flag: string; const Strip, Add, Condition: string; CrossProduct: boolean);
var
  Group: TAffixGroup;
  Rule: TPrefixRule;
  idx: integer;
begin
  if not FindAffixGroup(FPrefixRules, Flag, idx) then
  begin
    Group.CrossProduct := CrossProduct;
    SetLength(Group.Suffixes, 0);
    SetLength(Group.Prefixes, 0);
    AddAffixGroup(FPrefixRules, Flag, Group);
    if not FlagInArray(FActiveFlags, Flag) then
    begin
      SetLength(FActiveFlags, Length(FActiveFlags) + 1);
      FActiveFlags[High(FActiveFlags)] := Flag;
    end;
  end
  else
    Group := FPrefixRules[idx].Group;

  Rule.Strip := Strip;
  Rule.Add := Add;
  Rule.Condition := Condition;
  SetLength(Group.Prefixes, Length(Group.Prefixes) + 1);
  Group.Prefixes[High(Group.Prefixes)] := Rule;
  AddAffixGroup(FPrefixRules, Flag, Group);
end;

function THunSpellChecker.MatchesCondition(const Condition, word: string; IsPrefix: boolean): boolean;
var
  WideCond, WideWord: widestring;
  wPos, cPos: integer;
  wChar, cChar: widechar;
  openPos, closePos: integer;
  isNeg: boolean;
  classStr: widestring;
  startContent: integer;
begin
  if Condition = '' then Exit(True);

  WideCond := UTF8Decode(Condition);
  WideWord := UTF8Decode(word);

  if (WideCond = '.') and (Length(WideWord) > 0) then
    Exit(True);

  if (Pos('[', WideCond) = 0) and (Pos('.', WideCond) = 0) then
  begin
    if IsPrefix then
      Result := (Length(WideWord) >= Length(WideCond)) and (Copy(WideWord, 1, Length(WideCond)) = WideCond)
    else
      Result := (Length(WideWord) >= Length(WideCond)) and (Copy(WideWord, Length(WideWord) - Length(WideCond) +
        1, Length(WideCond)) = WideCond);
    Exit;
  end;

  if IsPrefix then
  begin
    // Original prefix matching code (unchanged)
    wPos := 1;
    cPos := 1;
    while (wPos <= Length(WideWord)) and (cPos <= Length(WideCond)) do
    begin
      cChar := WideCond[cPos];
      wChar := WideWord[wPos];

      if cChar = '[' then
      begin
        openPos := cPos;
        closePos := openPos;
        while (closePos <= Length(WideCond)) and (WideCond[closePos] <> ']') do
          Inc(closePos);
        if closePos > Length(WideCond) then Exit(False);

        isNeg := False;
        startContent := openPos + 1;
        if (startContent <= closePos) and (WideCond[startContent] = '^') then
        begin
          isNeg := True;
          startContent := openPos + 2;
        end;

        classStr := Copy(WideCond, startContent, closePos - startContent);

        if isNeg then
        begin
          if CharInClass(wChar, classStr) then Exit(False);
        end
        else
        begin
          if not CharInClass(wChar, classStr) then Exit(False);
        end;

        cPos := closePos + 1;
        Inc(wPos);
        Continue;
      end
      else if cChar = '.' then
      begin
        Inc(wPos);
        Inc(cPos);
        Continue;
      end
      else
      begin
        if cChar <> wChar then Exit(False);
        Inc(wPos);
        Inc(cPos);
        Continue;
      end;
    end;

    Result := (cPos > Length(WideCond));
  end
  else
  begin
    // Suffix matching: scan from the end
    wPos := Length(WideWord);
    cPos := Length(WideCond);
    while (wPos >= 1) and (cPos >= 1) do
    begin
      cChar := WideCond[cPos];
      wChar := WideWord[wPos];

      if cChar = ']' then
      begin
        // Find opening '['
        closePos := cPos;
        openPos := closePos;
        while (openPos >= 1) and (WideCond[openPos] <> '[') do
          Dec(openPos);
        if openPos < 1 then Exit(False);

        isNeg := False;
        startContent := openPos + 1;
        if (startContent <= closePos) and (WideCond[startContent] = '^') then
        begin
          isNeg := True;
          startContent := openPos + 2;
        end;

        classStr := Copy(WideCond, startContent, closePos - startContent);

        if isNeg then
        begin
          if CharInClass(wChar, classStr) then Exit(False);
        end
        else
        begin
          if not CharInClass(wChar, classStr) then Exit(False);
        end;

        cPos := openPos - 1;
        Dec(wPos);
        Continue;
      end
      else if cChar = '.' then
      begin
        Dec(wPos);
        Dec(cPos);
        Continue;
      end
      else
      begin
        if cChar <> wChar then Exit(False);
        Dec(wPos);
        Dec(cPos);
        Continue;
      end;
    end;

    Result := (cPos < 1);
  end;
end;

function THunSpellChecker.TryApplySuffixes(const word: string; const Flags: TFlagArray): boolean;
var
  i, r, idx: integer;
  Flag: string;
  Group: TAffixGroup;
  Rule: TSuffixRule;
  CandidateStem: string;
  StemIndex: integer;
begin
  Result := False;
  for i := 0 to High(FActiveFlags) do
  begin
    Flag := FActiveFlags[i];
    if (Length(Flags) > 0) and not HasFlag(Flags, Flag) then Continue;
    if not FindAffixGroup(FSuffixRules, Flag, idx) then Continue;
    Group := FSuffixRules[idx].Group;
    for r := 0 to High(Group.Suffixes) do
    begin
      Rule := Group.Suffixes[r];
      if UTF8EndsStr(Rule.Add, word) then
      begin
        CandidateStem := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(Rule.Add));
        if Rule.Strip <> '' then
          CandidateStem := CandidateStem + Rule.Strip;
        if MatchesCondition(Rule.Condition, CandidateStem, False) then
        begin
          if HashFind(CandidateStem, StemIndex) then
          begin
            if IsForbiddenWord(FWords[StemIndex].Flags) then Continue;
            if HasFlag(FWords[StemIndex].Flags, Flag) then
              Exit(True);
          end;
        end;
      end;
    end;
  end;
end;

function THunSpellChecker.TryApplyPrefixes(const word: string; const Flags: TFlagArray): boolean;
var
  i, r, idx: integer;
  Flag: string;
  Group: TAffixGroup;
  Rule: TPrefixRule;
  CandidateStem: string;
  StemIndex: integer;
begin
  Result := False;
  for i := 0 to High(FActiveFlags) do
  begin
    Flag := FActiveFlags[i];
    if (Length(Flags) > 0) and not HasFlag(Flags, Flag) then Continue;
    if not FindAffixGroup(FPrefixRules, Flag, idx) then Continue;
    Group := FPrefixRules[idx].Group;
    for r := 0 to High(Group.Prefixes) do
    begin
      Rule := Group.Prefixes[r];
      if UTF8StartsStr(Rule.Add, word) then
      begin
        CandidateStem := UTF8Copy(word, UTF8Length(Rule.Add) + 1, MaxInt);
        if Rule.Strip <> '' then
          CandidateStem := Rule.Strip + CandidateStem;
        if MatchesCondition(Rule.Condition, CandidateStem, True) then
        begin
          if HashFind(CandidateStem, StemIndex) then
          begin
            if IsForbiddenWord(FWords[StemIndex].Flags) then Continue;
            if HasFlag(FWords[StemIndex].Flags, Flag) then
              Exit(True);
          end;
        end;
      end;
    end;
  end;
end;

function THunSpellChecker.TryApplyCrossProduct(const word: string; const Flags: TFlagArray): boolean;
var
  suffixFlagIndex, prefixFlagIndex, suffixRuleIndex, prefixRuleIndex: integer;
  suffixFlag, prefixFlag: string;
  suffixGroup, prefixGroup: TAffixGroup;
  suffixRule: TSuffixRule;
  prefixRule: TPrefixRule;
  candidateAfterSuffix, candidateAfterPrefix, finalStem: string;
  stemIndex, idx: integer;
  stemFlags: TFlagArray;
  suffixIsCircumfix, prefixIsCircumfix: boolean;
  stemHasCircumfix: boolean;
begin
  Result := False;

  // suffix then prefix
  for suffixFlagIndex := 0 to High(FActiveFlags) do
  begin
    suffixFlag := FActiveFlags[suffixFlagIndex];
    if (Length(Flags) > 0) and not HasFlag(Flags, suffixFlag) then Continue;
    if not FindAffixGroup(FSuffixRules, suffixFlag, idx) then Continue;
    suffixGroup := FSuffixRules[idx].Group;
    if not suffixGroup.CrossProduct then Continue;
    suffixIsCircumfix := (suffixFlag = FCircumfixFlag);
    for suffixRuleIndex := 0 to High(suffixGroup.Suffixes) do
    begin
      suffixRule := suffixGroup.Suffixes[suffixRuleIndex];
      if UTF8EndsStr(suffixRule.Add, word) then
      begin
        candidateAfterSuffix := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(suffixRule.Add));
        if suffixRule.Strip <> '' then
          candidateAfterSuffix := candidateAfterSuffix + suffixRule.Strip;
        if MatchesCondition(suffixRule.Condition, candidateAfterSuffix, False) then
        begin
          for prefixFlagIndex := 0 to High(FActiveFlags) do
          begin
            prefixFlag := FActiveFlags[prefixFlagIndex];
            if (Length(Flags) > 0) and not HasFlag(Flags, prefixFlag) then Continue;
            if not FindAffixGroup(FPrefixRules, prefixFlag, idx) then Continue;
            prefixGroup := FPrefixRules[idx].Group;
            if not prefixGroup.CrossProduct then Continue;
            prefixIsCircumfix := (prefixFlag = FCircumfixFlag);
            for prefixRuleIndex := 0 to High(prefixGroup.Prefixes) do
            begin
              prefixRule := prefixGroup.Prefixes[prefixRuleIndex];
              if UTF8StartsStr(prefixRule.Add, candidateAfterSuffix) then
              begin
                finalStem := UTF8Copy(candidateAfterSuffix, UTF8Length(prefixRule.Add) + 1, MaxInt);
                if prefixRule.Strip <> '' then
                  finalStem := prefixRule.Strip + finalStem;
                if MatchesCondition(prefixRule.Condition, finalStem, True) then
                begin
                  if HashFind(finalStem, stemIndex) then
                  begin
                    stemFlags := FWords[stemIndex].Flags;
                    if IsForbiddenWord(stemFlags) then Continue;
                    stemHasCircumfix := HasFlag(stemFlags, FCircumfixFlag);
                    if stemHasCircumfix then
                    begin
                      if not (suffixIsCircumfix and prefixIsCircumfix) then Continue;
                    end
                    else
                    begin
                      if suffixIsCircumfix or prefixIsCircumfix then Continue;
                    end;
                    if HasFlag(stemFlags, suffixFlag) and HasFlag(stemFlags, prefixFlag) then
                      Exit(True);
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;
  end;

  // prefix then suffix
  for prefixFlagIndex := 0 to High(FActiveFlags) do
  begin
    prefixFlag := FActiveFlags[prefixFlagIndex];
    if (Length(Flags) > 0) and not HasFlag(Flags, prefixFlag) then Continue;
    if not FindAffixGroup(FPrefixRules, prefixFlag, idx) then Continue;
    prefixGroup := FPrefixRules[idx].Group;
    if not prefixGroup.CrossProduct then Continue;
    prefixIsCircumfix := (prefixFlag = FCircumfixFlag);
    for prefixRuleIndex := 0 to High(prefixGroup.Prefixes) do
    begin
      prefixRule := prefixGroup.Prefixes[prefixRuleIndex];
      if UTF8StartsStr(prefixRule.Add, word) then
      begin
        candidateAfterPrefix := UTF8Copy(word, UTF8Length(prefixRule.Add) + 1, MaxInt);
        if prefixRule.Strip <> '' then
          candidateAfterPrefix := prefixRule.Strip + candidateAfterPrefix;
        if MatchesCondition(prefixRule.Condition, candidateAfterPrefix, True) then
        begin
          for suffixFlagIndex := 0 to High(FActiveFlags) do
          begin
            suffixFlag := FActiveFlags[suffixFlagIndex];
            if (Length(Flags) > 0) and not HasFlag(Flags, suffixFlag) then Continue;
            if not FindAffixGroup(FSuffixRules, suffixFlag, idx) then Continue;
            suffixGroup := FSuffixRules[idx].Group;
            if not suffixGroup.CrossProduct then Continue;
            suffixIsCircumfix := (suffixFlag = FCircumfixFlag);
            for suffixRuleIndex := 0 to High(suffixGroup.Suffixes) do
            begin
              suffixRule := suffixGroup.Suffixes[suffixRuleIndex];
              if UTF8EndsStr(suffixRule.Add, candidateAfterPrefix) then
              begin
                finalStem := UTF8Copy(candidateAfterPrefix, 1, UTF8Length(candidateAfterPrefix) - UTF8Length(suffixRule.Add));
                if suffixRule.Strip <> '' then
                  finalStem := finalStem + suffixRule.Strip;
                if MatchesCondition(suffixRule.Condition, finalStem, False) then
                begin
                  if HashFind(finalStem, stemIndex) then
                  begin
                    stemFlags := FWords[stemIndex].Flags;
                    if IsForbiddenWord(stemFlags) then Continue;
                    stemHasCircumfix := HasFlag(stemFlags, FCircumfixFlag);
                    if stemHasCircumfix then
                    begin
                      if not (suffixIsCircumfix and prefixIsCircumfix) then Continue;
                    end
                    else
                    begin
                      if suffixIsCircumfix or prefixIsCircumfix then Continue;
                    end;
                    if HasFlag(stemFlags, suffixFlag) and HasFlag(stemFlags, prefixFlag) then
                      Exit(True);
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;
  end;
end;

function THunSpellChecker.TryApplyAffixes(const word: string; const Flags: TFlagArray): boolean;
begin
  Result := TryApplySuffixes(word, Flags) or TryApplyPrefixes(word, Flags);
end;

function THunSpellChecker.GetWordFlags(const word: string): TFlagArray;
var
  idx: integer;
begin
  if HashFind(word, idx) then
    Result := FWords[idx].Flags
  else
    SetLength(Result, 0);
end;

function THunSpellChecker.ApplyIconv(const S: string): string;
var
  i: integer;
begin
  Result := S;
  if Length(FIconvFrom) = 0 then Exit;
  for i := 0 to High(FIconvFrom) do
    Result := StringReplace(Result, FIconvFrom[i], FIconvTo[i], [rfReplaceAll]);
end;

function THunSpellChecker.MatchesCompoundRule(const word, Rule: string): boolean;
var
  i: integer;
  NumPart, Suffix: string;
  LastDigit, LastTwoDigits: integer;
begin
  Result := False;

  NumPart := '';
  for i := 1 to Length(word) do
  begin
    if CharInSet(word[i], ['0'..'9']) then
      NumPart := NumPart + word[i]
    else
      Break;
  end;
  if NumPart = '' then Exit;
  Suffix := Copy(word, Length(NumPart) + 1, MaxInt);

  if Rule <> 'n*mp' then Exit;

  if Length(NumPart) < 1 then Exit;
  LastDigit := StrToInt(NumPart[Length(NumPart)]);
  if not (LastDigit in [1..9]) then Exit;

  if Length(NumPart) >= 2 then
    LastTwoDigits := StrToInt(Copy(NumPart, Length(NumPart) - 1, 2))
  else
    LastTwoDigits := LastDigit;

  case Suffix of
    'st': Result := (LastDigit = 1) and (LastTwoDigits <> 11);
    'nd': Result := (LastDigit = 2) and (LastTwoDigits <> 12);
    'rd': Result := (LastDigit = 3) and (LastTwoDigits <> 13);
    'th': Result := not ((LastDigit = 1) and (LastTwoDigits <> 11)) and not ((LastDigit = 2) and (LastTwoDigits <> 12)) and
        not ((LastDigit = 3) and (LastTwoDigits <> 13));
    else
      Result := False;
  end;
end;

function THunSpellChecker.IsCompoundNumber(const word: string): boolean;
var
  i: integer;
  HasDigit: boolean;
begin
  Result := False;
  if FCompoundMin <= 0 then Exit;
  if Length(word) < FCompoundMin then Exit;

  HasDigit := False;
  for i := 1 to Length(word) do
    if CharInSet(word[i], ['0'..'9']) then
    begin
      HasDigit := True;
      Break;
    end;
  if not HasDigit then Exit;

  for i := 0 to High(FCompoundRules) do
    if MatchesCompoundRule(word, FCompoundRules[i]) then
      Exit(True);
end;

function THunSpellChecker.IsNoSuggestWord(const Flags: TFlagArray): boolean;
begin
  Result := (FNoSuggestFlag <> '') and HasFlag(Flags, FNoSuggestFlag);
end;

function THunSpellChecker.IsForbiddenWord(const Flags: TFlagArray): boolean;
begin
  Result := (FForbiddenWordFlag <> '') and HasFlag(Flags, FForbiddenWordFlag);
end;

function THunSpellChecker.IsWordChar(Ch: pchar; CharLen: integer): boolean;
var
  CodePoint: cardinal;
  i: integer;
begin
  CodePoint := 0;
  if CharLen = 1 then
    CodePoint := Ord(Ch^)
  else if CharLen = 2 then
    CodePoint := ((Ord(Ch^) and $1F) shl 6) or (Ord((Ch + 1)^) and $3F)
  else if CharLen = 3 then
    CodePoint := ((Ord(Ch^) and $0F) shl 12) or ((Ord((Ch + 1)^) and $3F) shl 6) or (Ord((Ch + 2)^) and $3F)
  else if CharLen = 4 then
    CodePoint := ((Ord(Ch^) and $07) shl 18) or ((Ord((Ch + 1)^) and $3F) shl 12) or ((Ord((Ch + 2)^) and $3F) shl 6) or
      (Ord((Ch + 3)^) and $3F);

  Result := (CodePoint >= Ord('A')) and (CodePoint <= Ord('Z')) or (CodePoint >= Ord('a')) and
    (CodePoint <= Ord('z')) or (CodePoint >= Ord('0')) and (CodePoint <= Ord('9')) or (CodePoint = Ord('_')) or
    (CodePoint >= $0410) and (CodePoint <= $044F) or (CodePoint = $0401) or (CodePoint = $0451);
  if Result then Exit;

  for i := 0 to High(FWordCharsCodes) do
    if FWordCharsCodes[i] = CodePoint then
      Exit(True);

  Result := False;
end;

procedure THunSpellChecker.BuildAllWordsArray;
var
  i, j, Len, MaxLen: integer;
  FirstChar: string;
begin
  SetLength(FAllWords, FWordCount);
  SetLength(FAllWordsFlags, FWordCount);
  SetLength(FAllWordsLower, FWordCount);
  SetLength(FAllWordsFirstChar, FWordCount);
  MaxLen := 0;

  for i := 0 to FWordCount - 1 do
  begin
    FAllWords[i] := FWords[i].word;
    SetLength(FAllWordsFlags[i], Length(FWords[i].Flags));
    for j := 0 to High(FWords[i].Flags) do
      FAllWordsFlags[i][j] := FWords[i].Flags[j];

    FAllWordsLower[i] := UTF8LowerCase(FAllWords[i]);
    if FAllWordsLower[i] <> '' then
      FirstChar := UTF8Copy(FAllWordsLower[i], 1, 1)
    else
      FirstChar := '';
    FAllWordsFirstChar[i] := FirstChar;

    Len := UTF8Length(FAllWords[i]);
    if Len > MaxLen then
      MaxLen := Len;
  end;

  SetLength(FLengthBuckets, MaxLen + 1);
  for i := 0 to FWordCount - 1 do
  begin
    Len := UTF8Length(FAllWords[i]);
    SetLength(FLengthBuckets[Len], Length(FLengthBuckets[Len]) + 1);
    FLengthBuckets[Len][High(FLengthBuckets[Len])] := i;
  end;
end;

procedure THunSpellChecker.AddWeightedSuggestion(var Suggestions: TWeightedSuggestionArray; const Candidate: string; Dist: integer);
var
  i: integer;
begin
  if Candidate = '' then Exit;

  // Check for duplicates
  for i := 0 to High(Suggestions) do
    if Suggestions[i].S = Candidate then
      Exit;
  SetLength(Suggestions, Length(Suggestions) + 1);
  Suggestions[High(Suggestions)].S := Candidate;
  Suggestions[High(Suggestions)].Dist := Dist;
end;

procedure THunSpellChecker.GenerateAndAddAffixForms(var Suggestions: TWeightedSuggestionArray; const BaseWord: string;
  const Flags: TFlagArray; const TargetWordLower: string);
var
  i, r, idx: integer;
  Flag: string;
  Group: TAffixGroup;
  RuleS: TSuffixRule;
  RuleP: TPrefixRule;
  Stripped: string;
  Form: string;
  Dist: integer;
begin
  // Suffix forms
  for i := 0 to High(FActiveFlags) do
  begin
    Flag := FActiveFlags[i];
    if not HasFlag(Flags, Flag) then Continue;
    if not FindAffixGroup(FSuffixRules, Flag, idx) then Continue;
    Group := FSuffixRules[idx].Group;
    for r := 0 to High(Group.Suffixes) do
    begin
      RuleS := Group.Suffixes[r];
      if (RuleS.Strip <> '') and (not UTF8EndsStr(RuleS.Strip, BaseWord)) then Continue;
      if not MatchesCondition(RuleS.Condition, BaseWord, False) then Continue;
      Stripped := BaseWord;
      if RuleS.Strip <> '' then
        UTF8Delete(Stripped, UTF8Length(Stripped) - UTF8Length(RuleS.Strip) + 1, UTF8Length(RuleS.Strip));
      Form := Stripped + RuleS.Add;
      Dist := LevenshteinDistance(TargetWordLower, UTF8LowerCase(Form));
      if (Dist <= 2) and (Form <> TargetWordLower) then
        AddWeightedSuggestion(Suggestions, Form, Dist);
    end;
  end;

  // Prefix forms
  for i := 0 to High(FActiveFlags) do
  begin
    Flag := FActiveFlags[i];
    if not HasFlag(Flags, Flag) then Continue;
    if not FindAffixGroup(FPrefixRules, Flag, idx) then Continue;
    Group := FPrefixRules[idx].Group;
    for r := 0 to High(Group.Prefixes) do
    begin
      RuleP := Group.Prefixes[r];
      if (RuleP.Strip <> '') and (not UTF8StartsStr(RuleP.Strip, BaseWord)) then Continue;
      if not MatchesCondition(RuleP.Condition, BaseWord, True) then Continue;
      Stripped := BaseWord;
      if RuleP.Strip <> '' then
        UTF8Delete(Stripped, 1, UTF8Length(RuleP.Strip));
      Form := RuleP.Add + Stripped;
      Dist := LevenshteinDistance(TargetWordLower, UTF8LowerCase(Form));
      if (Dist <= 2) and (Form <> TargetWordLower) then
        AddWeightedSuggestion(Suggestions, Form, Dist);
    end;
  end;
end;

function THunSpellChecker.CompareWeighted(const A, B: TWeightedSuggestion): integer;
begin
  if A.Dist <> B.Dist then
    Result := A.Dist - B.Dist
  else
  begin
    Result := UTF8Length(A.S) - UTF8Length(B.S);
    if Result = 0 then
      Result := CompareStr(UTF8LowerCase(A.S), UTF8LowerCase(B.S));
  end;
end;

procedure THunSpellChecker.SortWeightedSuggestions(var Arr: TWeightedSuggestionArray);
var
  i, j: integer;
  Temp: TWeightedSuggestion;
begin
  // Simple insertion sort (sufficient for small arrays)
  for i := 1 to High(Arr) do
  begin
    Temp := Arr[i];
    j := i - 1;
    while (j >= 0) and (CompareWeighted(Arr[j], Temp) > 0) do
    begin
      Arr[j + 1] := Arr[j];
      Dec(j);
    end;
    Arr[j + 1] := Temp;
  end;
end;

function THunSpellChecker.AdjustCase(const Source, S: string): string;
var
  SourceLower, SourceUpper: string;
  SrcFirstUp: boolean;
begin
  // Determine case pattern of Source
  SourceLower := UTF8LowerCase(Source);
  SourceUpper := UTF8UpperCase(Source);
  SrcFirstUp := (Source <> '') and (UTF8Copy(Source, 1, 1) = UTF8UpperCase(UTF8Copy(Source, 1, 1)));

  if Source = SourceLower then
    // all lower
    Result := UTF8LowerCase(S)
  else if Source = SourceUpper then
    // all upper
    Result := UTF8UpperCase(S)
  else if SrcFirstUp then
  begin
    // Title case: first char uppercase, rest lowercase
    Result := UTF8UpperCase(UTF8Copy(S, 1, 1)) + UTF8LowerCase(UTF8Copy(S, 2, MaxInt));
  end
  else
    // Mixed case - keep as is
    Result := S;
end;

procedure THunSpellChecker.ProcessREPandMAP(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
var
  RepIdx, MapIdx, i: integer;
  RepFrom, RepTo: string;
  REPResults: TStringArray;
  NewWord: string;
  FoundIndex: integer;
  Group: string;
  CharIdx: integer;
  OrigChar, Replacement: string;
begin
  // REP processing
  for RepIdx := 0 to High(FREPFrom) do
  begin
    RepFrom := FREPFrom[RepIdx];
    RepTo := FREPTo[RepIdx];
    REPResults := ApplyREP(CleanWord, RepFrom, RepTo);
    for i := 0 to High(REPResults) do
    begin
      NewWord := REPResults[i];
      if NewWord <> CleanWord then
      begin
        if HashFind(NewWord, FoundIndex) then
        begin
          if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
            AddWeightedSuggestion(Weighted, NewWord, LevenshteinDistance(CleanWord, NewWord));
        end;
      end;
    end;
  end;

  // MAP processing
  for MapIdx := 0 to High(FMAPGroups) do
  begin
    Group := FMAPGroups[MapIdx];
    CharIdx := 1;
    while CharIdx <= UTF8Length(CleanWord) do
    begin
      OrigChar := UTF8Copy(CleanWord, CharIdx, 1);
      if UTF8Pos(OrigChar, Group) = 0 then
      begin
        Inc(CharIdx);
        Continue;
      end;
      for i := 1 to UTF8Length(Group) do
      begin
        Replacement := UTF8Copy(Group, i, 1);
        if Replacement = OrigChar then Continue;
        NewWord := UTF8Copy(CleanWord, 1, CharIdx - 1) + Replacement + UTF8Copy(CleanWord, CharIdx + 1, MaxInt);
        if HashFind(NewWord, FoundIndex) then
        begin
          if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
            AddWeightedSuggestion(Weighted, NewWord, LevenshteinDistance(CleanWord, NewWord));
        end;
      end;
      Inc(CharIdx);
    end;
  end;
end;

procedure THunSpellChecker.GenerateTryKeyCandidates(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
var
  i, j, k, pos: integer;
  ch, repl: string;
  cand: string;
  FoundIndex: integer;
  Neighbor: string;
  Group: string;
begin
  // Generate replacements using TRY
  if FTryChars <> '' then
  begin
    for i := 1 to UTF8Length(CleanWord) do
    begin
      ch := UTF8Copy(CleanWord, i, 1);
      pos := UTF8Pos(ch, FTryChars);
      if pos > 0 then
      begin
        // Neighbor characters in TRY string
        for j := pos - 1 to pos + 1 do
        begin
          if (j >= 1) and (j <= UTF8Length(FTryChars)) and (j <> pos) then
          begin
            repl := UTF8Copy(FTryChars, j, 1);
            cand := UTF8Copy(CleanWord, 1, i - 1) + repl + UTF8Copy(CleanWord, i + 1, MaxInt);
            if HashFind(cand, FoundIndex) then
            begin
              if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
                AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
            end;
          end;
        end;
      end;
    end;
  end;

  // Generate replacements using KEY (keyboard neighbors)
  for i := 1 to UTF8Length(CleanWord) do
  begin
    ch := UTF8Copy(CleanWord, i, 1);
    for k := 0 to FKeyGroups.Count - 1 do
    begin
      Group := FKeyGroups[k];
      pos := UTF8Pos(ch, Group);
      if pos > 0 then
      begin
        // Horizontal neighbors
        if pos > 1 then
        begin
          Neighbor := UTF8Copy(Group, pos - 1, 1);
          cand := UTF8Copy(CleanWord, 1, i - 1) + Neighbor + UTF8Copy(CleanWord, i + 1, MaxInt);
          if HashFind(cand, FoundIndex) then
            if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
              AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
        end;
        if pos < UTF8Length(Group) then
        begin
          Neighbor := UTF8Copy(Group, pos + 1, 1);
          cand := UTF8Copy(CleanWord, 1, i - 1) + Neighbor + UTF8Copy(CleanWord, i + 1, MaxInt);
          if HashFind(cand, FoundIndex) then
            if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
              AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
        end;
      end;
    end;
  end;

  // Insert characters from TRY (first few)
  if FTryChars <> '' then
  begin
    for i := 0 to UTF8Length(CleanWord) do
    begin
      for j := 1 to Min(UTF8Length(FTryChars), 10) do
      begin
        repl := UTF8Copy(FTryChars, j, 1);
        cand := UTF8Copy(CleanWord, 1, i) + repl + UTF8Copy(CleanWord, i + 1, MaxInt);
        if HashFind(cand, FoundIndex) then
          if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
            AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
      end;
    end;
  end;

  // Delete characters
  for i := 1 to UTF8Length(CleanWord) do
  begin
    cand := UTF8Copy(CleanWord, 1, i - 1) + UTF8Copy(CleanWord, i + 1, MaxInt);
    if HashFind(cand, FoundIndex) then
      if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
        AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
  end;

  // Swap adjacent characters
  for i := 1 to UTF8Length(CleanWord) - 1 do
  begin
    cand := UTF8Copy(CleanWord, 1, i - 1) + UTF8Copy(CleanWord, i + 1, 1) + UTF8Copy(CleanWord, i, 1) + UTF8Copy(CleanWord, i + 2, MaxInt);
    if HashFind(cand, FoundIndex) then
      if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
        AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
  end;
end;

function THunSpellChecker.LevenshteinDistanceLimited(const S1, S2: string; MaxDist: integer): integer;
var
  Wide1, Wide2: widestring;
  Len1, Len2, i, j, Prev, Cur, Tmp, Cost, RowMin: integer;
  PrevRow, CurRow: array of integer;
begin
  Wide1 := UTF8Decode(S1);
  Wide2 := UTF8Decode(S2);
  Len1 := Length(Wide1);
  Len2 := Length(Wide2);
  PrevRow := [];
  CurRow := [];

  if Abs(Len1 - Len2) > MaxDist then
    Exit(MaxDist + 1);

  // Keep only two rows. Suggest() can call this function many times.
  if Len1 < Len2 then
  begin
    Tmp := Len1;
    Len1 := Len2;
    Len2 := Tmp;
    Wide1 := UTF8Decode(S2);
    Wide2 := UTF8Decode(S1);
  end;

  SetLength(PrevRow, Len2 + 1);
  SetLength(CurRow, Len2 + 1);
  for j := 0 to Len2 do
    PrevRow[j] := j;

  for i := 1 to Len1 do
  begin
    CurRow[0] := i;
    RowMin := CurRow[0];
    for j := 1 to Len2 do
    begin
      if Wide1[i] = Wide2[j] then
        Cost := 0
      else
        Cost := 1;

      Prev := PrevRow[j] + 1;
      Cur := CurRow[j - 1] + 1;
      Tmp := PrevRow[j - 1] + Cost;
      if Cur < Prev then Prev := Cur;
      if Tmp < Prev then Prev := Tmp;
      CurRow[j] := Prev;
      if Prev < RowMin then RowMin := Prev;
    end;

    if RowMin > MaxDist then
      Exit(MaxDist + 1);

    for j := 0 to Len2 do
    begin
      Tmp := PrevRow[j];
      PrevRow[j] := CurRow[j];
      CurRow[j] := Tmp;
    end;
  end;

  Result := PrevRow[Len2];
end;

procedure THunSpellChecker.ProcessDictionaryScan(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
var
  TargetLower, TargetFirst, TargetPrefix: string;
  TargetLen, MinLen, MaxLen, MinLenExt, MaxLenExt: integer;
  Len, BucketIdx, WordIndex, Dist: integer;
  FoundFlags: TFlagArray;
  CandidateLower: string;
begin
  TargetLower := UTF8LowerCase(CleanWord);
  TargetLen := UTF8Length(TargetLower);

  if TargetLen = 0 then
    Exit;

  TargetFirst := UTF8Copy(TargetLower, 1, 1);

  // Pass 1: exact dictionary words near the target length.
  // This is the hot path and remains very cheap.
  MinLen := Max(0, TargetLen - 2);
  MaxLen := TargetLen + 2;

  if MaxLen > High(FLengthBuckets) then
    MaxLen := High(FLengthBuckets);

  for Len := MinLen to MaxLen do
  begin
    for BucketIdx := 0 to High(FLengthBuckets[Len]) do
    begin
      WordIndex := FLengthBuckets[Len][BucketIdx];

      // Fast first-character rejection.
      if (TargetFirst <> '') and (FAllWordsFirstChar[WordIndex] <> TargetFirst) then
        Continue;

      Dist := LevenshteinDistanceLimited(TargetLower, FAllWordsLower[WordIndex], 2);

      if Dist > 2 then
        Continue;

      FoundFlags := FAllWordsFlags[WordIndex];

      if IsNoSuggestWord(FoundFlags) or IsForbiddenWord(FoundFlags) then
        Continue;

      AddWeightedSuggestion(
        Weighted,
        FAllWords[WordIndex],
        Dist
        );
    end;
  end;

  // Pass 2: only look for possible bases for affix forms.
  // The extended search is intentionally much more selective.
  MinLenExt := Max(1, TargetLen - 4);
  MaxLenExt := TargetLen + 4;

  if MaxLenExt > High(FLengthBuckets) then
    MaxLenExt := High(FLengthBuckets);

  for Len := MinLenExt to MaxLenExt do
  begin
    for BucketIdx := 0 to High(FLengthBuckets[Len]) do
    begin
      WordIndex := FLengthBuckets[Len][BucketIdx];

      FoundFlags := FAllWordsFlags[WordIndex];

      if IsNoSuggestWord(FoundFlags) or IsForbiddenWord(FoundFlags) then
        Continue;

      CandidateLower := FAllWordsLower[WordIndex];

      // Very cheap prefix filter.
      // For short words only compare the first character.
      // For longer words require the first two characters.
      if TargetLen >= 4 then
      begin
        TargetPrefix := UTF8Copy(TargetLower, 1, 2);

        if UTF8Copy(CandidateLower, 1, 2) <> TargetPrefix then
          Continue;
      end
      else
      begin
        if UTF8Copy(CandidateLower, 1, 1) <> TargetFirst then
          Continue;
      end;

      // Do not generate forms from completely unrelated bases.
      Dist := LevenshteinDistanceLimited(TargetLower, CandidateLower, 4);

      if Dist > 4 then
        Continue;

      GenerateAndAddAffixForms(
        Weighted,
        FAllWords[WordIndex],
        FoundFlags,
        TargetLower
        );
    end;
  end;
end;

function THunSpellChecker.CheckText(const Text: string): TSpellErrorArray;
var
  Ptr: pchar;
  CharLen: integer;
  CharIndex: integer;
  WordStartChar: integer;
  WordLengthChars: integer;
  InWord: boolean;
  word: string;
  Err: TSpellError;
begin
  Result := nil;
  SetLength(Result, 0);
  Ptr := PChar(Text);
  CharIndex := 0;
  InWord := False;
  WordStartChar := 0;
  WordLengthChars := 0;
  while Ptr^ <> #0 do
  begin
    {$NOTES OFF}
    CharLen := UTF8CodepointSize(Ptr);
    {$NOTES ON}
    if IsWordChar(Ptr, CharLen) then
    begin
      if not InWord then
      begin
        WordStartChar := CharIndex;
        WordLengthChars := 0;
        InWord := True;
      end;
      Inc(WordLengthChars);
    end
    else
    begin
      if InWord then
      begin
        word := UTF8Copy(Text, WordStartChar + 1, WordLengthChars);
        if not CheckWord(word) then
        begin
          Err.Offset := WordStartChar;
          Err.Length := WordLengthChars;
          Err.Message := 'Unknown word';
          Err.Replacements := Suggest(word);
          Err.Color := clRed;
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Err;
        end;
        InWord := False;
      end;
    end;
    Inc(Ptr, CharLen);
    Inc(CharIndex);
  end;
  if InWord then
  begin
    word := UTF8Copy(Text, WordStartChar + 1, WordLengthChars);
    if not CheckWord(word) then
    begin
      Err.Offset := WordStartChar;
      Err.Length := WordLengthChars;
      Err.Message := 'Unknown word';
      Err.Replacements := Suggest(word);
      Err.Color := clRed;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Err;
    end;
  end;
end;

function THunSpellChecker.Suggest(const word: string): TStringArray;
var
  CleanWord: string;
  Weighted: TWeightedSuggestionArray = nil;
  i: integer;
  CachedValue: string;
  Parts: TStringList;
  CacheIdx: integer;
  UniqueResults: TStringList; // To remove duplicates after case adjustment
  Adjusted: string;
begin
  Result := [];
  CleanWord := ApplyIconv(word);
  if FSuggestCache.Find(CleanWord, CacheIdx) then
  begin
    CachedValue := FSuggestCache.ValueFromIndex[CacheIdx];
    Parts := TStringList.Create;
    try
      Parts.Delimiter := '|';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := CachedValue;
      SetLength(Result, Parts.Count);
      for i := 0 to Parts.Count - 1 do
        Result[i] := Parts[i];
    finally
      Parts.Free;
    end;
    Exit;
  end;

  SetLength(Weighted, 0);

  // 1. REP and MAP
  ProcessREPandMAP(CleanWord, Weighted);

  // 2. TRY and KEY based generation
  GenerateTryKeyCandidates(CleanWord, Weighted);

  // 3. Dictionary scan
  ProcessDictionaryScan(CleanWord, Weighted);

  // Sort by distance
  SortWeightedSuggestions(Weighted);

  // Adjust case and remove duplicates
  UniqueResults := TStringList.Create;
  try
    UniqueResults.Sorted := True;
    UniqueResults.Duplicates := dupIgnore;
    SetLength(Result, 0);
    for i := 0 to High(Weighted) do
    begin
      Adjusted := AdjustCase(word, Weighted[i].S);
      if UniqueResults.IndexOf(Adjusted) = -1 then
      begin
        UniqueResults.Add(Adjusted);
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Adjusted;
        if Length(Result) >= 10 then Break;
      end;
    end;
  finally
    UniqueResults.Free;
  end;

  // Cache the result
  CachedValue := '';
  for i := 0 to High(Result) do
  begin
    if i > 0 then CachedValue := CachedValue + '|';
    CachedValue := CachedValue + Result[i];
  end;
  if CachedValue <> '' then
    FSuggestCache.Add(CleanWord + '=' + CachedValue);
end;

end.
