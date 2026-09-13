//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit HunSpellChecker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Math, StrUtils, Character, LazUTF8;

type
  TStringArray = array of string;
  TIntegerArray = array of integer;
  TCardinalArray = array of cardinal;

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
    Flag: integer;
    Group: TAffixGroup;
  end;

  TAffixList = array of TAffixEntry;

  TWordEntry = record
    word: string;
    Flags: TIntegerArray;
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
    // Flag pool. A flag is a string from AFF or DIC, stored once and referenced by ID
    FFlagStrings: array of string;
    FFlagCount: integer;
    FFlagHash: TIntegerArray;      // Open addressing hash on flag string -> flag ID
    FFlagHashSize: integer;
    FFlagHashMask: integer;
    // Affix rule tables indexed by flag ID
    FSuffixRules: TAffixList;
    FPrefixRules: TAffixList;
    FSuffixFlagToIdx: TIntegerArray;  // Flag ID -> index in FSuffixRules or -1
    FPrefixFlagToIdx: TIntegerArray;  // Flag ID -> index in FPrefixRules or -1
    FActiveFlags: TIntegerArray;      // All flag IDs with at least one rule
    FCrossSuffixFlags: TIntegerArray; // Flag IDs with cross product suffixes
    FCrossPrefixFlags: TIntegerArray; // Flag IDs with cross product prefixes
    // Word data for suggestions
    FAllWords: array of string;
    FAllWordsLower: array of string;
    FAllWordsFirstChar: TCardinalArray;  // First UTF-8 codepoint of each word
    FLengthBuckets: array of TIntegerArray;
    // Iconv substitutions
    FIconvFrom: array of string;
    FIconvTo: array of string;
    FWordCharsCodes: TCardinalArray;
    // Special flags stored as IDs. -1 means the flag is not defined for this dictionary
    FNoSuggestFlag: integer;
    FNeedAffixFlag: integer;
    FPseudoRootFlag: integer;
    FCircumfixFlag: integer;
    FForbiddenWordFlag: integer;
    FOnlyInCompoundFlag: integer;
    FCompoundFlag: integer;
    FCompoundBegin: integer;
    FCompoundMiddle: integer;
    FCompoundEnd: integer;
    FCompoundPermitFlag: integer;
    FCompoundForbidFlag: integer;
    FCompoundMin: integer;
    FCompoundRules: array of string;
    FREPFrom: array of string;
    FREPTo: array of string;
    FMAPGroups: array of string;
    FSuggestCache: TStringList;
    FFlagMode: string; // ASCII, UTF-8, long, num
    FAFCount: integer;
    FAAliases: array of TIntegerArray;
    FBreakPatterns: TStringList;
    FTryChars: string;
    FKeyGroups: TStringList;
    procedure LoadAFFFromStream(Stream: TStream);
    procedure LoadDICFromStream(Stream: TStream);
    function LoadAFF(const FileName: string): boolean;
    function LoadDIC(const FileName: string): boolean;
    function InternFlag(const S: string): integer;
    procedure RehashFlags;
    procedure AddAffixGroup(var List: TAffixList; const Flag: integer; const Group: TAffixGroup);
    procedure AddSuffixRule(const Flag: integer; const Strip, Add, Condition: string; CrossProduct: boolean);
    procedure AddPrefixRule(const Flag: integer; const Strip, Add, Condition: string; CrossProduct: boolean);
    procedure BuildAffixIndexes;
    function MatchesCondition(const Condition, word: string; IsPrefix: boolean): boolean;
    function TryApplySuffixes(const word: string; const Flags: TIntegerArray): boolean;
    function TryApplyPrefixes(const word: string; const Flags: TIntegerArray): boolean;
    function TryApplyCrossProduct(const word: string; const Flags: TIntegerArray): boolean;
    function TryApplyAffixes(const word: string; const Flags: TIntegerArray): boolean;
    function GetWordFlags(const word: string): TIntegerArray;
    procedure HashAdd(const word: string; const Flags: TIntegerArray);
    function HashFind(const word: string; out Index: integer): boolean;
    function FNV1aHash(const S: string): cardinal;
    procedure Rehash;
    function IsWordChar(Ch: pchar; CharLen: integer): boolean;
    procedure BuildAllWordsArray;
    function ApplyIconv(const S: string): string;
    function MatchesCompoundRule(const word, Rule: string): boolean;
    function IsCompoundNumber(const word: string): boolean;
    function IsNoSuggestWord(const Flags: TIntegerArray): boolean;
    function IsForbiddenWord(const Flags: TIntegerArray): boolean;
    function HasFlag(const Flags: TIntegerArray; const FlagId: integer): boolean;
    procedure AddWeightedSuggestion(var Suggestions: TWeightedSuggestionArray; const Candidate: string; Dist: integer);
    procedure GenerateAndAddAffixForms(var Suggestions: TWeightedSuggestionArray; const BaseWord: string;
      const Flags: TIntegerArray; const TargetWordLower: string);
    function StripComment(const S: string): string;
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

function HunspellDictionaryCandidates(const Lang: string): TStringArray;

implementation

function LevenshteinDistance(const S1, S2: string): integer; forward;

function HunspellDictionaryCandidates(const Lang: string): TStringArray;
var
  s, norm, base, preferred: string;
  i: integer;
  list: TStringList;
begin
  Result := nil;
  s := Trim(Lang);
  if s = '' then Exit;

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
    list.Add(norm);

    if Pos('_', norm) > 0 then
    begin
      base := Copy(norm, 1, Pos('_', norm) - 1);
      list.Add(base);
    end;

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
        'af': preferred := 'af_ZA';
        'an': preferred := 'an_ES';
        'as': preferred := 'as_IN';
        'bg': preferred := 'bg_BG';
        'br': preferred := 'br_FR';
        'bs': preferred := 'bs_BA';
        'et': preferred := 'et_EE';
        'gd': preferred := 'gd_GB';
        'gu': preferred := 'gu_IN';
        'hr': preferred := 'hr_HR';
        'hu': preferred := 'hu_HU';
        'id': preferred := 'id_ID';
        'kn': preferred := 'kn_IN';
        'lv': preferred := 'lv_LV';
        'mn': preferred := 'mn_MN';
        'nn': preferred := 'nn_NO';
        'oc': preferred := 'oc_FR';
        'or': preferred := 'or_IN';
        'pa': preferred := 'pa_IN';
        'ro': preferred := 'ro_RO';
        'sa': preferred := 'sa_IN';
        'sk': preferred := 'sk_SK';
        'sl': preferred := 'sl_SI';
        'th': preferred := 'th_TH';
        'zu': preferred := 'zu_ZA';
        else
          preferred := norm;
      end;

      if preferred <> norm then
        list.Insert(0, preferred);

      if preferred = 'fa_IR' then list.Add('fa-IR');
      if preferred = 'be_BY' then list.Add('be-official');
      if preferred = 'ca' then list.Add('ca-valencia');
      if preferred = 'sr' then list.Add('sr-Latn');
      if preferred = 'de_DE' then list.Insert(0, 'de_DE_frami');
      if preferred = 'en_US' then list.Add('en');
    end
    else if (Length(norm) > 2) and (Pos('_', norm) > 0) then
    begin
      if norm = 'fa_IR' then list.Add('fa-IR');
      if norm = 'be_BY' then list.Add('be-official');
      if norm = 'ca_ES' then list.Add('ca');
      if norm = 'ca_ES_valencia' then list.Insert(0, 'ca-valencia');
      if norm = 'de_DE' then list.Add('de_DE_frami');
      if norm = 'de_AT' then list.Add('de_AT_frami');
      if norm = 'de_CH' then list.Add('de_CH_frami');
      if norm = 'sr_Latn' then list.Insert(0, 'sr-Latn');
      if norm = 'pt_PT' then list.Add('pt');
    end;

    if Pos('-', s) > 0 then
      list.Add(s);

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

function FirstCodepoint(const S: string): cardinal;
var
  p: pchar;
  ch: integer;
