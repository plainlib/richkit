//-----------------------------------------------------------------------------------
//  RichKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit HunSpellChecker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Math, StrUtils, Character, LConvEncoding, LazUTF8;

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
    WideCondition: widestring;  // Cached UTF-16 decode of Condition for the slow path
    Continuation: TIntegerArray;
  end;

  TPrefixRule = record
    Strip: string;
    Add: string;
    Condition: string;
    WideCondition: widestring;  // Cached UTF-16 decode of Condition for the slow path
    Continuation: TIntegerArray;
  end;

  TAffixGroup = record
    Suffixes: array of TSuffixRule;
    Prefixes: array of TPrefixRule;
    SuffixCount: integer;  // Number of valid entries in Suffixes
    PrefixCount: integer;  // Number of valid entries in Prefixes
    CrossProduct: boolean;
  end;

  TAffixEntry = record
    Flag: integer;
    Group: TAffixGroup;
  end;

  TAffixList = array of TAffixEntry;

  // Flattened affix rule used for fast lookup by last/first byte of Add
  TFlatSuffixRule = record
    Add: string;
    Strip: string;
    Condition: string;
    WideCondition: widestring;
    Continuation: TIntegerArray;
    FlagId: integer;
    IsEmpty: boolean;  // True when Add='' and Strip=''
  end;
  TFlatSuffixRuleArray = array of TFlatSuffixRule;

  TZeroAffixEntry = record
    FlagId: integer;
    Continuation: TIntegerArray;
  end;
  TZeroAffixEntryArray = array of TZeroAffixEntry;

  TFlatPrefixRule = record
    Add: string;
    Strip: string;
    Condition: string;
    WideCondition: widestring;
    Continuation: TIntegerArray;
    FlagId: integer;
    IsEmpty: boolean;
  end;
  TFlatPrefixRuleArray = array of TFlatPrefixRule;

  TWordEntry = record
    word: string;
    Flags: TIntegerArray;
  end;

  TCompoundPattern = record
    EndChars: string;
    EndFlags: TIntegerArray;
    BeginChars: string;
    BeginFlags: TIntegerArray;
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
    FSuffixRulesUsed: integer;     // Number of valid entries in FSuffixRules
    FPrefixRulesUsed: integer;     // Number of valid entries in FPrefixRules
    FSuffixFlagToIdx: TIntegerArray;  // Flag ID -> index in FSuffixRules or -1
    FPrefixFlagToIdx: TIntegerArray;  // Flag ID -> index in FPrefixRules or -1
    FActiveFlags: TIntegerArray;      // All flag IDs with at least one rule
    // Flattened rule tables with byte-level indexes for fast TryDerive lookups
    FSuffixFlat: TFlatSuffixRuleArray;
    FPrefixFlat: TFlatPrefixRuleArray;
    FSuffixByLastByte: array[0..255] of TIntegerArray;
    FPrefixByFirstByte: array[0..255] of TIntegerArray;
    // Word data for suggestions
    FAllWords: array of string;
    FAllWordsLower: array of string;
    FAllWordsLowerWide: array of widestring;  // Pre-decoded UTF-16 lowercase words
    FAllWordsFirstChar: TCardinalArray;  // First UTF-8 codepoint of each word
    FLengthBuckets: array of TIntegerArray;
    // Iconv and oconv substitutions
    FIconvFrom: array of string;
    FIconvTo: array of string;
    // First bytes of every ICONV source pattern. Used to skip conversion when no rule can match
    FIconvFirstBytes: array[0..255] of boolean;
    FOCONVFrom: array of string;
    FOCONVTo: array of string;
    FWordCharsCodes: TCardinalArray;
    // Special flags stored as IDs. -1 means the flag is not defined for this dictionary
    FNoSuggestFlag: integer;
    FNeedAffixFlag: integer;
    FPseudoRootFlag: integer;
    FCircumfixFlag: integer;
    FForbiddenWordFlag: integer;
    FOnlyInCompoundFlag: integer;
    FKeepCaseFlag: integer;
    FForceUCaseFlag: integer;
    FCompoundFlag: integer;
    FCompoundBegin: integer;
    FCompoundMiddle: integer;
    FCompoundEnd: integer;
    FCompoundPermitFlag: integer;
    FCompoundForbidFlag: integer;
    FCompoundRecurse: integer;      // Guard against infinite recursion in nested compound validation
    FIncludeSuggestions: boolean;   // When False, CheckText skips Suggest for speed
    FCancelFlag: PInteger;          // Optional pointer to an external cancellation flag
    FCompoundMin: integer;
    FCompoundWordMax: integer;
    FCompoundRules: array of string;
    FCheckCompoundDup: boolean;
    FCheckCompoundCase: boolean;
    FCheckCompoundPatterns: array of TCompoundPattern;
    FREPFrom: array of string;
    FREPTo: array of string;
    FMAPGroups: array of string;
    FSuggestCache: TStringList;
    FFlagMode: string; // ASCII, UTF-8, long, num
    FEncoding: string; // Source encoding from the SET directive
    FAFCount: integer;
    FAAliases: array of TIntegerArray;
    FBreakPatterns: TStringList;
    FTryChars: string;
    FKeyGroups: TStringList;
    FIgnoreChars: TStringArray;
    FHasAffixContinuations: boolean;  // True when at least one affix rule carries continuation flags
    FZeroAffixEntries: TZeroAffixEntryArray;
    procedure LoadAFFFromStream(Stream: TStream);
    procedure LoadDICFromStream(Stream: TStream);
    function LoadAFF(const FileName: string): boolean;
    function LoadDIC(const FileName: string): boolean;
    function InternFlag(const S: string): integer;
    function ParseFlagString(const FlagStr: string): TIntegerArray;
    procedure RehashFlags;
    procedure AddAffixGroup(var List: TAffixList; const Flag: integer; const Group: TAffixGroup);
    procedure AddSuffixRule(const Flag: integer; const Strip, Add, Condition: string; const Continuation: TIntegerArray;
      CrossProduct: boolean);
    procedure AddPrefixRule(const Flag: integer; const Strip, Add, Condition: string; const Continuation: TIntegerArray;
      CrossProduct: boolean);
    procedure BuildAffixIndexes;
    procedure ShrinkAffixGroups;
    function MatchesCondition(const Condition: string; const WideCond: widestring; const word: string; IsPrefix: boolean): boolean;
    function TryDerive(const W: string; Depth: integer; AllowOnlyInCompound: boolean; RequiredFlag: integer;
      out OutFlags: TIntegerArray): boolean;
    function GetWordFlags(const word: string): TIntegerArray;
    procedure HashAdd(const word: string; const Flags: TIntegerArray);
    function HashFind(const word: string; out Index: integer): boolean;
    function FNV1aHash(const S: string): cardinal;
    procedure Rehash;
    function IsWordChar(Ch: pchar; CharLen: integer): boolean;
    procedure BuildAllWordsArray;
    function ApplyIconv(const S: string): string;
    function ApplyOconv(const S: string): string;
    function MatchesCompoundRule(const word, Rule: string): boolean;
    function IsCompoundNumber(const word: string): boolean;
    function IsNumericWord(const S: string): boolean;
    function IsNoSuggestWord(const Flags: TIntegerArray): boolean;
    function IsForbiddenWord(const Flags: TIntegerArray): boolean;
    function MatchesCompoundPattern(const LeftPart, RightPart: string; const LeftFlags, RightFlags: TIntegerArray): boolean;
    function TryGetPartFlags(const Part: string; out OutFlags: TIntegerArray): boolean;
    function PartCanCompoundLeft(const Flags: TIntegerArray): boolean;
    function PartCanCompoundMiddle(const Flags: TIntegerArray): boolean;
    function PartCanCompoundRight(const Flags: TIntegerArray): boolean;
    function TryCompoundWordRec(const word: string; depth: integer): boolean;
    function HasFlag(const Flags: TIntegerArray; const FlagId: integer): boolean;
    procedure AddWeightedSuggestion(var Suggestions: TWeightedSuggestionArray; const Candidate: string; Dist: integer);
    procedure GenerateAndAddAffixForms(var Suggestions: TWeightedSuggestionArray; const BaseWord: string;
      const Flags: TIntegerArray; const TargetWordLower: string);
    function StripComment(const S: string): string;
    function CharInClass(const Ch: widechar; const ClassStr: widestring): boolean;
    function ApplyREP(const word, From, Replacement: string): TStringArray;
    function CheckWordCore(const word: string; AllowBreak: boolean): boolean;
    function CheckWordInternal(const word: string; AllowBreak: boolean): boolean;
    function TryBreakWord(const word: string): boolean;
    function TryCompoundWord(const word: string): boolean;
    procedure GenerateTryKeyCandidates(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
    procedure ProcessREPandMAP(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
    function LevenshteinDistanceLimited(const S1, S2: string; MaxDist: integer): integer;
    function LevenshteinWideLimited(const W1, W2: widestring; MaxDist: integer): integer;
    procedure ProcessDictionaryScan(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
    function CompareWeighted(const A, B: TWeightedSuggestion): integer;
    procedure SortWeightedSuggestions(var Arr: TWeightedSuggestionArray);
    function AdjustCase(const Source, S: string): string;
  public
    // Creates a new checker instance with empty word and affix tables
    constructor Create;
    // Frees all internal tables, caches and affix rules
    destructor Destroy; override;
    // Loads affix and dictionary data from the given streams
    function LoadFromStream(AFFStream, DICStream: TStream): boolean;
    // Loads affix and dictionary data from the given files
    function LoadFromFiles(const AFFFileName, DICFileName: string): boolean;
    // Returns True when the given single word is spelled correctly
    function CheckWord(const word: string): boolean;
    // Scans the whole text and returns an array of spelling errors
    function CheckText(const Text: string): TSpellErrorArray;
    // Returns up to ten replacement candidates for the given misspelled word
    function Suggest(const word: string): TStringArray;
    // When False, CheckText skips suggestion generation for speed
    property IncludeSuggestions: boolean read FIncludeSuggestions write FIncludeSuggestions;
    // Optional pointer to an external integer flag. When it is not nil and its
    // value is non-zero, long running checks and suggestion scans abort as soon
    // as possible. The caller is responsible for the lifetime of the pointed value.
    property CancelFlag: PInteger read FCancelFlag write FCancelFlag;
  end;

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
        'pt': preferred := 'pt_PT';
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

function LevenshteinDistance(const S1, S2: string): integer; forward;

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

// Byte-level suffix and prefix checks. Both operands must be valid UTF-8 strings,
// so a byte-level match at the end or beginning corresponds to a codepoint boundary
function ByteEndsWith(const Suffix, S: string): boolean; inline;
var
  SLen, SuLen: integer;
begin
  SuLen := Length(Suffix);
  if SuLen = 0 then Exit(True);
  SLen := Length(S);
  if SuLen > SLen then Exit(False);
  Result := CompareMem(@S[SLen - SuLen + 1], @Suffix[1], SuLen);
end;

function ByteStartsWith(const Prefix, S: string): boolean; inline;
var
  SLen, PrLen: integer;
begin
  PrLen := Length(Prefix);
  if PrLen = 0 then Exit(True);
  SLen := Length(S);
  if PrLen > SLen then Exit(False);
  Result := CompareMem(@S[1], @Prefix[1], PrLen);
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

function IsUTF8EncodingName(const Name: string): boolean;
var
  n: string;
begin
  n := UpperCase(Trim(Name));
  n := StringReplace(n, '-', '', [rfReplaceAll]);
  n := StringReplace(n, '_', '', [rfReplaceAll]);
  Result := (n = '') or (n = 'UTF8');
end;

function HunEncodingToUTF8(const S, EncodingName: string): string;
var
  n: string;
begin
  Result := S;
  n := UpperCase(Trim(EncodingName));
  // Remove separators so the comparison is tolerant to iso-8859-7, ISO_8859-7, iso88597
  n := StringReplace(n, '-', '', [rfReplaceAll]);
  n := StringReplace(n, '_', '', [rfReplaceAll]);
  n := StringReplace(n, ' ', '', [rfReplaceAll]);
  if (n = '') or (n = 'UTF8') then Exit(S);

  if n = 'ISO88591' then Exit(ISO_8859_1ToUTF8(S));
  if n = 'ISO88592' then Exit(ISO_8859_2ToUTF8(S));
  if n = 'ISO88593' then Exit(ISO_8859_3ToUTF8(S));
  if n = 'ISO88594' then Exit(ISO_8859_4ToUTF8(S));
  if n = 'ISO88595' then Exit(ISO_8859_5ToUTF8(S));
  if n = 'ISO88597' then Exit(ISO_8859_7ToUTF8(S));
  if n = 'ISO88599' then Exit(ISO_8859_9ToUTF8(S));
  if n = 'ISO885910' then Exit(ISO_8859_10ToUTF8(S));
  if n = 'ISO885913' then Exit(ISO_8859_13ToUTF8(S));
  if n = 'ISO885914' then Exit(ISO_8859_14ToUTF8(S));
  if n = 'ISO885915' then Exit(ISO_8859_15ToUTF8(S));
  if n = 'ISO885916' then Exit(ISO_8859_16ToUTF8(S));
  if n = 'KOI8R' then Exit(KOI8RToUTF8(S));
  if n = 'CP1250' then Exit(CP1250ToUTF8(S));
  if n = 'CP1251' then Exit(CP1251ToUTF8(S));
  if n = 'CP1252' then Exit(CP1252ToUTF8(S));
  if n = 'CP1253' then Exit(CP1253ToUTF8(S));
  if n = 'CP1254' then Exit(CP1254ToUTF8(S));
  if n = 'CP1255' then Exit(CP1255ToUTF8(S));
  if n = 'CP1256' then Exit(CP1256ToUTF8(S));
  if n = 'CP1257' then Exit(CP1257ToUTF8(S));
  if n = 'CP1258' then Exit(CP1258ToUTF8(S));
  // ISO-8859-6, ISO-8859-8, ISO-8859-11 and KOI8-U have no dedicated helper in LConvEncoding
  // and are not required for the currently supported dictionaries. The string is returned as is.
end;

function RemoveIgnoreChars(const S: string; const IgnoreChars: TStringArray): string;
var
  i: integer;
begin
  Result := S;
  for i := 0 to High(IgnoreChars) do
    if IgnoreChars[i] <> '' then
      Result := StringReplace(Result, IgnoreChars[i], '', [rfReplaceAll]);
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
    if ByteStartsWith(Copy(From, 2, MaxInt), word) then
    begin
      candidate := Replacement + UTF8Copy(word, UTF8Length(Copy(From, 2, MaxInt)) + 1, MaxInt);
      candidate := StringReplace(candidate, '_', ' ', [rfReplaceAll]);
      SetLength(Result, 1);
      Result[0] := candidate;
    end;
  end
  else if From[Length(From)] = '$' then
  begin
    if ByteEndsWith(Copy(From, 1, Length(From) - 1), word) then
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

function THunSpellChecker.ParseFlagString(const FlagStr: string): TIntegerArray;
var
  i, startPos: integer;
  s: string;
  FlagList: TStringList;
  j, FlagId: integer;
begin
  Result := nil;
  if FlagStr = '' then Exit;
  FlagList := TStringList.Create;
  try
    case FFlagMode of
      'ASCII':
        for j := 1 to Length(FlagStr) do
          FlagList.Add(FlagStr[j]);
      'UTF-8':
      begin
        s := FlagStr;
        while s <> '' do
        begin
          FlagList.Add(UTF8Copy(s, 1, 1));
          UTF8Delete(s, 1, 1);
        end;
      end;
      'LONG':
      begin
        i := 1;
        while i + 1 <= Length(FlagStr) do
        begin
          FlagList.Add(Copy(FlagStr, i, 2));
          Inc(i, 2);
        end;
      end;
      'NUM':
      begin
        i := 1;
        while i <= Length(FlagStr) do
        begin
          while (i <= Length(FlagStr)) and (FlagStr[i] in [',', ' ', #9]) do Inc(i);
          if i > Length(FlagStr) then Break;
          startPos := i;
          while (i <= Length(FlagStr)) and not (FlagStr[i] in [',', ' ', #9]) do Inc(i);
          FlagList.Add(Copy(FlagStr, startPos, i - startPos));
        end;
      end;
      else
        for j := 1 to Length(FlagStr) do
          FlagList.Add(FlagStr[j]);
    end;

    for j := 0 to FlagList.Count - 1 do
    begin
      FlagId := InternFlag(FlagList[j]);
      if FlagId >= 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := FlagId;
      end;
    end;
  finally
    FlagList.Free;
  end;
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
var
  b: integer;
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
  FSuffixRulesUsed := 0;
  FPrefixRulesUsed := 0;
  SetLength(FSuffixFlagToIdx, 0);
  SetLength(FPrefixFlagToIdx, 0);
  SetLength(FActiveFlags, 0);
  SetLength(FSuffixFlat, 0);
  SetLength(FPrefixFlat, 0);
  for b := 0 to 255 do
  begin
    SetLength(FSuffixByLastByte[b], 0);
    SetLength(FPrefixByFirstByte[b], 0);
  end;
  FFlagMode := 'ASCII';
  FEncoding := 'UTF-8';

  SetLength(FAllWords, 0);
  SetLength(FAllWordsLower, 0);
  SetLength(FAllWordsLowerWide, 0);
  SetLength(FAllWordsFirstChar, 0);
  SetLength(FLengthBuckets, 0);

  SetLength(FIconvFrom, 0);
  SetLength(FIconvTo, 0);
  FillChar(FIconvFirstBytes, SizeOf(FIconvFirstBytes), 0);
  SetLength(FOCONVFrom, 0);
  SetLength(FOCONVTo, 0);
  SetLength(FWordCharsCodes, 0);
  SetLength(FREPFrom, 0);
  SetLength(FREPTo, 0);
  SetLength(FMAPGroups, 0);
  SetLength(FIgnoreChars, 0);
  SetLength(FCompoundRules, 0);

  FNoSuggestFlag := -1;
  FNeedAffixFlag := -1;
  FPseudoRootFlag := -1;
  FCircumfixFlag := -1;
  FForbiddenWordFlag := -1;
  FOnlyInCompoundFlag := -1;
  FKeepCaseFlag := -1;
  FForceUCaseFlag := -1;
  FCompoundFlag := -1;
  FCompoundBegin := -1;
  FCompoundMiddle := -1;
  FCompoundEnd := -1;
  FCompoundPermitFlag := -1;
  FCompoundForbidFlag := -1;
  FCompoundMin := 0;
  FCompoundRecurse := 0;
  FIncludeSuggestions := True;
  FCancelFlag := nil;
  FCompoundWordMax := 0;
  FAFCount := 0;
  SetLength(FAAliases, 0);

  FCheckCompoundDup := False;
  FCheckCompoundCase := False;
  SetLength(FCheckCompoundPatterns, 0);

  FBreakPatterns := TStringList.Create;
  FSuggestCache := TStringList.Create;
  FSuggestCache.Sorted := True;
  FSuggestCache.Duplicates := dupIgnore;
  FTryChars := '';
  FKeyGroups := TStringList.Create;
  FHasAffixContinuations := False;
  SetLength(FZeroAffixEntries, 0);
end;

destructor THunSpellChecker.Destroy;
var
  b: integer;
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
  SetLength(FSuffixFlat, 0);
  SetLength(FPrefixFlat, 0);
  for b := 0 to 255 do
  begin
    SetLength(FSuffixByLastByte[b], 0);
    SetLength(FPrefixByFirstByte[b], 0);
  end;
  SetLength(FAllWords, 0);
  SetLength(FAllWordsLower, 0);
  SetLength(FAllWordsLowerWide, 0);
  SetLength(FAllWordsFirstChar, 0);
  SetLength(FLengthBuckets, 0);
  SetLength(FIconvFrom, 0);
  SetLength(FIconvTo, 0);
  SetLength(FOCONVFrom, 0);
  SetLength(FOCONVTo, 0);
  SetLength(FWordCharsCodes, 0);
  SetLength(FREPFrom, 0);
  SetLength(FREPTo, 0);
  SetLength(FMAPGroups, 0);
  SetLength(FIgnoreChars, 0);
  SetLength(FCompoundRules, 0);
  SetLength(FCheckCompoundPatterns, 0);
  SetLength(FAAliases, 0);
  SetLength(FZeroAffixEntries, 0);
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
    FSuffixRulesUsed := 0;
    FPrefixRulesUsed := 0;
    SetLength(FSuffixFlagToIdx, 0);
    SetLength(FPrefixFlagToIdx, 0);
    SetLength(FActiveFlags, 0);
    SetLength(FSuffixFlat, 0);
    SetLength(FPrefixFlat, 0);
    SetLength(FAllWords, 0);
    SetLength(FAllWordsLower, 0);
    SetLength(FAllWordsLowerWide, 0);
    SetLength(FAllWordsFirstChar, 0);
    SetLength(FLengthBuckets, 0);
    SetLength(FIconvFrom, 0);
    SetLength(FIconvTo, 0);
    FillChar(FIconvFirstBytes, SizeOf(FIconvFirstBytes), 0);
    SetLength(FOCONVFrom, 0);
    SetLength(FOCONVTo, 0);
    SetLength(FWordCharsCodes, 0);
    SetLength(FIgnoreChars, 0);
    SetLength(FCompoundRules, 0);
    SetLength(FREPFrom, 0);
    SetLength(FREPTo, 0);
    SetLength(FAAliases, 0);
    SetLength(FZeroAffixEntries, 0);
    FBreakPatterns.Clear;
    FKeyGroups.Clear;
    FSuggestCache.Clear;
    FFlagMode := 'ASCII';
    FEncoding := 'UTF-8';
    FNoSuggestFlag := -1;
    FNeedAffixFlag := -1;
    FPseudoRootFlag := -1;
    FCircumfixFlag := -1;
    FForbiddenWordFlag := -1;
    FOnlyInCompoundFlag := -1;
    FKeepCaseFlag := -1;
    FForceUCaseFlag := -1;
    FCompoundFlag := -1;
    FCompoundBegin := -1;
    FCompoundMiddle := -1;
    FCompoundEnd := -1;
    FCompoundPermitFlag := -1;
    FCompoundForbidFlag := -1;
    FCompoundMin := 0;
    FCompoundWordMax := 0;
    FCheckCompoundDup := False;
    FCheckCompoundCase := False;
    SetLength(FCheckCompoundPatterns, 0);
    FHasAffixContinuations := False;
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
    FSuffixRulesUsed := 0;
    FPrefixRulesUsed := 0;
    SetLength(FSuffixFlagToIdx, 0);
    SetLength(FPrefixFlagToIdx, 0);
    SetLength(FActiveFlags, 0);
    SetLength(FSuffixFlat, 0);
    SetLength(FPrefixFlat, 0);
    SetLength(FAllWords, 0);
    SetLength(FAllWordsLower, 0);
    SetLength(FAllWordsLowerWide, 0);
    SetLength(FAllWordsFirstChar, 0);
    SetLength(FLengthBuckets, 0);
    SetLength(FIconvFrom, 0);
    SetLength(FIconvTo, 0);
    FillChar(FIconvFirstBytes, SizeOf(FIconvFirstBytes), 0);
    SetLength(FOCONVFrom, 0);
    SetLength(FOCONVTo, 0);
    SetLength(FWordCharsCodes, 0);
    SetLength(FIgnoreChars, 0);
    SetLength(FCompoundRules, 0);
    SetLength(FREPFrom, 0);
    SetLength(FREPTo, 0);
    SetLength(FAAliases, 0);
    SetLength(FZeroAffixEntries, 0);
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
    FKeepCaseFlag := -1;
    FForceUCaseFlag := -1;
    FCompoundFlag := -1;
    FCompoundBegin := -1;
    FCompoundMiddle := -1;
    FCompoundEnd := -1;
    FCompoundPermitFlag := -1;
    FCompoundForbidFlag := -1;
    FCompoundMin := 0;
    FCompoundWordMax := 0;
    FCheckCompoundDup := False;
    FCheckCompoundCase := False;
    SetLength(FCheckCompoundPatterns, 0);
    FHasAffixContinuations := False;
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
  AliasFlagStr: string = '';
  SlashAdd: integer = 0;
  IgnoreStr: string = '';
  IgnoreChar: string = '';
  Continuation: TIntegerArray = nil;
begin
  Lines := TStringList.Create;
  Parts := TStringList.Create;
  try
    Lines.LoadFromStream(Stream);

    // Detect encoding from the SET directive and convert lines to UTF-8 if needed
    FEncoding := 'UTF-8';
    for i := 0 to Min(200, Lines.Count - 1) do
    begin
      Line := Trim(Lines[i]);
      if (Length(Line) >= 4) and (Copy(Line, 1, 3) = 'SET') and (Line[4] in [' ', #9]) then
      begin
        FEncoding := Trim(Copy(Line, 4, MaxInt));
        Break;
      end;
    end;
    if not IsUTF8EncodingName(FEncoding) then
      for i := 0 to Lines.Count - 1 do
        Lines[i] := HunEncodingToUTF8(Lines[i], FEncoding);

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
            AliasFlagStr := '';
            for j := 0 to Parts.Count - 1 do
              AliasFlagStr := AliasFlagStr + Parts[j];
            FAAliases[i] := ParseFlagString(AliasFlagStr);
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
      else if Parts[0] = 'COMPOUNDWORDMAX' then
      begin
        if Parts.Count >= 2 then FCompoundWordMax := StrToIntDef(Parts[1], 0);
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
      else if Parts[0] = 'CHECKCOMPOUNDDUP' then
      begin
        FCheckCompoundDup := True;
      end
      else if Parts[0] = 'CHECKCOMPOUNDCASE' then
      begin
        FCheckCompoundCase := True;
      end
      else if Parts[0] = 'CHECKCOMPOUNDPATTERN' then
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
            if (Parts.Count >= 3) and (Parts[0] = 'CHECKCOMPOUNDPATTERN') then
            begin
              SetLength(FCheckCompoundPatterns, Length(FCheckCompoundPatterns) + 1);
              with FCheckCompoundPatterns[High(FCheckCompoundPatterns)] do
              begin
                if (Length(Parts[1]) > 0) and (Parts[1][1] = '/') then
                begin
                  EndChars := '';
                  EndFlags := ParseFlagString(Copy(Parts[1], 2, MaxInt));
                end
                else
                begin
                  EndChars := Parts[1];
                  SetLength(EndFlags, 0);
                end;
                if (Length(Parts[2]) > 0) and (Parts[2][1] = '/') then
                begin
                  BeginChars := '';
                  BeginFlags := ParseFlagString(Copy(Parts[2], 2, MaxInt));
                end
                else
                begin
                  BeginChars := Parts[2];
                  SetLength(BeginFlags, 0);
                end;
              end;
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
          // In long mode a single flag is 2 bytes. Truncate longer strings accordingly
          if (FFlagMode = 'LONG') and (Length(FlagStr) > 2) then
            FlagStr := Copy(FlagStr, 1, 2);
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
              // Split the add string from its continuation flags after the slash
              SetLength(Continuation, 0);
              SlashAdd := Pos('/', Add);
              if SlashAdd > 0 then
              begin
                Continuation := ParseFlagString(Copy(Add, SlashAdd + 1, MaxInt));
                Add := Copy(Add, 1, SlashAdd - 1);
              end;
              if Add = '0' then Add := '';
              AddSuffixRule(FlagId, Strip, Add, Condition, Continuation, CrossProduct);
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
          // In long mode a single flag is 2 bytes. Truncate longer strings accordingly
          if (FFlagMode = 'LONG') and (Length(FlagStr) > 2) then
            FlagStr := Copy(FlagStr, 1, 2);
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
              // Split the add string from its continuation flags after the slash
              SetLength(Continuation, 0);
              SlashAdd := Pos('/', Add);
              if SlashAdd > 0 then
              begin
                Continuation := ParseFlagString(Copy(Add, SlashAdd + 1, MaxInt));
                Add := Copy(Add, 1, SlashAdd - 1);
              end;
              if Add = '0' then Add := '';
              AddPrefixRule(FlagId, Strip, Add, Condition, Continuation, CrossProduct);
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
      else if Parts[0] = 'OCONV' then
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
            if (Parts.Count > 0) and (Parts[0] = 'OCONV') then Parts.Delete(0);
            if Parts.Count >= 2 then
            begin
              SetLength(FOCONVFrom, Length(FOCONVFrom) + 1);
              SetLength(FOCONVTo, Length(FOCONVTo) + 1);
              FOCONVFrom[High(FOCONVFrom)] := Parts[0];
              FOCONVTo[High(FOCONVTo)] := Parts[1];
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
      else if Parts[0] = 'KEEPCASE' then
      begin
        if Parts.Count >= 2 then FKeepCaseFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'FORCEUCASE' then
      begin
        if Parts.Count >= 2 then FForceUCaseFlag := InternFlag(Parts[1]);
      end
      else if Parts[0] = 'IGNORE' then
      begin
        IgnoreStr := '';
        for j := 1 to Parts.Count - 1 do
          IgnoreStr := IgnoreStr + Parts[j];
        SetLength(FIgnoreChars, 0);
        while IgnoreStr <> '' do
        begin
          IgnoreChar := UTF8Copy(IgnoreStr, 1, 1);
          SetLength(FIgnoreChars, Length(FIgnoreChars) + 1);
          FIgnoreChars[High(FIgnoreChars)] := IgnoreChar;
          UTF8Delete(IgnoreStr, 1, 1);
        end;
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

    // Precompute the set of first bytes of all ICONV source patterns
    FillChar(FIconvFirstBytes, SizeOf(FIconvFirstBytes), 0);
    for i := 0 to High(FIconvFrom) do
      if FIconvFrom[i] <> '' then
        FIconvFirstBytes[Ord(FIconvFrom[i][1])] := True;

    // Trim reserved capacity before the tables are used for lookups
    ShrinkAffixGroups;
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
  ExpectedWords: integer = 0;
  AliasNum: integer = 0;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromStream(Stream);

    // Convert lines from the source encoding (detected in the AFF file) to UTF-8
    if not IsUTF8EncodingName(FEncoding) then
      for i := 0 to Lines.Count - 1 do
        Lines[i] := HunEncodingToUTF8(Lines[i], FEncoding);

    // The first line of the DIC contains the number of words.
    // We use it to preallocate FWords in one shot, eliminating the doubling copies.
    // Some dictionaries store the count followed by additional fields separated by a tab
    if Lines.Count > 0 then
    begin
      Line := Lines[0];
      if (Length(Line) > 0) and (Ord(Line[1]) = $EF) then
        Delete(Line, 1, 3);
      i := Pos(#9, Line);
      if i = 0 then i := Pos(' ', Line);
      if i > 0 then Line := Copy(Line, 1, i - 1);
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
      if (Length(Line) > 0) and (Line[1] = '#') then Continue;

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
      word := RemoveIgnoreChars(word, FIgnoreChars);

      SetLength(FlagsArr, 0);
      if FlagsStr <> '' then
      begin
        // When AF aliases are defined the flag field is a single number that indexes FAAliases,
        // otherwise it is a raw flag string whose token size depends on FFlagMode
        AliasNum := -1;
        if (FAFCount > 0) and TryStrToInt(FlagsStr, AliasNum) and (AliasNum >= 1) and (AliasNum <= FAFCount) then
        begin
          SetLength(FlagsArr, Length(FAAliases[AliasNum - 1]));
          for i := 0 to High(FAAliases[AliasNum - 1]) do
            FlagsArr[i] := FAAliases[AliasNum - 1][i];
        end
        else
          FlagsArr := ParseFlagString(FlagsStr);
      end;

      HashAdd(word, FlagsArr);
    end;
  finally
    Lines.Free;
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

// Appends a suffix rule to the group with the given flag.
// The array of groups and the array of rules inside a group grow geometrically
// so that adding thousands of rules stays linear in time.
procedure THunSpellChecker.AddSuffixRule(const Flag: integer; const Strip, Add, Condition: string;
  const Continuation: TIntegerArray; CrossProduct: boolean);
var
  Rule: TSuffixRule;
  idx: integer = -1;
  i: integer = 0;
  Cap: integer = 0;
begin
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
    // Grow the group table geometrically to keep appends fast
    if FSuffixRulesUsed = Length(FSuffixRules) then
    begin
      if Length(FSuffixRules) = 0 then Cap := 16
      else
        Cap := Length(FSuffixRules) * 2;
      SetLength(FSuffixRules, Cap);
    end;
    idx := FSuffixRulesUsed;
    FSuffixRules[idx].Flag := Flag;
    FSuffixRules[idx].Group := Default(TAffixGroup);
    FSuffixRules[idx].Group.CrossProduct := CrossProduct;
    FSuffixFlagToIdx[Flag] := idx;
    Inc(FSuffixRulesUsed);
  end;

  Rule.Strip := Strip;
  Rule.Add := Add;
  Rule.Condition := Condition;
  // Decode the condition once if the slow path is likely needed
  if (Pos('[', Condition) > 0) or (Pos('.', Condition) > 0) then
    Rule.WideCondition := UTF8Decode(Condition)
  else
    Rule.WideCondition := '';
  if Length(Continuation) > 0 then FHasAffixContinuations := True;
  Rule.Continuation := Continuation;

  // Grow the suffix array geometrically to avoid quadratic reallocation
  if FSuffixRules[idx].Group.SuffixCount = Length(FSuffixRules[idx].Group.Suffixes) then
  begin
    if FSuffixRules[idx].Group.SuffixCount = 0 then Cap := 8
    else
      Cap := FSuffixRules[idx].Group.SuffixCount * 2;
    SetLength(FSuffixRules[idx].Group.Suffixes, Cap);
  end;
  FSuffixRules[idx].Group.Suffixes[FSuffixRules[idx].Group.SuffixCount] := Rule;
  Inc(FSuffixRules[idx].Group.SuffixCount);
end;

// Appends a prefix rule to the group with the given flag, with the same
// geometric growth strategy as suffixes.
procedure THunSpellChecker.AddPrefixRule(const Flag: integer; const Strip, Add, Condition: string;
  const Continuation: TIntegerArray; CrossProduct: boolean);
var
  Rule: TPrefixRule;
  idx: integer = -1;
  i: integer = 0;
  Cap: integer = 0;
begin
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
    // Grow the group table geometrically to keep appends fast
    if FPrefixRulesUsed = Length(FPrefixRules) then
    begin
      if Length(FPrefixRules) = 0 then Cap := 16
      else
        Cap := Length(FPrefixRules) * 2;
      SetLength(FPrefixRules, Cap);
    end;
    idx := FPrefixRulesUsed;
    FPrefixRules[idx].Flag := Flag;
    FPrefixRules[idx].Group := Default(TAffixGroup);
    FPrefixRules[idx].Group.CrossProduct := CrossProduct;
    FPrefixFlagToIdx[Flag] := idx;
    Inc(FPrefixRulesUsed);
  end;

  Rule.Strip := Strip;
  Rule.Add := Add;
  Rule.Condition := Condition;
  if (Pos('[', Condition) > 0) or (Pos('.', Condition) > 0) then
    Rule.WideCondition := UTF8Decode(Condition)
  else
    Rule.WideCondition := '';
  if Length(Continuation) > 0 then FHasAffixContinuations := True;
  Rule.Continuation := Continuation;

  // Grow the prefix array geometrically to avoid quadratic reallocation
  if FPrefixRules[idx].Group.PrefixCount = Length(FPrefixRules[idx].Group.Prefixes) then
  begin
    if FPrefixRules[idx].Group.PrefixCount = 0 then Cap := 8
    else
      Cap := FPrefixRules[idx].Group.PrefixCount * 2;
    SetLength(FPrefixRules[idx].Group.Prefixes, Cap);
  end;
  FPrefixRules[idx].Group.Prefixes[FPrefixRules[idx].Group.PrefixCount] := Rule;
  Inc(FPrefixRules[idx].Group.PrefixCount);
end;

// Trims affix arrays to their exact used sizes and drops reserved capacity.
// Must be called before BuildAffixIndexes so the flat tables are compact.
procedure THunSpellChecker.ShrinkAffixGroups;
var
  i: integer = 0;
begin
  for i := 0 to FSuffixRulesUsed - 1 do
    if Length(FSuffixRules[i].Group.Suffixes) > FSuffixRules[i].Group.SuffixCount then
      SetLength(FSuffixRules[i].Group.Suffixes, FSuffixRules[i].Group.SuffixCount);
  for i := 0 to FPrefixRulesUsed - 1 do
    if Length(FPrefixRules[i].Group.Prefixes) > FPrefixRules[i].Group.PrefixCount then
      SetLength(FPrefixRules[i].Group.Prefixes, FPrefixRules[i].Group.PrefixCount);
  SetLength(FSuffixRules, FSuffixRulesUsed);
  SetLength(FPrefixRules, FPrefixRulesUsed);
end;

procedure THunSpellChecker.BuildAffixIndexes;
var
  i: integer = 0;
  Cnt: integer = 0;
  b: integer = 0;
  r: integer = 0;
  Counts: array[0..255] of integer;
  Positions: array[0..255] of integer;
  LastByte: byte = 0;
  FirstByte: byte = 0;
  SrcSuffix: TSuffixRule;
  SrcPrefix: TPrefixRule;
  FlatS: TFlatSuffixRule;
  FlatP: TFlatPrefixRule;
begin
  // Shrink first so the flat tables are built on exact sizes
  ShrinkAffixGroups;

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
  for i := 0 to FSuffixRulesUsed - 1 do
  begin
    SetLength(FActiveFlags, Length(FActiveFlags) + 1);
    FActiveFlags[High(FActiveFlags)] := FSuffixRules[i].Flag;
  end;
  for i := 0 to FPrefixRulesUsed - 1 do
  begin
    SetLength(FActiveFlags, Length(FActiveFlags) + 1);
    FActiveFlags[High(FActiveFlags)] := FPrefixRules[i].Flag;
  end;

  // Build the flat suffix rules in creation order so that iteration order is preserved
  SetLength(FSuffixFlat, 0);
  for i := 0 to FSuffixRulesUsed - 1 do
    for r := 0 to FSuffixRules[i].Group.SuffixCount - 1 do
    begin
      SrcSuffix := FSuffixRules[i].Group.Suffixes[r];
      SetLength(FSuffixFlat, Length(FSuffixFlat) + 1);
      FlatS.Add := SrcSuffix.Add;
      FlatS.Strip := SrcSuffix.Strip;
      FlatS.Condition := SrcSuffix.Condition;
      FlatS.WideCondition := SrcSuffix.WideCondition;
      FlatS.Continuation := SrcSuffix.Continuation;
      FlatS.FlagId := FSuffixRules[i].Flag;
      FlatS.IsEmpty := (SrcSuffix.Add = '') and (SrcSuffix.Strip = '');
      FSuffixFlat[High(FSuffixFlat)] := FlatS;
    end;

  // Build the flat prefix rules in creation order
  SetLength(FPrefixFlat, 0);
  for i := 0 to FPrefixRulesUsed - 1 do
    for r := 0 to FPrefixRules[i].Group.PrefixCount - 1 do
    begin
      SrcPrefix := FPrefixRules[i].Group.Prefixes[r];
      SetLength(FPrefixFlat, Length(FPrefixFlat) + 1);
      FlatP.Add := SrcPrefix.Add;
      FlatP.Strip := SrcPrefix.Strip;
      FlatP.Condition := SrcPrefix.Condition;
      FlatP.WideCondition := SrcPrefix.WideCondition;
      FlatP.Continuation := SrcPrefix.Continuation;
      FlatP.FlagId := FPrefixRules[i].Flag;
      FlatP.IsEmpty := (SrcPrefix.Add = '') and (SrcPrefix.Strip = '');
      FPrefixFlat[High(FPrefixFlat)] := FlatP;
    end;

  // Collect zero-affix rules that carry continuation flags. They let a
  // prefix rule match a stem whose flag only appears through a zero-affix
  // suffix (e.g. French SFX S. 0 0/L'D'Q' [^sxz]).
  SetLength(FZeroAffixEntries, 0);
  for i := 0 to High(FSuffixFlat) do
    if FSuffixFlat[i].IsEmpty and (Length(FSuffixFlat[i].Continuation) > 0) then
    begin
      SetLength(FZeroAffixEntries, Length(FZeroAffixEntries) + 1);
      with FZeroAffixEntries[High(FZeroAffixEntries)] do
      begin
        FlagId := FSuffixFlat[i].FlagId;
        Continuation := FSuffixFlat[i].Continuation;
      end;
    end;
  for i := 0 to High(FPrefixFlat) do
    if FPrefixFlat[i].IsEmpty and (Length(FPrefixFlat[i].Continuation) > 0) then
    begin
      SetLength(FZeroAffixEntries, Length(FZeroAffixEntries) + 1);
      with FZeroAffixEntries[High(FZeroAffixEntries)] do
      begin
        FlagId := FPrefixFlat[i].FlagId;
        Continuation := FPrefixFlat[i].Continuation;
      end;
    end;

  // Build the suffix byte index: every bucket gets rules whose Add is empty
  // (they match any word) plus rules whose Add ends with the bucket byte
  for b := 0 to 255 do
  begin
    Counts[b] := 0;
    Positions[b] := 0;
    SetLength(FSuffixByLastByte[b], 0);
    SetLength(FPrefixByFirstByte[b], 0);
  end;
  for i := 0 to High(FSuffixFlat) do
  begin
    if FSuffixFlat[i].Add = '' then
      for b := 0 to 255 do
        Inc(Counts[b])
    else
      Inc(Counts[Ord(FSuffixFlat[i].Add[Length(FSuffixFlat[i].Add)])]);
  end;
  for b := 0 to 255 do
    SetLength(FSuffixByLastByte[b], Counts[b]);
  for i := 0 to High(FSuffixFlat) do
  begin
    if FSuffixFlat[i].Add = '' then
    begin
      for b := 0 to 255 do
      begin
        FSuffixByLastByte[b][Positions[b]] := i;
        Inc(Positions[b]);
      end;
    end
    else
    begin
      LastByte := Ord(FSuffixFlat[i].Add[Length(FSuffixFlat[i].Add)]);
      FSuffixByLastByte[LastByte][Positions[LastByte]] := i;
      Inc(Positions[LastByte]);
    end;
  end;

  // Build the prefix byte index: empty Add rules go into every bucket
  for b := 0 to 255 do
  begin
    Counts[b] := 0;
    Positions[b] := 0;
  end;
  for i := 0 to High(FPrefixFlat) do
  begin
    if FPrefixFlat[i].Add = '' then
      for b := 0 to 255 do
        Inc(Counts[b])
    else
      Inc(Counts[Ord(FPrefixFlat[i].Add[1])]);
  end;
  for b := 0 to 255 do
    SetLength(FPrefixByFirstByte[b], Counts[b]);
  for i := 0 to High(FPrefixFlat) do
  begin
    if FPrefixFlat[i].Add = '' then
    begin
      for b := 0 to 255 do
      begin
        FPrefixByFirstByte[b][Positions[b]] := i;
        Inc(Positions[b]);
      end;
    end
    else
    begin
      FirstByte := Ord(FPrefixFlat[i].Add[1]);
      FPrefixByFirstByte[FirstByte][Positions[FirstByte]] := i;
      Inc(Positions[FirstByte]);
    end;
  end;
end;

// ---------------------------------------------------------------------------------
// Conditions
// ---------------------------------------------------------------------------------

// Uses the pre-decoded WideCond when the slow path is needed.
// WideCond may be empty when the condition has no bracket or dot, in which case
// the fast byte-level comparison is used.
function THunSpellChecker.MatchesCondition(const Condition: string; const WideCond: widestring; const word: string;
  IsPrefix: boolean): boolean;
var
  WideWord: widestring;
  LocalWideCond: widestring;
  wPos, cPos: integer;
  wChar, cChar: widechar;
  openPos, closePos: integer;
  isNeg: boolean;
  classStr: widestring;
  startContent: integer;
begin
  if Condition = '' then Exit(True);

  // Fast path for plain (dot-less, bracket-less) conditions on the byte level
  if (Pos('[', Condition) = 0) and (Pos('.', Condition) = 0) then
  begin
    if IsPrefix then
      Result := ByteStartsWith(Condition, word)
    else
      Result := ByteEndsWith(Condition, word);
    Exit;
  end;

  LocalWideCond := WideCond;
  if LocalWideCond = '' then
    LocalWideCond := UTF8Decode(Condition);

  WideWord := UTF8Decode(word);

  if LocalWideCond = '.' then Exit(Length(WideWord) > 0);

  if IsPrefix then
  begin
    wPos := 1;
    cPos := 1;
    while (wPos <= Length(WideWord)) and (cPos <= Length(LocalWideCond)) do
    begin
      cChar := LocalWideCond[cPos];
      wChar := WideWord[wPos];

      if cChar = '[' then
      begin
        openPos := cPos;
        closePos := openPos;
        while (closePos <= Length(LocalWideCond)) and (LocalWideCond[closePos] <> ']') do Inc(closePos);
        if closePos > Length(LocalWideCond) then Exit(False);
        isNeg := False;
        startContent := openPos + 1;
        if (startContent <= closePos) and (LocalWideCond[startContent] = '^') then
        begin
          isNeg := True;
          startContent := openPos + 2;
        end;
        classStr := Copy(LocalWideCond, startContent, closePos - startContent);
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
    Result := (cPos > Length(LocalWideCond));
  end
  else
  begin
    wPos := Length(WideWord);
    cPos := Length(LocalWideCond);
    while (wPos >= 1) and (cPos >= 1) do
    begin
      cChar := LocalWideCond[cPos];
      wChar := WideWord[wPos];

      if cChar = ']' then
      begin
        closePos := cPos;
        openPos := closePos;
        while (openPos >= 1) and (LocalWideCond[openPos] <> '[') do Dec(openPos);
        if openPos < 1 then Exit(False);
        isNeg := False;
        startContent := openPos + 1;
        if (startContent <= closePos) and (LocalWideCond[startContent] = '^') then
        begin
          isNeg := True;
          startContent := openPos + 2;
        end;
        classStr := Copy(LocalWideCond, startContent, closePos - startContent);
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
// Affix derivation via recursion, with continuation flag chaining
// ---------------------------------------------------------------------------------

// Returns True if W is a valid derived form. OutFlags receives the flags of W.
// Uses the flat rule tables and byte-level indexes for fast lookup.
function THunSpellChecker.TryDerive(const W: string; Depth: integer; AllowOnlyInCompound: boolean;
  RequiredFlag: integer; out OutFlags: TIntegerArray): boolean;
var
  j, r, k, FlatIdx: integer;
  WIdx: integer = 0;
  WFound: boolean = False;
  WFlags: TIntegerArray;
  ContFlags: TIntegerArray;
  Prev: string;
  PrevFlags: TIntegerArray;
  NeedAffix: boolean;
  OnlyInCompound: boolean;
  LastByte: byte = 0;
  FirstByte: byte = 0;
  FSR: TFlatSuffixRule;
  FPR: TFlatPrefixRule;
begin
  Result := False;
  ContFlags := [];
  OutFlags := [];
  SetLength(OutFlags, 0);
  if W = '' then Exit;
  if Depth > 2 then Exit;

  WFound := HashFind(W, WIdx);
  if WFound then WFlags := FWords[WIdx].Flags
  else
    SetLength(WFlags, 0);

  if WFound and not IsForbiddenWord(WFlags) then
  begin
    NeedAffix := (FNeedAffixFlag >= 0) and HasFlag(WFlags, FNeedAffixFlag);
    if (FPseudoRootFlag >= 0) and HasFlag(WFlags, FPseudoRootFlag) then
      NeedAffix := True;
    OnlyInCompound := (FOnlyInCompoundFlag >= 0) and HasFlag(WFlags, FOnlyInCompoundFlag);
    if not NeedAffix and (AllowOnlyInCompound or not OnlyInCompound) then
    begin
      // Build candidate flags: WFlags plus all zero-affix continuations
      SetLength(ContFlags, Length(WFlags));
      for j := 0 to High(WFlags) do ContFlags[j] := WFlags[j];
      for r := 0 to High(FZeroAffixEntries) do
        if HasFlag(WFlags, FZeroAffixEntries[r].FlagId) then
        begin
          k := Length(ContFlags);
          SetLength(ContFlags, k + Length(FZeroAffixEntries[r].Continuation));
          for j := 0 to High(FZeroAffixEntries[r].Continuation) do
            ContFlags[k + j] := FZeroAffixEntries[r].Continuation[j];
        end;
      // Return the direct hit only if it satisfies the caller's required flag.
      // Otherwise fall through and try affix rule derivations.
      if (RequiredFlag < 0) or HasFlag(ContFlags, RequiredFlag) then
      begin
        OutFlags := ContFlags;
        Exit(True);
      end;
      if Depth >= 2 then Exit(False);
    end
    else if Depth > 0 then
      Exit(False);
  end;

  if Depth >= 2 then Exit(False);

  // ---- Suffix rules ----
  LastByte := Ord(W[Length(W)]);
  for r := 0 to High(FSuffixByLastByte[LastByte]) do
  begin
    FlatIdx := FSuffixByLastByte[LastByte][r];
    FSR := FSuffixFlat[FlatIdx];

    if FSR.IsEmpty then
    begin
      if WFound and HasFlag(WFlags, FSR.FlagId) and not IsForbiddenWord(WFlags) then
        if (RequiredFlag < 0) or HasFlag(FSR.Continuation, RequiredFlag) then
        begin
          SetLength(OutFlags, Length(FSR.Continuation));
          for k := 0 to High(FSR.Continuation) do
            OutFlags[k] := FSR.Continuation[k];
          Exit(True);
        end;
      Continue;
    end;

    if not ByteEndsWith(FSR.Add, W) then Continue;
    Prev := Copy(W, 1, Length(W) - Length(FSR.Add));
    if FSR.Strip <> '' then Prev := Prev + FSR.Strip;
    if not MatchesCondition(FSR.Condition, FSR.WideCondition, Prev, False) then Continue;
    // The stem must carry the rule's own flag
    if TryDerive(Prev, Depth + 1, AllowOnlyInCompound, FSR.FlagId, PrevFlags) then
      if (RequiredFlag < 0) or HasFlag(FSR.Continuation, RequiredFlag) then
      begin
        SetLength(OutFlags, Length(FSR.Continuation));
        for k := 0 to High(FSR.Continuation) do
          OutFlags[k] := FSR.Continuation[k];
        Exit(True);
      end;
  end;

  // ---- Prefix rules ----
  FirstByte := Ord(W[1]);
  for r := 0 to High(FPrefixByFirstByte[FirstByte]) do
  begin
    FlatIdx := FPrefixByFirstByte[FirstByte][r];
    FPR := FPrefixFlat[FlatIdx];

    if FPR.IsEmpty then
    begin
      if WFound and HasFlag(WFlags, FPR.FlagId) and not IsForbiddenWord(WFlags) then
        if (RequiredFlag < 0) or HasFlag(FPR.Continuation, RequiredFlag) then
        begin
          SetLength(OutFlags, Length(FPR.Continuation));
          for k := 0 to High(FPR.Continuation) do
            OutFlags[k] := FPR.Continuation[k];
          Exit(True);
        end;
      Continue;
    end;

    if not ByteStartsWith(FPR.Add, W) then Continue;
    Prev := Copy(W, Length(FPR.Add) + 1, MaxInt);
    if FPR.Strip <> '' then Prev := FPR.Strip + Prev;
    if not MatchesCondition(FPR.Condition, FPR.WideCondition, Prev, True) then Continue;
    if TryDerive(Prev, Depth + 1, AllowOnlyInCompound, FPR.FlagId, PrevFlags) then
      if (RequiredFlag < 0) or HasFlag(FPR.Continuation, RequiredFlag) then
      begin
        SetLength(OutFlags, Length(FPR.Continuation));
        for k := 0 to High(FPR.Continuation) do
          OutFlags[k] := FPR.Continuation[k];
        Exit(True);
      end;
  end;
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
  NeedsConv: boolean;
begin
  Result := S;
  if Length(FIconvFrom) = 0 then Exit;
  // Skip conversion when no byte in the string can start any ICONV pattern
  NeedsConv := False;
  for i := 1 to Length(S) do
    if FIconvFirstBytes[Ord(S[i])] then
    begin
      NeedsConv := True;
      Break;
    end;
  if not NeedsConv then Exit;
  for i := 0 to High(FIconvFrom) do
    Result := StringReplace(Result, FIconvFrom[i], FIconvTo[i], [rfReplaceAll]);
end;

function THunSpellChecker.ApplyOconv(const S: string): string;
var
  i: integer;
begin
  Result := S;
  if Length(FOCONVFrom) = 0 then Exit;
  for i := 0 to High(FOCONVFrom) do
    Result := StringReplace(Result, FOCONVFrom[i], FOCONVTo[i], [rfReplaceAll]);
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

function THunSpellChecker.IsNumericWord(const S: string): boolean;
var
  i: integer;
  Ch: string;
begin
  Result := False;
  if S = '' then Exit;
  for i := 1 to UTF8Length(S) do
  begin
    Ch := UTF8Copy(S, i, 1);
    if (Length(Ch) <> 1) or not CharInSet(Ch[1], ['0'..'9']) then Exit;
  end;
  Result := True;
end;

function THunSpellChecker.IsNoSuggestWord(const Flags: TIntegerArray): boolean;
begin
  Result := (FNoSuggestFlag >= 0) and HasFlag(Flags, FNoSuggestFlag);
end;

function THunSpellChecker.IsForbiddenWord(const Flags: TIntegerArray): boolean;
begin
  Result := (FForbiddenWordFlag >= 0) and HasFlag(Flags, FForbiddenWordFlag);
end;

// Helper: check if a candidate compound part passes CHECKCOMPOUNDPATTERN
function THunSpellChecker.MatchesCompoundPattern(const LeftPart, RightPart: string; const LeftFlags, RightFlags: TIntegerArray): boolean;
var
  pi, i: integer;
  P: TCompoundPattern;
  OkEnd, OkBegin: boolean;
begin
  Result := False;
  for pi := 0 to High(FCheckCompoundPatterns) do
  begin
    P := FCheckCompoundPatterns[pi];
    OkEnd := False;
    OkBegin := False;

    if (P.EndChars <> '') and ByteEndsWith(P.EndChars, LeftPart) then OkEnd := True
    else if Length(P.EndFlags) > 0 then
    begin
      for i := 0 to High(P.EndFlags) do
        if HasFlag(LeftFlags, P.EndFlags[i]) then
        begin
          OkEnd := True;
          Break;
        end;
    end;

    if (P.BeginChars <> '') and ByteStartsWith(P.BeginChars, RightPart) then OkBegin := True
    else if Length(P.BeginFlags) > 0 then
    begin
      for i := 0 to High(P.BeginFlags) do
        if HasFlag(RightFlags, P.BeginFlags[i]) then
        begin
          OkBegin := True;
          Break;
        end;
    end;

    if OkEnd and OkBegin then Exit(True);
  end;
end;

// Find a compound part: a dictionary entry or a derived form via TryDerive,
// which uses continuation flags to chain suffixes and prefixes
function THunSpellChecker.TryGetPartFlags(const Part: string; out OutFlags: TIntegerArray): boolean;
var
  Count: integer = 0;
  TempFlags: TIntegerArray = nil;
begin
  Result := TryDerive(Part, 0, True, -1, OutFlags);
  if Result then Exit;

  // A nested compound only makes sense when compound flags are defined
  if (FCompoundFlag < 0) and (FCompoundBegin < 0) and (FCompoundMiddle < 0) and (FCompoundEnd < 0) then Exit;

  if FCompoundRecurse >= 1 then Exit;
  Inc(FCompoundRecurse);
  try
    if TryCompoundWordRec(Part, 0) then
    begin
      SetLength(TempFlags, 4);
      if FCompoundFlag >= 0 then
      begin
        TempFlags[Count] := FCompoundFlag;
        Inc(Count);
      end;
      if FCompoundBegin >= 0 then
      begin
        TempFlags[Count] := FCompoundBegin;
        Inc(Count);
      end;
      if FCompoundMiddle >= 0 then
      begin
        TempFlags[Count] := FCompoundMiddle;
        Inc(Count);
      end;
      if FCompoundEnd >= 0 then
      begin
        TempFlags[Count] := FCompoundEnd;
        Inc(Count);
      end;
      SetLength(TempFlags, Count);
      OutFlags := TempFlags;
      Result := True;
    end;
  finally
    Dec(FCompoundRecurse);
  end;
end;

function THunSpellChecker.PartCanCompoundLeft(const Flags: TIntegerArray): boolean;
begin
  Result := False;
  if (FCompoundFlag >= 0) and HasFlag(Flags, FCompoundFlag) then Exit(True);
  if (FCompoundBegin >= 0) and HasFlag(Flags, FCompoundBegin) then Exit(True);
end;

function THunSpellChecker.PartCanCompoundMiddle(const Flags: TIntegerArray): boolean;
begin
  Result := False;
  if (FCompoundFlag >= 0) and HasFlag(Flags, FCompoundFlag) then Exit(True);
  if (FCompoundMiddle >= 0) and HasFlag(Flags, FCompoundMiddle) then Exit(True);
end;

function THunSpellChecker.PartCanCompoundRight(const Flags: TIntegerArray): boolean;
begin
  Result := False;
  if (FCompoundFlag >= 0) and HasFlag(Flags, FCompoundFlag) then Exit(True);
  if (FCompoundEnd >= 0) and HasFlag(Flags, FCompoundEnd) then Exit(True);
end;

function THunSpellChecker.TryCompoundWord(const word: string): boolean;
var
  LowerWord: string;
begin
  Result := False;
  if word = '' then Exit;
  // A capitalised compound is also checked in lowercase form
  LowerWord := UTF8LowerCase(word);
  if LowerWord <> word then
    if TryCompoundWord(LowerWord) then Exit(True);
  Result := TryCompoundWordRec(word, 0);
end;

// Recursive compound splitter. Depth 0 splits the first part, deeper levels split
// the rest. The maximum number of parts is limited by COMPOUNDWORDMAX when present,
// otherwise by an internal limit of 4.
function THunSpellChecker.TryCompoundWordRec(const word: string; depth: integer): boolean;
var
  i, lenWord, minPart, maxParts: integer;
  leftPart, rightPart: string;
  leftFlags: TIntegerArray = ();
  rightFlags: TIntegerArray = ();
  leftOk: boolean;
  LastLeft: string;
  FirstRight: string;
begin
  Result := False;
  if word = '' then Exit;

  maxParts := FCompoundWordMax;
  if maxParts < 2 then maxParts := 4;
  if depth >= maxParts - 1 then Exit;

  lenWord := UTF8Length(word);
  if lenWord < 2 then Exit;

  minPart := FCompoundMin;
  if minPart < 1 then minPart := 1;
  if lenWord < minPart * 2 then Exit;

  for i := minPart to lenWord - minPart do
  begin
    leftPart := UTF8Copy(word, 1, i);
    rightPart := UTF8Copy(word, i + 1, MaxInt);

    // CHECKCOMPOUNDDUP: reject identical adjacent parts
    if FCheckCompoundDup and (leftPart = rightPart) then Continue;

    // CHECKCOMPOUNDCASE: reject a compound border that mixes letter cases
    if FCheckCompoundCase and (leftPart <> '') and (rightPart <> '') then
    begin
      LastLeft := UTF8Copy(leftPart, UTF8Length(leftPart), 1);
      FirstRight := UTF8Copy(rightPart, 1, 1);
      if (LastLeft = UTF8UpperCase(LastLeft)) and (LastLeft <> UTF8LowerCase(LastLeft)) then
        Continue;
      if (FirstRight = UTF8UpperCase(FirstRight)) and (FirstRight <> UTF8LowerCase(FirstRight)) then
        Continue;
    end;

    // Left part: dictionary entry or suffix-derived form
    if not TryGetPartFlags(leftPart, leftFlags) then Continue;

    if depth = 0 then
      leftOk := PartCanCompoundLeft(leftFlags)
    else
      leftOk := PartCanCompoundMiddle(leftFlags);
    if not leftOk then Continue;

    // Option 1: right part is the final part of the compound
    if TryGetPartFlags(rightPart, rightFlags) then
    begin
      if PartCanCompoundRight(rightFlags) then
      begin
        if not MatchesCompoundPattern(leftPart, rightPart, leftFlags, rightFlags) then
        begin
          Result := True;
          Exit;
        end;
      end
      else
      begin
        // Fallback: if the right part is a valid word without Cc, allow it
        // This handles dictionaries where plural or derived forms do not inherit COMPOUNDEND
        if not IsNoSuggestWord(rightFlags) and not IsForbiddenWord(rightFlags) then
        begin
          if not MatchesCompoundPattern(leftPart, rightPart, leftFlags, rightFlags) then
          begin
            Result := True;
            Exit;
          end;
        end;
      end;
    end;

    // Option 2: right part contains further compound parts
    if TryCompoundWordRec(rightPart, depth + 1) then Exit(True);
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
      if ByteStartsWith(searchStr, word) then
      begin
        rightPart := UTF8Copy(word, UTF8Length(searchStr) + 1, MaxInt);
        if rightPart <> '' then
          if CheckWordCore(rightPart, False) then Exit(True);
      end;
    end
    else if (Length(pattern) > 0) and (pattern[Length(pattern)] = '$') then
    begin
      if ByteEndsWith(searchStr, word) then
      begin
        leftPart := UTF8Copy(word, 1, UTF8Length(word) - UTF8Length(searchStr));
        if leftPart <> '' then
          if CheckWordCore(leftPart, False) then Exit(True);
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
          if CheckWordCore(leftPart, False) and CheckWordCore(rightPart, False) then Exit(True);
        end;
        pos := UTF8Pos(searchStr, word, pos + 1);
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------------
// Word checking
// ---------------------------------------------------------------------------------

// Core check for a single form. Assumes the word has already been iconv-cleaned
// and had IGNORE characters removed. Handles direct lookup, lowercase fallback,
// affix derivation, compound words and BREAK patterns.
function THunSpellChecker.CheckWordCore(const word: string; AllowBreak: boolean): boolean;
var
  idx: integer;
  LowerWord: string;
  Flags: TIntegerArray;
  DerivedFlags: TIntegerArray = nil;
  KeepCase: boolean;
begin
  if word = '' then Exit(False);
  // A word made of digits only is always considered valid
  if IsNumericWord(word) then Exit(True);

  // Direct match in DIC
  if HashFind(word, idx) then
  begin
    Flags := FWords[idx].Flags;
    if not IsForbiddenWord(Flags) then
    begin
      if not ((FOnlyInCompoundFlag >= 0) and HasFlag(Flags, FOnlyInCompoundFlag)) and not
        ((FNeedAffixFlag >= 0) and HasFlag(Flags, FNeedAffixFlag)) and not ((FPseudoRootFlag >= 0) and
        HasFlag(Flags, FPseudoRootFlag)) then
        Exit(True);
    end;
  end;

  if IsCompoundNumber(word) then Exit(True);

  // Lowercase fallback, but not for KEEPCASE entries
  LowerWord := UTF8LowerCase(word);
  if LowerWord <> word then
  begin
    if HashFind(LowerWord, idx) then
    begin
      Flags := FWords[idx].Flags;
      KeepCase := (FKeepCaseFlag >= 0) and HasFlag(Flags, FKeepCaseFlag);
      if not KeepCase then
      begin
        if not IsForbiddenWord(Flags) and not ((FOnlyInCompoundFlag >= 0) and HasFlag(Flags, FOnlyInCompoundFlag)) and
          not ((FNeedAffixFlag >= 0) and HasFlag(Flags, FNeedAffixFlag)) and not
          ((FPseudoRootFlag >= 0) and HasFlag(Flags, FPseudoRootFlag)) then
          Exit(True);
      end;
    end;
  end;

  // Derived forms via affixes with continuation flag chaining
  if TryDerive(word, 0, False, -1, DerivedFlags) then Exit(True);
  if (LowerWord <> word) and TryDerive(LowerWord, 0, False, -1, DerivedFlags) then Exit(True);

  if AllowBreak and (FBreakPatterns.Count > 0) then
    if TryBreakWord(word) then Exit(True);

  if (FCompoundFlag >= 0) or (FCompoundBegin >= 0) or (FCompoundMiddle >= 0) or (FCompoundEnd >= 0) then
    if TryCompoundWord(word) then Exit(True);

  Result := False;
end;

// Public entry point for a single token. If the token ends with trailing dots
// (which can happen when '.' is part of WORDCHARS, as in the Dutch dictionary)
// and the raw form is not found, the dots are stripped and the check is retried.
function THunSpellChecker.CheckWordInternal(const word: string; AllowBreak: boolean): boolean;
var
  CleanWord: string;
  TrimmedWord: string;
  TailChar: string;
  TailCode: cardinal;
  InWordChars: boolean;
  IsLetterOrDigit: boolean;
  i: integer;
begin
  CleanWord := ApplyIconv(word);
  CleanWord := RemoveIgnoreChars(CleanWord, FIgnoreChars);

  if CheckWordCore(CleanWord, AllowBreak) then Exit(True);

  // Strip trailing punctuation that is listed in WORDCHARS and retry
  // This handles cases like "parametrar:" where ':' is a word character
  TrimmedWord := CleanWord;
  while TrimmedWord <> '' do
  begin
    TailChar := UTF8Copy(TrimmedWord, UTF8Length(TrimmedWord), 1);
    TailCode := FirstCodepoint(TailChar);

    IsLetterOrDigit := False;
    {$NOTES OFF}
    if TailCode <= $FFFF then
      IsLetterOrDigit := TCharacter.IsLetterOrDigit(widechar(TailCode));
    {$NOTES ON}
    if IsLetterOrDigit then Break;

    InWordChars := False;
    for i := 0 to High(FWordCharsCodes) do
      if FWordCharsCodes[i] = TailCode then
      begin
        InWordChars := True;
        Break;
      end;
    if not InWordChars then Break;

    UTF8Delete(TrimmedWord, UTF8Length(TrimmedWord), 1);
  end;

  if (TrimmedWord <> '') and (TrimmedWord <> CleanWord) then
    Result := CheckWordCore(TrimmedWord, AllowBreak)
  else
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
  ChStr: string = '';
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

  // Any character that has an ICONV mapping is also treated as part of a word
  // Fast path: skip the loop when the first byte cannot match any ICONV source
  if Length(FIconvFrom) > 0 then
  begin
    if not FIconvFirstBytes[Ord(Ch^)] then Exit(False);
    SetLength(ChStr, CharLen);
    Move(Ch^, ChStr[1], CharLen);
    for i := 0 to High(FIconvFrom) do
      if FIconvFrom[i] = ChStr then Exit(True);
  end;

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
    // Abort quickly if an external cancellation was requested
    if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
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
          if FIncludeSuggestions then
            Err.Replacements := Suggest(word)
          else
            SetLength(Err.Replacements, 0);
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
      if FIncludeSuggestions then
        Err.Replacements := Suggest(word)
      else
        SetLength(Err.Replacements, 0);
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
  SetLength(FAllWordsLowerWide, FWordCount);
  SetLength(FAllWordsFirstChar, FWordCount);
  MaxLen := 0;

  for i := 0 to FWordCount - 1 do
  begin
    FAllWords[i] := FWords[i].word;
    FAllWordsLower[i] := UTF8LowerCase(FAllWords[i]);
    FAllWordsLowerWide[i] := UTF8Decode(FAllWordsLower[i]);
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
    for r := 0 to Group.SuffixCount - 1 do
    begin
      RuleS := Group.Suffixes[r];
      if (RuleS.Strip <> '') and (not ByteEndsWith(RuleS.Strip, BaseWord)) then Continue;
      if not MatchesCondition(RuleS.Condition, RuleS.WideCondition, BaseWord, False) then Continue;
      Stripped := BaseWord;
      if RuleS.Strip <> '' then
        Delete(Stripped, Length(Stripped) - Length(RuleS.Strip) + 1, Length(RuleS.Strip));
      Form := Stripped + RuleS.Add;
      Dist := LevenshteinDistanceLimited(TargetWordLower, UTF8LowerCase(Form), 2);
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
    for r := 0 to Group.PrefixCount - 1 do
    begin
      RuleP := Group.Prefixes[r];
      if (RuleP.Strip <> '') and (not ByteStartsWith(RuleP.Strip, BaseWord)) then Continue;
      if not MatchesCondition(RuleP.Condition, RuleP.WideCondition, BaseWord, True) then Continue;
      Stripped := BaseWord;
      if RuleP.Strip <> '' then
        Delete(Stripped, 1, Length(RuleP.Strip));
      Form := RuleP.Add + Stripped;
      Dist := LevenshteinDistanceLimited(TargetWordLower, UTF8LowerCase(Form), 2);
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

// String wrapper: decodes both operands and calls the wide version
function THunSpellChecker.LevenshteinDistanceLimited(const S1, S2: string; MaxDist: integer): integer;
begin
  Result := LevenshteinWideLimited(UTF8Decode(S1), UTF8Decode(S2), MaxDist);
end;

// Wide-string distance with the band-limit optimization. Callers that already
// have decoded wide strings avoid the decode cost on every comparison
function THunSpellChecker.LevenshteinWideLimited(const W1, W2: widestring; MaxDist: integer): integer;
var
  Len1, Len2, i, j, Prev, Cur, Tmp, Cost, RowMin: integer;
  LocalW1: widestring;
  LocalW2: widestring;
  PrevRow, CurRow: TIntegerArray;
begin
  LocalW1 := W1;
  LocalW2 := W2;
  Len1 := Length(LocalW1);
  Len2 := Length(LocalW2);
  PrevRow := nil;
  CurRow := nil;

  if Abs(Len1 - Len2) > MaxDist then Exit(MaxDist + 1);

  if Len1 < Len2 then
  begin
    Tmp := Len1;
    Len1 := Len2;
    Len2 := Tmp;
    LocalW1 := W2;
    LocalW2 := W1;
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
      if LocalW1[i] = LocalW2[j] then Cost := 0
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
            AddWeightedSuggestion(Weighted, NewWord, LevenshteinDistanceLimited(CleanWord, NewWord, 2));
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
            AddWeightedSuggestion(Weighted, NewWord, LevenshteinDistanceLimited(CleanWord, NewWord, 2));
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
      if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
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
                AddWeightedSuggestion(Weighted, cand, LevenshteinDistanceLimited(CleanWord, cand, 2));
          end;
        end;
      end;
    end;
  end;

  for i := 1 to UTF8Length(CleanWord) do
  begin
    if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
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
              AddWeightedSuggestion(Weighted, cand, LevenshteinDistanceLimited(CleanWord, cand, 2));
        end;
        if pos < UTF8Length(Group) then
        begin
          Neighbor := UTF8Copy(Group, pos + 1, 1);
          cand := UTF8Copy(CleanWord, 1, i - 1) + Neighbor + UTF8Copy(CleanWord, i + 1, MaxInt);
          if HashFind(cand, FoundIndex) then
            if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
              AddWeightedSuggestion(Weighted, cand, LevenshteinDistanceLimited(CleanWord, cand, 2));
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
            AddWeightedSuggestion(Weighted, cand, LevenshteinDistanceLimited(CleanWord, cand, 2));
      end;
    end;
  end;

  for i := 1 to UTF8Length(CleanWord) do
  begin
    if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
    cand := UTF8Copy(CleanWord, 1, i - 1) + UTF8Copy(CleanWord, i + 1, MaxInt);
    if HashFind(cand, FoundIndex) then
      if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
        AddWeightedSuggestion(Weighted, cand, LevenshteinDistanceLimited(CleanWord, cand, 2));
  end;

  for i := 1 to UTF8Length(CleanWord) - 1 do
  begin
    cand := UTF8Copy(CleanWord, 1, i - 1) + UTF8Copy(CleanWord, i + 1, 1) + UTF8Copy(CleanWord, i, 1) + UTF8Copy(CleanWord, i + 2, MaxInt);
    if HashFind(cand, FoundIndex) then
      if not IsNoSuggestWord(FWords[FoundIndex].Flags) and not IsForbiddenWord(FWords[FoundIndex].Flags) then
        AddWeightedSuggestion(Weighted, cand, LevenshteinDistanceLimited(CleanWord, cand, 2));
  end;
end;

// Scans the dictionary buckets and uses the pre-decoded wide lowercase forms
// so LevenshteinWideLimited does not decode candidates again
procedure THunSpellChecker.ProcessDictionaryScan(const CleanWord: string; var Weighted: TWeightedSuggestionArray);
var
  TargetLower, TargetPrefix: string;
  TargetLowerWide: widestring;
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
  TargetLowerWide := UTF8Decode(TargetLower);

  MinLen := Max(0, TargetLen - 2);
  MaxLen := TargetLen + 2;
  if MaxLen > High(FLengthBuckets) then MaxLen := High(FLengthBuckets);

  for Len := MinLen to MaxLen do
  begin
    if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
    for BucketIdx := 0 to High(FLengthBuckets[Len]) do
    begin
      WordIndex := FLengthBuckets[Len][BucketIdx];
      if (TargetFirstCode <> 0) and (FAllWordsFirstChar[WordIndex] <> TargetFirstCode) then Continue;
      Dist := LevenshteinWideLimited(TargetLowerWide, FAllWordsLowerWide[WordIndex], 2);
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
    if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
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
      Dist := LevenshteinWideLimited(TargetLowerWide, FAllWordsLowerWide[WordIndex], 4);
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
  FirstChar: string;
begin
  SourceLower := UTF8LowerCase(Source);
  SourceUpper := UTF8UpperCase(Source);
  FirstChar := UTF8Copy(Source, 1, 1);
  SrcFirstUp := (Source <> '') and (FirstChar = UTF8UpperCase(FirstChar));

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
  CleanWord := RemoveIgnoreChars(CleanWord, FIgnoreChars);
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
  if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
  GenerateTryKeyCandidates(CleanWord, Weighted);
  if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
  ProcessDictionaryScan(CleanWord, Weighted);
  if (FCancelFlag <> nil) and (FCancelFlag^ <> 0) then Exit;
  SortWeightedSuggestions(Weighted);

  UniqueResults := TStringList.Create;
  try
    UniqueResults.Sorted := True;
    UniqueResults.Duplicates := dupIgnore;
    SetLength(Result, 0);
    for i := 0 to High(Weighted) do
    begin
      Adjusted := AdjustCase(word, Weighted[i].S);
      Adjusted := ApplyOconv(Adjusted);
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
  // Guard against unbounded growth of the suggestion cache
  if FSuggestCache.Count >= 20000 then FSuggestCache.Clear;
  if CachedValue <> '' then
    FSuggestCache.Add(CleanWord + '=' + CachedValue);
end;

end.