begin
  Result := 0;
  if S = '' then Exit;
  p := PChar(S);
  {$NOTES OFF}
  ch := UTF8CodepointSize(p);
  {$NOTES ON}
  if ch = 1 then
    Result := Ord(p^)
  else if ch = 2 then
    Result := ((Ord(p^) and $1F) shl 6) or (Ord((p + 1)^) and $3F)
  else if ch = 3 then
    Result := ((Ord(p^) and $0F) shl 12) or ((Ord((p + 1)^) and $3F) shl 6) or (Ord((p + 2)^) and $3F)
  else if ch = 4 then
    Result := ((Ord(p^) and $07) shl 18) or ((Ord((p + 1)^) and $3F) shl 12) or ((Ord((p + 2)^) and $3F) shl 6) or
      (Ord((p + 3)^) and $3F);
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
      RangeStart := ClassStr[i];
      RangeEnd := ClassStr[i + 2];
      if (Ch >= RangeStart) and (Ch <= RangeEnd) then Exit(True);
      Inc(i, 3);
    end
    else
    begin
      if Ch = ClassStr[i] then Exit(True);
      Inc(i);
    end;
  end;
  Result := False;
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
    if UTF8StartsStr(Copy(From, 2, MaxInt), word) then
    begin
      candidate := Replacement + UTF8Copy(word, UTF8Length(Copy(From, 2, MaxInt)) + 1, MaxInt);
      candidate := StringReplace(candidate, '_', ' ', [rfReplaceAll]);
      SetLength(Result, 1);
      Result[0] := candidate;
    end;
  end
  else if From[Length(From)] = '$' then
  begin
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

// ---------------------------------------------------------------------------------
// Flag interning
// ---------------------------------------------------------------------------------

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

procedure THunSpellChecker.RehashFlags;
var
  oldHash: TIntegerArray;
  oldSize, i: integer;
  h: cardinal;
  id: integer;
begin
  oldHash := FFlagHash;
  oldSize := FFlagHashSize;
  FFlagHashSize := FFlagHashSize * 2;
  FFlagHashMask := FFlagHashSize - 1;
  SetLength(FFlagHash, FFlagHashSize);
  FillDWord(FFlagHash[0], FFlagHashSize, $FFFFFFFF);
  for i := 0 to oldSize - 1 do
  begin
    id := oldHash[i];
    if id = -1 then Continue;
    h := FNV1aHash(FFlagStrings[id]) and cardinal(FFlagHashMask);
    while FFlagHash[h] <> -1 do
      h := (h + 1) and cardinal(FFlagHashMask);
    FFlagHash[h] := id;
  end;
  SetLength(oldHash, 0);
end;

function THunSpellChecker.InternFlag(const S: string): integer;
var
  h: cardinal;
  id: integer;
begin
  if S = '' then Exit(-1);
  h := FNV1aHash(S) and cardinal(FFlagHashMask);
  id := FFlagHash[h];
  while id <> -1 do
  begin
    if FFlagStrings[id] = S then Exit(id);
    h := (h + 1) and cardinal(FFlagHashMask);
    id := FFlagHash[h];
  end;

  // Not found: add a new entry
  if FFlagCount = Length(FFlagStrings) then
  begin
    if Length(FFlagStrings) = 0 then SetLength(FFlagStrings, 128)
    else
      SetLength(FFlagStrings, Length(FFlagStrings) * 2);
  end;
  FFlagStrings[FFlagCount] := S;
  Result := FFlagCount;
  FFlagHash[h] := Result;
  Inc(FFlagCount);

  if FFlagCount * 10 > FFlagHashSize * 7 then
    RehashFlags;
end;

// ---------------------------------------------------------------------------------
// Word hash table
// ---------------------------------------------------------------------------------

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

procedure THunSpellChecker.HashAdd(const word: string; const Flags: TIntegerArray);
var
  hash, idx: cardinal;
  existingFlags: TIntegerArray;
  i, j: integer;
  flagExists: boolean;
  newCap: integer;
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
  begin
    if Length(FWords) = 0 then newCap := 4096
    else
      newCap := Length(FWords) * 2;
    SetLength(FWords, newCap);
  end;
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

function THunSpellChecker.HasFlag(const Flags: TIntegerArray; const FlagId: integer): boolean;
var
  i: integer;
begin
  Result := False;
  if FlagId < 0 then Exit;
  for i := 0 to High(Flags) do
    if Flags[i] = FlagId then Exit(True);
end;

// ---------------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------------

constructor THunSpellChecker.Create;
begin
  inherited;
  FWordCount := 0;
  FHashSize := 65536;
  FHashMask := FHashSize - 1;
  SetLength(FHashTable, FHashSize);
  FillDWord(FHashTable[0], FHashSize, $FFFFFFFF);
  SetLength(FWords, 0);

  FFlagCount := 0;
  SetLength(FFlagStrings, 0);
  FFlagHashSize := 4096;
  FFlagHashMask := FFlagHashSize - 1;
  SetLength(FFlagHash, FFlagHashSize);
  FillDWord(FFlagHash[0], FFlagHashSize, $FFFFFFFF);

  SetLength(FSuffixRules, 0);
  SetLength(FPrefixRules, 0);
  SetLength(FSuffixFlagToIdx, 0);
  SetLength(FPrefixFlagToIdx, 0);
  SetLength(FActiveFlags, 0);
  SetLength(FCrossSuffixFlags, 0);
  SetLength(FCrossPrefixFlags, 0);
  FFlagMode := 'ASCII';

  SetLength(FAllWords, 0);
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

  FNoSuggestFlag := -1;
  FNeedAffixFlag := -1;
  FPseudoRootFlag := -1;
  FCircumfixFlag := -1;
  FForbiddenWordFlag := -1;
  FOnlyInCompoundFlag := -1;
  FCompoundFlag := -1;
  FCompoundBegin := -1;
  FCompoundMiddle := -1;
  FCompoundEnd := -1;
  FCompoundPermitFlag := -1;
  FCompoundForbidFlag := -1;
  FCompoundMin := 0;
  FAFCount := 0;
  SetLength(FAAliases, 0);

  FBreakPatterns := TStringList.Create;
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
  SetLength(FFlagStrings, 0);
  SetLength(FFlagHash, 0);
  SetLength(FSuffixRules, 0);
  SetLength(FPrefixRules, 0);
  SetLength(FSuffixFlagToIdx, 0);
  SetLength(FPrefixFlagToIdx, 0);
  SetLength(FActiveFlags, 0);
  SetLength(FCrossSuffixFlags, 0);
  SetLength(FCrossPrefixFlags, 0);
  SetLength(FAllWords, 0);
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
  SetLength(FAAliases, 0);
  FBreakPatterns.Free;
  FSuggestCache.Free;
  FKeyGroups.Free;
  inherited;
end;

// ---------------------------------------------------------------------------------
// AFF / DIC loading
// ---------------------------------------------------------------------------------

function THunSpellChecker.LoadFromStream(AFFStream, DICStream: TStream): boolean;
begin
  Result := False;
  try
    FWordCount := 0;
    SetLength(FWords, 0);
    FFlagCount := 0;
    SetLength(FFlagStrings, 0);
    FillDWord(FFlagHash[0], FFlagHashSize, $FFFFFFFF);
    SetLength(FSuffixRules, 0);
    SetLength(FPrefixRules, 0);
    SetLength(FSuffixFlagToIdx, 0);
    SetLength(FPrefixFlagToIdx, 0);
    SetLength(FActiveFlags, 0);
    SetLength(FCrossSuffixFlags, 0);
    SetLength(FCrossPrefixFlags, 0);
    SetLength(FAllWords, 0);
    SetLength(FAllWordsLower, 0);
    SetLength(FAllWordsFirstChar, 0);
    SetLength(FLengthBuckets, 0);
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
    FNoSuggestFlag := -1;
    FNeedAffixFlag := -1;
    FPseudoRootFlag := -1;
    FCircumfixFlag := -1;
    FForbiddenWordFlag := -1;
    FOnlyInCompoundFlag := -1;
    FCompoundFlag := -1;
    FCompoundBegin := -1;
    FCompoundMiddle := -1;
    FCompoundEnd := -1;
    FCompoundPermitFlag := -1;
    FCompoundForbidFlag := -1;
    FCompoundMin := 0;
    FAFCount := 0;
    FTryChars := '';

    FillDWord(FHashTable[0], FHashSize, $FFFFFFFF);

    LoadAFFFromStream(AFFStream);
    BuildAffixIndexes;
    LoadDICFromStream(DICStream);
    BuildAllWordsArray;
    Result := True;
  except
    FWordCount := 0;
    SetLength(FWords, 0);
    FFlagCount := 0;
    SetLength(FFlagStrings, 0);
    FillDWord(FFlagHash[0], FFlagHashSize, $FFFFFFFF);
    SetLength(FSuffixRules, 0);
    SetLength(FPrefixRules, 0);
    SetLength(FSuffixFlagToIdx, 0);
    SetLength(FPrefixFlagToIdx, 0);
    SetLength(FActiveFlags, 0);
    SetLength(FCrossSuffixFlags, 0);
    SetLength(FCrossPrefixFlags, 0);
    SetLength(FAllWords, 0);
    SetLength(FAllWordsLower, 0);
    SetLength(FAllWordsFirstChar, 0);
    SetLength(FLengthBuckets, 0);
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
    FNoSuggestFlag := -1;
    FNeedAffixFlag := -1;
    FPseudoRootFlag := -1;
    FCircumfixFlag := -1;
    FForbiddenWordFlag := -1;
    FOnlyInCompoundFlag := -1;
    FCompoundFlag := -1;
    FCompoundBegin := -1;
    FCompoundMiddle := -1;
    FCompoundEnd := -1;
    FCompoundPermitFlag := -1;
    FCompoundForbidFlag := -1;
    FCompoundMin := 0;
    FAFCount := 0;
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
  FlagStr: string = '';
  FlagId: integer = 0;
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
  AliasIds: TIntegerArray = nil;
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
        if Parts.Count >= 2 then FFlagMode := UpperCase(Parts[1]);
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
            if (Parts.Count > 0) and (Parts[0] = 'AF') then Parts.Delete(0);
            SetLength(AliasIds, Parts.Count);
            for j := 0 to Parts.Count - 1 do
              AliasIds[j] := InternFlag(Parts[j]);
            FAAliases[i] := AliasIds;
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
            if (Parts.Count > 0) and (Parts[0] = 'BREAK') then Parts.Delete(0);
            if Parts.Count > 0 then FBreakPatterns.Add(Parts[0]);
            Inc(i);
          end;
        end;
      end
      else if Parts[0] = 'COMPOUNDFLAG' then
      begin
        if Parts.Count >= 2 then FCompoundFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'COMPOUNDBEGIN' then
      begin
        if Parts.Count >= 2 then FCompoundBegin := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'COMPOUNDMIDDLE' then
      begin
        if Parts.Count >= 2 then FCompoundMiddle := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'COMPOUNDEND' then
      begin
        if Parts.Count >= 2 then FCompoundEnd := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'COMPOUNDPERMITFLAG' then
      begin
        if Parts.Count >= 2 then FCompoundPermitFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'COMPOUNDFORBIDFLAG' then
      begin
        if Parts.Count >= 2 then FCompoundForbidFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'ONLYINCOMPOUND' then
      begin
        if Parts.Count >= 2 then FOnlyInCompoundFlag := InternFlag(Parts[1]);
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
          FlagStr := Parts[1];
          FlagId := InternFlag(FlagStr);
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
              AddSuffixRule(FlagId, Strip, Add, Condition, CrossProduct);
              Inc(i);
            end;
          end;
        end;
      end
      else if Parts[0] = 'PFX' then
      begin
        if Parts.Count >= 4 then
        begin
          FlagStr := Parts[1];
          FlagId := InternFlag(FlagStr);
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
              AddPrefixRule(FlagId, Strip, Add, Condition, CrossProduct);
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
            if (Parts.Count > 0) and (Parts[0] = 'ICONV') then Parts.Delete(0);
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
        if Parts.Count >= 2 then FNoSuggestFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'NEEDAFFIX' then
      begin
        if Parts.Count >= 2 then FNeedAffixFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'PSEUDOROOT' then
      begin
        if Parts.Count >= 2 then FPseudoRootFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'CIRCUMFIX' then
      begin
        if Parts.Count >= 2 then FCircumfixFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'FORBIDDENWORD' then
      begin
        if Parts.Count >= 2 then FForbiddenWordFlag := InternFlag(Parts[1]);
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
            if (Parts.Count > 0) and (Parts[0] = 'REP') then Parts.Delete(0);
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
            if (Parts.Count > 0) and (Parts[0] = 'MAP') then Parts.Delete(0);
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
  LineIdx: integer = 0;
  Line: string = '';
  word: string = '';
  FlagsStr: string = '';
  SlashPos: integer = 0;
  FlagsArr: TIntegerArray = nil;
  i: integer = 0;
  j: integer = 0;
  s: string = '';
  startPos: integer = 0;
  ExpectedWords: integer = 0;
  FlagId: integer = 0;
  AliasNum: integer = 0;
  AliasFlag: integer = 0;
  FlagList: TStringList = nil;
begin
  Lines := TStringList.Create;
  FlagList := TStringList.Create;
  try
    Lines.LoadFromStream(Stream);

    // The first line of the DIC contains the number of words.
    // We use it to preallocate FWords in one shot, eliminating the doubling copies.
    if Lines.Count > 0 then
    begin
      Line := Lines[0];
      if (Length(Line) > 0) and (Ord(Line[1]) = $EF) then
        Delete(Line, 1, 3);
      ExpectedWords := StrToIntDef(Trim(Line), 0);
      if ExpectedWords > 0 then
        SetLength(FWords, ExpectedWords + 1024);
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
        // Split flags into tokens and intern each one.
        // If AF aliases are defined, the token is a number that indexes FAAliases.
        FlagList.Clear;
        case FFlagMode of
          'ASCII':
          begin
            for j := 1 to Length(FlagsStr) do
              FlagList.Add(FlagsStr[j]);
          end;
          'UTF-8':
          begin
            s := FlagsStr;
            while s <> '' do
            begin
              FlagList.Add(UTF8Copy(s, 1, 1));
              UTF8Delete(s, 1, 1);
            end;
          end;
          'LONG', 'NUM':
          begin
            i := 1;
            while i <= Length(FlagsStr) do
            begin
              while (i <= Length(FlagsStr)) and (FlagsStr[i] in [',', ' ', #9]) do Inc(i);
              if i > Length(FlagsStr) then Break;
              startPos := i;
              while (i <= Length(FlagsStr)) and not (FlagsStr[i] in [',', ' ', #9]) do Inc(i);
              FlagList.Add(Copy(FlagsStr, startPos, i - startPos));
            end;
          end;
        end;

        for j := 0 to FlagList.Count - 1 do
        begin
          AliasNum := -1;
          if (FAFCount > 0) and TryStrToInt(FlagList[j], AliasNum) and (AliasNum >= 1) and (AliasNum <= FAFCount) then
          begin
            // Expand the alias into the actual flags it points to
            for i := 0 to High(FAAliases[AliasNum - 1]) do
            begin
              AliasFlag := FAAliases[AliasNum - 1][i];
              SetLength(FlagsArr, Length(FlagsArr) + 1);
              FlagsArr[High(FlagsArr)] := AliasFlag;
            end;
          end
          else
          begin
            FlagId := InternFlag(FlagList[j]);
            if FlagId >= 0 then
            begin
              SetLength(FlagsArr, Length(FlagsArr) + 1);
              FlagsArr[High(FlagsArr)] := FlagId;
            end;
          end;
        end;
      end;

      HashAdd(word, FlagsArr);
    end;
  finally
    Lines.Free;
    FlagList.Free;
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
      BuildAffixIndexes;
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
      BuildAllWordsArray;
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

// ---------------------------------------------------------------------------------
// Affix table management
// ---------------------------------------------------------------------------------

procedure THunSpellChecker.AddAffixGroup(var List: TAffixList; const Flag: integer; const Group: TAffixGroup);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)].Flag := Flag;
  List[High(List)].Group := Group;
end;

procedure THunSpellChecker.AddSuffixRule(const Flag: integer; const Strip, Add, Condition: string; CrossProduct: boolean);
var
  Group: TAffixGroup;
  Rule: TSuffixRule;
  idx: integer;
  i: integer;
  CrossProd: boolean;
begin
  Group := Default(TAffixGroup);
  CrossProd := CrossProduct;
  SetLength(Group.Suffixes, 0);
  SetLength(Group.Prefixes, 0);
  Group.CrossProduct := CrossProd;

  idx := -1;
  if (Flag >= 0) and (Flag < Length(FSuffixFlagToIdx)) then
    idx := FSuffixFlagToIdx[Flag];

  if idx < 0 then
  begin
    if Flag >= Length(FSuffixFlagToIdx) then
    begin
      i := Length(FSuffixFlagToIdx);
      SetLength(FSuffixFlagToIdx, Flag + 64);
      while i < Length(FSuffixFlagToIdx) do
      begin
        FSuffixFlagToIdx[i] := -1;
        Inc(i);
      end;
    end;
    SetLength(FSuffixRules, Length(FSuffixRules) + 1);
    idx := High(FSuffixRules);
    FSuffixRules[idx].Flag := Flag;
    FSuffixRules[idx].Group := Group;
    FSuffixFlagToIdx[Flag] := idx;
  end
  else
    Group := FSuffixRules[idx].Group;

  Rule.Strip := Strip;
  Rule.Add := Add;
  Rule.Condition := Condition;
  SetLength(Group.Suffixes, Length(Group.Suffixes) + 1);
  Group.Suffixes[High(Group.Suffixes)] := Rule;
  FSuffixRules[idx].Group := Group;
end;

procedure THunSpellChecker.AddPrefixRule(const Flag: integer; const Strip, Add, Condition: string; CrossProduct: boolean);
var
  Group: TAffixGroup;
  Rule: TPrefixRule;
  idx: integer;
  i: integer;
  CrossProd: boolean;
begin
  Group := Default(TAffixGroup);
  CrossProd := CrossProduct;
  SetLength(Group.Suffixes, 0);
  SetLength(Group.Prefixes, 0);
  Group.CrossProduct := CrossProd;

  idx := -1;
  if (Flag >= 0) and (Flag < Length(FPrefixFlagToIdx)) then
    idx := FPrefixFlagToIdx[Flag];

  if idx < 0 then
  begin
    if Flag >= Length(FPrefixFlagToIdx) then
    begin
      i := Length(FPrefixFlagToIdx);
      SetLength(FPrefixFlagToIdx, Flag + 64);
      while i < Length(FPrefixFlagToIdx) do
      begin
        FPrefixFlagToIdx[i] := -1;
        Inc(i);
      end;
    end;
    SetLength(FPrefixRules, Length(FPrefixRules) + 1);
    idx := High(FPrefixRules);
    FPrefixRules[idx].Flag := Flag;
    FPrefixRules[idx].Group := Group;
    FPrefixFlagToIdx[Flag] := idx;
  end
  else
    Group := FPrefixRules[idx].Group;

  Rule.Strip := Strip;
  Rule.Add := Add;
  Rule.Condition := Condition;
  SetLength(Group.Prefixes, Length(Group.Prefixes) + 1);
  Group.Prefixes[High(Group.Prefixes)] := Rule;
  FPrefixRules[idx].Group := Group;
end;

procedure THunSpellChecker.BuildAffixIndexes;
var
  i, Cnt: integer;
  id: integer;
begin
  if Length(FSuffixFlagToIdx) < FFlagCount then
  begin
    Cnt := Length(FSuffixFlagToIdx);
    SetLength(FSuffixFlagToIdx, FFlagCount);
    while Cnt < FFlagCount do
    begin
      FSuffixFlagToIdx[Cnt] := -1;
      Inc(Cnt);
    end;
  end;
  if Length(FPrefixFlagToIdx) < FFlagCount then
  begin
    Cnt := Length(FPrefixFlagToIdx);
    SetLength(FPrefixFlagToIdx, FFlagCount);
    while Cnt < FFlagCount do
    begin
      FPrefixFlagToIdx[Cnt] := -1;
      Inc(Cnt);
    end;
  end;

  SetLength(FActiveFlags, 0);
  SetLength(FCrossSuffixFlags, 0);
  SetLength(FCrossPrefixFlags, 0);

  for i := 0 to High(FSuffixRules) do
  begin
    id := FSuffixRules[i].Flag;
    SetLength(FActiveFlags, Length(FActiveFlags) + 1);
    FActiveFlags[High(FActiveFlags)] := id;
    if FSuffixRules[i].Group.CrossProduct then
    begin
      SetLength(FCrossSuffixFlags, Length(FCrossSuffixFlags) + 1);
      FCrossSuffixFlags[High(FCrossSuffixFlags)] := id;
    end;
  end;
  for i := 0 to High(FPrefixRules) do
  begin
    id := FPrefixRules[i].Flag;
    SetLength(FActiveFlags, Length(FActiveFlags) + 1);
    FActiveFlags[High(FActiveFlags)] := id;
    if FPrefixRules[i].Group.CrossProduct then
    begin
      SetLength(FCrossPrefixFlags, Length(FCrossPrefixFlags) + 1);
      FCrossPrefixFlags[High(FCrossPrefixFlags)] := id;
    end;
  end;
end;

// ---------------------------------------------------------------------------------
// Conditions
// ---------------------------------------------------------------------------------

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

  if (WideCond = '.') and (Length(WideWord) > 0) then Exit(True);

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
        while (closePos <= Length(WideCond)) and (WideCond[closePos] <> ']') do Inc(closePos);
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
    wPos := Length(WideWord);
    cPos := Length(WideCond);
    while (wPos >= 1) and (cPos >= 1) do
    begin
      cChar := WideCond[cPos];
      wChar := WideWord[wPos];

      if cChar = ']' then
      begin
        closePos := cPos;
        openPos := closePos;
        while (openPos >= 1) and (WideCond[openPos] <> '[') do Dec(openPos);
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

// ---------------------------------------------------------------------------------
// Affix application
// ---------------------------------------------------------------------------------

function THunSpellChecker.TryApplySuffixes(const word: string; const Flags: TIntegerArray): boolean;
var
  i, r, idx: integer;
  FlagId: integer;
  Group: TAffixGroup;
  Rule: TSuffixRule;
  CandidateStem: string;
  StemIndex: integer;
  FlagsEmpty: boolean;
  StemFlags: TIntegerArray;
begin
  Result := False;
  FlagsEmpty := Length(Flags) = 0;
  if FlagsEmpty then
  begin
    for i := 0 to High(FActiveFlags) do
    begin
      FlagId := FActiveFlags[i];
      idx := -1;
      if (FlagId >= 0) and (FlagId < Length(FSuffixFlagToIdx)) then
        idx := FSuffixFlagToIdx[FlagId];
      if idx < 0 then Continue;
      Group := FSuffixRules[idx].Group;
      for r := 0 to High(Group.Suffixes) do
      begin
        Rule := Group.Suffixes[r];
        if UTF8EndsStr(Rule.Add, word) then
        begin
          CandidateStem := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(Rule.Add));
          if Rule.Strip <> '' then CandidateStem := CandidateStem + Rule.Strip;
          if MatchesCondition(Rule.Condition, CandidateStem, False) then
          begin
            if HashFind(CandidateStem, StemIndex) then
            begin
              if IsForbiddenWord(FWords[StemIndex].Flags) then Continue;
              if HasFlag(FWords[StemIndex].Flags, FlagId) then Exit(True);
            end;
          end;
        end;
      end;
    end;
  end
  else
  begin
    for i := 0 to High(Flags) do
    begin
      FlagId := Flags[i];
      idx := -1;
      if (FlagId >= 0) and (FlagId < Length(FSuffixFlagToIdx)) then
        idx := FSuffixFlagToIdx[FlagId];
      if idx < 0 then Continue;
      Group := FSuffixRules[idx].Group;
      for r := 0 to High(Group.Suffixes) do
      begin
        Rule := Group.Suffixes[r];
        if UTF8EndsStr(Rule.Add, word) then
        begin
          CandidateStem := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(Rule.Add));
          if Rule.Strip <> '' then CandidateStem := CandidateStem + Rule.Strip;
          if MatchesCondition(Rule.Condition, CandidateStem, False) then
          begin
            if HashFind(CandidateStem, StemIndex) then
            begin
              StemFlags := FWords[StemIndex].Flags;
              if IsForbiddenWord(StemFlags) then Continue;
              if HasFlag(StemFlags, FlagId) then Exit(True);
            end;
          end;
        end;
      end;
    end;
  end;
end;

function THunSpellChecker.TryApplyPrefixes(const word: string; const Flags: TIntegerArray): boolean;
var
  i, r, idx: integer;
  FlagId: integer;
  Group: TAffixGroup;
  Rule: TPrefixRule;
  CandidateStem: string;
  StemIndex: integer;
  FlagsEmpty: boolean;
  StemFlags: TIntegerArray;
begin
  Result := False;
  FlagsEmpty := Length(Flags) = 0;
  if FlagsEmpty then
  begin
    for i := 0 to High(FActiveFlags) do
    begin
      FlagId := FActiveFlags[i];
      idx := -1;
      if (FlagId >= 0) and (FlagId < Length(FPrefixFlagToIdx)) then
        idx := FPrefixFlagToIdx[FlagId];
      if idx < 0 then Continue;
      Group := FPrefixRules[idx].Group;
      for r := 0 to High(Group.Prefixes) do
      begin
        Rule := Group.Prefixes[r];
        if UTF8StartsStr(Rule.Add, word) then
        begin
          CandidateStem := UTF8Copy(word, UTF8Length(Rule.Add) + 1, MaxInt);
          if Rule.Strip <> '' then CandidateStem := Rule.Strip + CandidateStem;
          if MatchesCondition(Rule.Condition, CandidateStem, True) then
          begin
            if HashFind(CandidateStem, StemIndex) then
            begin
              if IsForbiddenWord(FWords[StemIndex].Flags) then Continue;
              if HasFlag(FWords[StemIndex].Flags, FlagId) then Exit(True);
            end;
          end;
        end;
      end;
    end;
  end
  else
  begin
    for i := 0 to High(Flags) do
    begin
      FlagId := Flags[i];
      idx := -1;
      if (FlagId >= 0) and (FlagId < Length(FPrefixFlagToIdx)) then
        idx := FPrefixFlagToIdx[FlagId];
      if idx < 0 then Continue;
      Group := FPrefixRules[idx].Group;
      for r := 0 to High(Group.Prefixes) do
      begin
        Rule := Group.Prefixes[r];
        if UTF8StartsStr(Rule.Add, word) then
        begin
          CandidateStem := UTF8Copy(word, UTF8Length(Rule.Add) + 1, MaxInt);
          if Rule.Strip <> '' then CandidateStem := Rule.Strip + CandidateStem;
          if MatchesCondition(Rule.Condition, CandidateStem, True) then
          begin
            if HashFind(CandidateStem, StemIndex) then
            begin
              StemFlags := FWords[StemIndex].Flags;
              if IsForbiddenWord(StemFlags) then Continue;
              if HasFlag(StemFlags, FlagId) then Exit(True);
            end;
          end;
        end;
      end;
    end;
  end;
end;

function THunSpellChecker.TryApplyCrossProduct(const word: string; const Flags: TIntegerArray): boolean;
var
  suffixFlagIndex, prefixFlagIndex, suffixRuleIndex, prefixRuleIndex: integer;
  suffixFlagId, prefixFlagId: integer;
  suffixGroup, prefixGroup: TAffixGroup;
  suffixRule: TSuffixRule;
  prefixRule: TPrefixRule;
  candidateAfterSuffix, candidateAfterPrefix, finalStem: string;
  stemIndex: integer;
  stemFlags: TIntegerArray;
  suffixIsCircumfix, prefixIsCircumfix, stemHasCircumfix: boolean;
  sidx, pidx: integer;
begin
  Result := False;

  // Suffix then prefix
  for suffixFlagIndex := 0 to High(FCrossSuffixFlags) do
  begin
    suffixFlagId := FCrossSuffixFlags[suffixFlagIndex];
    if (Length(Flags) > 0) and not HasFlag(Flags, suffixFlagId) then Continue;
    sidx := -1;
    if (suffixFlagId >= 0) and (suffixFlagId < Length(FSuffixFlagToIdx)) then
      sidx := FSuffixFlagToIdx[suffixFlagId];
    if sidx < 0 then Continue;
    suffixGroup := FSuffixRules[sidx].Group;
    suffixIsCircumfix := (suffixFlagId = FCircumfixFlag);
    for suffixRuleIndex := 0 to High(suffixGroup.Suffixes) do
    begin
      suffixRule := suffixGroup.Suffixes[suffixRuleIndex];
      if UTF8EndsStr(suffixRule.Add, word) then
      begin
        candidateAfterSuffix := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(suffixRule.Add));
        if suffixRule.Strip <> '' then candidateAfterSuffix := candidateAfterSuffix + suffixRule.Strip;
        if MatchesCondition(suffixRule.Condition, candidateAfterSuffix, False) then
        begin
          for prefixFlagIndex := 0 to High(FCrossPrefixFlags) do
          begin
            prefixFlagId := FCrossPrefixFlags[prefixFlagIndex];
            if (Length(Flags) > 0) and not HasFlag(Flags, prefixFlagId) then Continue;
            pidx := -1;
            if (prefixFlagId >= 0) and (prefixFlagId < Length(FPrefixFlagToIdx)) then
              pidx := FPrefixFlagToIdx[prefixFlagId];
            if pidx < 0 then Continue;
            prefixGroup := FPrefixRules[pidx].Group;
            prefixIsCircumfix := (prefixFlagId = FCircumfixFlag);
            for prefixRuleIndex := 0 to High(prefixGroup.Prefixes) do
            begin
              prefixRule := prefixGroup.Prefixes[prefixRuleIndex];
              if UTF8StartsStr(prefixRule.Add, candidateAfterSuffix) then
              begin
                finalStem := UTF8Copy(candidateAfterSuffix, UTF8Length(prefixRule.Add) + 1, MaxInt);
                if prefixRule.Strip <> '' then finalStem := prefixRule.Strip + finalStem;
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
                    if HasFlag(stemFlags, suffixFlagId) and HasFlag(stemFlags, prefixFlagId) then
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

  // Prefix then suffix
  for prefixFlagIndex := 0 to High(FCrossPrefixFlags) do
  begin
    prefixFlagId := FCrossPrefixFlags[prefixFlagIndex];
    if (Length(Flags) > 0) and not HasFlag(Flags, prefixFlagId) then Continue;
    pidx := -1;
    if (prefixFlagId >= 0) and (prefixFlagId < Length(FPrefixFlagToIdx)) then
      pidx := FPrefixFlagToIdx[prefixFlagId];
    if pidx < 0 then Continue;
    prefixGroup := FPrefixRules[pidx].Group;
    prefixIsCircumfix := (prefixFlagId = FCircumfixFlag);
    for prefixRuleIndex := 0 to High(prefixGroup.Prefixes) do
    begin
      prefixRule := prefixGroup.Prefixes[prefixRuleIndex];
      if UTF8StartsStr(prefixRule.Add, word) then
      begin
        candidateAfterPrefix := UTF8Copy(word, UTF8Length(prefixRule.Add) + 1, MaxInt);
        if prefixRule.Strip <> '' then candidateAfterPrefix := prefixRule.Strip + candidateAfterPrefix;
        if MatchesCondition(prefixRule.Condition, candidateAfterPrefix, True) then
        begin
          for suffixFlagIndex := 0 to High(FCrossSuffixFlags) do
          begin
            suffixFlagId := FCrossSuffixFlags[suffixFlagIndex];
            if (Length(Flags) > 0) and not HasFlag(Flags, suffixFlagId) then Continue;
            sidx := -1;
            if (suffixFlagId >= 0) and (suffixFlagId < Length(FSuffixFlagToIdx)) then
              sidx := FSuffixFlagToIdx[suffixFlagId];
            if sidx < 0 then Continue;
            suffixGroup := FSuffixRules[sidx].Group;
            suffixIsCircumfix := (suffixFlagId = FCircumfixFlag);
            for suffixRuleIndex := 0 to High(suffixGroup.Suffixes) do
            begin
              suffixRule := suffixGroup.Suffixes[suffixRuleIndex];
              if UTF8EndsStr(suffixRule.Add, candidateAfterPrefix) then
              begin
                finalStem := UTF8Copy(candidateAfterPrefix, 1, UTF8Length(candidateAfterPrefix) - UTF8Length(suffixRule.Add));
                if suffixRule.Strip <> '' then finalStem := finalStem + suffixRule.Strip;
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
                    if HasFlag(stemFlags, suffixFlagId) and HasFlag(stemFlags, prefixFlagId) then
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

function THunSpellChecker.TryApplyAffixes(const word: string; const Flags: TIntegerArray): boolean;
begin
  Result := TryApplySuffixes(word, Flags) or TryApplyPrefixes(word, Flags);
end;

function THunSpellChecker.GetWordFlags(const word: string): TIntegerArray;
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

// ---------------------------------------------------------------------------------
// Compound handling
// ---------------------------------------------------------------------------------

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
    if CharInSet(word[i], ['0'..'9']) then NumPart := NumPart + word[i]
    else
      Break;
  end;
  if NumPart = '' then Exit;
  Suffix := Copy(word, Length(NumPart) + 1, MaxInt);
  if Rule <> 'n*mp' then Exit;
  if Length(NumPart) < 1 then Exit;
  LastDigit := StrToInt(NumPart[Length(NumPart)]);
  if not (LastDigit in [1..9]) then Exit;
  if Length(NumPart) >= 2 then LastTwoDigits := StrToInt(Copy(NumPart, Length(NumPart) - 1, 2))
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
    if MatchesCompoundRule(word, FCompoundRules[i]) then Exit(True);
end;

function THunSpellChecker.IsNoSuggestWord(const Flags: TIntegerArray): boolean;
begin
  Result := (FNoSuggestFlag >= 0) and HasFlag(Flags, FNoSuggestFlag);
end;

function THunSpellChecker.IsForbiddenWord(const Flags: TIntegerArray): boolean;
begin
  Result := (FForbiddenWordFlag >= 0) and HasFlag(Flags, FForbiddenWordFlag);
end;

function THunSpellChecker.TryCompoundWord(const word: string): boolean;
var
  i, idx: integer;
  leftPart, rightPart: string;
  leftFlags, rightFlags: TIntegerArray;
  lenWord: integer;
  Rule: string;
  j: integer;
  LeftFlag, RightFlag: string;
  LeftFlagId, RightFlagId: integer;
begin
  Result := False;
  if word = '' then Exit;
  lenWord := UTF8Length(word);

  if Length(FCompoundRules) > 0 then
  begin
    for j := 0 to High(FCompoundRules) do
    begin
      Rule := FCompoundRules[j];
      i := Pos('*', Rule);
      if i = 0 then Continue;
      LeftFlag := Copy(Rule, 1, i - 1);
      RightFlag := Copy(Rule, i + 1, MaxInt);
      i := Pos('*', RightFlag);
      if i > 0 then RightFlag := Copy(RightFlag, 1, i - 1);
      LeftFlagId := InternFlag(LeftFlag);
      RightFlagId := InternFlag(RightFlag);

      for i := 1 to lenWord - 1 do
      begin
        leftPart := UTF8Copy(word, 1, i);
        rightPart := UTF8Copy(word, i + 1, MaxInt);
        if not HashFind(leftPart, idx) then
        begin
          if not TryApplyAffixes(leftPart, nil) then Continue;
          if not HashFind(leftPart, idx) then Continue;
        end;
        leftFlags := FWords[idx].Flags;
        if IsForbiddenWord(leftFlags) then Continue;
        if not HasFlag(leftFlags, LeftFlagId) then Continue;

        if not HashFind(rightPart, idx) then
        begin
          if not TryApplyAffixes(rightPart, nil) then Continue;
          if not HashFind(rightPart, idx) then Continue;
        end;
        rightFlags := FWords[idx].Flags;
        if IsForbiddenWord(rightFlags) then Continue;
        if not HasFlag(rightFlags, RightFlagId) then Continue;

        Result := True;
        Exit;
      end;
    end;
    Exit;
  end
  else
  begin
    for i := 1 to lenWord - 1 do
    begin
      leftPart := UTF8Copy(word, 1, i);
      rightPart := UTF8Copy(word, i + 1, MaxInt);
      if not HashFind(leftPart, idx) then
      begin
        if not TryApplyAffixes(leftPart, nil) then Continue;
        if not HashFind(leftPart, idx) then Continue;
      end;
      leftFlags := FWords[idx].Flags;
      if IsForbiddenWord(leftFlags) then Continue;

      if not HashFind(rightPart, idx) then
      begin
        if not TryApplyAffixes(rightPart, nil) then Continue;
        if not HashFind(rightPart, idx) then Continue;
      end;
      rightFlags := FWords[idx].Flags;
      if IsForbiddenWord(rightFlags) then Continue;

      if FCompoundFlag >= 0 then
      begin
        if not HasFlag(leftFlags, FCompoundFlag) and not HasFlag(leftFlags, FCompoundBegin) and not
          HasFlag(leftFlags, FCompoundMiddle) then Continue;
        if not HasFlag(rightFlags, FCompoundFlag) and not HasFlag(rightFlags, FCompoundEnd) and not
          HasFlag(rightFlags, FCompoundMiddle) then Continue;
        if (i = 1) and (FCompoundBegin >= 0) and (not HasFlag(leftFlags, FCompoundBegin)) then Continue;
        if (i = lenWord - 1) and (FCompoundEnd >= 0) and (not HasFlag(rightFlags, FCompoundEnd)) then Continue;
      end;
      Result := True;
      Exit;
    end;
  end;
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
    searchStr := pattern;
    if (Length(searchStr) > 0) and (searchStr[1] = '^') then Delete(searchStr, 1, 1);
    if (Length(searchStr) > 0) and (searchStr[Length(searchStr)] = '$') then Delete(searchStr, Length(searchStr), 1);
    if searchStr = '' then Continue;

    if (Length(pattern) > 0) and (pattern[1] = '^') then
    begin
      if UTF8StartsStr(searchStr, word) then
      begin
        rightPart := UTF8Copy(word, UTF8Length(searchStr) + 1, MaxInt);
        if rightPart <> '' then
          if CheckWordInternal(rightPart, False) then Exit(True);
      end;
    end
    else if (Length(pattern) > 0) and (pattern[Length(pattern)] = '$') then
    begin
      if UTF8EndsStr(searchStr, word) then
      begin
        leftPart := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(searchStr));
        if leftPart <> '' then
          if CheckWordInternal(leftPart, False) then Exit(True);
      end;
    end
    else
    begin
      pos := UTF8Pos(searchStr, word);
      while pos > 0 do
      begin
        leftPart := UTF8Copy(word, 1, pos - 1);
        rightPart := UTF8Copy(word, pos + UTF8Length(searchStr), MaxInt);
        if (leftPart <> '') and (rightPart <> '') then
        begin
          if CheckWordInternal(leftPart, False) and CheckWordInternal(rightPart, False) then Exit(True);
        end;
        pos := UTF8Pos(searchStr, word, pos + 1);
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------------
// Word checking
// ---------------------------------------------------------------------------------

function THunSpellChecker.CheckWordInternal(const word: string; AllowBreak: boolean): boolean;
var
  idx: integer;
  CleanWord: string;
  LowerWord: string;
  Flags: TIntegerArray;
  EmptyFlags: TIntegerArray = nil;
begin
  SetLength(EmptyFlags, 0);
  CleanWord := ApplyIconv(word);
  if HashFind(CleanWord, idx) then
  begin
    Flags := FWords[idx].Flags;
    if IsForbiddenWord(Flags) then Exit(False);
    if (FOnlyInCompoundFlag >= 0) and HasFlag(Flags, FOnlyInCompoundFlag) then Exit(False);
    if ((FNeedAffixFlag >= 0) and HasFlag(Flags, FNeedAffixFlag)) or ((FPseudoRootFlag >= 0) and HasFlag(Flags, FPseudoRootFlag)) then
    begin
      if TryApplyAffixes(CleanWord, Flags) then Exit(True);
      if TryApplyCrossProduct(CleanWord, Flags) then Exit(True);
      Exit(False);
    end;
    Exit(True);
  end;
  if IsCompoundNumber(CleanWord) then Exit(True);

  LowerWord := UTF8LowerCase(CleanWord);
  if LowerWord <> CleanWord then
  begin
    if HashFind(LowerWord, idx) then
    begin
      Flags := FWords[idx].Flags;
      if not IsForbiddenWord(Flags) and not ((FOnlyInCompoundFlag >= 0) and HasFlag(Flags, FOnlyInCompoundFlag)) and
        not ((FNeedAffixFlag >= 0) and HasFlag(Flags, FNeedAffixFlag)) and not ((FPseudoRootFlag >= 0) and
        HasFlag(Flags, FPseudoRootFlag)) then
        Exit(True);
      if ((FNeedAffixFlag >= 0) and HasFlag(Flags, FNeedAffixFlag)) or ((FPseudoRootFlag >= 0) and
        HasFlag(Flags, FPseudoRootFlag)) then
      begin
        if TryApplyAffixes(LowerWord, Flags) then Exit(True);
        if TryApplyCrossProduct(LowerWord, Flags) then Exit(True);
      end;
    end;
    if TryApplyAffixes(LowerWord, EmptyFlags) then Exit(True);
    if TryApplyCrossProduct(LowerWord, EmptyFlags) then Exit(True);
  end;

  if TryApplyAffixes(CleanWord, EmptyFlags) then Exit(True);
  if TryApplyCrossProduct(CleanWord, EmptyFlags) then Exit(True);

  if AllowBreak and (FBreakPatterns.Count > 0) then
    if TryBreakWord(CleanWord) then Exit(True);

  if FCompoundFlag >= 0 then
    if TryCompoundWord(CleanWord) then Exit(True);

  Result := False;
end;

function THunSpellChecker.CheckWord(const word: string): boolean;
begin
  Result := CheckWordInternal(word, True);
end;

// ---------------------------------------------------------------------------------
// Text checking
// ---------------------------------------------------------------------------------

function THunSpellChecker.IsWordChar(Ch: pchar; CharLen: integer): boolean;
var
  CodePoint: cardinal = 0;
  i: integer = 0;
begin
  if CharLen = 1 then CodePoint := Ord(Ch^)
  else if CharLen = 2 then CodePoint := ((Ord(Ch^) and $1F) shl 6) or (Ord((Ch + 1)^) and $3F)
  else if CharLen = 3 then CodePoint := ((Ord(Ch^) and $0F) shl 12) or ((Ord((Ch + 1)^) and $3F) shl 6) or (Ord((Ch + 2)^) and $3F)
  else if CharLen = 4 then CodePoint := ((Ord(Ch^) and $07) shl 18) or ((Ord((Ch + 1)^) and $3F) shl 12) or
      ((Ord((Ch + 2)^) and $3F) shl 6) or (Ord((Ch + 3)^) and $3F);

  if CodePoint = Ord('_') then Exit(True);

  {$NOTES OFF}
  if CodePoint <= $FFFF then
    if TCharacter.IsLetterOrDigit(widechar(CodePoint)) then Exit(True);
  {$NOTES ON}

  for i := 0 to High(FWordCharsCodes) do
    if FWordCharsCodes[i] = CodePoint then Exit(True);

  Result := False;
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

// ---------------------------------------------------------------------------------
// All words array for suggestions
// ---------------------------------------------------------------------------------

procedure THunSpellChecker.BuildAllWordsArray;
var
  i, Len, MaxLen: integer;
  BucketCounts: TIntegerArray = nil;
begin
  SetLength(FAllWords, FWordCount);
  SetLength(FAllWordsLower, FWordCount);
  SetLength(FAllWordsFirstChar, FWordCount);
  MaxLen := 0;

  for i := 0 to FWordCount - 1 do
  begin
    FAllWords[i] := FWords[i].word;
    FAllWordsLower[i] := UTF8LowerCase(FAllWords[i]);
    FAllWordsFirstChar[i] := FirstCodepoint(FAllWordsLower[i]);
    Len := UTF8Length(FAllWords[i]);
    if Len > MaxLen then MaxLen := Len;
  end;

  SetLength(FLengthBuckets, MaxLen + 1);
  SetLength(BucketCounts, MaxLen + 1);
  for i := 0 to FWordCount - 1 do
  begin
    Len := UTF8Length(FAllWords[i]);
    Inc(BucketCounts[Len]);
  end;
  for i := 0 to MaxLen do
    SetLength(FLengthBuckets[i], BucketCounts[i]);
  FillChar(BucketCounts[0], (MaxLen + 1) * SizeOf(integer), 0);
  for i := 0 to FWordCount - 1 do
  begin
    Len := UTF8Length(FAllWords[i]);
    FLengthBuckets[Len][BucketCounts[Len]] := i;
    Inc(BucketCounts[Len]);
  end;
end;

// ---------------------------------------------------------------------------------
// Suggestions
// ---------------------------------------------------------------------------------

procedure THunSpellChecker.AddWeightedSuggestion(var Suggestions: TWeightedSuggestionArray; const Candidate: string; Dist: integer);
var
  i: integer;
begin
  if Candidate = '' then Exit;
  for i := 0 to High(Suggestions) do
    if Suggestions[i].S = Candidate then Exit;
  SetLength(Suggestions, Length(Suggestions) + 1);
  Suggestions[High(Suggestions)].S := Candidate;
  Suggestions[High(Suggestions)].Dist := Dist;
end;

procedure THunSpellChecker.GenerateAndAddAffixForms(var Suggestions: TWeightedSuggestionArray;
  const BaseWord: string; const Flags: TIntegerArray; const TargetWordLower: string);
var
  i, r, idx: integer;
  FlagId: integer;
  Group: TAffixGroup;
  RuleS: TSuffixRule;
  RuleP: TPrefixRule;
  Stripped: string;
  Form: string;
  Dist: integer;
begin
  // Suffix forms. Iterate over the word's own flags only.
  for i := 0 to High(Flags) do
  begin
    FlagId := Flags[i];
    idx := -1;
    if (FlagId >= 0) and (FlagId < Length(FSuffixFlagToIdx)) then
      idx := FSuffixFlagToIdx[FlagId];
    if idx < 0 then Continue;
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
  for i := 0 to High(Flags) do
  begin
    FlagId := Flags[i];
    idx := -1;
    if (FlagId >= 0) and (FlagId < Length(FPrefixFlagToIdx)) then
      idx := FPrefixFlagToIdx[FlagId];
    if idx < 0 then Continue;
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
      if Wide1[i] = Wide2[j] then D[i, j] := D[i - 1, j - 1]
      else
        D[i, j] := Min(Min(D[i - 1, j] + 1, D[i, j - 1] + 1), D[i - 1, j - 1] + 1);
    end;
  Result := D[Len1, Len2];
end;

function THunSpellChecker.LevenshteinDistanceLimited(const S1, S2: string; MaxDist: integer): integer;
var
  Wide1, Wide2: widestring;
  Len1, Len2, i, j, Prev, Cur, Tmp, Cost, RowMin: integer;
  PrevRow, CurRow: TIntegerArray;
begin
  Wide1 := UTF8Decode(S1);
  Wide2 := UTF8Decode(S2);
  Len1 := Length(Wide1);
  Len2 := Length(Wide2);
  PrevRow := nil;
  CurRow := nil;

  if Abs(Len1 - Len2) > MaxDist then Exit(MaxDist + 1);

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
  for j := 0 to Len2 do PrevRow[j] := j;

  for i := 1 to Len1 do
  begin
    CurRow[0] := i;
    RowMin := CurRow[0];
    for j := 1 to Len2 do
    begin
      if Wide1[i] = Wide2[j] then Cost := 0
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
    if RowMin > MaxDist then Exit(MaxDist + 1);
    for j := 0 to Len2 do
    begin
      Tmp := PrevRow[j];
      PrevRow[j] := CurRow[j];
      CurRow[j] := Tmp;
    end;
  end;

  Result := PrevRow[Len2];
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
  for RepIdx := 0 to High(FREPFrom) do
  begin
    RepFrom := FREPFrom[RepIdx];
    RepTo := FREPTo[RepIdx];
    REPResults := ApplyREP(CleanWord, RepFrom, RepTo);
    for i := 0 to High(REPResults) do
    begin
      NewWord := REPResults[i];
      if NewWord <> CleanWord then
        if HashFind(NewWord, FoundIndex) then
          if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
            AddWeightedSuggestion(Weighted, NewWord, LevenshteinDistance(CleanWord, NewWord));
    end;
  end;

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
          if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
            AddWeightedSuggestion(Weighted, NewWord, LevenshteinDistance(CleanWord, NewWord));
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
  if FTryChars <> '' then
  begin
    for i := 1 to UTF8Length(CleanWord) do
    begin
      ch := UTF8Copy(CleanWord, i, 1);
      pos := UTF8Pos(ch, FTryChars);
      if pos > 0 then
      begin
        for j := pos - 1 to pos + 1 do
        begin
          if (j >= 1) and (j <= UTF8Length(FTryChars)) and (j <> pos) then
          begin
            repl := UTF8Copy(FTryChars, j, 1);
            cand := UTF8Copy(CleanWord, 1, i - 1) + repl + UTF8Copy(CleanWord, i + 1, MaxInt);
            if HashFind(cand, FoundIndex) then
              if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
                AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
          end;
        end;
      end;
    end;
  end;

  for i := 1 to UTF8Length(CleanWord) do
  begin
    ch := UTF8Copy(CleanWord, i, 1);
    for k := 0 to FKeyGroups.Count - 1 do
    begin
      Group := FKeyGroups[k];
      pos := UTF8Pos(ch, Group);
      if pos > 0 then
      begin
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

  for i := 1 to UTF8Length(CleanWord) do
  begin
    cand := UTF8Copy(CleanWord, 1, i - 1) + UTF8Copy(CleanWord, i + 1, MaxInt);
    if HashFind(cand, FoundIndex) then
      if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
        AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
  end;

  for i := 1 to UTF8Length(CleanWord) - 1 do
  begin
    cand := UTF8Copy(CleanWord, 1, i - 1) + UTF8Copy(CleanWord, i + 1, 1) + UTF8Copy(CleanWord, i, 1) + UTF8Copy(CleanWord, i + 2, MaxInt);
    if HashFind(cand, FoundIndex) then
      if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
        AddWeightedSuggestion(Weighted, cand, LevenshteinDistance(CleanWord, cand));
  end;
end;

procedure THunSpellChecker.ProcessDictionaryScan(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
var
  TargetLower, TargetPrefix: string;
  TargetFirstCode: cardinal;
  TargetLen, MinLen, MaxLen, MinLenExt, MaxLenExt: integer;
  Len, BucketIdx, WordIndex, Dist: integer;
  FoundFlags: TIntegerArray;
  CandidateLower: string;
begin
  TargetLower := UTF8LowerCase(CleanWord);
  TargetLen := UTF8Length(TargetLower);
  if TargetLen = 0 then Exit;
  TargetFirstCode := FirstCodepoint(TargetLower);

  MinLen := Max(0, TargetLen - 2);
  MaxLen := TargetLen + 2;
  if MaxLen > High(FLengthBuckets) then MaxLen := High(FLengthBuckets);

  for Len := MinLen to MaxLen do
  begin
    for BucketIdx := 0 to High(FLengthBuckets[Len]) do
    begin
      WordIndex := FLengthBuckets[Len][BucketIdx];
      if (TargetFirstCode <> 0) and (FAllWordsFirstChar[WordIndex] <> TargetFirstCode) then Continue;
      Dist := LevenshteinDistanceLimited(TargetLower, FAllWordsLower[WordIndex], 2);
      if Dist > 2 then Continue;
      FoundFlags := FWords[WordIndex].Flags;
      if IsNoSuggestWord(FoundFlags) or IsForbiddenWord(FoundFlags) then Continue;
      AddWeightedSuggestion(Weighted, FAllWords[WordIndex], Dist);
    end;
  end;

  MinLenExt := Max(1, TargetLen - 4);
  MaxLenExt := TargetLen + 4;
  if MaxLenExt > High(FLengthBuckets) then MaxLenExt := High(FLengthBuckets);

  for Len := MinLenExt to MaxLenExt do
  begin
    for BucketIdx := 0 to High(FLengthBuckets[Len]) do
    begin
      WordIndex := FLengthBuckets[Len][BucketIdx];
      FoundFlags := FWords[WordIndex].Flags;
      if IsNoSuggestWord(FoundFlags) or IsForbiddenWord(FoundFlags) then Continue;
      CandidateLower := FAllWordsLower[WordIndex];
      if TargetLen >= 4 then
      begin
        TargetPrefix := UTF8Copy(TargetLower, 1, 2);
        if UTF8Copy(CandidateLower, 1, 2) <> TargetPrefix then Continue;
      end
      else
      begin
        if FirstCodepoint(CandidateLower) <> TargetFirstCode then Continue;
      end;
      Dist := LevenshteinDistanceLimited(TargetLower, CandidateLower, 4);
      if Dist > 4 then Continue;
      GenerateAndAddAffixForms(Weighted, FAllWords[WordIndex], FoundFlags, TargetLower);
    end;
  end;
end;

function THunSpellChecker.CompareWeighted(const A, B: TWeightedSuggestion): integer;
begin
  if A.Dist <> B.Dist then Result := A.Dist - B.Dist
  else
  begin
    Result := UTF8Length(A.S) - UTF8Length(B.S);
    if Result = 0 then Result := CompareStr(UTF8LowerCase(A.S), UTF8LowerCase(B.S));
  end;
end;

procedure THunSpellChecker.SortWeightedSuggestions(var Arr: TWeightedSuggestionArray);
var
  i, j: integer;
  Temp: TWeightedSuggestion;
begin
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
  SourceLower := UTF8LowerCase(Source);
  SourceUpper := UTF8UpperCase(Source);
  SrcFirstUp := (Source <> '') and (UTF8Copy(Source, 1, 1) = UTF8UpperCase(UTF8Copy(Source, 1, 1)));

  if Source = SourceLower then Result := UTF8LowerCase(S)
  else if Source = SourceUpper then Result := UTF8UpperCase(S)
  else if SrcFirstUp then Result := UTF8UpperCase(UTF8Copy(S, 1, 1)) + UTF8LowerCase(UTF8Copy(S, 2, MaxInt))
  else
    Result := S;
end;

function THunSpellChecker.Suggest(const word: string): TStringArray;
var
  CleanWord: string;
  Weighted: TWeightedSuggestionArray = nil;
  i: integer;
  CachedValue: string;
  Parts: TStringList;
  CacheIdx: integer;
  UniqueResults: TStringList;
  Adjusted: string;
begin
  Result := nil;
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
      for i := 0 to Parts.Count - 1 do Result[i] := Parts[i];
    finally
      Parts.Free;
    end;
    Exit;
  end;

  SetLength(Weighted, 0);
  ProcessREPandMAP(CleanWord, Weighted);
  GenerateTryKeyCandidates(CleanWord, Weighted);
  ProcessDictionaryScan(CleanWord, Weighted);
  SortWeightedSuggestions(Weighted);

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
